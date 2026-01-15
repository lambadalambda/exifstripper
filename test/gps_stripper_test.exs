# SPDX-License-Identifier: MIT

defmodule ExifStripper.GpsStripperTest do
  use ExUnit.Case, async: true

  alias ExifStripper.GpsStripper

  describe "strip_gps_data/2" do
    test "strips GPS data from JPEG, PNG, WebP and HEIC" do
      for ext <- ~w(jpg png webp heic) do
        fixture = fixture_path("strip_location_gps.#{ext}")
        tmp_path = copy_to_tmp(fixture)

        assert exiftool_gps_tags(tmp_path) != ""
        assert :ok = GpsStripper.strip_gps_data(tmp_path, tmp_path)
        assert exiftool_gps_tags(tmp_path) == ""
      end
    end

    test "returns :noop for images without GPS metadata" do
      for fixture <- [
            fixture_path("image.jpg"),
            fixture_path("image.png"),
            fixture_path("image.webp"),
            fixture_path("image.heic")
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

  defp exiftool_gps_tags(file_path) do
    {output, 0} = System.cmd("exiftool", ["-m", "-gps:all", file_path])
    String.trim(output)
  end
end
