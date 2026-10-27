# SPDX-License-Identifier: MIT

defmodule ExifStripper.TIFF do
  @moduledoc false
  # Finds the bytes to wipe to remove GPS data from a TIFF structure (a TIFF
  # file or an EXIF payload): GPS directories, the GPS pointer entries and all
  # out-of-line GPS values. Patches keep every offset and length unchanged.

  alias ExifStripper.Reader

  @gps_ifd_tag 0x8825

  @type patch :: {non_neg_integer(), binary()}

  @doc "Returns zero-filling patches, relative to the reader. `[]` means no GPS data."
  @spec gps_patches(Reader.t()) :: {:ok, [patch()]} | {:error, term()}
  def gps_patches(reader) do
    case Reader.read(reader, 0, 8) do
      {:ok, <<"II", 42::16-little, ifd0::32-little>>} -> gps_patches(reader, ifd0, :little)
      {:ok, <<"MM", 42::16-big, ifd0::32-big>>} -> gps_patches(reader, ifd0, :big)
      _ -> {:error, :unsupported_tiff}
    end
  end

  # First validate and collect ranges, then wipe.
  defp gps_patches(reader, offset, endian) do
    with {:ok, kept, wiped} <-
           collect_ifds(reader, [{offset, :keep}], endian, MapSet.new(), [], []),
         kept <- merge_ranges(kept),
         wiped <- merge_ranges(wiped),
         false <- ranges_overlap?(kept, wiped) do
      {:ok, Enum.map(wiped, fn {pos, len} -> {pos, :binary.copy(<<0>>, len)} end)}
    else
      true -> {:error, :overlapping_gps_data}
      {:error, _} = error -> error
    end
  end

  defp collect_ifds(_reader, [], _endian, _seen, kept, wiped), do: {:ok, [{0, 8} | kept], wiped}

  defp collect_ifds(reader, [{offset, role} | pending], endian, seen, kept, wiped) do
    with false <- MapSet.member?(seen, offset),
         {:ok, entries, next, size} <- read_ifd(reader, offset, endian),
         {kept, wiped} <-
           if(role == :wipe,
             do: {kept, [{offset, size} | wiped]},
             else: {[{offset, 2}, {offset + size - 4, 4} | kept], wiped}
           ),
         pending <- if(next == 0, do: pending, else: [{next, role} | pending]),
         {:ok, pending, kept, wiped} <-
           Enum.reduce_while(entries, {:ok, pending, kept, wiped}, fn entry,
                                                                      {:ok, todo, keep, wipe} ->
             case collect_entry(reader, entry, role, endian, todo, keep, wipe) do
               {:ok, _, _, _} = result -> {:cont, result}
               {:error, _} = error -> {:halt, error}
             end
           end) do
      collect_ifds(reader, pending, endian, MapSet.put(seen, offset), kept, wiped)
    else
      true -> {:error, :cyclic_ifd}
      {:error, _} = error -> error
    end
  end

  defp read_ifd(reader, offset, endian) do
    with true <- valid_range?(reader, offset, 2),
         {:ok, count} <- read_uint(reader, offset, 2, endian),
         size <- 2 + count * 12 + 4,
         true <- valid_range?(reader, offset, size),
         {:ok, ifd} <- Reader.read(reader, offset, size) do
      entries =
        for i <- indices(count), do: {offset + 2 + i * 12, binary_part(ifd, 2 + i * 12, 12)}

      {:ok, entries, decode_uint(binary_part(ifd, size - 4, 4), endian), size}
    else
      _ -> {:error, :invalid_ifd}
    end
  end

  defp collect_entry(reader, {pos, entry}, role, endian, pending, kept, wiped) do
    <<tag::binary-size(2), type::binary-size(2), count::binary-size(4), value::binary-size(4)>> =
      entry

    [tag, type, count, value] = Enum.map([tag, type, count, value], &decode_uint(&1, endian))

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
             true <- valid_range?(reader, start, length),
             {:ok, pending} <-
               referenced_ifds(reader, tag, type, count, start, role, endian, pending) do
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
  defp referenced_ifds(_reader, _tag, 13, _count, _start, :wipe, _endian, _pending),
    do: {:error, :unsupported_gps_pointer}

  defp referenced_ifds(reader, tag, type, count, start, :keep, endian, pending)
       when tag in [0x8769, 0xA005, 0x014A] or type == 13 do
    with true <- type in [4, 13] and (tag == 0x014A or type == 13 or count == 1),
         {:ok, values} <- Reader.read(reader, start, count * 4) do
      offsets = for <<value::binary-size(4) <- values>>, do: {decode_uint(value, endian), :keep}
      {:ok, offsets ++ pending}
    else
      _ -> {:error, :invalid_ifd_pointer}
    end
  end

  defp referenced_ifds(_reader, _tag, _type, _count, _start, _role, _endian, pending),
    do: {:ok, pending}

  defp tiff_type_size(type) when type in [1, 2, 6, 7], do: {:ok, 1}
  defp tiff_type_size(type) when type in [3, 8], do: {:ok, 2}
  defp tiff_type_size(type) when type in [4, 9, 11, 13], do: {:ok, 4}
  defp tiff_type_size(type) when type in [5, 10, 12], do: {:ok, 8}
  defp tiff_type_size(_), do: {:error, :unsupported_tiff_type}

  defp valid_range?(reader, offset, length),
    do: offset >= 8 and length > 0 and offset + length <= Reader.size(reader)

  defp read_uint(reader, offset, bytes, endian) do
    with {:ok, data} <- Reader.read(reader, offset, bytes), do: {:ok, decode_uint(data, endian)}
  end

  defp decode_uint(data, endian), do: :binary.decode_unsigned(data, endian)

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
end
