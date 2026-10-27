# SPDX-License-Identifier: MIT

defmodule ExifStripper.PathApiTest do
  use ExUnit.Case, async: true

  alias ExifStripper.GpsStripper

  @fixtures Path.wildcard(Path.expand("fixtures/*", __DIR__))

  # Inputs beyond the fixtures: trailing PNG data, a GPS JPEG with a bad pointer.
  defp inputs do
    png = File.read!(fixture("strip_location_gps.png"))
    jpeg = File.read!(fixture("strip_location_gps.jpg"))
    {pos, _} = :binary.match(jpeg, <<0x88, 0x25>>)

    Enum.map(@fixtures, &{Path.basename(&1), File.read!(&1)}) ++
      [
        {"png_trailer.png", png <> "trailing data"},
        {"bad_gps_pointer.jpg", replace(jpeg, pos + 8, <<0xFF, 0xFF, 0xFF, 0xFF>>)},
        {"truncated.png", binary_part(png, 0, byte_size(png) - 20)},
        {"empty", <<>>}
      ]
  end

  test "the path API gives the same results as the binary API, in place" do
    for {name, data} <- inputs() do
      path = tmp_file(name, data)
      expected = GpsStripper.strip_gps_data(data)

      case expected do
        {:ok, stripped} ->
          assert :ok = GpsStripper.strip_gps_data(path, path), name
          assert File.read!(path) == stripped, name

        other ->
          assert GpsStripper.strip_gps_data(path, path) == other, name
          assert File.read!(path) == data, name
      end
    end
  end

  test "the path API gives the same results as the binary API, to another file" do
    for {name, data} <- inputs() do
      input = tmp_file(name, data)
      output = tmp_path(name)
      expected = GpsStripper.strip_gps_data(data)

      case expected do
        {:ok, stripped} ->
          assert :ok = GpsStripper.strip_gps_data(input, output), name
          assert File.read!(output) == stripped, name

        other ->
          assert GpsStripper.strip_gps_data(input, output) == other, name
          refute File.exists?(output), name
      end

      assert File.read!(input) == data, name
    end
  end

  test "errors leave an existing output file unchanged" do
    {_, data} = Enum.find(inputs(), &(elem(&1, 0) == "bad_gps_pointer.jpg"))
    input = tmp_file("bad.jpg", data)
    output = tmp_file("out.jpg", "previous output")

    assert {:error, _} = GpsStripper.strip_gps_data(input, output)
    assert File.read!(output) == "previous output"
  end

  test "patches in place when both paths name the same file differently" do
    for name <- ~w(strip_location_gps.jpg strip_location_gps.png) do
      data = File.read!(fixture(name))
      path = tmp_file(name, data)
      other = Path.join([Path.dirname(path), ".", Path.basename(path)])
      assert {:ok, expected} = GpsStripper.strip_gps_data(data)

      assert :ok = GpsStripper.strip_gps_data(path, other)
      assert File.read!(path) == expected
    end
  end

  test "keeps the file mode when a PNG is rewritten" do
    path = tmp_file("mode.png", File.read!(fixture("strip_location_gps.png")))
    File.chmod!(path, 0o640)

    assert :ok = GpsStripper.strip_gps_data(path, path)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o640
    assert Path.wildcard(Path.join(Path.dirname(path), ".*mode.png*.tmp")) == []
  end

  test "keeps JPEG fill bytes before markers" do
    <<0xFF, 0xD8, rest::binary>> = File.read!(fixture("strip_location_gps.jpg"))
    data = <<0xFF, 0xD8, 0xFF, 0xFF>> <> rest
    path = tmp_file("fill.jpg", data)

    assert {:ok, <<0xFF, 0xD8, 0xFF, 0xFF, _::binary>> = stripped} =
             GpsStripper.strip_gps_data(data)

    assert byte_size(stripped) == byte_size(data)
    assert :ok = GpsStripper.strip_gps_data(path, path)
    assert File.read!(path) == stripped
  end

  test "writes a separate output atomically, without leaving temporary files" do
    for name <- ~w(strip_location_gps.jpg strip_location_gps.png) do
      dir = tmp_path("dir")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      input = tmp_file(name, File.read!(fixture(name)))
      output = Path.join(dir, "out")
      File.write!(output, "previous")

      assert :ok = GpsStripper.strip_gps_data(input, output)
      assert {:ok, File.read!(output)} == GpsStripper.strip_gps_data(File.read!(input))
      assert File.ls!(dir) == ["out"]
    end
  end

  test "returns an error for a missing input file" do
    assert {:error, _} = GpsStripper.strip_gps_data(tmp_path("missing.jpg"), tmp_path("out"))
  end

  defp fixture(name), do: Path.expand("fixtures/#{name}", __DIR__)

  defp tmp_path(name) do
    path =
      Path.join(System.tmp_dir!(), "exif_path_api_#{System.unique_integer([:positive])}_#{name}")

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp tmp_file(name, data) do
    path = tmp_path(name)
    File.write!(path, data)
    path
  end

  defp replace(data, offset, bytes) do
    binary_part(data, 0, offset) <>
      bytes <>
      binary_part(data, offset + byte_size(bytes), byte_size(data) - offset - byte_size(bytes))
  end
end
