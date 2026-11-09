defmodule Meshcore.Parsing do
  @moduledoc """
  Parsers for the binary sub-structures carried by status, telemetry and ACL
  responses.
  """

  import Meshcore.Util, only: [hex: 1]

  @doc """
  Parses a repeater/room status block.

  `offset` is where the numeric fields start; for push frames that is `8`
  (code + reserved + 6 byte key prefix) and the key prefix is taken from the
  data. When `pubkey_prefix` is given (binary response path) it is used
  verbatim and the offset is `0`.

  Frames shorter than 52 bytes after the offset are zero-padded, as the Python
  parser tolerates short reads. `:recv_errors` is `nil` for frames from
  firmware older than v1.12.0.
  """
  @spec parse_status(binary(), String.t() | nil, non_neg_integer()) :: map()
  def parse_status(data, pubkey_prefix \\ nil, offset \\ 0) do
    {pre, offset} =
      case pubkey_prefix do
        nil -> {hex(binary_part(data, 2, 6)), 8}
        prefix -> {prefix, offset}
      end

    body = data |> binary_part(offset, byte_size(data) - offset) |> pad(56)

    <<bat::little-16, tx_queue_len::little-16, noise_floor::little-signed-16,
      last_rssi::little-signed-16, nb_recv::little-32, nb_sent::little-32, airtime::little-32,
      uptime::little-32, sent_flood::little-32, sent_direct::little-32, recv_flood::little-32,
      recv_direct::little-32, full_evts::little-16, last_snr::little-signed-16,
      direct_dups::little-16, flood_dups::little-16, rx_airtime::little-32,
      recv_errors::little-32>> = binary_part(body, 0, 56)

    %{
      pubkey_pre: pre,
      bat: bat,
      tx_queue_len: tx_queue_len,
      noise_floor: noise_floor,
      last_rssi: last_rssi,
      nb_recv: nb_recv,
      nb_sent: nb_sent,
      airtime: airtime,
      uptime: uptime,
      sent_flood: sent_flood,
      sent_direct: sent_direct,
      recv_flood: recv_flood,
      recv_direct: recv_direct,
      full_evts: full_evts,
      last_snr: last_snr / 4,
      direct_dups: direct_dups,
      flood_dups: flood_dups,
      rx_airtime: rx_airtime,
      recv_errors: if(byte_size(data) - offset >= 56, do: recv_errors, else: nil)
    }
  end

  defp pad(bin, size) when byte_size(bin) >= size, do: bin
  defp pad(bin, size), do: bin <> :binary.copy(<<0>>, size - byte_size(bin))

  @doc """
  Parses an access-control list: 7 byte entries (6 byte key prefix, 1 byte
  permission). Empty (all-zero) slots are skipped.
  """
  @spec parse_acl(binary()) :: [%{key: String.t(), perm: 0..255}]
  def parse_acl(buf), do: do_acl(buf, [])

  defp do_acl(<<key::binary-6, perm, rest::binary>>, acc) do
    if key == <<0, 0, 0, 0, 0, 0>>,
      do: do_acl(rest, acc),
      else: do_acl(rest, [%{key: hex(key), perm: perm} | acc])
  end

  defp do_acl(_, acc), do: Enum.reverse(acc)
end
