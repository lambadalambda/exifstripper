# SPDX-License-Identifier: MIT

defmodule ExifStripper.TiffGpsTest do
  use ExUnit.Case, async: true

  alias ExifStripper.{Description, GpsStripper}

  for endian <- [:little, :big], container <- [:jpeg, :webp, :webp_exif, :heic] do
    test "wipes GPS directories and every out-of-line value in #{container} / #{endian}" do
      {tiff, clean, _offsets} = gps_tiff(unquote(endian))
      original = wrap(tiff, unquote(container))
      expected = wrap(clean, unquote(container))

      assert Description.read_binary(original) == "Keep this description"
      assert {:ok, ^expected} = GpsStripper.strip_gps_data(original)
      assert Description.read_binary(expected) == "Keep this description"
      assert :noop = GpsStripper.strip_gps_data(expected)
    end

    test "fails closed on malformed GPS metadata in #{container} / #{endian}" do
      endian = unquote(endian)
      {tiff, _clean, offsets} = gps_tiff(endian)

      for {offset, replacement} <- [
            {offsets.pointer + 2, uint(3, 2, endian)},
            {offsets.pointer + 4, uint(2, 4, endian)},
            {offsets.pointer + 8, uint(byte_size(tiff) + 1, 4, endian)},
            {offsets.pointer + 8, uint(0, 4, endian)},
            {offsets.gps, uint(65_535, 2, endian)},
            {offsets.gps + 4, uint(99, 2, endian)},
            {offsets.latitude + 4, uint(0xFFFFFFFF, 4, endian)},
            {offsets.latitude + 8, uint(byte_size(tiff) - 1, 4, endian)},
            {offsets.latitude + 8, uint(8, 4, endian)},
            {offsets.latitude + 8, uint(offsets.description, 4, endian)},
            {offsets.gps_next, uint(offsets.gps, 4, endian)}
          ] do
        malformed = replace(tiff, offset, replacement) |> wrap(unquote(container))
        assert {:error, _} = GpsStripper.strip_gps_data(malformed)
      end
    end
  end

  test "wipes chained GPS directories and follows non-GPS IFDs without changing them" do
    for endian <- [:little, :big] do
      {tiff, clean, offsets} = gps_tiff(endian)
      next_offset = byte_size(tiff)

      extra_gps =
        uint(1, 2, endian) <>
          entry(27, 7, 8, uint(next_offset + 18, 4, endian), endian) <>
          uint(0, 4, endian) <> "GPS tail"

      chained = replace(tiff, offsets.gps_next, uint(next_offset, 4, endian)) <> extra_gps
      expected = clean <> :binary.copy(<<0>>, byte_size(extra_gps))
      assert {:ok, result} = GpsStripper.strip_gps_data(wrap(chained, :jpeg))
      assert result == wrap(expected, :jpeg)

      # Move IFD0's GPS entry into an Exif subdirectory.
      subdirectory =
        uint(1, 2, endian) <>
          binary_part(tiff, offsets.pointer, 12) <> uint(0, 4, endian)

      tiff =
        replace(tiff, offsets.pointer, entry(0x8769, 4, 1, uint(next_offset, 4, endian), endian)) <>
          subdirectory

      clean =
        replace(clean, offsets.pointer, entry(0x8769, 4, 1, uint(next_offset, 4, endian), endian)) <>
          uint(1, 2, endian) <> :binary.copy(<<0>>, 12) <> uint(0, 4, endian)

      assert {:ok, result} = GpsStripper.strip_gps_data(wrap(tiff, :jpeg))
      assert result == wrap(clean, :jpeg)
    end
  end

  test "refuses TIFF files with too many IFDs or SubIFD pointers" do
    # A chain of `n` empty IFDs.
    chain = fn n ->
      ifds =
        for i <- 0..(n - 1),
            into: <<>>,
            do: <<0::16-little, if(i == n - 1, do: 0, else: 8 + (i + 1) * 6)::32-little>>

      <<"II", 42::16-little, 8::32-little>> <> ifds
    end

    # IFD0 with a SubIFDs entry pointing at `n` distinct empty IFDs.
    subifds = fn n ->
      first = 26 + n * 4
      pointers = for i <- 0..(n - 1), into: <<>>, do: <<first + i * 6::32-little>>

      <<"II", 42::16-little, 8::32-little, 1::16-little, 0x014A::16-little, 4::16-little,
        n::32-little, 26::32-little,
        0::32-little>> <>
        pointers <> :binary.copy(<<0::16, 0::32>>, n)
    end

    assert :noop = GpsStripper.strip_gps_data(chain.(1000))
    assert {:error, :too_many_ifds} = GpsStripper.strip_gps_data(chain.(1100))
    assert :noop = GpsStripper.strip_gps_data(subifds.(1000))
    assert {:error, :too_many_ifds} = GpsStripper.strip_gps_data(subifds.(1100))

    # Millions of pointers fail before they are read.
    huge =
      <<"II", 42::16-little, 8::32-little, 1::16-little, 0x014A::16-little, 4::16-little,
        4_000_000::32-little, 26::32-little,
        0::32-little>> <> :binary.copy(<<8::32-little>>, 4_000_000)

    {micros, result} = :timer.tc(fn -> GpsStripper.strip_gps_data(huge) end)
    assert {:error, :too_many_ifds} = result
    assert micros < 2_000_000
  end

  test "handles HEIC file-offset item locations in versions 1 and 2; rejects other methods" do
    {tiff, clean, _} = gps_tiff(:big)

    for version <- [1, 2] do
      assert {:ok, result} = GpsStripper.strip_gps_data(heic(tiff, version))
      assert result == heic(clean, version)
      assert {:error, _} = GpsStripper.strip_gps_data(heic(tiff, version, 1))
    end
  end

  test "fails closed on truncated HEIC item tables instead of accepting partial metadata" do
    {tiff, _, _} = gps_tiff(:big)
    data = wrap(tiff, :heic)
    {iloc, _} = :binary.match(data, "iloc")
    {iinf, _} = :binary.match(data, "iinf")

    for {offset, bytes} <- [
          {iloc + 4 + 6, <<2::16>>},
          {iinf + 4 + 4, <<2::16>>},
          {iloc + 4 + 12, <<2::16>>},
          {iloc + 4 + 8, <<2::16>>}
        ] do
      assert {:error, _} = GpsStripper.strip_gps_data(replace(data, offset, bytes))
    end
  end

  test "preserves disjoint HEIC items and adjacent extents without changing container lengths" do
    {tiff, clean, _} = gps_tiff(:big)

    for layout <- [:disjoint_items, :adjacent] do
      original = heic(tiff, 0, 0, layout)
      assert {:ok, result} = GpsStripper.strip_gps_data(original)
      assert result == heic(clean, 0, 0, layout)
      assert byte_size(result) == byte_size(original)
    end
  end

  for overlap <- [:across_items, :within_item, :partial] do
    test "rejects #{overlap} overlapping HEIC extents in the binary API" do
      {tiff, _, _} = gps_tiff(:big)
      assert {:error, _} = GpsStripper.strip_gps_data(heic(tiff, 0, 0, unquote(overlap)))
    end

    test "leaves the destination unchanged for #{overlap} overlapping HEIC extents" do
      {tiff, _, _} = gps_tiff(:big)
      data = heic(tiff, 0, 0, unquote(overlap))

      path =
        Path.join(System.tmp_dir!(), "exif_gps_alias_#{System.unique_integer([:positive])}.heic")

      on_exit(fn -> File.rm(path) end)
      File.write!(path, data)
      assert {:error, _} = GpsStripper.strip_gps_data(path, path)
      assert File.read!(path) == data
    end
  end

  test "malformed GPS never overwrites the destination or reports a file noop" do
    {tiff, _, offsets} = gps_tiff(:big)
    data = replace(tiff, offsets.pointer + 8, <<0xFFFFFFFF::32>>) |> wrap(:jpeg)
    path = Path.join(System.tmp_dir!(), "exif_gps_bad_#{System.unique_integer([:positive])}.jpg")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, data)
    assert {:error, _} = GpsStripper.strip_gps_data(path, path)
    assert File.read!(path) == data
  end

  # Includes standard GPS signatures used to recover a deleted pointer, plus
  # out-of-line values of every classic TIFF scalar type (not just coordinates).
  defp gps_tiff(endian) do
    description = "Keep this description\0"
    description_offset = 8 + 2 + 3 * 12 + 4
    gps_offset = description_offset + byte_size(description)

    fields =
      [
        {0, 1, <<2, 3, 0, 0>>},
        {1, 2, "N\0"},
        {2, 5,
         uint(37, 4, endian) <>
           uint(1, 4, endian) <>
           uint(48, 4, endian) <>
           uint(1, 4, endian) <> uint(1234, 4, endian) <> uint(100, 4, endian)},
        {3, 2, "W\0"},
        {4, 5,
         uint(122, 4, endian) <>
           uint(1, 4, endian) <>
           uint(24, 4, endian) <>
           uint(1, 4, endian) <> uint(5678, 4, endian) <> uint(100, 4, endian)}
      ] ++ for(type <- 1..12, do: {100 + type, type, :binary.copy(<<type>>, type_size(type) * 8)})

    value_offset = gps_offset + 2 + length(fields) * 12 + 4

    {entries, values, _} =
      Enum.reduce(fields, {[], [], value_offset}, fn {tag, type, bytes}, {entries, values, pos} ->
        count = div(byte_size(bytes), type_size(type))

        if byte_size(bytes) <= 4 do
          inline = bytes <> :binary.copy(<<0>>, 4 - byte_size(bytes))
          {entries ++ [entry(tag, type, count, inline, endian)], values, pos}
        else
          {entries ++ [entry(tag, type, count, uint(pos, 4, endian), endian)], values ++ [bytes],
           pos + byte_size(bytes)}
        end
      end)

    header = if endian == :little, do: "II", else: "MM"
    pointer = 8 + 2 + 2 * 12

    prefix =
      header <>
        uint(42, 2, endian) <>
        uint(8, 4, endian) <>
        uint(3, 2, endian) <>
        entry(0x010E, 2, byte_size(description), uint(description_offset, 4, endian), endian) <>
        entry(0x0112, 3, 1, uint(6, 2, endian) <> <<0, 0>>, endian) <>
        entry(0x8825, 4, 1, uint(gps_offset, 4, endian), endian) <>
        uint(0, 4, endian) <>
        description

    gps =
      IO.iodata_to_binary([uint(length(fields), 2, endian), entries, uint(0, 4, endian), values])

    tiff = prefix <> gps

    clean =
      replace(prefix, pointer, :binary.copy(<<0>>, 12)) <> :binary.copy(<<0>>, byte_size(gps))

    {tiff, clean,
     %{
       pointer: pointer,
       gps: gps_offset,
       latitude: gps_offset + 2 + 2 * 12,
       description: description_offset,
       gps_next: value_offset - 4
     }}
  end

  defp type_size(type) when type in [1, 2, 6, 7], do: 1
  defp type_size(type) when type in [3, 8], do: 2
  defp type_size(type) when type in [4, 9, 11], do: 4
  defp type_size(type) when type in [5, 10, 12], do: 8

  defp uint(n, bytes, :little), do: <<n::little-size(bytes)-unit(8)>>
  defp uint(n, bytes, :big), do: <<n::big-size(bytes)-unit(8)>>

  defp entry(tag, type, count, value, endian),
    do: uint(tag, 2, endian) <> uint(type, 2, endian) <> uint(count, 4, endian) <> value

  defp replace(data, offset, bytes) do
    binary_part(data, 0, offset) <>
      bytes <>
      binary_part(data, offset + byte_size(bytes), byte_size(data) - offset - byte_size(bytes))
  end

  defp wrap(tiff, :jpeg) do
    payload = "Exif\0\0" <> tiff
    <<0xFF, 0xD8, 0xFF, 0xE1, byte_size(payload) + 2::16>> <> payload <> <<0xFF, 0xD9>>
  end

  defp wrap(tiff, :webp_exif), do: wrap("Exif\0\0" <> tiff, :webp)

  defp wrap(tiff, :webp) do
    chunk =
      "EXIF" <>
        <<byte_size(tiff)::32-little>> <>
        tiff <>
        :binary.copy(<<0>>, rem(byte_size(tiff), 2))

    "RIFF" <> <<byte_size(chunk) + 4::32-little>> <> "WEBP" <> chunk
  end

  defp wrap(tiff, :heic), do: heic(tiff, 0)

  defp heic(tiff, version, method \\ 0, overlap \\ nil) do
    ftyp = box("ftyp", "heic" <> <<0::32>> <> "heic")
    item = <<0::32>> <> tiff
    length = byte_size(item)

    locations =
      case overlap do
        :across_items -> [{1, [{0, length}]}, {2, [{0, length}]}]
        :disjoint_items -> [{1, [{0, length}]}, {2, [{length, length}]}]
        :adjacent -> [{1, [{0, 16}, {16, length - 16}]}]
        :within_item -> [{1, [{0, length}, {0, length}]}]
        :partial -> [{1, [{0, length}, {length - 16, 16}]}]
        nil -> [{1, [{0, length}]}]
      end

    entries =
      Enum.map(locations, fn {id, _} ->
        box("infe", <<2, 0::24, id::16, 0::16, "Exif", 0>>)
      end)
      |> IO.iodata_to_binary()

    iinf = box("iinf", <<0::32, length(locations)::16>> <> entries)

    iloc = fn offset ->
      bytes = if version == 2, do: 4, else: 2
      construction = if version == 0, do: <<>>, else: <<0::12, method::4>>

      entries =
        Enum.map(locations, fn {id, extents} ->
          ranges =
            Enum.map(extents, fn {relative, size} -> <<offset + relative::32, size::32>> end)

          [uint(id, bytes, :big), construction, <<0::16, length(extents)::16>>, ranges]
        end)

      box(
        "iloc",
        IO.iodata_to_binary([
          <<version, 0::24, 0x44, 0>>,
          uint(length(locations), bytes, :big),
          entries
        ])
      )
    end

    meta = fn offset -> box("meta", <<0::32>> <> iinf <> iloc.(offset)) end
    offset = byte_size(ftyp) + byte_size(meta.(0)) + 8
    payload = if overlap == :disjoint_items, do: item <> item, else: item
    ftyp <> meta.(offset) <> box("mdat", payload)
  end

  defp box(type, data), do: <<byte_size(data) + 8::32>> <> type <> data
end
