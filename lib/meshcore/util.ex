defmodule Meshcore.Util do
  @moduledoc """
  Small binary/encoding helpers shared across the library.

  ## Destinations

  The Python library distinguishes `bytes` and `str` destinations. Elixir
  binaries are both, so `to_key/2` applies this rule: a binary made only of
  hex digits and at least `2 * prefix_length` characters long is treated as a
  **hex string**, anything else as **raw bytes**. A contact map (anything with
  a `:public_key` hex string) is accepted as well.
  """

  @type destination :: binary() | %{required(:public_key) => String.t(), optional(any()) => any()}

  @doc """
  Resolves a destination (raw key, hex key or contact map) into `prefix_length`
  raw key bytes.

  Raises `ArgumentError` for malformed input (the equivalent of Python's
  `ValueError`).
  """
  @spec to_key(destination(), pos_integer()) :: binary()
  def to_key(dst, prefix_length \\ 6)

  def to_key(%{public_key: pk}, prefix_length) when is_binary(pk) do
    case Base.decode16(pk, case: :mixed) do
      {:ok, bin} when byte_size(bin) >= prefix_length ->
        binary_part(bin, 0, prefix_length)

      {:ok, bin} ->
        raise ArgumentError,
              "Invalid prefix len, expecting #{prefix_length}, got #{byte_size(bin)}"

      :error ->
        raise ArgumentError, "Invalid public_key in contact: #{inspect(pk)}"
    end
  end

  def to_key(%{}, _prefix_length),
    do: raise(ArgumentError, "Contact object must have a :public_key field")

  def to_key(dst, prefix_length) when is_binary(dst) do
    if hex?(dst) and byte_size(dst) >= 2 * prefix_length do
      dst |> Base.decode16!(case: :mixed) |> binary_part(0, prefix_length)
    else
      if byte_size(dst) < prefix_length do
        raise ArgumentError,
              "Invalid prefix len, expecting #{prefix_length}, got #{byte_size(dst)}"
      end

      binary_part(dst, 0, prefix_length)
    end
  end

  def to_key(dst, _prefix_length) do
    raise ArgumentError,
          "Destination must be a public key or contact map, got: #{inspect(dst)}"
  end

  @doc "Returns `true` if `bin` is a non-empty, even-length string of hex digits."
  @spec hex?(binary()) :: boolean()
  def hex?(bin) when is_binary(bin) do
    byte_size(bin) > 0 and rem(byte_size(bin), 2) == 0 and
      match?({:ok, _}, Base.decode16(bin, case: :mixed))
  end

  @doc """
  Normalises raw bytes: accepts a binary (taken verbatim) or `{:hex, string}`.
  """
  @spec to_bytes(binary() | {:hex, String.t()}) :: binary()
  def to_bytes({:hex, hex}) when is_binary(hex), do: Base.decode16!(hex, case: :mixed)
  def to_bytes(bin) when is_binary(bin), do: bin

  @doc "Lower-case hex encoding."
  @spec hex(binary()) :: String.t()
  def hex(bin), do: Base.encode16(bin, case: :lower)

  @doc """
  Decodes UTF-8, silently dropping invalid bytes (Python's
  `decode("utf-8", "ignore")`).
  """
  @spec utf8(binary()) :: String.t()
  def utf8(bin) when is_binary(bin) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      result when is_binary(result) ->
        result

      {:error, good, <<_bad, rest::binary>>} ->
        good <> utf8(rest)

      {:incomplete, good, _rest} ->
        good
    end
  end

  @doc "Like `utf8/1` but also removes every NUL character."
  @spec cstr(binary()) :: String.t()
  def cstr(bin), do: bin |> utf8() |> String.replace("\0", "")

  @doc "Removes leading and trailing NUL bytes."
  @spec strip_nul(binary()) :: binary()
  def strip_nul(bin) do
    bin |> String.trim_leading("\0") |> String.trim_trailing("\0")
  end

  @doc """
  Splits an encoded path-length byte into `{hash_mode, hop_count}`.

  `255` means "flood" and yields `{-1, -1}`.
  """
  @spec split_path_len(0..255) :: {integer(), integer()}
  def split_path_len(255), do: {-1, -1}
  def split_path_len(plen), do: {Bitwise.bsr(plen, 6), Bitwise.band(plen, 0x3F)}

  @doc "Current Unix time in seconds."
  @spec now() :: non_neg_integer()
  def now, do: System.os_time(:second)

  @doc "SHA-256 digest."
  @spec sha256(iodata()) :: binary()
  def sha256(data), do: :crypto.hash(:sha256, data)

  @doc "Reads a random unsigned 32 bit integer in `1..0xFFFFFFFF`."
  @spec random_u32() :: pos_integer()
  def random_u32, do: :rand.uniform(0xFFFFFFFF)

  @doc "Little-endian unsigned integer encoding."
  @spec u(integer(), pos_integer()) :: binary()
  def u(value, bytes), do: <<value::little-unsigned-integer-size(bytes * 8)>>

  @doc "Little-endian signed integer encoding."
  @spec s(integer(), pos_integer()) :: binary()
  def s(value, bytes), do: <<value::little-signed-integer-size(bytes * 8)>>
end
