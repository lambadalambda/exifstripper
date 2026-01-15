# SPDX-License-Identifier: MIT

defmodule ExifStripper.DescriptionTest do
  use ExUnit.Case, async: true

  alias ExifStripper.Description

  test "reads ImageDescription from JPEG EXIF" do
    fixture = fixture_path("image_with_imagedescription_and_caption-abstract.jpg")
    expected = exiftool_tag(fixture, "ImageDescription")
    assert is_binary(expected)

    assert Description.read_file(fixture) == expected
  end

  test "prefers ImageDescription over Caption-Abstract when both are present" do
    fixture = fixture_path("image_with_imagedescription_and_caption-abstract.jpg")
    expected = exiftool_tag(fixture, "ImageDescription")
    assert is_binary(expected)

    assert Description.read_file(fixture) == expected
  end

  test "reads ImageDescription when image contains stray data after" do
    fixture =
      fixture_path("image_with_imagedescription_and_caption-abstract_and_stray_data_after.png")

    expected = exiftool_tag(fixture, "ImageDescription")
    assert is_binary(expected)

    assert Description.read_file(fixture) == expected

    fixture = fixture_path("image_with_stray_data_after.png")
    assert Description.read_file(fixture) == nil
  end

  test "reads iptc:Caption-Abstract when present in JPEG" do
    fixture = fixture_path("image_with_caption-abstract.jpg")
    expected = exiftool_tag(fixture, "Caption-Abstract")
    assert is_binary(expected)

    assert Description.read_file(fixture) == expected
  end

  test "reads ImageDescription from PNG EXIF chunk" do
    fixture = fixture_path("image_with_imagedescription_exif.png")
    expected = exiftool_tag(fixture, "ImageDescription")
    assert is_binary(expected)

    assert Description.read_file(fixture) == expected
  end

  test "reads iptc:Caption-Abstract from PNG zTXt profile" do
    fixture = fixture_path("image_with_caption-abstract.png")
    expected = exiftool_tag(fixture, "Caption-Abstract")
    assert is_binary(expected)

    assert Description.read_file(fixture) == expected
  end

  test "reads ImageDescription from WebP EXIF chunk" do
    fixture = fixture_path("strip_location_gps.webp")
    expected = exiftool_tag(fixture, "ImageDescription")
    assert is_binary(expected)

    assert Description.read_file(fixture) == expected
  end

  test "reads ImageDescription from HEIC EXIF item" do
    fixture = fixture_path("strip_location_gps.heic")
    expected = exiftool_tag(fixture, "ImageDescription")
    assert is_binary(expected)

    assert Description.read_file(fixture) == expected
  end

  test "reads ImageDescription from GIF XMP" do
    fixture = fixture_path("image_with_imagedescription_xmp.gif")
    expected = exiftool_tag(fixture, "ImageDescription")
    assert is_binary(expected)

    assert Description.read_file(fixture) == expected
  end

  test "returns nil for unsupported or missing metadata" do
    assert Description.read_file(fixture_path("image.svg")) == nil
    assert Description.read_file(fixture_path("image.gif")) == nil
    assert Description.read_file(fixture_path("image_with_no_description.jpg")) == nil
  end

  test "returns nil when the extracted description exceeds max_length" do
    fixture = fixture_path("image_with_imagedescription_and_caption-abstract.jpg")
    assert Description.read_file(fixture, max_length: 5) == nil
  end

  test "returns nil when the extracted description is only whitespace" do
    fixture = fixture_path("image_with_imagedescription_and_caption-abstract_whitespaces.jpg")
    assert Description.read_file(fixture) == nil
  end

  test "returns nil when the file can't be read" do
    assert Description.read_file(fixture_path("does-not-exist.jpg")) == nil
  end

  defp fixture_path(name), do: Path.expand("fixtures/#{name}", __DIR__)

  defp exiftool_tag(file_path, tag) do
    {output, 0} = System.cmd("exiftool", ["-m", "-s3", "-#{tag}", file_path])

    output
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end
end
