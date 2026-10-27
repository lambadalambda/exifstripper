# SPDX-License-Identifier: MIT

defmodule ExifStripper.GpsStripperTest do
  use ExUnit.Case, async: true

  alias ExifStripper.GpsStripper

  describe "strip_gps_data/2" do
    test "strips GPS data from JPEG, PNG, WebP and HEIC" do
      for name <- ~w(jpg png webp heic) |> Enum.map(&"strip_location_gps.#{&1}") do
        fixture = fixture_path(name)
        tmp_path = copy_to_tmp(fixture)

        assert exiftool_gps_tags(tmp_path) != ""
        assert :ok = GpsStripper.strip_gps_data(tmp_path, tmp_path)
        assert exiftool_gps_tags(tmp_path) == ""
      end
    end

    test "wipes recoverable GPS payloads while preserving non-GPS EXIF" do
      marker = "private GPS processing method " <> String.duplicate("sensitive", 30)

      for ext <- ~w(jpg webp heic) do
        path = copy_to_tmp(fixture_path("strip_location_gps.#{ext}"))
        on_exit(fn -> File.rm(path) end)

        {_, 0} =
          System.cmd("exiftool", [
            "-overwrite_original",
            "-GPSProcessingMethod=#{marker}",
            "-Orientation#=6",
            "-ImageDescription=Keep this description",
            path
          ])

        {original_tiff, 0} = System.cmd("exiftool", ["-b", "-EXIF", path])
        {pointer_offset, pointer} = gps_pointer(original_tiff)
        assert exiftool_gps_tags(path) =~ "GPS Latitude"
        assert :binary.match(File.read!(path), marker) != :nomatch

        assert :ok = GpsStripper.strip_gps_data(path, path)
        stripped = File.read!(path)
        assert :binary.match(stripped, marker) == :nomatch
        assert exiftool_gps_tags(path) == ""
        assert {"6\n", 0} = System.cmd("exiftool", ["-s3", "-Orientation#", path])
        assert ExifStripper.Description.read_file(path) == "Keep this description"

        # Restoring even the ORIGINAL pointer (stronger than scanning standard
        # GPS signatures) must not recover coordinates or other GPS values.
        {tiff, 0} = System.cmd("exiftool", ["-b", "-EXIF", path])

        restored =
          binary_part(tiff, 0, pointer_offset) <>
            pointer <>
            binary_part(tiff, pointer_offset + 12, byte_size(tiff) - pointer_offset - 12)

        File.write!(path, :binary.replace(stripped, tiff, restored))
        assert exiftool_gps_tags(path) == ""
      end
    end

    test "strips GPS data from a gridded HEIC (iloc items with construction method 1)" do
      tmp_path = copy_to_tmp(fixture_path("strip_location_gps_grid.heic"))

      assert exiftool_gps_tags(tmp_path) != ""
      assert :ok = GpsStripper.strip_gps_data(tmp_path, tmp_path)
      assert exiftool_gps_tags(tmp_path) == ""
    end

    test "drops data after the PNG IEND chunk" do
      trailer = "trailing data after IEND"
      tmp_path = copy_to_tmp(fixture_path("strip_location_gps.png"))
      File.write!(tmp_path, File.read!(tmp_path) <> trailer)

      assert :ok = GpsStripper.strip_gps_data(tmp_path, tmp_path)
      assert exiftool_gps_tags(tmp_path) == ""
      assert :binary.match(File.read!(tmp_path), trailer) == :nomatch

      tmp_path = copy_to_tmp(fixture_path("image_with_stray_data_after.png"))
      assert :ok = GpsStripper.strip_gps_data(tmp_path, tmp_path)

      assert String.ends_with?(
               File.read!(tmp_path),
               <<0, 0, 0, 0, "IEND", 0xAE, 0x42, 0x60, 0x82>>
             )
    end

    test "returns :noop for images without GPS metadata" do
      for fixture <- [
            fixture_path("image.jpg"),
            fixture_path("image.png"),
            fixture_path("image.webp"),
            fixture_path("image.heic"),
            fixture_path("image_grid.heic")
          ] do
        original = File.read!(fixture)
        tmp_path = copy_to_tmp(fixture)

        assert exiftool_gps_tags(tmp_path) == ""
        assert :noop = GpsStripper.strip_gps_data(tmp_path, tmp_path)
        assert File.read!(tmp_path) == original
      end
    end

    test "returns :noop for unsupported image types" do
      for fixture <- [fixture_path("image.gif"), fixture_path("image.svg")] do
        original = File.read!(fixture)
        tmp_path = copy_to_tmp(fixture)

        assert :noop = GpsStripper.strip_gps_data(tmp_path, tmp_path)
        assert File.read!(tmp_path) == original
      end
    end
  end

  defp fixture_path(name), do: Path.expand("fixtures/#{name}", __DIR__)

  defp copy_to_tmp(source_path) do
    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "exif_stripper_strip_location_#{System.unique_integer([:positive])}#{Path.extname(source_path)}"
      )

    File.cp!(source_path, tmp_path)
    tmp_path
  end

  defp gps_pointer(tiff) do
    endian = if binary_part(tiff, 0, 2) == "II", do: :little, else: :big
    uint = fn offset, size -> :binary.decode_unsigned(binary_part(tiff, offset, size), endian) end
    offset = uint.(4, 4)
    count = uint.(offset, 2)

    pos =
      Enum.find_value(0..(count - 1), fn i ->
        pos = offset + 2 + i * 12
        if uint.(pos, 2) == 0x8825, do: pos
      end)

    {pos, binary_part(tiff, pos, 12)}
  end

  defp exiftool_gps_tags(file_path) do
    {output, 0} = System.cmd("exiftool", ["-m", "-gps:all", file_path])
    String.trim(output)
  end
end
