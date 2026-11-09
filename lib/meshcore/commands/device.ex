defmodule Meshcore.Commands.Device do
  @moduledoc """
  Commands that read or configure the companion device itself.
  """

  require Logger
  import Meshcore.Util
  import Meshcore.Commands.Base

  alias Meshcore.{Client, Event, Packets}

  @type mc :: GenServer.server()
  @type result :: {:ok, Event.t()} | {:error, Event.t()}

  @doc """
  Sends `CMD_APP_START`, which initialises the session and returns the
  device's `:self_info`. Options: `:timeout`.
  """
  @spec send_appstart(mc(), keyword()) :: result()
  def send_appstart(mc, opts \\ []),
    do: send_command(mc, <<0x01, 0x03, "      mccli">>, [:self_info, :error], opts)

  @doc "Queries device info (`:device_info`: model, firmware, limits…)."
  @spec send_device_query(mc()) :: result()
  def send_device_query(mc), do: send_command(mc, <<0x16, 0x03>>, [:device_info, :error])

  @doc "Runs a CLI command on the device and returns its `:cli_reply`."
  @spec run_cli_command(mc(), String.t()) :: result()
  def run_cli_command(mc, cmd),
    do: send_command(mc, <<Packets.command(:run_cli_command)>> <> cmd, [:cli_reply, :error])

  @doc """
  Transmits a raw radio packet. `data` is raw bytes or `{:hex, string}`.
  """
  @spec send_raw_packet(mc(), binary() | {:hex, String.t()}, 0..255) :: result()
  def send_raw_packet(mc, data, priority \\ 0) do
    data = to_bytes(data)
    send_ok(mc, <<Packets.command(:send_raw_packet), priority>> <> data)
  end

  @doc "Sends a self advertisement, optionally flooded."
  @spec send_advert(mc(), boolean()) :: result()
  def send_advert(mc, flood \\ false)
  def send_advert(mc, true), do: send_ok(mc, <<0x07, 0x01>>)
  def send_advert(mc, false), do: send_ok(mc, <<0x07>>)

  @doc "Sets the advertised node name."
  @spec set_name(mc(), String.t()) :: result()
  def set_name(mc, name), do: send_ok(mc, <<0x08>> <> name)

  @doc "Sets the advertised coordinates."
  @spec set_coords(mc(), float(), float()) :: result()
  def set_coords(mc, lat, lon),
    do: send_ok(mc, <<0x0E>> <> s(trunc(lat * 1.0e6), 4) <> s(trunc(lon * 1.0e6), 4) <> u(0, 4))

  @doc "Reboots the device. Fire-and-forget, always returns `{:ok, _}` once sent."
  @spec reboot(mc()) :: result()
  def reboot(mc), do: send_command(mc, <<0x13, "reboot">>)

  @doc "Reads battery level (and storage use on newer firmware)."
  @spec get_bat(mc()) :: result()
  def get_bat(mc), do: send_command(mc, <<0x14>>, [:battery, :error])

  @doc "Reads the device clock."
  @spec get_time(mc()) :: result()
  def get_time(mc), do: send_command(mc, <<0x05>>, [:current_time, :error])

  @doc "Sets the device clock (Unix seconds)."
  @spec set_time(mc(), non_neg_integer()) :: result()
  def set_time(mc, val), do: send_ok(mc, <<0x06>> <> u(val, 4))

  @doc "Sets the transmit power in dBm."
  @spec set_tx_power(mc(), non_neg_integer()) :: result()
  def set_tx_power(mc, val), do: send_ok(mc, <<0x0C>> <> u(val, 4))

  @doc """
  Sets the radio parameters: frequency (MHz), bandwidth (kHz), spreading
  factor, coding rate and – on repeater-capable firmware – `repeat`.
  """
  @spec set_radio(mc(), number(), number(), integer(), integer(), boolean() | integer() | nil) ::
          result()
  def set_radio(mc, freq, bw, sf, cr, repeat \\ nil) do
    data =
      <<0x0B>> <> u(trunc(freq * 1000), 4) <> u(trunc(bw * 1000), 4) <> <<sf, cr>>

    data =
      case repeat do
        nil -> data
        v -> data <> <<to_int(v)>>
      end

    send_ok(mc, data)
  end

  @doc "Sets RX delay and airtime factor."
  @spec set_tuning(mc(), non_neg_integer(), non_neg_integer()) :: result()
  def set_tuning(mc, rx_dly, af),
    do: send_ok(mc, <<0x15>> <> u(rx_dly, 4) <> u(af, 4) <> <<0, 0>>)

  @doc """
  Legacy variant of `set_other_params_from_infos/2` without `multi_acks`.
  """
  @spec set_other_params(mc(), boolean(), 0..3, 0..3, 0..3, 0..255) :: result()
  def set_other_params(
        mc,
        manual_add_contacts,
        telemetry_base,
        telemetry_loc,
        telemetry_env,
        advert_loc_policy
      ) do
    mode = telemetry_mode(telemetry_base, telemetry_loc, telemetry_env)
    send_ok(mc, <<0x26, to_int(manual_add_contacts), mode, advert_loc_policy>>)
  end

  @doc """
  Writes the "other params" block from a map shaped like `:self_info`
  (`:manual_add_contacts`, `:telemetry_mode_base|loc|env`, `:adv_loc_policy`,
  `:multi_acks`).
  """
  @spec set_other_params_from_infos(mc(), map()) :: result()
  def set_other_params_from_infos(mc, infos) do
    mode =
      telemetry_mode(
        infos.telemetry_mode_base,
        infos.telemetry_mode_loc,
        infos.telemetry_mode_env
      )

    send_ok(
      mc,
      <<0x26, to_int(infos.manual_add_contacts), mode, infos.adv_loc_policy, infos.multi_acks>>
    )
  end

  defp telemetry_mode(base, loc, env) do
    import Bitwise
    (base &&& 3) ||| (loc &&& 3) <<< 2 ||| (env &&& 3) <<< 4
  end

  defp to_int(true), do: 1
  defp to_int(false), do: 0
  defp to_int(n) when is_integer(n), do: n

  # read-modify-write of the "other params" block
  defp update_infos(mc, changes) do
    with {:ok, %Event{payload: infos}} <- send_appstart(mc) do
      set_other_params_from_infos(mc, Map.merge(infos, changes))
    end
  end

  @doc "Sets the base telemetry mode (0-3), keeping other parameters."
  @spec set_telemetry_mode_base(mc(), 0..3) :: result()
  def set_telemetry_mode_base(mc, mode), do: update_infos(mc, %{telemetry_mode_base: mode})

  @doc "Sets the location telemetry mode (0-3), keeping other parameters."
  @spec set_telemetry_mode_loc(mc(), 0..3) :: result()
  def set_telemetry_mode_loc(mc, mode), do: update_infos(mc, %{telemetry_mode_loc: mode})

  @doc "Sets the environment telemetry mode (0-3), keeping other parameters."
  @spec set_telemetry_mode_env(mc(), 0..3) :: result()
  def set_telemetry_mode_env(mc, mode), do: update_infos(mc, %{telemetry_mode_env: mode})

  @doc "Enables or disables manual contact adding, keeping other parameters."
  @spec set_manual_add_contacts(mc(), boolean()) :: result()
  def set_manual_add_contacts(mc, value), do: update_infos(mc, %{manual_add_contacts: value})

  @doc "Sets the advert location policy, keeping other parameters."
  @spec set_advert_loc_policy(mc(), 0..255) :: result()
  def set_advert_loc_policy(mc, policy), do: update_infos(mc, %{adv_loc_policy: policy})

  @doc "Sets the multi-ack count, keeping other parameters."
  @spec set_multi_acks(mc(), 0..255) :: result()
  def set_multi_acks(mc, n), do: update_infos(mc, %{multi_acks: n})

  @doc "Sets the BLE pairing PIN."
  @spec set_devicepin(mc(), non_neg_integer()) :: result()
  def set_devicepin(mc, pin), do: send_ok(mc, <<0x25>> <> u(pin, 4))

  @doc "Reads the device's own telemetry (`:telemetry_response`)."
  @spec get_self_telemetry(mc()) :: result()
  def get_self_telemetry(mc),
    do: send_command(mc, <<0x27, 0, 0, 0>>, [:telemetry_response, :error])

  @doc "Reads the custom variables (`:custom_vars`, a map of strings)."
  @spec get_custom_vars(mc()) :: result()
  def get_custom_vars(mc), do: send_command(mc, <<0x28>>, [:custom_vars, :error])

  @doc "Sets one custom variable."
  @spec set_custom_var(mc(), String.t(), String.t()) :: result()
  def set_custom_var(mc, key, value), do: send_ok(mc, <<0x29>> <> key <> ":" <> value)

  @doc "Reads channel `channel_idx` (`:channel_info`)."
  @spec get_channel(mc(), 0..255) :: result()
  def get_channel(mc, channel_idx),
    do: send_command(mc, <<0x1F, channel_idx>>, [:channel_info, :error])

  @doc """
  Configures channel `channel_idx`.

  When `channel_secret` is `nil` – or the name starts with `#` – the 16 byte
  secret is derived as the first half of `SHA-256(name)` (public hashtag
  channels). Raises `ArgumentError` if an explicit secret is not 16 bytes.
  """
  @spec set_channel(mc(), 0..255, String.t(), binary() | nil) :: result()
  def set_channel(mc, channel_idx, channel_name, channel_secret \\ nil) do
    name =
      channel_name
      |> binary_part(0, min(32, byte_size(channel_name)))
      |> String.pad_trailing(32, <<0>>)

    secret =
      if String.starts_with?(channel_name, "#") or is_nil(channel_secret) do
        binary_part(sha256(channel_name), 0, 16)
      else
        channel_secret
      end

    if byte_size(secret) != 16,
      do: raise(ArgumentError, "Channel secret must be exactly 16 bytes")

    send_ok(mc, <<0x20, channel_idx>> <> name <> secret)
  end

  @doc "Exports the device's private key (`:private_key`, or `:disabled`)."
  @spec export_private_key(mc()) :: result()
  def export_private_key(mc), do: send_command(mc, <<0x17>>, [:private_key, :disabled, :error])

  @doc "Imports a 64 byte private key."
  @spec import_private_key(mc(), binary()) :: result()
  def import_private_key(mc, key), do: send_ok(mc, <<0x18>> <> key)

  @doc "Starts a signing session; the reply carries `max_length`."
  @spec sign_start(mc()) :: result()
  def sign_start(mc), do: send_command(mc, <<0x21>>, [:sign_start, :error])

  @doc """
  Streams one chunk of data to sign.

  A missing acknowledgement (timeout) is tolerated – the chunk was most likely
  processed – and reported as `{:ok, ok_event}`, like the Python library.
  """
  @spec sign_data(mc(), binary()) :: result()
  def sign_data(mc, chunk) when is_binary(chunk) do
    case send_ok(mc, <<0x22>> <> chunk, timeout: 5_000) do
      {:error, %Event{payload: %{reason: reason}}}
      when reason in [:timeout, :no_event_received] ->
        Logger.warning("sign_data OK response not received (timeout), but continuing")
        {:ok, Event.new(:ok, %{})}

      other ->
        other
    end
  end

  @doc """
  Finishes the signing session and returns the `:signature`.

  Options: `:timeout` (default `max(3 × default_timeout, 15s)` plus a bonus
  growing with `:data_size`), `:data_size`.
  """
  @spec sign_finish(mc(), keyword()) :: result()
  def sign_finish(mc, opts \\ []) do
    timeout =
      opts[:timeout] ||
        trunc(
          max(Client.get(mc, :default_timeout) * 3, 15_000) +
            min(Keyword.get(opts, :data_size, 0) / 2048.0, 5.0) * 1000
        )

    send_command(mc, <<0x23>>, [:signature, :error], timeout: timeout)
  end

  @doc """
  Signs `data` with the device key: `sign_start/1`, chunked `sign_data/2`,
  `sign_finish/2`. Options: `:chunk_size` (default `120`), `:timeout`.

  Returns the `:signature` event, or an error event (`reason: :data_too_large`
  if `data` exceeds the device buffer).
  """
  @spec sign(mc(), binary(), keyword()) :: result()
  def sign(mc, data, opts \\ []) when is_binary(data) do
    chunk_size = Keyword.get(opts, :chunk_size, 120)
    if chunk_size <= 0, do: raise(ArgumentError, "chunk_size must be > 0")

    with {:ok, start} <- sign_start(mc),
         :ok <- check_size(start.payload, byte_size(data)),
         :ok <- send_chunks(mc, data, chunk_size) do
      sign_finish(mc, timeout: opts[:timeout], data_size: byte_size(data))
    end
  end

  defp check_size(%{max_length: max}, len) when max > 0 and len > max,
    do: {:error, Event.error(:data_too_large, %{max_length: max, len: len})}

  defp check_size(_payload, _len), do: :ok

  defp send_chunks(mc, data, size) do
    data
    |> chunks(size)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case sign_data(mc, chunk) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp chunks(<<>>, _), do: []
  defp chunks(bin, size) when byte_size(bin) <= size, do: [bin]

  defp chunks(bin, size) do
    <<chunk::binary-size(size), rest::binary>> = bin
    [chunk | chunks(rest, size)]
  end

  @doc "Checks whether the device has an active connection (`CMD 28`)."
  @spec has_connection(mc()) :: result()
  def has_connection(mc), do: send_ok(mc, <<0x1C>>)

  @doc "Reads RX delay and airtime factor (`:tuning_params`)."
  @spec get_tuning(mc()) :: result()
  def get_tuning(mc), do: send_command(mc, <<0x2B>>, [:tuning_params, :error])

  @doc """
  Step 1 of a factory reset: returns a confirmation token.

  The two-step flow is a client-side safety net; the firmware itself performs
  no token check. Pass the token to `confirm_factory_reset/2`.
  """
  @spec request_factory_reset(mc()) :: {:ok, String.t()}
  def request_factory_reset(mc) do
    token = 8 |> :crypto.strong_rand_bytes() |> hex()

    Logger.warning(
      "Factory reset requested. Call confirm_factory_reset('#{token}') to proceed. This will ERASE ALL DATA on the device."
    )

    Client.call(mc, {:factory_reset_token, token})
    {:ok, token}
  end

  @doc """
  Step 2 of a factory reset. Returns `{:error, :invalid_token}` if `token` does
  not match the pending one.
  """
  @spec confirm_factory_reset(mc(), String.t()) :: result() | {:error, :invalid_token}
  def confirm_factory_reset(mc, token) do
    expected = Client.call(mc, :take_factory_reset_token)

    if is_binary(expected) and expected == token do
      Logger.warning("Executing factory reset - all device data will be erased")
      send_ok(mc, <<0x33>>)
    else
      {:error, :invalid_token}
    end
  end

  @doc "Core statistics (battery, uptime, errors, queue length)."
  @spec get_stats_core(mc()) :: result()
  def get_stats_core(mc),
    do: send_command(mc, <<Packets.command(:get_stats), 0>>, [:stats_core, :error])

  @doc "Radio statistics (noise floor, RSSI, SNR, airtime)."
  @spec get_stats_radio(mc()) :: result()
  def get_stats_radio(mc),
    do: send_command(mc, <<Packets.command(:get_stats), 1>>, [:stats_radio, :error])

  @doc "Packet counters."
  @spec get_stats_packets(mc()) :: result()
  def get_stats_packets(mc),
    do: send_command(mc, <<Packets.command(:get_stats), 2>>, [:stats_packets, :error])

  @doc "Frequency ranges in which repeating is allowed."
  @spec get_allowed_repeat_freq(mc()) :: result()
  def get_allowed_repeat_freq(mc), do: send_command(mc, <<0x3C>>, [:allowed_repeat_freq, :error])

  @doc "Sets the path hash mode (0 = 1 byte hashes, 1 = 2 bytes, 2 = 3 bytes)."
  @spec set_path_hash_mode(mc(), 0..2) :: result()
  def set_path_hash_mode(mc, mode), do: send_ok(mc, <<0x3D, 0, mode>>)

  @doc """
  Reads the active path hash mode. Returns the integer directly (`0` when the
  device does not report one), like the Python method.
  """
  @spec get_path_hash_mode(mc()) :: non_neg_integer()
  def get_path_hash_mode(mc) do
    case send_device_query(mc) do
      {:ok, %Event{payload: %{path_hash_mode: mode}}} -> mode
      _ -> 0
    end
  end
end
