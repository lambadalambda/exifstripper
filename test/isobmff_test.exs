# SPDX-License-Identifier: MIT

defmodule ExifStripper.ISOBMFFTest do
  use ExUnit.Case, async: true

  alias ExifStripper.{Description, GpsStripper, ISOBMFF}

  defp box(type, payload),
    do: <<byte_size(payload) + 8::32, type::binary-size(4), payload::binary>>

  defp full_box(type, version, payload), do: box(type, <<version::8, 0::24, payload::binary>>)

  # A minimal HEIF with one Exif item (id 1) and the given iloc payload (version 1).
  defp heif(iloc_payload) do
    infe = full_box("infe", 2, <<1::16, 0::16, "Exif", 0>>)
    iinf = full_box("iinf", 0, <<1::16, infe::binary>>)
    iloc = full_box("iloc", 1, iloc_payload)
    box("ftyp", "heic" <> <<0::32>> <> "mif1heic") <> full_box("meta", 0, iinf <> iloc)
  end

  defp assert_fast(fun) do
    {micros, _} = :timer.tc(fun)
    assert micros < 200_000, "took #{div(micros, 1000)} ms"
  end

  test "rejects zero-width extents instead of building one entry per extent" do
    # offset_size = length_size = base_offset_size = index_size = 0, so every
    # extent takes 0 bytes; one item claims 65535 extents.
    items = for id <- 1..50, into: <<>>, do: <<id::16, 0::16, 0::16, 65_535::16>>
    data = heif(<<0, 0, 50::16, items::binary>>)

    assert_fast(fn -> assert {:error, _} = ISOBMFF.exif_item_locations(data) end)
    assert_fast(fn -> assert {:error, _} = GpsStripper.strip_gps_data(data) end)
    assert_fast(fn -> assert Description.read_binary(data) == nil end)
  end

  test "rejects extent counts larger than the iloc box" do
    # 4-byte offsets and lengths, but no extent data at all.
    data = heif(<<0x44, 0, 1::16, 1::16, 0::16, 0::16, 1_000::16>>)

    assert {:error, _} = ISOBMFF.exif_item_locations(data)
  end

  test "rejects duplicate item ids" do
    item = <<1::16, 0::16, 0::16, 1::16, 100::32, 10::32>>
    items = :binary.copy(item, 20_000)
    data = heif(<<0x44, 0, 20_000::16, items::binary>>)

    assert_fast(fn -> assert {:error, _} = ISOBMFF.exif_item_locations(data) end)
  end

  test "refuses Exif items larger than the metadata limit instead of loading them" do
    size = 17 * 1024 * 1024
    offset = byte_size(heif(<<0x44, 0, 1::16, 1::16, 0::16, 0::16, 1::16, 0::32, 0::32>>))
    data = heif(<<0x44, 0, 1::16, 1::16, 0::16, 0::16, 1::16, offset::32, size::32>>)
    data = data <> :binary.copy(<<0>>, size)

    assert {:error, :metadata_too_large} = GpsStripper.strip_gps_data(data)
  end
end
