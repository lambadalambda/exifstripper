# SPDX-License-Identifier: MIT

defmodule ExifStripper.GpsStripper do
  @moduledoc """
  Losslessly strips GPS-related EXIF metadata, without re-encoding images.

  Supported containers:

  - JPEG: wipes GPS directories and values in EXIF (APP1)
  - WebP: wipes GPS directories and values in the `EXIF` RIFF chunk
  - HEIC / other ISO-BMFF images: wipes GPS directories and values in the `Exif` item
  - PNG: removes metadata chunks (`eXIf`, `tEXt`, `zTXt`, `iTXt`)

  If no supported metadata is found, returns `:noop` and does not change the output.
  Malformed or unsafe EXIF metadata returns an error without writing the output.
  """

  alias ExifStripper.ISOBMFF

  @gps_ifd_tag 0x8825

  @png_signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @jpg_soi_marker <<0xFF, 0xD8>>
  @webp_riff_marker "RIFF"

  @jpg_app1_marker 0xE1
  @jpg_sos_marker 0xDA
  @jpg_tem_marker 0x01

  @type result :: :ok | :noop | {:error, term()}

  @spec strip_gps_data(Path.t(), Path.t()) :: result()
  def strip_gps_data(input_path, output_path) do
    with {:ok, data} <- File.read(input_path),
         {:ok, stripped_data} <- strip_gps_data(data),
         :ok <- File.write(output_path, stripped_data) do
      :ok
    else
      :noop -> :noop
      {:error, _} = error -> error
    end
  rescue
    e ->
      {:error, "#{__MODULE__}: #{inspect(e)}"}
  end

  @spec strip_gps_data(binary()) :: {:ok, binary()} | :noop | {:error, term()}
  def strip_gps_data(data) when is_binary(data), do: process_file(data)

  defp process_file(<<@png_signature, rest::binary>>) do
    case strip_png_chunks(rest, [], false) do
      {:ok, new_rest, true} -> {:ok, @png_signature <> new_rest}
      {:ok, _new_rest, false} -> :noop
      {:error, _} = error -> error
    end
  end

  defp process_file(<<@jpg_soi_marker, rest::binary>>) do
    case strip_jpeg_segments(rest, [], false) do
      {:ok, iodata, true} -> {:ok, @jpg_soi_marker <> IO.iodata_to_binary(iodata)}
      {:ok, _iodata, false} -> :noop
      {:error, _} = error -> error
    end
  end

  defp process_file(<<@webp_riff_marker, riff_size::32-little, "WEBP", rest::binary>>) do
    case strip_webp_chunks(rest, [], false) do
      {:ok, iodata, true} ->
        {:ok,
         @webp_riff_marker <> <<riff_size::32-little>> <> "WEBP" <> IO.iodata_to_binary(iodata)}

      {:ok, _iodata, false} ->
        :noop

      {:error, _} = error ->
        error
    end
  end

  defp process_file(<<_size::32-big, "ftyp", _rest::binary>> = data) do
    case strip_isobmff_exif_items(data) do
      {:ok, new_data, true} -> {:ok, new_data}
      {:ok, _new_data, false} -> :noop
      {:error, _} = error -> error
    end
  end

  defp process_file(<<magic::binary-size(4), _rest::binary>> = data)
       when magic in [<<"II", 42, 0>>, <<"MM", 0, 42>>] do
    case strip_gps_from_tiff(data) do
      {:ok, new_data, true} -> {:ok, new_data}
      {:ok, _new_data, false} -> :noop
      {:error, _} = error -> error
    end
  end

  defp process_file(_), do: :noop

  defp strip_png_chunks(<<>>, acc, stripped?),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(acc)), stripped?}

  # Anything after IEND is not part of the image and may hold metadata: drop it.
  defp strip_png_chunks(<<0::32, "IEND", crc::32, rest::binary>>, acc, stripped?) do
    iend = <<0::32, "IEND", crc::32>>
    {:ok, IO.iodata_to_binary(Enum.reverse([iend | acc])), stripped? or rest != <<>>}
  end

  defp strip_png_chunks(
         <<chunk_size::32, chunk_type::binary-size(4), chunk_data::binary-size(chunk_size),
           crc::32, rest::binary>>,
         acc,
         stripped?
       ) do
    if chunk_type in ["eXIf", "tEXt", "zTXt", "iTXt"] do
      strip_png_chunks(rest, acc, true)
    else
      chunk =
        <<chunk_size::32, chunk_type::binary-size(4), chunk_data::binary-size(chunk_size),
          crc::32>>

      strip_png_chunks(rest, [chunk | acc], stripped?)
    end
  end

  defp strip_png_chunks(_data, _acc, _stripped?), do: {:error, :invalid_png}

  defp strip_webp_chunks(<<>>, acc, stripped?),
    do: {:ok, Enum.reverse(acc), stripped?}

  defp strip_webp_chunks(
         <<chunk_type::binary-size(4), chunk_size::32-little, rest::binary>>,
         acc,
         stripped?
       )
       when byte_size(rest) >= chunk_size do
    <<chunk_data::binary-size(chunk_size), after_chunk::binary>> = rest

    {padding, remaining} =
      if rem(chunk_size, 2) == 1 and byte_size(after_chunk) >= 1 do
        <<pad::binary-size(1), remaining::binary>> = after_chunk
        {pad, remaining}
      else
        {<<>>, after_chunk}
      end

    with {:ok, chunk_data, patched?} <-
           if(chunk_type == "EXIF",
             do: strip_gps_from_exif_payload(chunk_data),
             else: {:ok, chunk_data, false}
           ) do
      chunk = <<chunk_type::binary-size(4), chunk_size::32-little>> <> chunk_data <> padding
      strip_webp_chunks(remaining, [chunk | acc], stripped? or patched?)
    end
  end

  defp strip_webp_chunks(_data, _acc, _stripped?), do: {:error, :invalid_webp}

  defp strip_jpeg_segments(<<0xFF, @jpg_sos_marker, _::binary>> = data, acc, changed?) do
    {:ok, Enum.reverse([data | acc]), changed?}
  end

  defp strip_jpeg_segments(<<0xFF, 0xFF, rest::binary>>, acc, changed?) do
    strip_jpeg_segments(<<0xFF, rest::binary>>, acc, changed?)
  end

  defp strip_jpeg_segments(<<0xFF, @jpg_tem_marker, rest::binary>>, acc, changed?) do
    strip_jpeg_segments(rest, [<<0xFF, @jpg_tem_marker>> | acc], changed?)
  end

  defp strip_jpeg_segments(<<0xFF, marker, rest::binary>>, acc, changed?)
       when marker in 0xD0..0xD9 do
    strip_jpeg_segments(rest, [<<0xFF, marker>> | acc], changed?)
  end

  defp strip_jpeg_segments(<<0xFF, marker, segment_length::16, rest::binary>>, acc, changed?) do
    segment_data_len = segment_length - 2

    if segment_length >= 2 and byte_size(rest) >= segment_data_len do
      <<segment_data::binary-size(segment_data_len), remaining::binary>> = rest

      with {:ok, segment_data, patched?} <-
             if(marker == @jpg_app1_marker,
               do: strip_gps_from_app1_segment(segment_data),
               else: {:ok, segment_data, false}
             ) do
        segment = <<0xFF, marker, segment_length::16>> <> segment_data
        strip_jpeg_segments(remaining, [segment | acc], changed? or patched?)
      end
    else
      {:error, :invalid_jpeg}
    end
  end

  defp strip_jpeg_segments(<<>>, acc, changed?), do: {:ok, Enum.reverse(acc), changed?}
  defp strip_jpeg_segments(_data, _acc, _changed?), do: {:error, :invalid_jpeg}

  defp strip_gps_from_app1_segment(<<"Exif", 0, 0, _::binary>> = payload),
    do: strip_gps_from_exif_payload(payload)

  defp strip_gps_from_app1_segment(payload), do: {:ok, payload, false}

  defp strip_gps_from_exif_payload(<<"Exif", 0, 0, tiff::binary>>) do
    with {:ok, new_tiff, patched?} <- strip_gps_from_tiff(tiff) do
      {:ok, <<"Exif", 0, 0>> <> new_tiff, patched?}
    end
  end

  defp strip_gps_from_exif_payload(tiff), do: strip_gps_from_tiff(tiff)

  defp strip_gps_from_tiff(<<"II", 0x002A::16-little, ifd0_offset::32-little, _::binary>> = tiff) do
    strip_gps_from_ifd0(tiff, ifd0_offset, :little)
  end

  defp strip_gps_from_tiff(<<"MM", 0x002A::16-big, ifd0_offset::32-big, _::binary>> = tiff) do
    strip_gps_from_ifd0(tiff, ifd0_offset, :big)
  end

  defp strip_gps_from_tiff(_), do: {:error, :unsupported_tiff}

  # First validate and collect ranges, then wipe. Keeping offsets and lengths
  # unchanged avoids rebuilding TIFF or changing JPEG/WebP/HEIF container tables.
  defp strip_gps_from_ifd0(tiff, offset, endian) do
    with {:ok, kept, wiped} <-
           collect_ifds(tiff, [{offset, :keep}], endian, MapSet.new(), [], []),
         kept <- merge_ranges(kept),
         wiped <- merge_ranges(wiped),
         false <- ranges_overlap?(kept, wiped) do
      patches = Enum.map(wiped, fn {pos, len} -> {pos, len, :binary.copy(<<0>>, len)} end)
      {:ok, apply_binary_patches(tiff, patches), wiped != []}
    else
      true -> {:error, :overlapping_gps_data}
      {:error, _} = error -> error
    end
  end

  defp collect_ifds(_tiff, [], _endian, _seen, kept, wiped), do: {:ok, [{0, 8} | kept], wiped}

  defp collect_ifds(tiff, [{offset, role} | pending], endian, seen, kept, wiped) do
    with false <- MapSet.member?(seen, offset),
         {:ok, entries, next, size} <- read_ifd(tiff, offset, endian),
         {kept, wiped} <-
           if(role == :wipe,
             do: {kept, [{offset, size} | wiped]},
             else: {[{offset, 2}, {offset + size - 4, 4} | kept], wiped}
           ),
         pending <- if(next == 0, do: pending, else: [{next, role} | pending]),
         {:ok, pending, kept, wiped} <-
           Enum.reduce_while(entries, {:ok, pending, kept, wiped}, fn entry,
                                                                      {:ok, todo, keep, wipe} ->
             case collect_entry(tiff, entry, role, endian, todo, keep, wipe) do
               {:ok, _, _, _} = result -> {:cont, result}
               {:error, _} = error -> {:halt, error}
             end
           end) do
      collect_ifds(tiff, pending, endian, MapSet.put(seen, offset), kept, wiped)
    else
      true -> {:error, :cyclic_ifd}
      {:error, _} = error -> error
    end
  end

  defp read_ifd(tiff, offset, endian) do
    with true <- valid_range?(tiff, offset, 2),
         count <- read_uint(tiff, offset, 2, endian),
         size <- 2 + count * 12 + 4,
         true <- valid_range?(tiff, offset, size) do
      entries = for i <- indices(count), do: offset + 2 + i * 12
      {:ok, entries, read_uint(tiff, offset + size - 4, 4, endian), size}
    else
      _ -> {:error, :invalid_ifd}
    end
  end

  defp collect_entry(tiff, pos, role, endian, pending, kept, wiped) do
    tag = read_uint(tiff, pos, 2, endian)
    type = read_uint(tiff, pos + 2, 2, endian)
    count = read_uint(tiff, pos + 4, 4, endian)
    value = read_uint(tiff, pos + 8, 4, endian)

    cond do
      role == :keep and tag == @gps_ifd_tag ->
        if type == 4 and count == 1 and value >= 8 do
          {:ok, [{value, :wipe} | pending], kept, [{pos, 12} | wiped]}
        else
          {:error, :invalid_gps_pointer}
        end

      # Entries wiped by a previous invocation are deliberately left as padding.
      tag == 0 and type == 0 and count == 0 and value == 0 ->
        kept = if role == :keep, do: [{pos, 12} | kept], else: kept
        {:ok, pending, kept, wiped}

      true ->
        with {:ok, width} <- tiff_type_size(type),
             true <- count > 0,
             length <- count * width,
             start <- if(length <= 4, do: pos + 8, else: value),
             true <- valid_range?(tiff, start, length),
             {:ok, pending} <-
               referenced_ifds(tiff, tag, type, count, start, role, endian, pending) do
          ranges = if length > 4, do: [{start, length}], else: []

          if role == :wipe do
            {:ok, pending, kept, ranges ++ wiped}
          else
            {:ok, pending, [{pos, 12} | ranges ++ kept], wiped}
          end
        else
          _ -> {:error, :invalid_tiff_entry}
        end
    end
  end

  # Follow standard non-GPS subdirectories so their contents cannot accidentally
  # be wiped through an overlapping GPS value. GPS fields themselves are scalar.
  defp referenced_ifds(_tiff, _tag, 13, _count, _start, :wipe, _endian, _pending),
    do: {:error, :unsupported_gps_pointer}

  defp referenced_ifds(tiff, tag, type, count, start, :keep, endian, pending)
       when tag in [0x8769, 0xA005, 0x014A] or type == 13 do
    if type in [4, 13] and (tag == 0x014A or type == 13 or count == 1) do
      offsets = for i <- indices(count), do: {read_uint(tiff, start + i * 4, 4, endian), :keep}
      {:ok, offsets ++ pending}
    else
      {:error, :invalid_ifd_pointer}
    end
  end

  defp referenced_ifds(_tiff, _tag, _type, _count, _start, _role, _endian, pending),
    do: {:ok, pending}

  defp tiff_type_size(type) when type in [1, 2, 6, 7], do: {:ok, 1}
  defp tiff_type_size(type) when type in [3, 8], do: {:ok, 2}
  defp tiff_type_size(type) when type in [4, 9, 11, 13], do: {:ok, 4}
  defp tiff_type_size(type) when type in [5, 10, 12], do: {:ok, 8}
  defp tiff_type_size(_), do: {:error, :unsupported_tiff_type}

  defp valid_range?(data, offset, length),
    do: offset >= 8 and length > 0 and offset + length <= byte_size(data)

  defp read_uint(data, offset, bytes, endian),
    do: data |> binary_part(offset, bytes) |> :binary.decode_unsigned(endian)

  defp indices(0), do: []
  defp indices(count), do: 0..(count - 1)

  defp merge_ranges(ranges) do
    ranges
    |> Enum.sort()
    |> Enum.reduce([], fn
      {pos, len}, [{prev, size} | rest] when pos <= prev + size ->
        [{prev, max(prev + size, pos + len) - prev} | rest]

      range, acc ->
        [range | acc]
    end)
    |> Enum.reverse()
  end

  defp ranges_overlap?([], _), do: false
  defp ranges_overlap?(_, []), do: false

  defp ranges_overlap?([{a, alen} | as], [{b, blen} | bs]) do
    cond do
      a + alen <= b -> ranges_overlap?(as, [{b, blen} | bs])
      b + blen <= a -> ranges_overlap?([{a, alen} | as], bs)
      true -> true
    end
  end

  defp strip_isobmff_exif_items(data) when is_binary(data) do
    with {:ok, exif_locations} <- ISOBMFF.exif_item_locations(data),
         {:ok, patches, changed?} <- isobmff_gps_patches(data, exif_locations),
         :ok <- validate_disjoint_patches(patches) do
      {:ok, apply_binary_patches(data, patches), changed?}
    else
      {:error, _} = error -> error
      _ -> {:ok, data, false}
    end
  end

  defp isobmff_gps_patches(_data, []), do: {:ok, [], false}

  defp isobmff_gps_patches(data, exif_items) do
    Enum.reduce_while(exif_items, {:ok, [], false}, fn {_item_id, extents},
                                                       {:ok, acc, changed?} ->
      with true <-
             extents != [] and
               Enum.all?(extents, fn %{offset: offset, length: length} ->
                 offset >= 0 and length > 0 and byte_size(data) >= offset + length
               end),
           exif_item <-
             Enum.map(extents, fn %{offset: offset, length: length} ->
               binary_part(data, offset, length)
             end)
             |> IO.iodata_to_binary(),
           {:ok, new_exif_item, patched?} <- patch_heif_exif_item(exif_item),
           {:ok, item_patches} <- split_isobmff_item_to_patches(extents, new_exif_item) do
        {:cont, {:ok, item_patches ++ acc, changed? or patched?}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :invalid_exif_extents}}
      end
    end)
  end

  # Whole-item replacements must never read backwards into unsanitized bytes.
  # Check all physical ranges together, including aliases across different IDs.
  defp validate_disjoint_patches(patches) do
    overlap? =
      patches
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [{offset, length, _}, {next_offset, _, _}] ->
        offset + length > next_offset
      end)

    if overlap?, do: {:error, :overlapping_exif_extents}, else: :ok
  end

  defp split_isobmff_item_to_patches(extents, new_item) do
    {patches, rest} =
      Enum.reduce(extents, {[], new_item}, fn %{offset: offset, length: length},
                                              {acc, remaining} ->
        <<part::binary-size(length), rest::binary>> = remaining
        {[{offset, length, part} | acc], rest}
      end)

    if rest == <<>> do
      {:ok, Enum.reverse(patches)}
    else
      {:error, :length_mismatch}
    end
  rescue
    _ -> {:error, :invalid_extents}
  end

  defp patch_heif_exif_item(<<tiff_offset::32-big, rest::binary>>)
       when byte_size(rest) >= tiff_offset do
    <<prelude::binary-size(tiff_offset), tiff::binary>> = rest

    case strip_gps_from_tiff(tiff) do
      {:ok, new_tiff, true} ->
        {:ok, <<tiff_offset::32-big>> <> prelude <> new_tiff, true}

      {:ok, _tiff, false} ->
        {:ok, <<tiff_offset::32-big>> <> prelude <> tiff, false}

      {:error, _} ->
        {:error, :invalid_tiff}
    end
  end

  defp patch_heif_exif_item(_), do: {:error, :invalid_exif_item}

  defp apply_binary_patches(data, patches) do
    patches =
      patches
      |> Enum.sort_by(fn {offset, _len, _replacement} -> offset end)

    {iodata, pos} =
      Enum.reduce(patches, {[], 0}, fn {offset, len, replacement}, {acc, pos} ->
        acc = [acc, binary_part(data, pos, offset - pos), replacement]
        {acc, offset + len}
      end)

    IO.iodata_to_binary([iodata, binary_part(data, pos, byte_size(data) - pos)])
  end
end
