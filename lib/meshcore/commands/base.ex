defmodule Meshcore.Commands.Base do
  @moduledoc """
  Shared plumbing for the command modules.

  All commands share these conventions:

    * the first argument is the connection (`mc`, the pid or registered name of
      a `Meshcore.Client`);
    * timeouts are **milliseconds** (Python uses seconds);
    * a command returns `{:ok, %Meshcore.Event{}}` or `{:error, %Meshcore.Event{}}`.
      The error event has `type: :error` and a payload with either
      `:reason` (`:timeout`, `:not_connected`, `:disconnected`, …) or
      `:error_code`/`:code_string` when the device rejected the command;
    * a *destination* (`t:Meshcore.Util.destination/0`) is a contact map, a hex
      public key or a raw public key;
    * programmer errors (malformed destination, wrong key size…) raise
      `ArgumentError`, like Python's `ValueError`.
  """

  require Logger
  import Meshcore.Util

  alias Meshcore.{Client, Event}

  @max_reply_path_bytes 64
  @max_reply_path_hops 63

  @type mc :: GenServer.server()
  @type result :: {:ok, Event.t()} | {:error, Event.t()}

  @doc """
  Sends raw command bytes and waits for one of the `expected` event types.

  See `Meshcore.Client.command/4` for the options. With no expected events the
  command is fire-and-forget.
  """
  @spec send_command(mc(), iodata(), [Event.type()], keyword()) :: result()
  def send_command(mc, data, expected \\ [], opts \\ []) do
    Client.command(mc, IO.iodata_to_binary(data), expected, opts)
  end

  @doc false
  # Same as `send_command/4` for the common "OK or ERROR" acknowledgement.
  def send_ok(mc, data, opts \\ []), do: send_command(mc, data, [:ok, :error], opts)

  @doc false
  def contact_by_prefix(mc, hex_prefix), do: Client.call(mc, {:contact_by_prefix, hex_prefix})

  @doc false
  def update_local_contact(mc, public_key, changes),
    do: Client.cast(mc, {:update_contact, public_key, changes})

  @doc """
  Sends a binary request (command `0x32`) to `dst`.

  The pending request is registered with the reader *atomically* when the
  `:msg_sent` acknowledgement arrives, so a response can never overtake the
  registration. Options: `:timeout` and `:min_timeout` (ms, `nil`/`0` = use the
  device's suggestion), `:context`, `:then` (see `Meshcore.Client.command/4`).
  """
  @spec send_binary_req(mc(), Meshcore.Util.destination(), atom(), binary() | nil, keyword()) ::
          result()
  def send_binary_req(mc, dst, request_type, data \\ nil, opts \\ []) do
    dst_bytes = to_key(dst, 32)
    prefix = to_key(dst, 6)
    Logger.debug("Binary request to #{hex(dst_bytes)}")

    payload =
      <<0x32>> <>
        dst_bytes <> <<Meshcore.Packets.binary_req_type(request_type)>> <> (data || <<>>)

    register = %{
      prefix: hex(prefix),
      request_type: request_type,
      timeout: opts[:timeout] || 0,
      min_timeout: opts[:min_timeout] || 0,
      context: Keyword.get(opts, :context, %{})
    }

    send_command(mc, payload, [:msg_sent, :error], register: register, then: opts[:then])
  end

  @doc """
  Sends an anonymous request (command `0x39`) to `dst`.

  `dst` need not be a known contact. When it is, the contact's out path is used
  as the reply path; otherwise a zero-hop direct reply is requested. A contact
  that is currently flooded is temporarily pinned to a zero-hop path (the
  servers gate these requests behind direct routing) and reset afterwards.
  """
  @spec send_anon_req(mc(), Meshcore.Util.destination(), atom(), keyword()) :: result()
  def send_anon_req(mc, dst, request_type, opts \\ []) do
    dst_bytes = to_key(dst, 32)
    prefix = to_key(dst, 6)
    Logger.debug("Anon request to #{hex(dst_bytes)}")

    contact = contact_by_prefix(mc, hex(dst_bytes))

    case anon_reply_path(mc, contact) do
      {:error, _} = error ->
        error

      {:ok, reply_path, zero_hop?} ->
        payload =
          <<0x39>> <> dst_bytes <> <<Meshcore.Packets.anon_req_type(request_type)>> <> reply_path

        register = %{
          prefix: hex(prefix),
          request_type: request_type,
          timeout: opts[:timeout] || 0,
          min_timeout: opts[:min_timeout] || 0,
          context: Keyword.get(opts, :context, %{}),
          is_anon: true,
          hops: Bitwise.band(:binary.first(reply_path), 63)
        }

        result =
          send_command(mc, payload, [:msg_sent, :error], register: register, then: opts[:then])

        if zero_hop?, do: Meshcore.Commands.Contact.reset_path(mc, contact)
        result
    end
  end

  defp anon_reply_path(_mc, nil) do
    Logger.debug("No contact found, requesting a zero-hop direct reply path")
    {:ok, encode_reply_path(0, "", 0), false}
  end

  defp anon_reply_path(mc, contact) do
    if contact.out_path_len == -1 do
      Logger.info("No path set, trying zero hop")

      case Meshcore.Commands.Contact.change_contact_path(mc, contact, "") do
        {:error, _} ->
          Logger.error("Could not set zero-hop path, aborting anon request")
          {:error, Event.error(:path_reset_failed)}

        {:ok, _} ->
          {:ok, encode_reply_path(0, "", Map.get(contact, :out_path_hash_mode, 0)), true}
      end
    else
      {:ok,
       encode_reply_path(
         max(contact.out_path_len, 0),
         contact.out_path,
         Map.get(contact, :out_path_hash_mode, 0)
       ), false}
    end
  end

  @doc """
  Encodes the reply path a server should use when answering us.

  The first byte packs `hop_count | hash_mode << 6`; the path is reversed **by
  hop** (multi-byte hashes stay intact). Paths are truncated to what the
  server's 64 byte buffer can hold.
  """
  @spec encode_reply_path(integer(), String.t(), integer()) :: binary()
  def encode_reply_path(out_path_len, out_path_hex, out_path_hash_mode) do
    mode = max(out_path_hash_mode, 0)

    if mode > 2 do
      Logger.warning(
        "Unsupported out_path_hash_mode #{out_path_hash_mode}; requesting a zero-hop reply path instead"
      )

      <<0>>
    else
      hash_size = mode + 1
      hops = out_path_len |> max(0) |> min(@max_reply_path_hops)
      raw = Base.decode16!(out_path_hex || "", case: :mixed)
      hops = min(hops, div(byte_size(raw), hash_size))
      max_hops = min(@max_reply_path_hops, div(@max_reply_path_bytes, hash_size))

      hops =
        if hops > max_hops do
          Logger.warning(
            "Reply path of #{hops} hops x #{hash_size}B exceeds the #{@max_reply_path_bytes}B the server can hold; truncating to #{max_hops}"
          )

          max_hops
        else
          hops
        end

      path =
        for i <- (hops - 1)..0//-1, into: <<>>, do: binary_part(raw, i * hash_size, hash_size)

      <<Bitwise.bor(hops, Bitwise.bsl(mode, 6))>> <> path
    end
  end
end
