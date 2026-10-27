# SPDX-License-Identifier: MIT

defmodule ExifStripper.XMPTest do
  use ExUnit.Case, async: true

  alias ExifStripper.XMP

  @exif "http://ns.adobe.com/exif/1.0/"

  defp scrub(packet) do
    with {:ok, patches} <- XMP.gps_patches(packet) do
      result =
        Enum.reduce(patches, packet, fn {pos, bytes}, acc ->
          binary_part(acc, 0, pos) <>
            bytes <>
            binary_part(acc, pos + byte_size(bytes), byte_size(acc) - pos - byte_size(bytes))
        end)

      assert byte_size(result) == byte_size(packet)
      {:ok, result}
    end
  end

  defp packet(body, ns \\ "xmlns:exif='#{@exif}'") do
    """
    <?xpacket begin='﻿' id='W5M0MpCehiHzreSzNTczkc9d'?>
    <x:xmpmeta xmlns:x='adobe:ns:meta/'>
    <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
    <rdf:Description rdf:about='' #{ns} xmlns:dc='http://purl.org/dc/elements/1.1/'>
    #{body}
    </rdf:Description>
    </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end='w'?>
    """
  end

  # Whitespace-insensitive comparison of the scrubbed packet.
  defp squash(data), do: String.replace(data, ~r/\s+/, " ")

  test "blanks GPS property elements and keeps others" do
    original =
      packet("""
      <exif:GPSLatitude>48,48.0N</exif:GPSLatitude>
      <dc:title>Keep</dc:title>
      <exif:GPSLongitude>2,18.0E</exif:GPSLongitude>
      <exif:ExposureTime>1/60</exif:ExposureTime>
      """)

    assert {:ok, result} = scrub(original)
    refute result =~ "GPS"
    refute result =~ "48,48"
    assert result =~ "<dc:title>Keep</dc:title>"
    assert result =~ "<exif:ExposureTime>1/60</exif:ExposureTime>"
    assert squash(result) == squash(String.replace(original, ~r/<exif:GPS.*<\/exif:GPS\w+>/, ""))
  end

  test "blanks nested structures, attributes and self-closing elements" do
    original =
      packet(
        """
        <exif:GPSDestLatitude>
          <rdf:Seq><rdf:li><exif:GPSDestLatitude>1</exif:GPSDestLatitude></rdf:li></rdf:Seq>
        </exif:GPSDestLatitude>
        <exif:GPSAreaInformation rdf:resource='x'/>
        <dc:creator>Me</dc:creator>
        """,
        "xmlns:exif='#{@exif}' exif:GPSAltitude=\"12/1\" exif:Flash='1' dc:format='image/jpeg'"
      )

    assert {:ok, result} = scrub(original)
    refute result =~ "GPS"
    refute result =~ "12/1"
    assert result =~ "exif:Flash='1' dc:format='image/jpeg'"
    assert result =~ "<dc:creator>Me</dc:creator>"
  end

  test "resolves the prefixes bound to the EXIF namespace" do
    original =
      packet(
        """
        <e:GPSLatitude>1</e:GPSLatitude>
        <GPSLongitude xmlns='#{@exif}'>2</GPSLongitude>
        <exif:GPSTimeStamp>not the EXIF namespace</exif:GPSTimeStamp>
        <other:GPSLatitude xmlns:other='http://example.com/'>keep</other:GPSLatitude>
        <e:Model xmlns:e='http://example.com/'><e:GPSLatitude>keep too</e:GPSLatitude></e:Model>
        """,
        "xmlns:e='#{@exif}' xmlns:exif='http://example.com/exif' e:GPSAltitude='3'"
      )

    assert {:ok, result} = scrub(original)
    refute result =~ "<e:GPSLatitude>1"
    refute result =~ "GPSLongitude"
    refute result =~ "GPSAltitude"
    assert result =~ "<exif:GPSTimeStamp>not the EXIF namespace</exif:GPSTimeStamp>"

    assert result =~
             "<other:GPSLatitude xmlns:other='http://example.com/'>keep</other:GPSLatitude>"

    assert result =~ "<e:GPSLatitude>keep too</e:GPSLatitude>"
  end

  test "blanks GPS elements with GPS attributes once" do
    original = packet("<exif:GPSLatitude exif:GPSAltitude='1'>48,48.0N</exif:GPSLatitude>")

    assert {:ok, [_]} = XMP.gps_patches(original)
    assert {:ok, result} = scrub(original)
    refute result =~ "GPS"
  end

  test "treats the EXIF namespace variants that exiftool reads as EXIF" do
    for uri <- ["http://ns.adobe.com/exif/1.0", "http://ns.adobe.com/exif/2.1/"] do
      assert {:ok, result} = scrub(packet("<e:GPSLatitude>1</e:GPSLatitude>", "xmlns:e='#{uri}'"))
      refute result =~ "GPS"
    end

    assert {:ok, []} =
             XMP.gps_patches(
               packet(
                 "<e:GPSLatitude>1</e:GPSLatitude>",
                 "xmlns:e='http://ns.adobe.com/exif/1.0/aux/'"
               )
             )
  end

  test "blanks DJI drone location properties and keeps other DJI properties" do
    dji = "xmlns:drone-dji='http://www.dji.com/drone-dji/1.0/'"

    location =
      ~w(GpsLatitude GpsLongitude GpsLongtitude Latitude Longitude AbsoluteAltitude
         RelativeAltitude LRFTargetLat LRFTargetLon LRFTargetAlt LRFTargetAbsAlt)

    attributes = Enum.map_join(location, " ", &"drone-dji:#{&1}='+1.5'")
    elements = Enum.map_join(location, "\n", &"<d:#{&1}>+1.5</d:#{&1}>")

    original =
      packet(
        elements <> "<d:FlightYawDegree>12.5</d:FlightYawDegree>",
        "#{dji} xmlns:d='http://www.dji.com/drone-dji/1.0/' #{attributes} " <>
          "drone-dji:GimbalPitchDegree='-90' drone-dji:RtkStdLat='0.01' drone-dji:LRFTargetDistance='5'"
      )

    assert {:ok, result} = scrub(original)
    refute result =~ "+1.5"
    for name <- location, do: refute(result =~ name)
    assert result =~ "drone-dji:GimbalPitchDegree='-90' drone-dji:RtkStdLat='0.01'"
    assert result =~ "<d:FlightYawDegree>12.5</d:FlightYawDegree>"
    assert result =~ "LRFTargetDistance='5'"

    # Same local names in other namespaces stay.
    assert {:ok, []} = XMP.gps_patches(packet("<dc:Latitude>1</dc:Latitude>"))

    assert {:error, :unbound_xmp_prefix} =
             XMP.gps_patches(
               packet("<undeclared:AbsoluteAltitude>1</undeclared:AbsoluteAltitude>")
             )
  end

  test "accepts trailing NUL bytes" do
    assert {:ok, [_]} =
             XMP.gps_patches(packet("<exif:GPSLatitude>1</exif:GPSLatitude>") <> <<0, 0>>)
  end

  test "returns no patches without GPS properties" do
    assert {:ok, []} = XMP.gps_patches(packet("<dc:title>Keep</dc:title>"))
    assert {:ok, []} = XMP.gps_patches("")
  end

  test "keeps comments, CDATA and processing instructions opaque" do
    original =
      packet("""
      <!-- <exif:GPSLatitude>comment</exif:GPSLatitude> -->
      <dc:title><![CDATA[<exif:GPSLatitude>cdata</exif:GPSLatitude>]]></dc:title>
      <?pi exif:GPSLatitude?>
      <exif:GPSLatitude>1 &amp; 2 &#x31;</exif:GPSLatitude>
      """)

    assert {:ok, result} = scrub(original)
    assert result =~ "comment</exif:GPSLatitude> -->"
    assert result =~ "cdata</exif:GPSLatitude>]]>"
    refute result =~ "1 &amp; 2"
  end

  test "fails closed on malformed or unsafe XMP" do
    for body <- [
          "<exif:GPSLatitude>1</exif:GPSLongitude>",
          "<exif:GPSLatitude>1",
          "<dc:title>x</dc:title></rdf:Description>",
          "<exif:GPSLatitude attr=unquoted>1</exif:GPSLatitude>",
          "<exif:GPSLatitude a='1' a='2'>1</exif:GPSLatitude>",
          "<dc:title a='<'>x</dc:title>",
          "<dc:title>x</dc:title><!-- unterminated",
          "<dc:title><![CDATA[x</dc:title>",
          "<undeclared:GPSLatitude>1</undeclared:GPSLatitude>",
          "<exif:GPSLatitude xmlns:exif=''>1</exif:GPSLatitude>",
          "< dc:title>x</dc:title>",
          "<dc:title>x</dc:title",
          # exiftool ends processing instructions at the first `>`.
          "<?pi > <exif:GPSLatitude>1</exif:GPSLatitude> ?>",
          "<dc:title>x</dc:title><dc:a>\0</dc:a>"
        ] do
      assert {:error, _} = XMP.gps_patches(packet(body)), body
    end

    for data <- [
          "<!DOCTYPE x [<!ENTITY e '<exif:GPSLatitude>1</exif:GPSLatitude>'>]><x>&e;</x>",
          # UTF-16 cannot be scanned as ASCII-compatible bytes.
          :unicode.characters_to_binary(packet("<dc:title>x</dc:title>"), :utf8, {:utf16, :big}),
          # Other encodings could hide markup from a byte scanner.
          "<?xml version='1.0' encoding='UTF-7'?>" <> packet("<dc:title>x</dc:title>"),
          # Blanking the root element would leave no document.
          "<exif:GPSLatitude xmlns:exif='#{@exif}'>1</exif:GPSLatitude>"
        ] do
      assert {:error, _} = XMP.gps_patches(data), inspect(data)
    end
  end

  test "handles deep nesting and many attributes without blowing up" do
    depth = 50_000
    nested = String.duplicate("<dc:a>", depth) <> String.duplicate("</dc:a>", depth)
    attrs = Enum.map_join(1..20_000, " ", &"dc:a#{&1}='x'")
    data = packet(nested <> "<dc:b #{attrs}/><exif:GPSLatitude>1</exif:GPSLatitude>")

    {micros, result} = :timer.tc(fn -> XMP.gps_patches(data) end)
    assert {:ok, [_]} = result
    assert micros < 2_000_000
  end
end
