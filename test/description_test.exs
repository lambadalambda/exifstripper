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

  test "reads ImageDescription and the IPTC fallback from TIFF files" do
    for {name, tag} <- [
          {"image_with_imagedescription.tiff", "ImageDescription"},
          {"image_with_caption-abstract.tiff", "Caption-Abstract"}
        ] do
      fixture = fixture_path(name)
      expected = exiftool_tag(fixture, tag)
      assert is_binary(expected)

      assert Description.read_file(fixture) == expected
    end

    assert Description.read_file(fixture_path("strip_location_gps.tiff")) == nil
  end

  test "returns nil for BigTIFF and truncated TIFF files" do
    data = File.read!(fixture_path("image_with_imagedescription.tiff"))

    for broken <- [
          <<"II", 43, 0, 8, 0, 0, 0>> <> binary_part(data, 8, byte_size(data) - 8),
          binary_part(data, 0, 12),
          <<"MM", 0, 42, 0xFF, 0xFF, 0xFF, 0xFF>>
        ] do
      assert Description.read_binary(broken) == nil
    end
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

  test "reads ImageDescription from a gridded HEIC (iloc version 1)" do
    assert Description.read_file(fixture_path("image_with_imagedescription_grid.heic")) ==
             "Grid description"
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

  for ext <- ~w(jpg png),
      {label, description} <- [{"blank", " \t\n "}, {"oversized", String.duplicate("x", 100)}] do
    test "falls back to IPTC for #{label} EXIF ImageDescription in #{ext}" do
      ext = unquote(ext)

      path =
        Path.join(
          System.tmp_dir!(),
          "exif_description_#{System.unique_integer([:positive])}.#{ext}"
        )

      on_exit(fn -> File.rm(path) end)
      File.cp!(fixture_path("image_with_caption-abstract.#{ext}"), path)

      {_, 0} =
        System.cmd("exiftool", [
          "-overwrite_original",
          "-EXIF:ImageDescription=#{unquote(description)}",
          "-IPTC:Caption-Abstract=Short caption",
          path
        ])

      assert exiftool_tag(path, "Caption-Abstract") == "Short caption"
      assert Description.read_file(path, max_length: 20) == "Short caption"
    end
  end

  for {ext, fixture, fallback} <- [
        {"JPEG", "image_with_imagedescription_and_caption-abstract.jpg",
         :jpeg_iptc_caption_abstract},
        {"PNG", "image_with_imagedescription_exif.png", :png_iptc_caption_abstract}
      ] do
    test "short-circuits IPTC parsing for a valid #{ext} EXIF description" do
      path = fixture_path(unquote(fixture))
      expected = exiftool_tag(path, "ImageDescription")
      parent = self()

      reader =
        spawn(fn ->
          receive do
            :read -> send(parent, {:description, Description.read_file(path)})
          end

          receive do
            :done -> :ok
          end
        end)

      pattern = {Description, unquote(fallback), 1}
      Code.ensure_loaded!(Description)
      assert :erlang.trace_pattern(pattern, true, [:local]) == 1
      :erlang.trace(reader, true, [:call])

      try do
        send(reader, :read)
        assert_receive {:description, ^expected}
        ref = :erlang.trace_delivered(reader)
        assert_receive {:trace_delivered, ^reader, ^ref}
        refute_received {:trace, ^reader, :call, {Description, unquote(fallback), _}}
      after
        :erlang.trace_pattern(pattern, false, [:local])
        send(reader, :done)
      end
    end
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
