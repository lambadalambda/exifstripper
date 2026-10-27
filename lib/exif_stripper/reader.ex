# SPDX-License-Identifier: MIT

defmodule ExifStripper.Reader do
  @moduledoc false
  # Random access to a binary or an open file, so that the same parsers work on
  # both. Offsets are relative to the reader; `slice/3` makes a sub-reader. All
  # reads are bounds-checked against the reader size.
  #
  # `peek/3` is for walking many small headers: on files it reads whole blocks
  # and keeps the last one in the returned reader. It raises if the file
  # shrinks or cannot be read; `strip_gps_data/2` turns that into an error.

  defstruct [:source, base: 0, size: 0, cache: nil]

  @type t :: %__MODULE__{}

  @block_size 65_536

  # Metadata that parsers load into memory (ISO-BMFF `meta` boxes, Exif and
  # XMP items) is refused above this size.
  @max_metadata_size 16 * 1024 * 1024

  @spec max_metadata_size() :: pos_integer()
  def max_metadata_size, do: @max_metadata_size

  @spec from_binary(binary()) :: t()
  def from_binary(data) when is_binary(data),
    do: %__MODULE__{source: data, size: byte_size(data)}

  @doc "A reader over an open raw binary file. Reads fail if the file shrinks."
  @spec from_file(:file.fd(), non_neg_integer()) :: t()
  def from_file(fd, size), do: %__MODULE__{source: {:file, fd}, size: size}

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @spec read(t(), integer(), integer()) :: {:ok, binary()} | {:error, term()}
  def read(%__MODULE__{} = reader, offset, length) do
    if in_bounds?(reader, offset, length),
      do: do_read(reader, reader.base + offset, length),
      else: {:error, :out_of_bounds}
  end

  @doc "Reads up to `length` bytes: fewer at the end of the data."
  @spec peek(t(), non_neg_integer(), non_neg_integer()) :: {binary(), t()}
  def peek(%__MODULE__{source: data} = reader, offset, length) when is_binary(data),
    do: {binary_part(data, reader.base + offset, clamp(reader, offset, length)), reader}

  def peek(%__MODULE__{} = reader, offset, length) do
    length = clamp(reader, offset, length)
    absolute = reader.base + offset

    case reader.cache do
      {start, block} when absolute >= start and absolute + length <= start + byte_size(block) ->
        {binary_part(block, absolute - start, length), reader}

      _ ->
        block_length = clamp(reader, offset, max(length, @block_size))
        {:ok, block} = do_read(reader, absolute, block_length)
        {binary_part(block, 0, length), %{reader | cache: {absolute, block}}}
    end
  end

  @spec slice(t(), integer(), integer()) :: {:ok, t()} | {:error, term()}
  def slice(%__MODULE__{} = reader, offset, length) do
    if in_bounds?(reader, offset, length),
      do: {:ok, %{reader | base: reader.base + offset, size: length, cache: nil}},
      else: {:error, :out_of_bounds}
  end

  defp in_bounds?(reader, offset, length),
    do:
      is_integer(offset) and is_integer(length) and offset >= 0 and length >= 0 and
        offset + length <= reader.size

  defp clamp(reader, offset, length), do: max(0, min(length, reader.size - offset))

  defp do_read(_reader, _absolute, 0), do: {:ok, <<>>}

  defp do_read(%__MODULE__{source: data}, absolute, length) when is_binary(data),
    do: {:ok, binary_part(data, absolute, length)}

  defp do_read(%__MODULE__{source: {:file, fd}}, absolute, length) do
    case :file.pread(fd, absolute, length) do
      {:ok, data} when byte_size(data) == length -> {:ok, data}
      {:ok, _short} -> {:error, :file_changed}
      :eof -> {:error, :file_changed}
      {:error, _} = error -> error
    end
  end
end
