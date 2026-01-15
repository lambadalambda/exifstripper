# SPDX-License-Identifier: MIT

defmodule ExifStripper.GpsStripper do
  @moduledoc """
  Losslessly strips GPS-related EXIF metadata, without re-encoding images.

  Supported containers:

  - JPEG: clears the GPS IFD pointer in EXIF (APP1)
  - WebP: clears the GPS IFD pointer in the `EXIF` RIFF chunk
  - HEIC / other ISO-BMFF images: clears the GPS IFD pointer in the `Exif` item
  - PNG: removes metadata chunks (`eXIf`, `tEXt`, `zTXt`, `iTXt`)

  If no supported metadata is found, returns `:noop` and does not change the output.
  """

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

  defp process_file(_), do: :noop

  defp strip_png_chunks(<<>>, acc, stripped?),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(acc)), stripped?}

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

    {chunk_data, patched?} =
      if chunk_type == "EXIF" do
        strip_gps_from_exif_payload(chunk_data)
      else
        {chunk_data, false}
      end

    chunk = <<chunk_type::binary-size(4), chunk_size::32-little>> <> chunk_data <> padding
    strip_webp_chunks(remaining, [chunk | acc], stripped? or patched?)
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

      {segment_data, patched?} =
        if marker == @jpg_app1_marker do
          strip_gps_from_app1_segment(segment_data)
        else
          {segment_data, false}
        end

      segment = <<0xFF, marker, segment_length::16>> <> segment_data
      strip_jpeg_segments(remaining, [segment | acc], changed? or patched?)
    else
      {:error, :invalid_jpeg}
    end
  end

  defp strip_jpeg_segments(<<>>, acc, changed?), do: {:ok, Enum.reverse(acc), changed?}
  defp strip_jpeg_segments(_data, _acc, _changed?), do: {:error, :invalid_jpeg}

  defp strip_gps_from_app1_segment(<<"Exif", 0, 0, tiff::binary>> = segment_data) do
    case strip_gps_from_tiff(tiff) do
      {:ok, _tiff, false} -> {segment_data, false}
      {:ok, new_tiff, true} -> {<<"Exif", 0, 0>> <> new_tiff, true}
      {:error, _reason} -> {segment_data, false}
    end
  end

  defp strip_gps_from_app1_segment(segment_data), do: {segment_data, false}

  defp strip_gps_from_exif_payload(payload) when is_binary(payload) do
    case strip_gps_from_tiff(payload) do
      {:ok, new_tiff, patched?} -> {new_tiff, patched?}
      {:error, _reason} -> {payload, false}
    end
  end

  defp strip_gps_from_tiff(<<"II", 0x002A::16-little, ifd0_offset::32-little, _::binary>> = tiff) do
    strip_gps_from_ifd0(tiff, ifd0_offset, :little)
  end

  defp strip_gps_from_tiff(<<"MM", 0x002A::16-big, ifd0_offset::32-big, _::binary>> = tiff) do
    strip_gps_from_ifd0(tiff, ifd0_offset, :big)
  end

  defp strip_gps_from_tiff(_), do: {:error, :unsupported_tiff}

  defp strip_gps_from_ifd0(tiff, ifd0_offset, endian) do
    if byte_size(tiff) < ifd0_offset + 2 do
      {:error, :invalid_ifd0_offset}
    else
      <<before_ifd0::binary-size(ifd0_offset), ifd0::binary>> = tiff

      {entry_count, entry_count_bytes, ifd0_entries_and_rest} =
        case endian do
          :little ->
            <<count::16-little, rest::binary>> = ifd0
            {count, <<count::16-little>>, rest}

          :big ->
            <<count::16-big, rest::binary>> = ifd0
            {count, <<count::16-big>>, rest}
        end

      entries_len = entry_count * 12

      if byte_size(ifd0_entries_and_rest) < entries_len do
        {:error, :invalid_ifd0}
      else
        <<entries::binary-size(entries_len), rest_after_entries::binary>> = ifd0_entries_and_rest

        {patched_entries, patched?} = patch_ifd_entries(entries, endian, false, [])

        new_tiff = before_ifd0 <> entry_count_bytes <> patched_entries <> rest_after_entries
        {:ok, new_tiff, patched?}
      end
    end
  end

  defp patch_ifd_entries(<<>>, _endian, patched?, acc),
    do: {IO.iodata_to_binary(Enum.reverse(acc)), patched?}

  defp patch_ifd_entries(<<entry::binary-size(12), rest::binary>>, endian, patched?, acc) do
    tag =
      case endian do
        :little ->
          <<tag::16-little, _::binary-size(10)>> = entry
          tag

        :big ->
          <<tag::16-big, _::binary-size(10)>> = entry
          tag
      end

    if tag == @gps_ifd_tag do
      patch_ifd_entries(rest, endian, true, [<<0::size(12)-unit(8)>> | acc])
    else
      patch_ifd_entries(rest, endian, patched?, [entry | acc])
    end
  end

  defp strip_isobmff_exif_items(data) when is_binary(data) do
    with {:ok, meta_payload} <- isobmff_find_meta_payload(data),
         {:ok, iinf_box} <- isobmff_find_child_box(meta_payload, "iinf"),
         {:ok, iloc_box} <- isobmff_find_child_box(meta_payload, "iloc"),
         {:ok, exif_item_ids} <- isobmff_exif_item_ids(iinf_box),
         {:ok, item_locations} <- isobmff_item_locations(iloc_box),
         exif_locations <- isobmff_pick_items(item_locations, exif_item_ids),
         {:ok, patches, changed?} <- isobmff_gps_patches(data, exif_locations) do
      {:ok, apply_binary_patches(data, patches), changed?}
    else
      {:error, _} = error -> error
      _ -> {:ok, data, false}
    end
  end

  defp isobmff_find_meta_payload(data) do
    case isobmff_find_top_box(data, "meta") do
      {:ok, meta_box} ->
        with {:ok, payload} <- isobmff_box_payload(meta_box),
             <<_version::8, _flags::24, rest::binary>> <- payload do
          {:ok, rest}
        else
          _ -> {:error, :invalid_meta_box}
        end

      _ ->
        {:error, :no_meta_box}
    end
  end

  defp isobmff_find_top_box(data, wanted_type) do
    do_isobmff_find_top_box(data, wanted_type)
  end

  defp do_isobmff_find_top_box(<<>>, _wanted_type), do: {:error, :not_found}

  defp do_isobmff_find_top_box(data, wanted_type) when is_binary(data) do
    with {:ok, box_type, box_size, _header_size} <- isobmff_box_header(data),
         true <- byte_size(data) >= box_size do
      <<box::binary-size(box_size), rest::binary>> = data

      if box_type == wanted_type do
        {:ok, box}
      else
        do_isobmff_find_top_box(rest, wanted_type)
      end
    else
      _ -> {:error, :invalid_isobmff}
    end
  end

  defp isobmff_find_child_box(data, wanted_type) when is_binary(data) do
    case do_isobmff_find_child_box(data, wanted_type) do
      {:ok, box} -> {:ok, box}
      _ -> {:error, :not_found}
    end
  end

  defp do_isobmff_find_child_box(<<>>, _wanted_type), do: {:error, :not_found}

  defp do_isobmff_find_child_box(data, wanted_type) do
    with {:ok, box_type, box_size, _header_size} <- isobmff_box_header(data),
         true <- byte_size(data) >= box_size do
      <<box::binary-size(box_size), rest::binary>> = data

      if box_type == wanted_type do
        {:ok, box}
      else
        do_isobmff_find_child_box(rest, wanted_type)
      end
    else
      _ -> {:error, :invalid_isobmff}
    end
  end

  defp isobmff_box_header(<<size::32-big, type::binary-size(4), _rest::binary>>) when size >= 8,
    do: {:ok, type, size, 8}

  defp isobmff_box_header(<<1::32-big, type::binary-size(4), size::64-big, _rest::binary>>)
       when size >= 16,
       do: {:ok, type, size, 16}

  defp isobmff_box_header(_), do: {:error, :invalid_box_header}

  defp isobmff_box_payload(box) when is_binary(box) do
    with {:ok, _type, box_size, header_size} <- isobmff_box_header(box),
         true <- byte_size(box) >= box_size,
         payload_size <- box_size - header_size,
         payload when payload_size >= 0 <- binary_part(box, header_size, payload_size) do
      {:ok, payload}
    else
      _ -> {:error, :invalid_box}
    end
  end

  defp isobmff_exif_item_ids(iinf_box) do
    with {:ok, payload} <- isobmff_box_payload(iinf_box),
         <<version::8, _flags::24, rest::binary>> <- payload do
      {item_count, rest} =
        case version do
          0 -> decode_u16_be(rest)
          1 -> decode_u16_be(rest)
          _ -> decode_u32_be(rest)
        end

      {ids, _rest} = isobmff_collect_infe_exif_ids(rest, item_count, [])
      {:ok, Enum.reverse(ids)}
    else
      _ -> {:error, :invalid_iinf_box}
    end
  end

  defp isobmff_collect_infe_exif_ids(rest, 0, acc), do: {acc, rest}

  defp isobmff_collect_infe_exif_ids(rest, remaining, acc) do
    with {:ok, box_type, box_size, _header_size} <- isobmff_box_header(rest),
         true <- byte_size(rest) >= box_size,
         <<box::binary-size(box_size), next::binary>> <- rest do
      acc =
        if box_type == "infe" do
          case isobmff_infe_item(box) do
            {:ok, item_id, "Exif"} -> [item_id | acc]
            _ -> acc
          end
        else
          acc
        end

      isobmff_collect_infe_exif_ids(next, remaining - 1, acc)
    else
      _ -> {acc, rest}
    end
  end

  defp isobmff_infe_item(infe_box) do
    with {:ok, payload} <- isobmff_box_payload(infe_box),
         <<version::8, _flags::24, rest::binary>> <- payload do
      case version do
        2 ->
          with {item_id, rest} <- decode_u16_be(rest),
               {_protection, rest} <- decode_u16_be(rest),
               <<item_type::binary-size(4), _::binary>> <- rest do
            {:ok, item_id, item_type}
          else
            _ -> {:error, :invalid_infe}
          end

        3 ->
          with {item_id, rest} <- decode_u32_be(rest),
               {_protection, rest} <- decode_u16_be(rest),
               <<item_type::binary-size(4), _::binary>> <- rest do
            {:ok, item_id, item_type}
          else
            _ -> {:error, :invalid_infe}
          end

        _ ->
          {:error, :unsupported_infe}
      end
    else
      _ -> {:error, :invalid_infe}
    end
  end

  defp isobmff_item_locations(iloc_box) do
    with {:ok, payload} <- isobmff_box_payload(iloc_box),
         <<version::8, _flags::24, rest::binary>> <- payload,
         <<offset_and_length_sizes::8, base_and_reserved::8, rest::binary>> <- rest do
      offset_size = div(offset_and_length_sizes, 16)
      length_size = rem(offset_and_length_sizes, 16)
      base_offset_size = div(base_and_reserved, 16)

      {index_size, rest} =
        if version in [1, 2] do
          <<index_and_reserved::8, rest::binary>> = rest
          {div(index_and_reserved, 16), rest}
        else
          {0, rest}
        end

      {item_count, rest} =
        if version == 2 do
          decode_u32_be(rest)
        else
          decode_u16_be(rest)
        end

      {locations, _rest} =
        isobmff_parse_iloc_items(
          rest,
          version,
          item_count,
          offset_size,
          length_size,
          base_offset_size,
          index_size,
          %{}
        )

      {:ok, locations}
    else
      _ -> {:error, :invalid_iloc}
    end
  end

  defp isobmff_parse_iloc_items(rest, _version, 0, _os, _ls, _bos, _is, acc), do: {acc, rest}

  defp isobmff_parse_iloc_items(
         rest,
         version,
         remaining,
         offset_size,
         length_size,
         base_offset_size,
         index_size,
         acc
       ) do
    {item_id, rest} =
      if version == 2 do
        decode_u32_be(rest)
      else
        decode_u16_be(rest)
      end

    rest =
      if version in [1, 2] do
        <<_reserved::12, _construction_method::4, rest::binary>> = rest
        rest
      else
        rest
      end

    {_data_reference_index, rest} = decode_u16_be(rest)

    {base_offset, rest} = decode_uint_be(rest, base_offset_size)
    {extent_count, rest} = decode_u16_be(rest)

    {extents, rest} =
      isobmff_parse_iloc_extents(
        rest,
        version,
        extent_count,
        offset_size,
        length_size,
        index_size,
        base_offset,
        []
      )

    acc = Map.update(acc, item_id, extents, fn existing -> existing ++ extents end)

    isobmff_parse_iloc_items(
      rest,
      version,
      remaining - 1,
      offset_size,
      length_size,
      base_offset_size,
      index_size,
      acc
    )
  rescue
    _ -> {acc, rest}
  end

  defp isobmff_parse_iloc_extents(rest, _version, 0, _os, _ls, _is, _base_offset, acc),
    do: {Enum.reverse(acc), rest}

  defp isobmff_parse_iloc_extents(
         rest,
         version,
         remaining,
         offset_size,
         length_size,
         index_size,
         base_offset,
         acc
       ) do
    rest =
      if version in [1, 2] and index_size > 0 do
        <<_extent_index::binary-size(index_size), rest::binary>> = rest
        rest
      else
        rest
      end

    {extent_offset, rest} = decode_uint_be(rest, offset_size)
    {extent_length, rest} = decode_uint_be(rest, length_size)

    abs_offset = base_offset + extent_offset
    extent = %{offset: abs_offset, length: extent_length}

    isobmff_parse_iloc_extents(
      rest,
      version,
      remaining - 1,
      offset_size,
      length_size,
      index_size,
      base_offset,
      [extent | acc]
    )
  end

  defp isobmff_pick_items(item_locations, ids) when is_map(item_locations) and is_list(ids) do
    ids
    |> Enum.map(fn id -> {id, Map.get(item_locations, id, [])} end)
    |> Enum.reject(fn {_id, extents} -> extents == [] end)
  end

  defp isobmff_gps_patches(_data, []), do: {:ok, [], false}

  defp isobmff_gps_patches(data, exif_items) do
    {patches, changed?} =
      Enum.reduce(exif_items, {[], false}, fn {_item_id, extents}, {acc, changed?} ->
        extents = Enum.sort_by(extents, & &1.offset)

        with true <- Enum.all?(extents, &is_map/1),
             true <-
               Enum.all?(extents, fn %{offset: offset, length: length} ->
                 length > 0 and byte_size(data) >= offset + length
               end),
             exif_item <-
               Enum.map(extents, fn %{offset: offset, length: length} ->
                 binary_part(data, offset, length)
               end),
             exif_item <- IO.iodata_to_binary(exif_item),
             {:ok, new_exif_item, true} <- patch_heif_exif_item(exif_item),
             {:ok, item_patches} <- split_isobmff_item_to_patches(extents, new_exif_item) do
          {acc ++ item_patches, true}
        else
          _ -> {acc, changed?}
        end
      end)

    {:ok, patches, changed?}
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

  defp decode_u16_be(<<value::16-big, rest::binary>>), do: {value, rest}
  defp decode_u32_be(<<value::32-big, rest::binary>>), do: {value, rest}

  defp decode_uint_be(rest, 0), do: {0, rest}

  defp decode_uint_be(rest, bytes) when bytes in 1..8 and byte_size(rest) >= bytes do
    <<value::binary-size(bytes), rest::binary>> = rest
    {:binary.decode_unsigned(value, :big), rest}
  end
end
