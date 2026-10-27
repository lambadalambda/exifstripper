# SPDX-License-Identifier: MIT

defmodule ExifStripper.GpsStripper do
  @moduledoc """
  Losslessly strips GPS-related EXIF and XMP metadata, without re-encoding images.

  Supported containers:

  - JPEG: wipes GPS directories and values in EXIF (APP1), and GPS properties
    in XMP, Extended XMP and other APP1 segments that look like XMP
  - WebP: wipes GPS directories and values in the `EXIF` chunk, and GPS
    properties in the `XMP ` chunk
  - HEIC / other ISO-BMFF images: wipes GPS directories and values in the
    `Exif` item, and GPS properties in XMP (`application/rdf+xml`) items
  - PNG: removes metadata chunks (`eXIf`, `tEXt`, `zTXt`, `iTXt`, which holds
    XMP) and any data after `IEND`
  - TIFF: wipes GPS directories and values, and GPS properties in XMP (tag 700),
    in place (BigTIFF is refused)

  XMP GPS properties are the elements and attributes in the EXIF namespace
  (`http://ns.adobe.com/exif/1.0/`) whose names start with `GPS`, and the DJI
  drone position and altitude properties (`http://www.dji.com/drone-dji/1.0/`:
  `GpsLatitude`, `GpsLongitude`, `GpsLongtitude`, `Latitude`, `Longitude`,
  `AbsoluteAltitude`, `RelativeAltitude`, `LRFTargetLat`, `LRFTargetLon`,
  `LRFTargetAlt`, `LRFTargetAbsAlt`). They are overwritten with spaces, so no
  offsets change and the XMP stays well-formed.
  XMP that cannot be scanned safely (for example with a DTD, unbalanced tags or
  in UTF-16) returns an error.

  If no supported metadata is found, returns `:noop` and does not change the output.
  Malformed or unsafe EXIF or XMP metadata returns an error without writing the output.

  `strip_gps_data/2` reads only the metadata, not the image data. When input
  and output are the same file, JPEG, WebP, ISO-BMFF and TIFF files are patched
  in place (through symlinks and hard links). In all other cases, the result is
  written to a temporary file next to the output, which then replaces the output
  path (this needs write access to the output directory). Metadata that must be
  loaded into memory is limited to 16 MiB; larger metadata returns
  `{:error, :metadata_too_large}`. Hostile structures (too many IFDs, metadata
  segments or XMP elements) also return errors.
  """

  import Bitwise, only: [<<<: 2, &&&: 2, |||: 2]

  alias ExifStripper.{ISOBMFF, Reader, TIFF, XMP}

  @png_signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @png_metadata_chunks ["eXIf", "tEXt", "zTXt", "iTXt"]

  @jpg_app1_marker 0xE1
  @jpg_sos_marker 0xDA
  @jpg_tem_marker 0x01

  @xmp_header "http://ns.adobe.com/xap/1.0/\0"
  @extended_xmp_header "http://ns.adobe.com/xmp/extension/\0"

  @block_size 65_536

  # Metadata segments (JPEG APP1, WebP EXIF and XMP chunks) per file. Real
  # files have a few (an Extended XMP packet of the maximum metadata size needs
  # 258); this bounds the work and the patches for hostile files.
  @max_metadata_segments 1024

  @type result :: :ok | :noop | {:error, term()}

  # A plan is either byte patches that keep the size of the file, or the
  # ranges of the input to keep, in order.
  @typep plan ::
           {:patch, [{non_neg_integer(), binary()}]}
           | {:rebuild, [{non_neg_integer(), non_neg_integer()}]}

  @spec strip_gps_data(Path.t(), Path.t()) :: result()
  def strip_gps_data(input_path, output_path) do
    # All patches are known before anything is written.
    result =
      with_file(input_path, [:read], fn fd, size ->
        reader = Reader.from_file(fd, size)

        case plan(reader) do
          {:patch, patches} ->
            if same_file?(input_path, output_path),
              do: {:patch_in_place, patches},
              else: replace_file(reader, [{0, size}], patches, input_path, output_path)

          {:rebuild, ranges} ->
            replace_file(reader, ranges, [], input_path, output_path)

          other ->
            other
        end
      end)

    case result do
      {:patch_in_place, patches} -> patch_in_place(patches, input_path)
      other -> other
    end
  rescue
    e ->
      {:error, "#{__MODULE__}: #{inspect(e)}"}
  end

  @spec strip_gps_data(binary()) :: {:ok, binary()} | :noop | {:error, term()}
  def strip_gps_data(data) when is_binary(data) do
    case plan(Reader.from_binary(data)) do
      {:patch, patches} ->
        {:ok, apply_patches(data, patches)}

      {:rebuild, ranges} ->
        {:ok, IO.iodata_to_binary(for {o, l} <- ranges, do: binary_part(data, o, l))}

      other ->
        other
    end
  end

  @spec plan(Reader.t()) :: plan() | :noop | {:error, term()}
  defp plan(reader) do
    case Reader.peek(reader, 0, 12) do
      {<<@png_signature, _::binary>>, reader} ->
        png_plan(reader, 8, [{0, 8}], false)

      {<<0xFF, 0xD8, _::binary>>, reader} ->
        patch_plan(jpeg_patches(reader, 2, [], [], 0))

      {<<"RIFF", _size::32, "WEBP">>, reader} ->
        patch_plan(webp_patches(reader, 12, [], 0))

      {<<_size::32, "ftyp", _::binary>>, reader} ->
        patch_plan(isobmff_patches(reader))

      {<<magic::binary-size(4), _::binary>>, reader}
      when magic in [<<"II", 42, 0>>, <<"MM", 0, 42>>] ->
        patch_plan(TIFF.gps_patches(reader))

      # BigTIFF uses 64-bit offsets, which the IFD patcher does not handle.
      {<<magic::binary-size(4), _::binary>>, _reader}
      when magic in [<<"II", 43, 0>>, <<"MM", 0, 43>>] ->
        {:error, :unsupported_bigtiff}

      _ ->
        :noop
    end
  end

  defp patch_plan({:ok, []}), do: :noop

  # A safety net: overlapping patches would corrupt the output.
  defp patch_plan({:ok, patches}) do
    patches = Enum.sort_by(patches, &elem(&1, 0))

    if overlapping?(for {pos, bytes} <- patches, do: {pos, byte_size(bytes)}),
      do: {:error, :overlapping_patches},
      else: {:patch, patches}
  end

  defp patch_plan({:error, _} = error), do: error

  ## PNG

  # Walks the chunk headers in `buffer` (the data at `pos`), refilled by blocks.
  defp png_plan(reader, pos, kept, stripped?),
    do: png_plan(reader, Reader.size(reader), pos, <<>>, kept, stripped?)

  defp png_plan(reader, size, pos, buffer, kept, stripped?)
       when byte_size(buffer) < 12 and pos + byte_size(buffer) < size do
    {buffer, reader} = Reader.peek(reader, pos, @block_size)
    png_chunk(reader, size, pos, buffer, kept, stripped?)
  end

  defp png_plan(reader, size, pos, buffer, kept, stripped?),
    do: png_chunk(reader, size, pos, buffer, kept, stripped?)

  defp png_chunk(reader, size, pos, buffer, kept, stripped?) do
    case buffer do
      <<>> ->
        png_finish(kept, stripped?)

      # Anything after IEND is not part of the image and may hold metadata: drop it.
      <<0::32, "IEND", _crc::32, _::binary>> ->
        png_finish(keep(kept, pos, 12), stripped? or pos + 12 < size)

      <<length::32, type::binary-size(4), _::binary>> when size - pos >= length + 12 ->
        next = pos + 12 + length

        buffer =
          if byte_size(buffer) >= 12 + length,
            do: binary_part(buffer, 12 + length, byte_size(buffer) - 12 - length),
            else: <<>>

        if png_metadata?(type),
          do: png_plan(reader, size, next, buffer, kept, true),
          else: png_plan(reader, size, next, buffer, keep(kept, pos, 12 + length), stripped?)

      _ ->
        {:error, :invalid_png}
    end
  end

  for type <- @png_metadata_chunks, do: defp(png_metadata?(unquote(type)), do: true)
  defp png_metadata?(_type), do: false

  # Kept ranges, newest first; adjacent ranges are merged.
  defp keep([{start, length} | rest], pos, add) when start + length == pos,
    do: [{start, length + add} | rest]

  defp keep(kept, pos, add), do: [{pos, add} | kept]

  defp png_finish(_kept, false), do: :noop
  defp png_finish(kept, true), do: {:rebuild, Enum.reverse(kept)}

  ## JPEG

  # Extended XMP chunks are collected, then patched once all are known.
  defp jpeg_patches(_reader, _pos, _acc, _extended, segments)
       when segments > @max_metadata_segments,
       do: {:error, :too_many_metadata_segments}

  defp jpeg_patches(reader, pos, acc, extended, segments) do
    case Reader.peek(reader, pos, 4) do
      {<<>>, _reader} ->
        extended_xmp_patches(reader, extended, acc)

      {<<0xFF, @jpg_sos_marker, _::binary>>, _reader} ->
        extended_xmp_patches(reader, extended, acc)

      {<<0xFF, 0xFF, _::binary>>, reader} ->
        jpeg_patches(reader, pos + 1, acc, extended, segments)

      {<<0xFF, marker, _::binary>>, reader}
      when marker == @jpg_tem_marker or marker in 0xD0..0xD9 ->
        jpeg_patches(reader, pos + 2, acc, extended, segments)

      {<<0xFF, marker, length::16>>, reader} when length >= 2 ->
        start = pos + 4
        next = start + length - 2
        segments = if marker == @jpg_app1_marker, do: segments + 1, else: segments

        with {:ok, segment, reader} <- jpeg_segment_reader(reader, marker, start, length - 2) do
          case jpeg_segment(marker, segment) do
            {:ok, patches} ->
              jpeg_patches(reader, next, shift(patches, start) ++ acc, extended, segments)

            {:extended, chunk} ->
              jpeg_patches(reader, next, acc, [{start, chunk} | extended], segments)

            error ->
              error
          end
        end

      _ ->
        {:error, :invalid_jpeg}
    end
  end

  # APP1 segments (at most 64 KiB) are read into memory through the block cache.
  defp jpeg_segment_reader(reader, marker, start, length) do
    cond do
      start + length > Reader.size(reader) ->
        {:error, :invalid_jpeg}

      marker == @jpg_app1_marker ->
        {bytes, reader} = Reader.peek(reader, start, length)
        {:ok, Reader.from_binary(bytes), reader}

      true ->
        {:ok, nil, reader}
    end
  end

  defp jpeg_segment(@jpg_app1_marker, segment) do
    {header, _} = Reader.peek(segment, 0, 75)

    case exif_header_length(header) do
      nil ->
        jpeg_app1(segment, header)

      length ->
        {:ok, tiff} = Reader.slice(segment, length, Reader.size(segment) - length)
        with {:ok, patches} <- TIFF.gps_patches(tiff), do: {:ok, shift(patches, length)}
    end
  end

  defp jpeg_segment(_marker, _segment), do: {:ok, []}

  # Like exiftool (`/^(.{0,4})Exif\0./is`): `Exif\0` in any letter case, after
  # up to 4 bytes of garbage, and one more byte. The TIFF data follows.
  defp exif_header_length(header) do
    Enum.find_value(4..0//-1, fn skip ->
      case header do
        <<_::binary-size(skip), e, x, i, f, 0, _, _::binary>>
        when (e ||| 0x20) == ?e and (x ||| 0x20) == ?x and (i ||| 0x20) == ?i and
               (f ||| 0x20) == ?f ->
          skip + 6

        _ ->
          nil
      end
    end)
  end

  defp jpeg_app1(segment, <<@xmp_header, _::binary>>) do
    {:ok, packet} = Reader.slice(segment, 29, Reader.size(segment) - 29)
    with {:ok, patches} <- XMP.gps_patches(packet), do: {:ok, shift(patches, 29)}
  end

  defp jpeg_app1(segment, <<@extended_xmp_header, guid::binary-size(32), size::32, offset::32>>),
    do: {:extended, {guid, size, offset, 75, Reader.size(segment) - 75}}

  defp jpeg_app1(_segment, <<@extended_xmp_header, _::binary>>),
    do: {:error, :invalid_extended_xmp}

  defp jpeg_app1(segment, header), do: other_app1_patches(segment, header)

  # exiftool also reads APP1 segments as XMP if they start with `http` or
  # `XMP\0`, or contain `<exif:` or `<?xpacket`. Scan those from the first `<`.
  defp other_app1_patches(segment, header) do
    {:ok, data} = Reader.read(segment, 0, Reader.size(segment))

    xmp? =
      match?(<<"http", _::binary>>, header) or match?(<<"XMP", 0, _::binary>>, header) or
        :binary.match(data, ["<exif:", "<?xpacket"]) != :nomatch

    case xmp? && :binary.match(data, "<") do
      {start, 1} ->
        with {:ok, patches} <- XMP.gps_patches(binary_part(data, start, byte_size(data) - start)),
             do: {:ok, shift(patches, start)}

      _ ->
        {:ok, []}
    end
  end

  # Each Extended XMP packet (by GUID) must be complete: chunks of one size,
  # without gaps or overlaps. Patches are mapped back onto the chunks.
  defp extended_xmp_patches(reader, extended, acc) do
    extended
    |> Enum.group_by(fn {_start, {guid, _, _, _, _}} -> guid end)
    |> Enum.reduce_while({:ok, acc}, fn {_guid, chunks}, {:ok, acc} ->
      chunks = Enum.sort_by(chunks, fn {_start, {_, _, offset, _, _}} -> offset end)
      [{_, {_, size, _, _, _}} | _] = chunks

      {complete?, total} =
        Enum.reduce(chunks, {true, 0}, fn {_, {_, chunk_size, offset, _, length}}, {ok?, pos} ->
          {ok? and chunk_size == size and offset == pos, pos + length}
        end)

      extents =
        for {start, {_, _, _, skip, length}} <- chunks,
            do: %{offset: start + skip, length: length}

      with true <- complete? and total == size,
           {:ok, packet} <- read_extents(reader, extents),
           {:ok, patches} <- XMP.gps_patches(packet) do
        {:cont, {:ok, to_physical(patches, extents, 0, acc)}}
      else
        false -> {:halt, {:error, :invalid_extended_xmp}}
        error -> {:halt, error}
      end
    end)
  end

  ## WebP

  defp webp_patches(_reader, _pos, _acc, segments) when segments > @max_metadata_segments,
    do: {:error, :too_many_metadata_segments}

  defp webp_patches(reader, pos, acc, segments) do
    remaining = Reader.size(reader) - pos

    case Reader.peek(reader, pos, 8) do
      {<<>>, _reader} ->
        {:ok, acc}

      {<<type::binary-size(4), length::32-little>>, reader} when remaining - 8 >= length ->
        start = pos + 8
        padding = if rem(length, 2) == 1 and remaining - 8 > length, do: 1, else: 0

        # Small metadata chunks are read into memory through the block cache.
        {chunk, reader} =
          if type in ["EXIF", "XMP "] and length <= @block_size do
            {bytes, reader} = Reader.peek(reader, start, length)
            {Reader.from_binary(bytes), reader}
          else
            {:ok, chunk} = Reader.slice(reader, start, length)
            {chunk, reader}
          end

        segments = if type in ["EXIF", "XMP "], do: segments + 1, else: segments

        with {:ok, patches} <- webp_chunk_patches(type, chunk) do
          webp_patches(reader, start + length + padding, shift(patches, start) ++ acc, segments)
        end

      _ ->
        {:error, :invalid_webp}
    end
  end

  defp webp_chunk_patches("EXIF", chunk), do: exif_payload_patches(chunk)
  defp webp_chunk_patches("XMP ", chunk), do: XMP.gps_patches(chunk)
  defp webp_chunk_patches(_type, _chunk), do: {:ok, []}

  # An EXIF payload is a TIFF structure, optionally after an `Exif\0\0` header.
  defp exif_payload_patches(reader) do
    case Reader.peek(reader, 0, 6) do
      {<<"Exif", 0, 0>>, _} ->
        {:ok, tiff} = Reader.slice(reader, 6, Reader.size(reader) - 6)
        with {:ok, patches} <- TIFF.gps_patches(tiff), do: {:ok, shift(patches, 6)}

      _ ->
        TIFF.gps_patches(reader)
    end
  end

  ## ISO-BMFF

  defp isobmff_patches(reader) do
    with {:ok, items} <- ISOBMFF.metadata_item_locations(reader, [:exif, :xmp]),
         :ok <- validate_extents(reader, items) do
      Enum.reduce_while(items, {:ok, []}, fn {kind, _id, extents}, {:ok, acc} ->
        with {:ok, item} <- read_extents(reader, extents),
             {:ok, patches} <- heif_item_patches(kind, item) do
          {:cont, {:ok, to_physical(patches, extents, 0, acc)}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  # Whole-item replacements must never read backwards into unsanitized bytes.
  # Check all physical ranges together, including aliases across different IDs.
  defp validate_extents(reader, items) do
    extents = Enum.flat_map(items, &elem(&1, 2))
    size = Reader.size(reader)

    valid? =
      Enum.all?(items, fn {_kind, _id, extents} -> extents != [] end) and
        Enum.all?(extents, fn %{offset: o, length: l} -> o >= 0 and l > 0 and o + l <= size end)

    cond do
      not valid? ->
        {:error, :invalid_exif_extents}

      overlapping?(for e <- extents, do: {e.offset, e.length}) ->
        {:error, :overlapping_exif_extents}

      true ->
        :ok
    end
  end

  defp read_extents(reader, extents) do
    if Enum.sum(Enum.map(extents, & &1.length)) > Reader.max_metadata_size(),
      do: {:error, :metadata_too_large},
      else: do_read_extents(reader, extents)
  end

  defp do_read_extents(reader, extents) do
    Enum.reduce_while(extents, {:ok, []}, fn %{offset: offset, length: length}, {:ok, acc} ->
      case Reader.read(reader, offset, length) do
        {:ok, part} -> {:cont, {:ok, [acc, part]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      error -> error
    end
  end

  defp heif_item_patches(:xmp, item), do: XMP.gps_patches(item)

  defp heif_item_patches(:exif, <<tiff_offset::32-big, rest::binary>> = item)
       when byte_size(rest) >= tiff_offset do
    start = 4 + tiff_offset
    {:ok, tiff} = Reader.slice(Reader.from_binary(item), start, byte_size(item) - start)

    case TIFF.gps_patches(tiff) do
      {:ok, patches} -> {:ok, shift(patches, start)}
      {:error, _} -> {:error, :invalid_tiff}
    end
  end

  defp heif_item_patches(:exif, _item), do: {:error, :invalid_exif_item}

  # Maps sorted, disjoint patches within an item onto its physical extents.
  defp to_physical([], _extents, _logical, acc), do: acc
  defp to_physical(_patches, [], _logical, acc), do: acc

  defp to_physical([{pos, bytes} | patches], [extent | extents] = all, logical, acc) do
    extent_end = logical + extent.length

    if extent_end <= pos do
      to_physical([{pos, bytes} | patches], extents, extent_end, acc)
    else
      take = min(pos + byte_size(bytes), extent_end) - pos
      <<part::binary-size(take), rest::binary>> = bytes
      acc = [{extent.offset + pos - logical, part} | acc]

      if rest == <<>>,
        do: to_physical(patches, all, logical, acc),
        else: to_physical([{pos + take, rest} | patches], extents, extent_end, acc)
    end
  end

  ## Helpers

  defp overlapping?(ranges) do
    ranges
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [{pos, length}, {next, _}] -> pos + length > next end)
  end

  defp shift(patches, by), do: Enum.map(patches, fn {pos, bytes} -> {pos + by, bytes} end)

  defp apply_patches(data, patches) do
    {iodata, pos} =
      Enum.reduce(patches, {[], 0}, fn {offset, bytes}, {acc, pos} ->
        {[acc, binary_part(data, pos, offset - pos), bytes], offset + byte_size(bytes)}
      end)

    IO.iodata_to_binary([iodata, binary_part(data, pos, byte_size(data) - pos)])
  end

  ## Files

  defp with_file(path, modes, fun) do
    with {:ok, fd} <- :file.open(path, [:raw, :binary | modes]) do
      try do
        with {:ok, size} <- :file.position(fd, :eof), do: fun.(fd, size)
      after
        :file.close(fd)
      end
    end
  end

  # Patches close to each other are applied with one read and one write per
  # block, instead of one write per patch.
  defp patch_in_place(patches, path) do
    with_file(path, [:read, :write], fn fd, size ->
      reader = Reader.from_file(fd, size)

      writes =
        patches
        |> group_patches()
        |> Enum.map(fn
          [single] ->
            {:ok, single}

          [{start, _} | _] = group ->
            {last, bytes} = List.last(group)

            with {:ok, block} <- Reader.read(reader, start, last + byte_size(bytes) - start) do
              {data, []} = patch_block(block, start, group)
              {:ok, {start, IO.iodata_to_binary(data)}}
            end
        end)

      case Enum.find(writes, &match?({:error, _}, &1)) do
        nil -> pwrite(fd, Enum.map(writes, &elem(&1, 1)))
        error -> error
      end
    end)
  end

  defp group_patches(patches) do
    patches
    |> Enum.chunk_while(
      [],
      fn
        patch, [] ->
          {:cont, [patch]}

        {pos, bytes} = patch, [{start, _} | _] = group ->
          if pos + byte_size(bytes) - start <= @block_size,
            do: {:cont, [patch | group]},
            else: {:cont, Enum.reverse(group), [patch]}
      end,
      fn
        [] -> {:cont, []}
        group -> {:cont, Enum.reverse(group), []}
      end
    )
  end

  # Applies the sorted patches that start inside `block` (at offset `offset`).
  # Returns the patched block as iodata and the patches (or remainders of
  # patches) after it.
  defp patch_block(block, offset, patches, acc \\ [], cursor \\ nil)

  defp patch_block(block, offset, [{pos, bytes} | rest], acc, cursor)
       when pos < offset + byte_size(block) do
    cursor = cursor || offset
    take = min(byte_size(bytes), offset + byte_size(block) - pos)
    <<part::binary-size(take), remainder::binary>> = bytes
    acc = [acc, binary_part(block, cursor - offset, pos - cursor), part]
    rest = if remainder == <<>>, do: rest, else: [{pos + take, remainder} | rest]
    patch_block(block, offset, rest, acc, pos + take)
  end

  defp patch_block(block, offset, patches, acc, cursor) do
    cursor = cursor || offset
    {[acc, binary_part(block, cursor - offset, offset + byte_size(block) - cursor)], patches}
  end

  defp pwrite(_fd, []), do: :ok

  defp pwrite(fd, patches) do
    case :file.pwrite(fd, patches) do
      :ok -> :ok
      {:error, {_written, reason}} -> {:error, reason}
    end
  end

  defp same_file?(path, path), do: true

  defp same_file?(a, b) do
    case {File.stat(a), File.stat(b)} do
      {{:ok, %{inode: inode, major_device: device}}, {:ok, %{inode: inode, major_device: device}}} ->
        inode != 0

      _ ->
        false
    end
  end

  # Writes the kept ranges of the input, then the patches, to a temporary file
  # next to the output, and renames it over the output. The output is either
  # unchanged or complete.
  defp replace_file(reader, ranges, patches, input_path, output_path) do
    suffix = Integer.to_string(:rand.uniform(1 <<< 48), 36)

    tmp_path =
      Path.join(Path.dirname(output_path), ".#{Path.basename(output_path)}.#{suffix}.tmp")

    with {:ok, out} <- :file.open(tmp_path, [:raw, :binary, :write, :exclusive]) do
      try do
        with :ok <- copy_ranges(reader, out, ranges, patches),
             :ok <- :file.close(out),
             {:ok, %{mode: mode}} <- File.stat(input_path),
             :ok <- File.chmod(tmp_path, mode &&& 0o777) do
          File.rename(tmp_path, output_path)
        end
      after
        :file.close(out)
        File.rm(tmp_path)
      end
    end
  end

  # Copies the ranges in blocks, applying the patches (in input offsets), and
  # writes through a buffer of about one block.
  defp copy_ranges(reader, out, ranges, patches),
    do: copy_ranges(reader, out, ranges, patches, [], 0)

  defp copy_ranges(_reader, out, [], _patches, buffer, _buffered), do: :file.write(out, buffer)

  defp copy_ranges(reader, out, [{_offset, 0} | ranges], patches, buffer, buffered),
    do: copy_ranges(reader, out, ranges, patches, buffer, buffered)

  defp copy_ranges(reader, out, [{offset, length} | ranges], patches, buffer, buffered) do
    block = min(length, @block_size)
    {bytes, reader} = Reader.peek(reader, offset, block)
    {data, patches} = patch_block(bytes, offset, patches)
    ranges = [{offset + block, length - block} | ranges]

    if buffered + block >= @block_size do
      with :ok <- :file.write(out, [buffer, data]),
           do: copy_ranges(reader, out, ranges, patches, [], 0)
    else
      copy_ranges(reader, out, ranges, patches, [buffer, data], buffered + block)
    end
  end
end
