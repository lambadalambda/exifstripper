# SPDX-License-Identifier: MIT

defmodule ExifStripper.GpsStripper do
  @moduledoc """
  Losslessly strips GPS-related EXIF and XMP metadata, without re-encoding images.

  Supported containers:

  - JPEG: wipes GPS directories and values in EXIF (APP1), and GPS properties
    in XMP and Extended XMP (APP1)
  - WebP: wipes GPS directories and values in the `EXIF` chunk, and GPS
    properties in the `XMP ` chunk
  - HEIC / other ISO-BMFF images: wipes GPS directories and values in the
    `Exif` item, and GPS properties in XMP (`application/rdf+xml`) items
  - PNG: removes metadata chunks (`eXIf`, `tEXt`, `zTXt`, `iTXt`, which holds
    XMP) and any data after `IEND`
  - TIFF: wipes GPS directories and values, and GPS properties in XMP (tag 700),
    in place (BigTIFF is refused)

  XMP GPS properties are the elements and attributes in the EXIF namespace
  (`http://ns.adobe.com/exif/1.0/`) whose names start with `GPS`. They are
  overwritten with spaces, so no offsets change and the XMP stays well-formed.
  XMP that cannot be scanned safely (for example with a DTD, unbalanced tags or
  in UTF-16) returns an error.

  If no supported metadata is found, returns `:noop` and does not change the output.
  Malformed or unsafe EXIF or XMP metadata returns an error without writing the output.

  `strip_gps_data/2` reads only the metadata, not the image data. When input
  and output are the same file, JPEG, WebP, ISO-BMFF and TIFF files are patched
  in place. In all other cases, the result is written to a temporary file next
  to the output, which then replaces the output (this needs write access to the
  output directory). Metadata that must be loaded into memory is limited to
  16 MiB; larger metadata returns `{:error, :metadata_too_large}`.
  """

  import Bitwise, only: [<<<: 2, &&&: 2]

  alias ExifStripper.{ISOBMFF, Reader, TIFF, XMP}

  @png_signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @png_metadata_chunks ["eXIf", "tEXt", "zTXt", "iTXt"]

  @jpg_app1_marker 0xE1
  @jpg_sos_marker 0xDA
  @jpg_tem_marker 0x01

  @xmp_header "http://ns.adobe.com/xap/1.0/\0"
  @extended_xmp_header "http://ns.adobe.com/xmp/extension/\0"

  @copy_block_size 65_536

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
        patch_plan(jpeg_patches(reader, 2, [], []))

      {<<"RIFF", _size::32, "WEBP">>, reader} ->
        patch_plan(webp_patches(reader, 12, []))

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

    overlap? =
      patches
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [{pos, bytes}, {next, _}] -> pos + byte_size(bytes) > next end)

    if overlap?, do: {:error, :overlapping_patches}, else: {:patch, patches}
  end

  defp patch_plan({:error, _} = error), do: error

  ## PNG

  defp png_plan(reader, pos, kept, stripped?) do
    size = Reader.size(reader)

    case Reader.peek(reader, pos, 12) do
      {<<>>, _reader} ->
        png_finish(kept, stripped?)

      # Anything after IEND is not part of the image and may hold metadata: drop it.
      {<<0::32, "IEND", _crc::32>>, _reader} ->
        png_finish(keep(kept, pos, 12), stripped? or pos + 12 < size)

      {<<length::32, type::binary-size(4), _::binary>>, reader} when size - pos >= length + 12 ->
        if type in @png_metadata_chunks,
          do: png_plan(reader, pos + 12 + length, kept, true),
          else: png_plan(reader, pos + 12 + length, keep(kept, pos, 12 + length), stripped?)

      _ ->
        {:error, :invalid_png}
    end
  end

  # Kept ranges, newest first; adjacent ranges are merged.
  defp keep([{start, length} | rest], pos, add) when start + length == pos,
    do: [{start, length + add} | rest]

  defp keep(kept, pos, add), do: [{pos, add} | kept]

  defp png_finish(_kept, false), do: :noop
  defp png_finish(kept, true), do: {:rebuild, Enum.reverse(kept)}

  ## JPEG

  # Extended XMP chunks are collected, then patched once all are known.
  defp jpeg_patches(reader, pos, acc, extended) do
    case Reader.peek(reader, pos, 4) do
      {<<>>, _reader} ->
        extended_xmp_patches(reader, extended, acc)

      {<<0xFF, @jpg_sos_marker, _::binary>>, _reader} ->
        extended_xmp_patches(reader, extended, acc)

      {<<0xFF, 0xFF, _::binary>>, reader} ->
        jpeg_patches(reader, pos + 1, acc, extended)

      {<<0xFF, marker, _::binary>>, reader}
      when marker == @jpg_tem_marker or marker in 0xD0..0xD9 ->
        jpeg_patches(reader, pos + 2, acc, extended)

      {<<0xFF, marker, length::16>>, reader} when length >= 2 ->
        start = pos + 4
        next = start + length - 2

        with {:ok, segment} <- slice(reader, start, length - 2, :invalid_jpeg) do
          case jpeg_segment(marker, segment) do
            {:ok, patches} -> jpeg_patches(reader, next, shift(patches, start) ++ acc, extended)
            {:extended, chunk} -> jpeg_patches(reader, next, acc, [{start, chunk} | extended])
            error -> error
          end
        end

      _ ->
        {:error, :invalid_jpeg}
    end
  end

  defp jpeg_segment(@jpg_app1_marker, segment) do
    case Reader.peek(segment, 0, 75) do
      {<<"Exif", 0, 0, _::binary>>, _} ->
        exif_payload_patches(segment)

      {<<@xmp_header, _::binary>>, _} ->
        {:ok, packet} = Reader.slice(segment, 29, Reader.size(segment) - 29)
        with {:ok, patches} <- XMP.gps_patches(packet), do: {:ok, shift(patches, 29)}

      {<<@extended_xmp_header, guid::binary-size(32), size::32, offset::32>>, _} ->
        {:extended, {guid, size, offset, 75, Reader.size(segment) - 75}}

      {<<@extended_xmp_header, _::binary>>, _} ->
        {:error, :invalid_extended_xmp}

      _ ->
        {:ok, []}
    end
  end

  defp jpeg_segment(_marker, _segment), do: {:ok, []}

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

  defp webp_patches(reader, pos, acc) do
    remaining = Reader.size(reader) - pos

    case Reader.peek(reader, pos, 8) do
      {<<>>, _reader} ->
        {:ok, acc}

      {<<type::binary-size(4), length::32-little>>, reader} when remaining - 8 >= length ->
        start = pos + 8
        {:ok, chunk} = Reader.slice(reader, start, length)
        padding = if rem(length, 2) == 1 and remaining - 8 > length, do: 1, else: 0

        with {:ok, patches} <- webp_chunk_patches(type, chunk) do
          webp_patches(reader, start + length + padding, shift(patches, start) ++ acc)
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

    overlap? =
      extents
      |> Enum.sort_by(& &1.offset)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [a, b] -> a.offset + a.length > b.offset end)

    cond do
      not valid? -> {:error, :invalid_exif_extents}
      overlap? -> {:error, :overlapping_exif_extents}
      true -> :ok
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

  defp slice(reader, offset, length, error) do
    with {:error, _} <- Reader.slice(reader, offset, length), do: {:error, error}
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

  defp patch_in_place(patches, path),
    do: with_file(path, [:read, :write], fn fd, _size -> pwrite(fd, patches) end)

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
        with :ok <- copy_ranges(reader, out, ranges),
             :ok <- pwrite(out, patches),
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

  defp copy_ranges(reader, out, ranges) do
    Enum.reduce_while(ranges, :ok, fn {offset, length}, :ok ->
      case copy_range(reader, out, offset, length) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp copy_range(_reader, _out, _offset, 0), do: :ok

  defp copy_range(reader, out, offset, length) do
    block = min(length, @copy_block_size)

    with {:ok, bytes} <- Reader.read(reader, offset, block),
         :ok <- :file.write(out, bytes) do
      copy_range(reader, out, offset + block, length - block)
    end
  end
end
