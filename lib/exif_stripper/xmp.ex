# SPDX-License-Identifier: MIT

defmodule ExifStripper.XMP do
  @moduledoc false
  # Finds location properties in an XMP packet and returns patches that
  # overwrite them with spaces, so that no byte offsets change and the XML
  # stays well-formed. Location properties are elements and attributes in the
  # EXIF namespace whose local name starts with `GPS`, and the position and
  # altitude properties of the DJI drone namespace. Prefixes are resolved
  # through the xmlns declarations in scope.
  #
  # The scanner is a strict subset of XML: anything it cannot follow safely
  # (DTDs, unbalanced tags, unbound prefixes on location names, UTF-16, ...) is
  # an error, so that no location property can hide from it.

  @root_scope %{"xml" => "http://www.w3.org/XML/1998/namespace"}

  # DJI drone position and altitude (exiftool's DJI XMP table, plus the laser
  # rangefinder target position of enterprise drones). Attitude, speeds,
  # calibration and RTK accuracies (RtkStd*) are kept.
  @dji_ns "http://www.dji.com/drone-dji/1.0/"
  @dji_location ~w(GpsLatitude GpsLongitude GpsLongtitude Latitude Longitude
                   AbsoluteAltitude RelativeAltitude
                   LRFTargetLat LRFTargetLon LRFTargetAlt LRFTargetAbsAlt)
  @whitespace [?\s, ?\t, ?\r, ?\n]
  @name_stop [?\s, ?\t, ?\r, ?\n, ?/, ?>, ?<, ?=, ?', ?", ??, ?!]

  alias ExifStripper.Reader

  @doc "Patches relative to the packet; reads the whole reader (limited in size)."
  @spec gps_patches(binary() | Reader.t()) ::
          {:ok, [{non_neg_integer(), binary()}]} | {:error, term()}
  def gps_patches(%Reader{} = reader) do
    size = Reader.size(reader)

    if size > Reader.max_metadata_size(),
      do: {:error, :metadata_too_large},
      else: with({:ok, packet} <- Reader.read(reader, 0, size), do: gps_patches(packet))
  end

  def gps_patches(packet) when is_binary(packet) do
    # Some writers add NUL terminators; NUL anywhere else means UTF-16/32.
    packet = String.trim_trailing(packet, <<0>>)

    {rest, pos} =
      case packet do
        <<0xEF, 0xBB, 0xBF, rest::binary>> -> {rest, 3}
        _ -> {packet, 0}
      end

    if :binary.match(packet, <<0>>) != :nomatch do
      {:error, :unsupported_xmp_encoding}
    else
      with {:ok, ranges} <- content(rest, pos, [], []) do
        {:ok, for({pos, len} <- Enum.reverse(ranges), do: {pos, :binary.copy(" ", len)})}
      end
    end
  end

  # The stack holds {name, scope, mode} for open elements; mode is :keep,
  # :inside (within a blanked element) or {:blank, start}.
  defp content(rest, pos, stack, acc) do
    case :binary.match(rest, "<") do
      :nomatch ->
        with :ok <- check_text(rest, stack) do
          if stack == [], do: {:ok, acc}, else: {:error, :unclosed_xmp_element}
        end

      {i, 1} ->
        <<text::binary-size(i), markup::binary>> = rest

        with :ok <- check_text(text, stack),
             {:ok, rest, pos, stack, acc} <- markup(markup, pos + i, stack, acc) do
          content(rest, pos, stack, acc)
        end
    end
  end

  # Character data outside the root element can only be whitespace (padding).
  defp check_text(<<c, rest::binary>>, []) when c in @whitespace, do: check_text(rest, [])
  defp check_text(<<>>, []), do: :ok
  defp check_text(_text, []), do: {:error, :invalid_xmp}

  defp check_text(_text, _stack), do: :ok

  # exiftool ends processing instructions at the first `>`, and an XML
  # declaration could switch to an encoding that hides markup: refuse both.
  defp markup(<<"<?", rest::binary>>, pos, stack, acc) do
    case :binary.match(rest, "?>") do
      {i, 2} ->
        <<body::binary-size(i), "?>", rest::binary>> = rest

        cond do
          :binary.match(body, [">", "<"]) != :nomatch -> {:error, :invalid_xmp_markup}
          not utf8?(body) -> {:error, :unsupported_xmp_encoding}
          true -> {:ok, rest, pos + i + 4, stack, acc}
        end

      :nomatch ->
        {:error, :unterminated_xmp_markup}
    end
  end

  defp markup(<<"<!--", rest::binary>>, pos, stack, acc),
    do: skip_past(rest, pos + 4, "-->", stack, acc)

  defp markup(<<"<![CDATA[", rest::binary>>, pos, [_ | _] = stack, acc),
    do: skip_past(rest, pos + 9, "]]>", stack, acc)

  # DTDs can declare entities that expand to markup the scanner would not see.
  defp markup(<<"<!", _::binary>>, _pos, _stack, _acc), do: {:error, :unsupported_xmp_markup}

  defp markup(<<"</", rest::binary>>, pos, stack, acc) do
    with {:ok, name, rest, end_pos} <- name(rest, pos + 2),
         {rest, end_pos, _} <- skip_whitespace(rest, end_pos),
         <<">", rest::binary>> <- rest,
         [{^name, _scope, mode} | stack] <- stack do
      acc =
        case mode do
          {:blank, start} -> [{start, end_pos + 1 - start} | acc]
          _ -> acc
        end

      {:ok, rest, end_pos + 1, stack, acc}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_xmp_end_tag}
    end
  end

  defp markup(<<"<", rest::binary>>, pos, stack, acc) do
    {parent_scope, parent_mode} =
      case stack do
        [{_, scope, mode} | _] -> {scope, mode}
        [] -> {@root_scope, :keep}
      end

    with {:ok, name, rest, end_pos} <- name(rest, pos + 1),
         {:ok, attributes, self_closing?, rest, end_pos} <- attributes(rest, end_pos, []),
         {:ok, scope} <- declare(attributes, parent_scope),
         {:ok, mode, acc} <- classify(name, attributes, scope, parent_mode, pos, stack, acc) do
      cond do
        not self_closing? -> {:ok, rest, end_pos, [{name, scope, mode} | stack], acc}
        match?({:blank, _}, mode) -> {:ok, rest, end_pos, stack, [{pos, end_pos - pos} | acc]}
        true -> {:ok, rest, end_pos, stack, acc}
      end
    end
  end

  defp skip_past(rest, pos, terminator, stack, acc) do
    case :binary.match(rest, terminator) do
      {i, len} ->
        <<_::binary-size(i + len), rest::binary>> = rest
        {:ok, rest, pos + i + len, stack, acc}

      :nomatch ->
        {:error, :unterminated_xmp_markup}
    end
  end

  # Decides whether the element is blanked; if not, blanks GPS attributes.
  defp classify(_name, _attributes, _scope, mode, _pos, _stack, acc) when mode != :keep,
    do: {:ok, :inside, acc}

  defp classify(name, attributes, scope, :keep, pos, stack, acc) do
    case gps?(name, scope, :element) do
      # Blanking the root element would leave no document.
      {:ok, true} when stack == [] ->
        {:error, :gps_xmp_root}

      {:ok, true} ->
        {:ok, {:blank, pos}, acc}

      {:ok, false} ->
        with {:ok, acc} <- gps_attributes(attributes, scope, acc), do: {:ok, :keep, acc}

      error ->
        error
    end
  end

  defp gps_attributes(attributes, scope, acc) do
    Enum.reduce_while(attributes, {:ok, acc}, fn {name, _value, start, stop}, {:ok, acc} ->
      case gps?(name, scope, :attribute) do
        {:ok, true} -> {:cont, {:ok, [{start, stop - start} | acc]}}
        {:ok, false} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp gps?("xmlns" <> _, _scope, :attribute), do: {:ok, false}

  defp gps?(name, scope, kind) do
    {prefix, local} =
      case :binary.split(name, ":") do
        [prefix, local] -> {prefix, local}
        # Unprefixed attributes are in no namespace.
        [local] -> {if(kind == :element, do: "", else: nil), local}
      end

    cond do
      not location_name?(local) -> {:ok, false}
      prefix == nil -> {:ok, false}
      Map.has_key?(scope, prefix) -> {:ok, location?(Map.fetch!(scope, prefix), local)}
      prefix == "" -> {:ok, false}
      true -> {:error, :unbound_xmp_prefix}
    end
  end

  defp location_name?(local), do: match?("GPS" <> _, local) or local in @dji_location

  defp location?(@dji_ns, local), do: local in @dji_location
  defp location?(uri, "GPS" <> _), do: exif_namespace?(uri)
  defp location?(_uri, _local), do: false

  # exiftool also reads other versions, and the Nikon NX2 form without the slash.
  defp exif_namespace?(uri),
    do: is_binary(uri) and uri =~ ~r{\Ahttp://ns\.adobe\.com/exif/\d+\.\d+/?\z}

  # True unless an XML declaration names an encoding other than UTF-8.
  defp utf8?(<<"xml", c, _::binary>> = body) when c in @whitespace do
    case Regex.run(~r/encoding\s*=\s*(["'])(.*?)\1/, body) do
      [_, _, encoding] -> String.downcase(encoding) in ["utf-8", "utf8"]
      nil -> not String.contains?(body, "encoding")
    end
  end

  defp utf8?(_body), do: true

  # Applies xmlns declarations. Entity references in namespace names could
  # hide the EXIF namespace, so they are refused.
  defp declare(attributes, scope) do
    Enum.reduce_while(attributes, {:ok, scope}, fn {name, value, _, _}, {:ok, scope} ->
      prefix =
        case name do
          "xmlns" -> ""
          "xmlns:" <> prefix -> prefix
          _ -> nil
        end

      cond do
        prefix == nil ->
          {:cont, {:ok, scope}}

        value =~ "&" or (value == "" and prefix != "") ->
          {:halt, {:error, :invalid_xmp_namespace}}

        true ->
          {:cont, {:ok, Map.put(scope, prefix, value)}}
      end
    end)
  end

  # Returns {name, value, start, stop} per attribute, `stop` after the quote.
  defp attributes(rest, pos, acc) do
    case skip_whitespace(rest, pos) do
      {<<"/>", rest::binary>>, pos, _} ->
        finish_attributes(acc, true, rest, pos + 2)

      {<<">", rest::binary>>, pos, _} ->
        finish_attributes(acc, false, rest, pos + 1)

      {rest, start, true} ->
        with {:ok, name, rest, pos} <- name(rest, start),
             {<<"=", rest::binary>>, pos, _} <- skip_whitespace(rest, pos),
             {<<q, rest::binary>>, pos, _} when q in [?', ?"] <- skip_whitespace(rest, pos + 1),
             {length, 1} <- :binary.match(rest, <<q>>),
             <<value::binary-size(length), _quote, rest::binary>> <- rest,
             :nomatch <- :binary.match(value, "<") do
          attributes(rest, pos + 1 + length + 1, [
            {name, value, start, pos + 1 + length + 1} | acc
          ])
        else
          {:error, _} = error -> error
          _ -> {:error, :invalid_xmp_attribute}
        end

      _ ->
        {:error, :invalid_xmp_tag}
    end
  end

  defp finish_attributes(acc, self_closing?, rest, pos) do
    names = Enum.map(acc, &elem(&1, 0))

    if length(names) == MapSet.size(MapSet.new(names)),
      do: {:ok, Enum.reverse(acc), self_closing?, rest, pos},
      else: {:error, :duplicate_xmp_attribute}
  end

  defp name(rest, pos) do
    case name_length(rest, 0) do
      0 ->
        {:error, :invalid_xmp_name}

      length ->
        <<name::binary-size(length), rest::binary>> = rest
        {:ok, name, rest, pos + length}
    end
  end

  defp name_length(<<c, rest::binary>>, n) when c not in @name_stop, do: name_length(rest, n + 1)
  defp name_length(_rest, n), do: n

  # Returns {rest, pos, skipped_any?}.
  defp skip_whitespace(rest, pos, skipped? \\ false)

  defp skip_whitespace(<<c, rest::binary>>, pos, _) when c in @whitespace,
    do: skip_whitespace(rest, pos + 1, true)

  defp skip_whitespace(rest, pos, skipped?), do: {rest, pos, skipped?}
end
