# SPDX-License-Identifier: MIT

defmodule ExifStripper.ISOBMFF do
  @moduledoc false
  # Shared ISO Base Media File Format (HEIC, AVIF) parsing: finds the Exif
  # items and where they are stored in the file.

  @doc """
  Returns the file extents of every Exif item. Fails closed on malformed
  boxes, and on Exif items that are not stored at plain file offsets.
  """
  @spec exif_item_locations(binary()) ::
          {:ok, [{non_neg_integer(), [%{offset: integer(), length: integer()}]}]}
          | {:error, term()}
  def exif_item_locations(data) when is_binary(data) do
    with {:ok, meta_payload} <- isobmff_find_meta_payload(data),
         {:ok, iinf_box} <- isobmff_find_child_box(meta_payload, "iinf"),
         {:ok, iloc_box} <- isobmff_find_child_box(meta_payload, "iloc"),
         {:ok, exif_item_ids} <- isobmff_exif_item_ids(iinf_box),
         {:ok, item_locations} <- isobmff_item_locations(iloc_box) do
      isobmff_pick_items(item_locations, exif_item_ids)
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
         <<version::8, _flags::24, rest::binary>> <- payload,
         {item_count, rest} <-
           if(version == 0, do: decode_u16_be(rest), else: decode_u32_be(rest)),
         {:ok, ids} <- isobmff_collect_infe_exif_ids(rest, item_count, []) do
      {:ok, Enum.reverse(ids)}
    else
      _ -> {:error, :invalid_iinf_box}
    end
  rescue
    _ -> {:error, :invalid_iinf_box}
  end

  defp isobmff_collect_infe_exif_ids(_rest, 0, acc), do: {:ok, acc}

  defp isobmff_collect_infe_exif_ids(rest, remaining, acc) do
    with {:ok, "infe", box_size, _header_size} <- isobmff_box_header(rest),
         <<box::binary-size(box_size), next::binary>> <- rest,
         {:ok, item_id, item_type} <- isobmff_infe_item(box) do
      acc = if item_type == "Exif", do: [item_id | acc], else: acc
      isobmff_collect_infe_exif_ids(next, remaining - 1, acc)
    else
      _ -> {:error, :invalid_iinf_box}
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
         true <- version in [0, 1, 2],
         <<offset_and_length_sizes::8, base_and_reserved::8, rest::binary>> <- rest do
      offset_size = div(offset_and_length_sizes, 16)
      length_size = rem(offset_and_length_sizes, 16)
      base_offset_size = div(base_and_reserved, 16)

      index_size = if version in [1, 2], do: rem(base_and_reserved, 16), else: 0

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
  rescue
    _ -> {:error, :invalid_iloc}
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

    {construction_method, rest} =
      if version in [1, 2] do
        <<_reserved::12, construction_method::4, rest::binary>> = rest
        {construction_method, rest}
      else
        {0, rest}
      end

    {data_reference_index, rest} = decode_u16_be(rest)

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

    # Only items stored at file offsets (construction method 0, in this file)
    # can be patched in place. Others (e.g. grid items in `idat`) are fine
    # unless they are the Exif item, see isobmff_pick_items/2.
    location =
      if construction_method == 0 and data_reference_index == 0, do: extents, else: :unsupported

    acc =
      Map.update(acc, item_id, location, fn
        existing when is_list(existing) and is_list(location) -> existing ++ location
        _ -> :unsupported
      end)

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
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Map.get(item_locations, id, []) do
        :unsupported -> {:halt, {:error, :unsupported_exif_location}}
        extents -> {:cont, {:ok, acc ++ [{id, extents}]}}
      end
    end)
  end

  defp decode_u16_be(<<value::16-big, rest::binary>>), do: {value, rest}
  defp decode_u32_be(<<value::32-big, rest::binary>>), do: {value, rest}

  defp decode_uint_be(rest, 0), do: {0, rest}

  defp decode_uint_be(rest, bytes) when bytes in 1..8 and byte_size(rest) >= bytes do
    <<value::binary-size(bytes), rest::binary>> = rest
    {:binary.decode_unsigned(value, :big), rest}
  end
end
