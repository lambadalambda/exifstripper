# SPDX-License-Identifier: MIT

defmodule ExifStripper.BoundedReadsTest do
  # Not async: call tracing patterns are global to the node.
  use ExUnit.Case, async: false

  alias ExifStripper.GpsStripper

  @big 4_000_000

  # Only metadata may be read: the bulk image data stays on disk.
  for {name, max_read} <- [jpg: 300_000, webp: 300_000, heic: 300_000, tiff: 300_000] do
    test "reads only the metadata of a large #{name} file, in place" do
      data = large(unquote(name))
      path = tmp_file("large.#{unquote(name)}", data)
      assert {:ok, expected} = GpsStripper.strip_gps_data(data)

      {result, reads} = traced_reads(fn -> GpsStripper.strip_gps_data(path, path) end)

      assert result == :ok
      assert File.read!(path) == expected
      assert Enum.sum(reads) < unquote(max_read), "read #{Enum.sum(reads)} bytes"
    end
  end

  test "streams a large PNG in bounded pieces and skips removed chunks" do
    data = large(:png)
    path = tmp_file("large.png", data)
    assert {:ok, expected} = GpsStripper.strip_gps_data(data)

    {result, reads} = traced_reads(fn -> GpsStripper.strip_gps_data(path, path) end)

    assert result == :ok
    assert File.read!(path) == expected
    assert Enum.max(reads) <= 65_536
    # The removed tEXt chunk holds @big bytes and is never read.
    assert Enum.sum(reads) < byte_size(expected) + 300_000
  end

  defp large(:jpg) do
    jpeg = fixture("strip_location_gps.jpg")
    # Entropy-coded data after SOS, before EOI.
    binary_part(jpeg, 0, byte_size(jpeg) - 2) <> filler(@big) <> <<0xFF, 0xD9>>
  end

  defp large(:webp) do
    <<"RIFF", size::32-little, rest::binary>> = fixture("strip_location_gps.webp")
    chunk = "JUNK" <> <<@big::32-little>> <> filler(@big)
    "RIFF" <> <<size + byte_size(chunk)::32-little>> <> rest <> chunk
  end

  defp large(:heic), do: fixture("strip_location_gps.heic") <> box("free", filler(@big))
  defp large(:tiff), do: fixture("strip_location_gps.tiff") <> filler(@big)

  defp large(:png) do
    <<signature::binary-size(8), rest::binary>> = fixture("strip_location_gps.png")
    text = "tEXt" <> "Comment\0" <> filler(@big)
    idat_size = byte_size(rest) - 12
    <<header::binary-size(idat_size), iend::binary>> = rest
    big_idat = "IDAT" <> filler(@big)

    signature <>
      header <>
      <<byte_size(text) - 4::32>> <>
      text <>
      <<0::32>> <>
      <<byte_size(big_idat) - 4::32>> <> big_idat <> <<0::32>> <> iend
  end

  defp box(type, data), do: <<byte_size(data) + 8::32>> <> type <> data
  defp filler(size), do: :binary.copy(<<0x55>>, size)
  defp fixture(name), do: File.read!(Path.expand("fixtures/#{name}", __DIR__))

  # Returns the sizes of all file reads made by `fun`. A read of a whole file
  # counts as its size.
  defp traced_reads(fun) do
    patterns = [{:file, :pread, 3}, {:file, :read, 2}, {:file, :read_file, 1}]
    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:global]))

    # A process cannot trace itself: run `fun` in a traced task.
    task =
      Task.async(fn ->
        receive do
          :go -> fun.()
        end
      end)

    :erlang.trace(task.pid, true, [:call])
    send(task.pid, :go)

    result =
      try do
        Task.await(task, 30_000)
      after
        Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:global]))
      end

    ref = :erlang.trace_delivered(task.pid)
    assert_receive {:trace_delivered, _, ^ref}
    {result, collect_reads([])}
  end

  defp collect_reads(acc) do
    receive do
      {:trace, _, :call, {:file, :pread, [_fd, _pos, size]}} ->
        collect_reads([size | acc])

      {:trace, _, :call, {:file, :read, [_fd, size]}} ->
        collect_reads([size | acc])

      {:trace, _, :call, {:file, :read_file, [path]}} ->
        collect_reads([File.stat!(path).size | acc])
    after
      0 -> acc
    end
  end

  defp tmp_file(name, data) do
    path =
      Path.join(System.tmp_dir!(), "exif_reads_#{System.unique_integer([:positive])}_#{name}")

    on_exit(fn -> File.rm(path) end)
    File.write!(path, data)
    path
  end
end
