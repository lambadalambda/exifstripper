# SPDX-License-Identifier: MIT

defmodule ExifStripper.ISOBMFF do
  @moduledoc false
  # Shared ISO Base Media File Format (HEIC, AVIF) parsing: finds the Exif and
  # XMP items and where they are stored in the file.

  alias ExifStripper.Reader

  @type extents :: [%{offset: integer(), length: integer()}]

  @doc "Returns the file extents of every Exif item, see `metadata_item_locations/1`."
  @spec exif_item_locations(binary()) ::
          {:ok, [{non_neg_integer(), extents()}]} | {:error, term()}
  def exif_item_locations(data) when is_binary(data) do
    with {:ok, items} <- metadata_item_locations(Reader.from_binary(data), [:exif]),
         do: {:ok, for({:exif, id, extents} <- items, do: {id, extents})}
  end

  @doc """
  Returns the file extents of every Exif and/or XMP (`application/rdf+xml`)
  item. Fails closed on malformed boxes, and on wanted items that are not
  stored at plain file offsets or are encoded XMP. Only the top-level box
  headers and the `meta` box are read.
  """
  @spec metadata_item_locations(Reader.t(), [:exif | :xmp]) ::
          {:ok, [{:exif | :xmp, non_neg_integer(), extents()}]} | {:error, term()}
  def metadata_item_locations(%Reader{} = reader, kinds) do
    with {:ok, meta_payload} <- isobmff_find_meta_payload(reader),
         {:ok, iinf_box} <- isobmff_find_child_box(meta_payload, "iinf"),
         {:ok, iloc_box} <- isobmff_find_child_box(meta_payload, "iloc"),
         {:ok, metadata_items} <- isobmff_metadata_items(iinf_box),
         {:ok, item_locations} <- isobmff_item_locations(iloc_box) do
      wanted = Enum.filter(metadata_items, fn {kind, _id} -> base_kind(kind) in kinds end)
      isobmff_pick_items(item_locations, wanted)
    end
  end

  defp isobmff_find_meta_payload(reader) do
    case find_top_box(reader, 0, "meta") do
      {:ok, meta_box} ->
        with {:ok, payload} <- isobmff_box_payload(meta_box),
             <<_version::8, _flags::24, rest::binary>> <- payload do
          {:ok, rest}
        else
          _ -> {:error, :invalid_meta_box}
        end

      {:error, :metadata_too_large} = error ->
        error

      _ ->
        {:error, :no_meta_box}
    end
  end

  defp find_top_box(reader, pos, wanted_type) do
    case Reader.peek(reader, pos, 16) do
      {<<>>, _reader} ->
        {:error, :not_found}

      {header, reader} ->
        with {:ok, box_type, box_size, _header_size} <- isobmff_box_header(header),
             true <- Reader.size(reader) - pos >= box_size do
          cond do
            box_type != wanted_type -> find_top_box(reader, pos + box_size, wanted_type)
            box_size > Reader.max_metadata_size() -> {:error, :metadata_too_large}
            true -> Reader.read(reader, pos, box_size)
          end
        else
          _ -> {:error, :invalid_isobmff}
        end
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

  defp isobmff_metadata_items(iinf_box) do
    with {:ok, payload} <- isobmff_box_payload(iinf_box),
         <<version::8, _flags::24, rest::binary>> <- payload,
         {item_count, rest} <-
           if(version == 0, do: decode_u16_be(rest), else: decode_u32_be(rest)),
         {:ok, items} <- isobmff_collect_infe_items(rest, item_count, []) do
      {:ok, Enum.reverse(items)}
    else
      _ -> {:error, :invalid_iinf_box}
    end
  rescue
    _ -> {:error, :invalid_iinf_box}
  end

  defp isobmff_collect_infe_items(_rest, 0, acc), do: {:ok, acc}

  defp isobmff_collect_infe_items(rest, remaining, acc) do
    with {:ok, "infe", box_size, _header_size} <- isobmff_box_header(rest),
         <<box::binary-size(box_size), next::binary>> <- rest,
         {:ok, item_id, item_type, fields} <- isobmff_infe_item(box) do
      acc =
        case metadata_kind(item_type, fields) do
          nil -> acc
          kind -> [{kind, item_id} | acc]
        end

      isobmff_collect_infe_items(next, remaining - 1, acc)
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
               <<item_type::binary-size(4), fields::binary>> <- rest do
            {:ok, item_id, item_type, fields}
          else
            _ -> {:error, :invalid_infe}
          end

        3 ->
          with {item_id, rest} <- decode_u32_be(rest),
               {_protection, rest} <- decode_u16_be(rest),
               <<item_type::binary-size(4), fields::binary>> <- rest do
            {:ok, item_id, item_type, fields}
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

  # `mime` items have null-terminated item_name, content_type and an optional
  # content_encoding. Encoded (e.g. deflated) XMP cannot be patched in place.
  defp metadata_kind("Exif", _fields), do: :exif

  defp metadata_kind("mime", fields) do
    case :binary.split(fields, <<0>>, [:global]) do
      [_name, "application/rdf+xml", encoding | _] when encoding != "" -> :encoded_xmp
      [_name, "application/rdf+xml" | _] -> :xmp
      _ -> nil
    end
  end

  defp metadata_kind(_type, _fields), do: nil

  defp base_kind(:encoded_xmp), do: :xmp
  defp base_kind(kind), do: kind

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

    # Bound the work by the input size: zero-width extents would otherwise let
    # a few bytes claim 65535 extents each. Rescued as :invalid_iloc.
    extent_width = offset_size + length_size + if(version in [1, 2], do: index_size, else: 0)

    if (extent_width == 0 and extent_count > 1) or extent_count * extent_width > byte_size(rest),
      do: raise(ArgumentError, "iloc extents exceed the box")

    if Map.has_key?(acc, item_id), do: raise(ArgumentError, "duplicate iloc item")

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

    acc = Map.put(acc, item_id, location)

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

  defp isobmff_pick_items(item_locations, items) when is_map(item_locations) do
    items
    |> Enum.reduce_while({:ok, []}, fn {kind, id}, {:ok, acc} ->
      case {kind, Map.get(item_locations, id, [])} do
        {:encoded_xmp, _} -> {:halt, {:error, :unsupported_xmp_encoding}}
        {:exif, :unsupported} -> {:halt, {:error, :unsupported_exif_location}}
        {:xmp, :unsupported} -> {:halt, {:error, :unsupported_xmp_location}}
        {kind, extents} -> {:cont, {:ok, [{kind, id, extents} | acc]}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp decode_u16_be(<<value::16-big, rest::binary>>), do: {value, rest}
  defp decode_u32_be(<<value::32-big, rest::binary>>), do: {value, rest}

  defp decode_uint_be(rest, 0), do: {0, rest}

  defp decode_uint_be(rest, bytes) when bytes in 1..8 and byte_size(rest) >= bytes do
    <<value::binary-size(bytes), rest::binary>> = rest
    {:binary.decode_unsigned(value, :big), rest}
  end
end
