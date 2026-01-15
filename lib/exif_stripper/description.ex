# SPDX-License-Identifier: MIT

defmodule ExifStripper.Description do
  @moduledoc """
  Reads a human-readable description from common image metadata fields.

  Extraction order:

  - EXIF `ImageDescription`
  - IPTC `Caption-Abstract` (JPEG APP13 / PNG raw profiles)
  - XMP `tiff:ImageDescription` (GIF application extension)

  Supported containers:

  - JPEG
  - PNG
  - WebP (EXIF chunk)
  - HEIC / other ISO-BMFF images (Exif item)
  - GIF (XMP)
  """

  @image_description_exif_tag 0x010E

  @iptc_marker 0x1C
  @iptc_caption_record 0x02
  @iptc_caption_dataset 0x78

  @png_signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @jpg_soi_marker <<0xFF, 0xD8>>
  @webp_riff_marker "RIFF"
  @gif87a_header "GIF87a"
  @gif89a_header "GIF89a"

  @spec read_file(Path.t(), keyword()) :: String.t() | nil
  def read_file(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with true <- File.exists?(path),
         {:ok, data} <- File.read(path) do
      read_binary(data, opts)
    else
      _ -> nil
    end
  end

  @spec read_binary(binary(), keyword()) :: String.t() | nil
  def read_binary(data, opts \\ []) when is_binary(data) and is_list(opts) do
    data
    |> read_description_from_binary()
    |> normalize_description(opts)
  end

  defp read_description_from_binary(<<@jpg_soi_marker, _rest::binary>> = data) do
    case jpeg_image_description(data) do
      description when is_binary(description) -> description
      _ -> jpeg_iptc_caption_abstract(data)
    end
  end

  defp read_description_from_binary(<<@png_signature, _rest::binary>> = data) do
    case png_image_description(data) do
      description when is_binary(description) -> description
      _ -> png_iptc_caption_abstract(data)
    end
  end

  defp read_description_from_binary(
         <<@webp_riff_marker, _riff_size::32-little, "WEBP", _rest::binary>> = data
       ) do
    webp_image_description(data)
  end

  defp read_description_from_binary(<<@gif87a_header, _rest::binary>> = data) do
    gif_image_description(data)
  end

  defp read_description_from_binary(<<@gif89a_header, _rest::binary>> = data) do
    gif_image_description(data)
  end

  defp read_description_from_binary(<<_size::32-big, "ftyp", _rest::binary>> = data) do
    isobmff_image_description(data)
  end

  defp read_description_from_binary(_), do: nil

  defp normalize_description(nil, _opts), do: nil

  defp normalize_description(description, opts) when is_binary(description) and is_list(opts) do
    description =
      description
      |> to_utf8()
      |> String.trim()

    max_length = opts[:max_length]

    cond do
      description == "" ->
        nil

      is_integer(max_length) and String.length(description) > max_length ->
        nil

      true ->
        description
    end
  end

  defp to_utf8(data) when is_binary(data) do
    if String.valid?(data) do
      data
    else
      :unicode.characters_to_binary(data, :latin1)
    end
  end

  defp jpeg_image_description(data) do
    data
    |> jpeg_find_exif_tiff()
    |> exif_ascii_tag(@image_description_exif_tag)
  rescue
    _ -> nil
  end

  defp jpeg_iptc_caption_abstract(data) do
    data
    |> jpeg_find_app13_photoshop()
    |> photoshop_irb_caption_abstract()
  rescue
    _ -> nil
  end

  defp png_image_description(data) do
    case png_text_keyword(data, "exif:ImageDescription") do
      nil ->
        data
        |> png_find_exif_tiff()
        |> exif_ascii_tag(@image_description_exif_tag)

      description ->
        description
    end
  rescue
    _ -> nil
  end

  defp png_iptc_caption_abstract(data) do
    iptc_profile_data =
      data
      |> png_text_or_compressed_text_keyword("Raw profile type iptc")
      |> decode_imagemagick_profile()

    caption =
      case iptc_profile_data do
        nil -> nil
        iptc -> iptc_caption_abstract(iptc)
      end

    if is_binary(caption) do
      caption
    else
      data
      |> png_text_or_compressed_text_keyword("Raw profile type 8bim")
      |> decode_imagemagick_profile()
      |> photoshop_irb_caption_abstract()
    end
  rescue
    _ -> nil
  end

  defp webp_image_description(data) do
    data
    |> webp_find_exif_tiff()
    |> exif_ascii_tag(@image_description_exif_tag)
  rescue
    _ -> nil
  end

  defp gif_image_description(data) do
    data
    |> gif_find_xmp()
    |> xmp_image_description()
  rescue
    _ -> nil
  end

  defp gif_find_xmp(data) when is_binary(data) do
    case :binary.match(data, <<0x21, 0xFF, 0x0B, "XMP DataXMP">>) do
      {start, _len} ->
        xmp_start = start + 3 + byte_size("XMP DataXMP")
        gif_read_sub_blocks(binary_part(data, xmp_start, byte_size(data) - xmp_start), [])

      :nomatch ->
        nil
    end
  end

  defp gif_read_sub_blocks(<<0, _rest::binary>>, acc),
    do: IO.iodata_to_binary(Enum.reverse(acc))

  defp gif_read_sub_blocks(<<size::8, rest::binary>>, acc) when byte_size(rest) >= size do
    <<chunk::binary-size(size), rest::binary>> = rest
    gif_read_sub_blocks(rest, [chunk | acc])
  end

  defp gif_read_sub_blocks(_rest, _acc), do: nil

  defp xmp_image_description(nil), do: nil

  defp xmp_image_description(xmp) when is_binary(xmp) do
    xmp = xmp |> to_utf8()

    with [inner] <-
           Regex.run(
             ~r/<tiff:ImageDescription(?:\s[^>]*)?>(.*?)<\/tiff:ImageDescription>/s,
             xmp,
             capture: :all_but_first
           ) do
      case Regex.scan(~r/<rdf:li([^>]*)>(.*?)<\/rdf:li>/s, inner, capture: :all_but_first) do
        [] ->
          String.trim(inner)

        lis ->
          parsed =
            Enum.map(lis, fn [attrs, value] ->
              {attrs, String.trim(value)}
            end)

          Enum.find_value(parsed, fn {attrs, value} ->
            if value != "" and String.contains?(attrs, "x-default"), do: value
          end) ||
            Enum.find_value(parsed, fn {_attrs, value} ->
              if value != "", do: value
            end)
      end
    else
      _ -> nil
    end
  end

  defp isobmff_image_description(data) do
    data
    |> isobmff_find_exif_tiff()
    |> exif_ascii_tag(@image_description_exif_tag)
  rescue
    _ -> nil
  end

  defp jpeg_find_exif_tiff(<<@jpg_soi_marker, rest::binary>>),
    do: jpeg_find_exif_tiff_segments(rest)

  defp jpeg_find_exif_tiff(_), do: nil

  defp jpeg_find_exif_tiff_segments(<<0xFF, 0xDA, _rest::binary>>), do: nil

  defp jpeg_find_exif_tiff_segments(<<0xFF, 0xFF, rest::binary>>),
    do: jpeg_find_exif_tiff_segments(<<0xFF, rest::binary>>)

  defp jpeg_find_exif_tiff_segments(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD9,
    do: jpeg_find_exif_tiff_segments(rest)

  defp jpeg_find_exif_tiff_segments(<<0xFF, marker, segment_length::16, rest::binary>>)
       when segment_length >= 2 and byte_size(rest) >= segment_length - 2 do
    segment_data_len = segment_length - 2
    <<segment_data::binary-size(segment_data_len), remaining::binary>> = rest

    if marker == 0xE1 and match?(<<"Exif", 0, 0, _::binary>>, segment_data) do
      <<"Exif", 0, 0, tiff::binary>> = segment_data
      tiff
    else
      jpeg_find_exif_tiff_segments(remaining)
    end
  end

  defp jpeg_find_exif_tiff_segments(_), do: nil

  defp jpeg_find_app13_photoshop(<<@jpg_soi_marker, rest::binary>>),
    do: jpeg_find_photoshop_segments(rest)

  defp jpeg_find_app13_photoshop(_), do: nil

  defp jpeg_find_photoshop_segments(<<0xFF, 0xDA, _rest::binary>>), do: nil

  defp jpeg_find_photoshop_segments(<<0xFF, 0xFF, rest::binary>>),
    do: jpeg_find_photoshop_segments(<<0xFF, rest::binary>>)

  defp jpeg_find_photoshop_segments(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD9,
    do: jpeg_find_photoshop_segments(rest)

  defp jpeg_find_photoshop_segments(<<0xFF, marker, segment_length::16, rest::binary>>)
       when segment_length >= 2 and byte_size(rest) >= segment_length - 2 do
    segment_data_len = segment_length - 2
    <<segment_data::binary-size(segment_data_len), remaining::binary>> = rest

    if marker == 0xED and match?(<<"Photoshop 3.0", 0, _::binary>>, segment_data) do
      segment_data
    else
      jpeg_find_photoshop_segments(remaining)
    end
  end

  defp jpeg_find_photoshop_segments(_), do: nil

  defp webp_find_exif_tiff(<<@webp_riff_marker, _riff_size::32-little, "WEBP", rest::binary>>),
    do: webp_find_exif_chunk(rest)

  defp webp_find_exif_tiff(_), do: nil

  defp webp_find_exif_chunk(<<>>), do: nil

  defp webp_find_exif_chunk(<<chunk_type::binary-size(4), chunk_size::32-little, rest::binary>>)
       when byte_size(rest) >= chunk_size do
    <<chunk_data::binary-size(chunk_size), after_chunk::binary>> = rest

    remaining =
      if rem(chunk_size, 2) == 1 and byte_size(after_chunk) >= 1 do
        <<_pad::8, remaining::binary>> = after_chunk
        remaining
      else
        after_chunk
      end

    if chunk_type == "EXIF" do
      case chunk_data do
        <<"Exif", 0, 0, tiff::binary>> -> tiff
        tiff -> tiff
      end
    else
      webp_find_exif_chunk(remaining)
    end
  end

  defp webp_find_exif_chunk(_), do: nil

  defp png_text_keyword(<<@png_signature, rest::binary>>, keyword),
    do: png_find_text_chunk(rest, keyword)

  defp png_text_keyword(_, _), do: nil

  defp png_find_text_chunk(<<>>, _keyword), do: nil

  defp png_find_text_chunk(
         <<chunk_size::32, chunk_type::binary-size(4), chunk_data::binary-size(chunk_size),
           _crc::32, rest::binary>>,
         keyword
       ) do
    if chunk_type == "tEXt" do
      case png_split_key_value(chunk_data) do
        {^keyword, value} -> value
        _ -> png_find_text_chunk(rest, keyword)
      end
    else
      png_find_text_chunk(rest, keyword)
    end
  end

  defp png_find_text_chunk(_rest, _keyword), do: nil

  defp png_text_or_compressed_text_keyword(<<@png_signature, rest::binary>>, keyword),
    do: png_find_text_or_compressed_chunk(rest, keyword)

  defp png_text_or_compressed_text_keyword(_, _), do: nil

  defp png_find_text_or_compressed_chunk(<<>>, _keyword), do: nil

  defp png_find_text_or_compressed_chunk(
         <<chunk_size::32, chunk_type::binary-size(4), chunk_data::binary-size(chunk_size),
           _crc::32, rest::binary>>,
         keyword
       ) do
    cond do
      chunk_type == "tEXt" ->
        case png_split_key_value(chunk_data) do
          {^keyword, value} -> value
          _ -> png_find_text_or_compressed_chunk(rest, keyword)
        end

      chunk_type == "zTXt" ->
        case png_split_key_value(chunk_data) do
          {^keyword, <<_compression_method::8, compressed::binary>>} ->
            case safe_uncompress(compressed) do
              {:ok, uncompressed} -> uncompressed
              :error -> png_find_text_or_compressed_chunk(rest, keyword)
            end

          _ ->
            png_find_text_or_compressed_chunk(rest, keyword)
        end

      true ->
        png_find_text_or_compressed_chunk(rest, keyword)
    end
  end

  defp png_find_text_or_compressed_chunk(_rest, _keyword), do: nil

  defp png_find_exif_tiff(<<@png_signature, rest::binary>>), do: png_find_exif_chunk(rest)
  defp png_find_exif_tiff(_), do: nil

  defp png_find_exif_chunk(<<>>), do: nil

  defp png_find_exif_chunk(
         <<chunk_size::32, chunk_type::binary-size(4), chunk_data::binary-size(chunk_size),
           _crc::32, rest::binary>>
       ) do
    cond do
      chunk_type == "eXIf" -> chunk_data
      chunk_type == "IEND" -> nil
      true -> png_find_exif_chunk(rest)
    end
  end

  defp png_find_exif_chunk(_), do: nil

  defp png_split_key_value(chunk_data) when is_binary(chunk_data) do
    case :binary.match(chunk_data, <<0>>) do
      {idx, 1} ->
        key = binary_part(chunk_data, 0, idx) |> to_utf8()
        value = binary_part(chunk_data, idx + 1, byte_size(chunk_data) - idx - 1)
        {key, value}

      :nomatch ->
        nil
    end
  end

  defp safe_uncompress(data) when is_binary(data) do
    try do
      {:ok, :zlib.uncompress(data)}
    rescue
      _ -> :error
    end
  end

  defp decode_imagemagick_profile(nil), do: nil

  defp decode_imagemagick_profile(profile_text) when is_binary(profile_text) do
    lines = profile_text |> to_utf8() |> String.split(~r/\r?\n/, trim: true)

    case lines do
      [_profile_name, _length | hex_lines] ->
        hex = hex_lines |> Enum.join("") |> String.replace(~r/\s+/, "")

        case Base.decode16(hex, case: :mixed) do
          {:ok, data} -> data
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp exif_ascii_tag(nil, _tag), do: nil

  defp exif_ascii_tag(<<"II", 0x002A::16-little, ifd0_offset::32-little, _::binary>> = tiff, tag) do
    exif_ifd0_ascii_tag(tiff, ifd0_offset, :little, tag)
  end

  defp exif_ascii_tag(<<"MM", 0x002A::16-big, ifd0_offset::32-big, _::binary>> = tiff, tag) do
    exif_ifd0_ascii_tag(tiff, ifd0_offset, :big, tag)
  end

  defp exif_ascii_tag(_, _tag), do: nil

  defp exif_ifd0_ascii_tag(tiff, ifd0_offset, endian, tag)
       when byte_size(tiff) >= ifd0_offset + 2 do
    <<_::binary-size(ifd0_offset), ifd0::binary>> = tiff
    {entry_count, rest} = exif_decode_u16(ifd0, endian)
    entries_len = entry_count * 12

    if byte_size(rest) < entries_len do
      nil
    else
      <<entries::binary-size(entries_len), _::binary>> = rest
      exif_entries_ascii_tag(entries, endian, tiff, tag)
    end
  end

  defp exif_ifd0_ascii_tag(_tiff, _ifd0_offset, _endian, _tag), do: nil

  defp exif_entries_ascii_tag(<<>>, _endian, _tiff, _tag), do: nil

  defp exif_entries_ascii_tag(<<entry::binary-size(12), rest::binary>>, endian, tiff, tag) do
    {entry_tag, entry_type, entry_count, entry_value, entry_value_bytes} =
      case endian do
        :little ->
          <<entry_tag::16-little, entry_type::16-little, entry_count::32-little,
            entry_value_bytes::binary-size(4)>> = entry

          entry_value = :binary.decode_unsigned(entry_value_bytes, :little)
          {entry_tag, entry_type, entry_count, entry_value, entry_value_bytes}

        :big ->
          <<entry_tag::16-big, entry_type::16-big, entry_count::32-big,
            entry_value_bytes::binary-size(4)>> = entry

          entry_value = :binary.decode_unsigned(entry_value_bytes, :big)
          {entry_tag, entry_type, entry_count, entry_value, entry_value_bytes}
      end

    if entry_tag == tag and entry_type == 2 do
      exif_ascii_value(tiff, entry_count, entry_value, entry_value_bytes)
    else
      exif_entries_ascii_tag(rest, endian, tiff, tag)
    end
  end

  defp exif_ascii_value(_tiff, 0, _offset, _inline), do: nil

  defp exif_ascii_value(_tiff, count, _offset, inline) when count <= 4 do
    inline |> binary_part(0, count) |> :binary.replace(<<0>>, <<>>, [:global])
  end

  defp exif_ascii_value(tiff, count, offset, _inline) do
    if byte_size(tiff) >= offset + count do
      tiff |> binary_part(offset, count) |> :binary.replace(<<0>>, <<>>, [:global])
    else
      nil
    end
  end

  defp exif_decode_u16(<<value::16-little, rest::binary>>, :little), do: {value, rest}
  defp exif_decode_u16(<<value::16-big, rest::binary>>, :big), do: {value, rest}

  defp photoshop_irb_caption_abstract(nil), do: nil

  defp photoshop_irb_caption_abstract(<<"Photoshop 3.0", 0, rest::binary>>),
    do: photoshop_irb_caption_abstract(rest)

  defp photoshop_irb_caption_abstract(data) when is_binary(data),
    do: photoshop_irb_blocks_caption_abstract(data)

  defp photoshop_irb_blocks_caption_abstract(<<>>), do: nil

  defp photoshop_irb_blocks_caption_abstract(<<"8BIM", resource_id::16-big, rest::binary>>) do
    with {:ok, _name, rest} <- photoshop_read_pascal_string(rest),
         {:ok, data_size, rest} <- photoshop_read_u32(rest),
         {:ok, resource_data, rest} <- photoshop_read_data_with_padding(rest, data_size) do
      if resource_id == 0x0404 do
        iptc_caption_abstract(resource_data)
      else
        photoshop_irb_blocks_caption_abstract(rest)
      end
    else
      _ -> nil
    end
  end

  defp photoshop_irb_blocks_caption_abstract(<<_::8, rest::binary>>),
    do: photoshop_irb_blocks_caption_abstract(rest)

  defp photoshop_read_pascal_string(<<len::8, rest::binary>>) when byte_size(rest) >= len do
    <<name::binary-size(len), rest::binary>> = rest

    rest =
      if rem(len + 1, 2) == 1 and byte_size(rest) >= 1 do
        <<_pad::8, remaining::binary>> = rest
        remaining
      else
        rest
      end

    {:ok, name, rest}
  end

  defp photoshop_read_pascal_string(_), do: {:error, :invalid_pascal_string}

  defp photoshop_read_u32(<<value::32-big, rest::binary>>), do: {:ok, value, rest}
  defp photoshop_read_u32(_), do: {:error, :invalid_u32}

  defp photoshop_read_data_with_padding(rest, size) when byte_size(rest) >= size do
    <<data::binary-size(size), remaining::binary>> = rest

    remaining =
      if rem(size, 2) == 1 and byte_size(remaining) >= 1 do
        <<_pad::8, after_pad::binary>> = remaining
        after_pad
      else
        remaining
      end

    {:ok, data, remaining}
  end

  defp photoshop_read_data_with_padding(_rest, _size), do: {:error, :invalid_data}

  defp iptc_caption_abstract(nil), do: nil

  defp iptc_caption_abstract(data) when is_binary(data) do
    case iptc_find_dataset(data) do
      nil ->
        case photoshop_irb_caption_abstract(data) do
          nil -> nil
          caption -> caption
        end

      caption ->
        caption
    end
  end

  defp iptc_find_dataset(<<@iptc_marker, record::8, dataset::8, length::16-big, rest::binary>>)
       when byte_size(rest) >= length do
    <<value::binary-size(length), remaining::binary>> = rest

    if record == @iptc_caption_record and dataset == @iptc_caption_dataset do
      value
    else
      iptc_find_dataset(remaining)
    end
  end

  defp iptc_find_dataset(<<_::8, rest::binary>>), do: iptc_find_dataset(rest)
  defp iptc_find_dataset(<<>>), do: nil

  # ISO Base Media File Format (e.g. HEIC, AVIF)
  defp isobmff_find_exif_tiff(data) do
    with {:ok, meta_payload} <- isobmff_find_meta_payload(data),
         {:ok, iinf_box} <- isobmff_find_child_box(meta_payload, "iinf"),
         {:ok, iloc_box} <- isobmff_find_child_box(meta_payload, "iloc"),
         {:ok, exif_item_ids} <- isobmff_exif_item_ids(iinf_box),
         {:ok, item_locations} <- isobmff_item_locations(iloc_box),
         [item_id | _] <- exif_item_ids,
         extents when is_list(extents) and extents != [] <- Map.get(item_locations, item_id),
         exif_item <- isobmff_read_item(data, extents),
         tiff <- isobmff_exif_item_tiff(exif_item) do
      tiff
    else
      _ -> nil
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

  defp isobmff_find_top_box(data, wanted_type) when is_binary(data),
    do: do_isobmff_find_box(data, wanted_type)

  defp do_isobmff_find_box(<<>>, _wanted_type), do: {:error, :not_found}

  defp do_isobmff_find_box(data, wanted_type) do
    with {:ok, box_type, box_size, _header_size} <- isobmff_box_header(data),
         true <- byte_size(data) >= box_size do
      <<box::binary-size(box_size), rest::binary>> = data

      if box_type == wanted_type do
        {:ok, box}
      else
        do_isobmff_find_box(rest, wanted_type)
      end
    else
      _ -> {:error, :invalid_isobmff}
    end
  end

  defp isobmff_find_child_box(data, wanted_type) when is_binary(data),
    do: do_isobmff_find_box(data, wanted_type)

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

    acc = Map.put(acc, item_id, extents)

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

  defp isobmff_read_item(data, extents) do
    extents = Enum.sort_by(extents, & &1.offset)

    extents
    |> Enum.map(fn %{offset: offset, length: length} -> binary_part(data, offset, length) end)
    |> IO.iodata_to_binary()
  end

  defp isobmff_exif_item_tiff(<<tiff_offset::32-big, rest::binary>>)
       when byte_size(rest) >= tiff_offset do
    <<_prelude::binary-size(tiff_offset), tiff::binary>> = rest
    tiff
  end

  defp isobmff_exif_item_tiff(_), do: nil

  defp decode_u16_be(<<value::16-big, rest::binary>>), do: {value, rest}
  defp decode_u32_be(<<value::32-big, rest::binary>>), do: {value, rest}

  defp decode_uint_be(rest, 0), do: {0, rest}

  defp decode_uint_be(rest, bytes) when bytes in 1..8 and byte_size(rest) >= bytes do
    <<value::binary-size(bytes), rest::binary>> = rest
    {:binary.decode_unsigned(value, :big), rest}
  end
end
