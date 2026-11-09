defmodule Meshcore.Lpp do
  @moduledoc """
  Decoder for Cayenne LPP (Low Power Payload) telemetry frames.

  Mirrors Python's `lpp_parse` / `lpp_json_encoder`: a frame is a list of
  `%{channel: integer, type: String.t(), value: term}` maps. Multi-field types
  decode to maps (`:gps` → `%{latitude:, longitude:, altitude:}`), the
  gyrometer to a list, everything else to a number.

  As in the Python library, a zero byte where a channel number is expected
  terminates parsing.
  """

  # type => {name, byte size per field, fields, signed?, scale, field names}
  # field names: [] => scalar, nil => raw list, [..] => map
  @types %{
    0 => {"digital input", 1, 1, false, 1, []},
    1 => {"digital output", 1, 1, false, 1, []},
    2 => {"analog input", 2, 1, true, 100, []},
    3 => {"analog output", 2, 1, true, 100, []},
    100 => {"generic sensor", 4, 1, false, 1, []},
    101 => {"illuminance", 2, 1, false, 1, []},
    102 => {"presence", 1, 1, false, 1, []},
    103 => {"temperature", 2, 1, true, 10, []},
    104 => {"humidity", 1, 1, false, 2, []},
    113 => {"accelerometer", 2, 3, true, 1000, [:acc_x, :acc_y, :acc_z]},
    115 => {"barometer", 2, 1, false, 10, []},
    116 => {"voltage", 2, 1, true, 100, []},
    117 => {"current", 2, 1, true, 1000, []},
    118 => {"frequency", 4, 1, false, 1, []},
    120 => {"percentage", 1, 1, false, 1, []},
    121 => {"altitude", 2, 1, true, 1, []},
    122 => {"load", 3, 1, true, 1000, []},
    125 => {"concentration", 2, 1, false, 1, []},
    128 => {"power", 2, 1, false, 1, []},
    130 => {"distance", 4, 1, false, 1000, []},
    131 => {"energy", 4, 1, false, 1000, []},
    132 => {"direction", 2, 1, false, 1, []},
    133 => {"time", 4, 1, false, 1, []},
    134 => {"gyrometer", 2, 3, true, 100, nil},
    135 => {"colour", 1, 3, false, 1, [:red, :green, :blue]},
    142 => {"switch", 1, 1, false, 1, []}
  }

  @type reading :: %{channel: non_neg_integer(), type: String.t(), value: term()}

  @doc """
  Parses a full LPP frame.

  Returns `{:error, {:unknown_lpp_type, type}}` or `{:error, :truncated}` for
  malformed input.
  """
  @spec parse(binary()) :: {:ok, [reading()]} | {:error, term()}
  def parse(buf), do: do_parse(buf, [])

  defp do_parse(<<0, _::binary>>, acc), do: {:ok, Enum.reverse(acc)}
  defp do_parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_parse(<<chan, type, rest::binary>>, acc) do
    case read_value(type, rest) do
      {:ok, name, value, rest} ->
        do_parse(rest, [%{channel: chan, type: name, value: value} | acc])

      {:error, _} = err ->
        err
    end
  end

  defp do_parse(_, _), do: {:error, :truncated}

  @doc """
  Parses a min/max/average (MMA) telemetry block: repeated
  `channel, type, min, max, avg` records.
  """
  @spec parse_mma(binary()) :: {:ok, [map()]} | {:error, term()}
  def parse_mma(buf), do: do_mma(buf, [])

  defp do_mma(<<0, _::binary>>, acc), do: {:ok, Enum.reverse(acc)}
  defp do_mma(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_mma(<<chan, type, rest::binary>>, acc) do
    case Map.fetch(@types, type) do
      :error ->
        {:error, {:unknown_lpp_type, type}}

      {:ok, {name, size, fields, _, _, _} = spec} ->
        total = size * fields

        case rest do
          <<min::binary-size(total), max::binary-size(total), avg::binary-size(total),
            rest::binary>> ->
            rec = %{
              channel: chan,
              type: name,
              min: format(spec, decode(spec, min)),
              max: format(spec, decode(spec, max)),
              avg: format(spec, decode(spec, avg))
            }

            do_mma(rest, [rec | acc])

          _ ->
            {:error, :truncated}
        end
    end
  end

  defp do_mma(_, _), do: {:error, :truncated}

  defp read_value(136, rest) do
    case rest do
      <<lat::big-signed-24, lon::big-signed-24, alt::big-signed-24, rest::binary>> ->
        {:ok, "gps", %{latitude: lat / 10_000, longitude: lon / 10_000, altitude: alt / 100},
         rest}

      _ ->
        {:error, :truncated}
    end
  end

  defp read_value(type, rest) do
    case Map.fetch(@types, type) do
      :error ->
        {:error, {:unknown_lpp_type, type}}

      {:ok, {name, size, fields, _, _, _} = spec} ->
        total = size * fields

        case rest do
          <<raw::binary-size(total), rest::binary>> ->
            {:ok, name, format(spec, decode(spec, raw)), rest}

          _ ->
            {:error, :truncated}
        end
    end
  end

  defp decode({_, size, _fields, signed, scale, _}, raw) do
    bits = size * 8

    for <<chunk::binary-size(size) <- raw>> do
      int =
        if signed do
          <<v::big-signed-size(bits)>> = chunk
          v
        else
          <<v::big-unsigned-size(bits)>> = chunk
          v
        end

      if scale == 1, do: int, else: int / scale
    end
  end

  defp format({_, _, _, _, _, []}, [v]), do: v
  defp format({_, _, _, _, _, nil}, vals), do: vals

  defp format({_, _, _, _, _, names}, vals) do
    names |> Enum.zip(vals) |> Map.new()
  end
end
