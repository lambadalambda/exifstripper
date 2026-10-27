# SPDX-License-Identifier: MIT

defmodule ExifStripper.XmpGpsTest do
  use ExUnit.Case, async: true

  alias ExifStripper.GpsStripper

  @exif "http://ns.adobe.com/exif/1.0/"
  @xmp_header "http://ns.adobe.com/xap/1.0/\0"
  @extension_header "http://ns.adobe.com/xmp/extension/\0"

  for ext <- ~w(jpg webp heic tiff) do
    test "blanks XMP GPS properties in #{ext} and keeps other XMP" do
      path = tmp_copy(fixture("xmp_gps.#{unquote(ext)}"))
      original = File.read!(path)
      assert xmp_tags(path) =~ "GPS Latitude"

      assert :ok = GpsStripper.strip_gps_data(path, path)
      tags = xmp_tags(path)
      refute tags =~ "GPS"
      refute tags =~ "Warning"
      assert tags =~ "Keep me"
      assert tags =~ "Keep tool"
      assert exiftool(["-a", "-gps:all", path]) == ""
      assert byte_size(File.read!(path)) == byte_size(original)
      assert :noop = GpsStripper.strip_gps_data(path, path)
    end
  end

  test "removes XMP from PNG files with the iTXt chunk" do
    path = tmp_copy(fixture("xmp_gps.png"))
    assert xmp_tags(path) =~ "GPS Latitude"

    assert :ok = GpsStripper.strip_gps_data(path, path)
    assert xmp_tags(path) == ""
    assert exiftool(["-a", "-gps:all", path]) == ""
  end

  test "blanks GPS properties in JPEG Extended XMP split across segments" do
    extended = packet("<exif:GPSLatitude>48,48.0N</exif:GPSLatitude><dc:title>Keep</dc:title>")
    guid = :crypto.hash(:md5, extended) |> Base.encode16()
    {gps, _} = :binary.match(extended, "GPSLatitude")

    main =
      packet("", "xmlns:xmpNote='http://ns.adobe.com/xmp/note/' xmpNote:HasExtendedXMP='#{guid}'")

    # Split the extended packet in the middle of the GPS property.
    path = tmp_file(jpeg([xmp_segment(main) | extension_segments(extended, guid, [gps + 5])]))
    assert xmp_tags(path) =~ "GPS Latitude"

    assert :ok = GpsStripper.strip_gps_data(path, path)
    tags = xmp_tags(path)
    refute tags =~ "GPS"
    assert tags =~ "Title"
  end

  test "fails closed on malformed XMP and incomplete Extended XMP" do
    extended = packet("<exif:GPSLatitude>1</exif:GPSLatitude>")
    guid = String.duplicate("A", 32)
    size = byte_size(extended)

    for segments <- [
          [xmp_segment(packet("<exif:GPSLatitude>1</exif:GPSLongitude>"))],
          [xmp_segment("<!DOCTYPE x><x/>")],
          # A missing chunk, overlapping chunks, and disagreeing total sizes.
          extension_segments(extended, guid, [100]) |> tl(),
          extension_segments(extended, guid, [100])
          |> Enum.concat(extension_segments(extended, guid, [50])),
          [
            extension_segment(guid, size, 0, binary_part(extended, 0, 100)),
            extension_segment(guid, size + 1, 100, binary_part(extended, 100, size - 100))
          ]
        ] do
      data = jpeg(segments)
      path = tmp_file(data)
      assert {:error, _} = GpsStripper.strip_gps_data(data)
      assert {:error, _} = GpsStripper.strip_gps_data(path, path)
      assert File.read!(path) == data
    end
  end

  test "fails closed on malformed XMP in WebP, HEIC and TIFF" do
    for ext <- ~w(webp heic tiff) do
      data = File.read!(fixture("xmp_gps.#{ext}"))
      {pos, _} = :binary.match(data, "</exif:GPSLatitude>")

      broken =
        binary_part(data, 0, pos) <>
          "</exif:GPSLongitude" <> binary_part(data, pos + 19, byte_size(data) - pos - 19)

      assert {:error, _} = GpsStripper.strip_gps_data(broken), ext
    end
  end

  defp packet(body, extra \\ "") do
    """
    <?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>
    <x:xmpmeta xmlns:x='adobe:ns:meta/'>
    <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
    <rdf:Description rdf:about='' xmlns:exif='#{@exif}' xmlns:dc='http://purl.org/dc/elements/1.1/' #{extra}>
    #{body}
    </rdf:Description>
    </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end='w'?>
    """
  end

  defp jpeg(segments) do
    <<0xFF, 0xD8, rest::binary>> = File.read!(fixture("image_with_no_description.jpg"))
    IO.iodata_to_binary([<<0xFF, 0xD8>>, segments, rest])
  end

  defp app1(payload), do: <<0xFF, 0xE1, byte_size(payload) + 2::16>> <> payload
  defp xmp_segment(packet), do: app1(@xmp_header <> packet)

  defp extension_segment(guid, size, offset, chunk),
    do: app1(@extension_header <> guid <> <<size::32, offset::32>> <> chunk)

  defp extension_segments(packet, guid, cuts) do
    bounds = [0 | cuts] ++ [byte_size(packet)]

    bounds
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] ->
      extension_segment(guid, byte_size(packet), from, binary_part(packet, from, to - from))
    end)
  end

  defp xmp_tags(path), do: exiftool(["-a", "-G1", "-xmp:all", "-warning", "--XMPToolkit", path])

  defp exiftool(args) do
    {output, 0} = System.cmd("exiftool", args)
    String.trim(output)
  end

  defp fixture(name), do: Path.expand("fixtures/#{name}", __DIR__)

  defp tmp_copy(source), do: tmp_file(File.read!(source), Path.extname(source))

  defp tmp_file(data, ext \\ ".jpg") do
    path = Path.join(System.tmp_dir!(), "exif_xmp_#{System.unique_integer([:positive])}#{ext}")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, data)
    path
  end
end
