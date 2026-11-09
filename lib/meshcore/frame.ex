defmodule Meshcore.Frame do
  @moduledoc """
  Stream framing used by the serial and TCP transports.

  Frames sent to the device are `0x3C | length (u16 LE) | payload`; frames
  coming from the device are `0x3E | length (u16 LE) | payload`. The decoder is
  resilient against garbage on the line (some radios interleave console
  output on the same UART): it resynchronises on the next `0x3E` byte and
  drops frames announcing more than #{300} bytes.
  """

  @to_device 0x3C
  @from_device 0x3E
  @max_frame 300

  @type t :: %__MODULE__{buffer: binary()}
  defstruct buffer: <<>>

  @doc "Creates an empty decoder state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Wraps `payload` into an outgoing frame."
  @spec encode(binary()) :: binary()
  def encode(payload) when is_binary(payload) do
    <<@to_device, byte_size(payload)::little-unsigned-16, payload::binary>>
  end

  @doc """
  Feeds a chunk of received bytes; returns the completed frame payloads (in
  order) and the new decoder state.

      iex> {frames, _} = Meshcore.Frame.decode(Meshcore.Frame.new(), <<0x3E, 2, 0, 0xAA, 0xBB, 0x3E, 1>>)
      iex> frames
      [<<0xAA, 0xBB>>]
  """
  @spec decode(t(), binary()) :: {[binary()], t()}
  def decode(%__MODULE__{buffer: buffer} = state, chunk) when is_binary(chunk) do
    {frames, rest} = extract(buffer <> chunk, [])
    {frames, %{state | buffer: rest}}
  end

  defp extract(buffer, acc) do
    case :binary.match(buffer, <<@from_device>>) do
      :nomatch ->
        {Enum.reverse(acc), <<>>}

      {idx, _} ->
        <<_junk::binary-size(idx), buf::binary>> = buffer

        case buf do
          <<@from_device, size::little-unsigned-16, rest::binary>> when size > @max_frame ->
            extract(rest, acc)

          <<@from_device, size::little-unsigned-16, payload::binary-size(size), rest::binary>> ->
            acc = if size == 0, do: acc, else: [payload | acc]
            extract(rest, acc)

          incomplete ->
            {Enum.reverse(acc), incomplete}
        end
    end
  end
end
