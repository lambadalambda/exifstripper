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

  # 0.1.2 handled these in memory; the path API must not need one system call
  # per small segment, chunk or patch.
  test "uses few file operations for many small segments, chunks and patches" do
    exif =
      "Exif\0\0" <>
        <<"II", 42::16-little, 8::32-little, 1::16-little, 0x8825::16-little, 4::16-little,
          1::32-little, 26::32-little, 0::32-little, 1::16-little, 1::16-little, 2::16-little,
          2::32-little, "N\0", 0::16, 0::32>>

    segment = <<0xFF, 0xE1, byte_size(exif) + 2::16>> <> exif
    jpeg = <<0xFF, 0xD8>> <> :binary.copy(segment, 1000) <> <<0xFF, 0xDA, 0, 2, 0xFF, 0xD9>>

    too_many =
      <<0xFF, 0xD8>> <> :binary.copy(segment, 1100) <> <<0xFF, 0xDA, 0, 2, 0xFF, 0xD9>>

    assert {:error, :too_many_metadata_segments} = GpsStripper.strip_gps_data(too_many)

    chunk = "EXIF" <> <<byte_size(exif)::32-little>> <> exif
    webp = fn n -> "RIFF" <> <<0::32>> <> "WEBP" <> :binary.copy(chunk, n) end
    assert {:ok, _} = GpsStripper.strip_gps_data(webp.(1000))
    assert {:error, :too_many_metadata_segments} = GpsStripper.strip_gps_data(webp.(1100))

    pair = <<0::32, "tEXt", 0::32, 0::32, "abcd", 0::32>>
    signature = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
    png = signature <> :binary.copy(pair, 20_000) <> <<0::32, "IEND", 0::32>>

    for {name, data} <- [{"many.jpg", jpeg}, {"many.png", png}], in_place? <- [true, false] do
      input = tmp_file(name, data)
      output = if in_place?, do: input, else: input <> ".out"
      on_exit(fn -> File.rm(input <> ".out") end)
      assert {:ok, expected} = GpsStripper.strip_gps_data(data)

      {result, calls} = traced_calls(fn -> GpsStripper.strip_gps_data(input, output) end)
      assert result == :ok
      assert File.read!(output) == expected
      assert operations(calls) < 100, "#{name}: #{operations(calls)} file operations"
    end
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
    {result, calls} = traced_calls(fun)

    reads =
      for call <- calls, size = read_size(call), size != nil, do: size

    {result, reads}
  end

  defp read_size({:pread, [_fd, _pos, size]}), do: size
  defp read_size({:read, [_fd, size]}), do: size
  defp read_size({:read_file, [path]}), do: File.stat!(path).size
  defp read_size(_call), do: nil

  # File operations: reads, writes, and each element of a pwrite list.
  defp operations(calls) do
    Enum.sum(
      for call <- calls do
        case call do
          {:pwrite, [_fd, list]} -> length(list)
          _ -> 1
        end
      end
    )
  end

  # Returns the :file calls made by `fun` as {function, args}.
  defp traced_calls(fun) do
    patterns =
      [{:pread, 3}, {:read, 2}, {:read_file, 1}, {:pwrite, 2}, {:pwrite, 3}, {:write, 2}]
      |> Enum.map(fn {f, a} -> {:file, f, a} end)

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
    {result, collect_calls([])}
  end

  defp collect_calls(acc) do
    receive do
      {:trace, _, :call, {:file, function, args}} -> collect_calls([{function, args} | acc])
    after
      0 -> Enum.reverse(acc)
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
