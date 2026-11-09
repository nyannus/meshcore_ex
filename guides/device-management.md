# Device management

## Identity and radio

```elixir
Meshcore.Commands.set_name(mc, "My Node")
Meshcore.Commands.set_coords(mc, 48.137, 11.575)
Meshcore.Commands.set_tx_power(mc, 20)
Meshcore.Commands.set_radio(mc, 869.525, 250.0, 11, 5)          # MHz, kHz, SF, CR
Meshcore.Commands.set_radio(mc, 869.525, 250.0, 11, 5, true)    # + repeat (client repeat mode)
Meshcore.Commands.set_tuning(mc, 0, 100)                        # rx delay, airtime factor
{:ok, %{payload: p}} = Meshcore.Commands.get_tuning(mc)
Meshcore.Commands.send_advert(mc)         # zero-hop
Meshcore.Commands.send_advert(mc, true)   # flooded
Meshcore.Commands.set_time(mc, System.os_time(:second))
```

`send_device_query/1` returns the model and firmware:

```elixir
{:ok, %{payload: info}} = Meshcore.Commands.send_device_query(mc)
info.model; info.ver; info.fw_build; info.max_contacts; info.max_channels
```

Parameters that firmware calls "other params" are changed with read-modify-write helpers, so
you can set one without touching the rest:

```elixir
Meshcore.Commands.set_manual_add_contacts(mc, true)
Meshcore.Commands.set_telemetry_mode_base(mc, 2)
Meshcore.Commands.set_telemetry_mode_loc(mc, 1)
Meshcore.Commands.set_telemetry_mode_env(mc, 1)
Meshcore.Commands.set_advert_loc_policy(mc, 1)
Meshcore.Commands.set_multi_acks(mc, 1)
Meshcore.Commands.set_devicepin(mc, 123_456)
Meshcore.Commands.set_path_hash_mode(mc, 1)
Meshcore.Commands.set_autoadd_config(mc, 0b11)
```

## Statistics (`ble_stats`)

```elixir
{:ok, %{payload: core}} = Meshcore.Commands.get_stats_core(mc)
#=> %{battery_mv: 4100, uptime_secs: 86_400, errors: 0, queue_len: 0}

{:ok, %{payload: radio}} = Meshcore.Commands.get_stats_radio(mc)
#=> %{noise_floor: -110, last_rssi: -92, last_snr: 6.5, tx_air_secs: 120, rx_air_secs: 4300}

{:ok, %{payload: packets}} = Meshcore.Commands.get_stats_packets(mc)
#=> %{recv: …, sent: …, flood_tx: …, direct_tx: …, flood_rx: …, direct_rx: …, recv_errors: …}

{:ok, %{payload: %{level: mv}}} = Meshcore.Commands.get_bat(mc)
```

A condensed `ble_stats.py`:

```elixir
for {title, fun} <- [core: &Meshcore.Commands.get_stats_core/1,
                     radio: &Meshcore.Commands.get_stats_radio/1,
                     packets: &Meshcore.Commands.get_stats_packets/1] do
  case fun.(mc) do
    {:ok, %{payload: p}} -> IO.puts("#{title}: #{inspect(p)}")
    {:error, e} -> IO.puts("#{title} failed: #{inspect(e.payload)}")
  end
end
```

## Custom variables (`ble_t1000_*`)

```elixir
{:ok, %{payload: vars}} = Meshcore.Commands.get_custom_vars(mc)   # %{"gps" => "1", …}
{:ok, _} = Meshcore.Commands.set_custom_var(mc, "gps", "1")
```

## CLI

```elixir
{:ok, %{payload: %{text: text}}} = Meshcore.Commands.run_cli_command(mc, "ver")
```

## GPS position as map preference (`mepo_mc_gps`)

```elixir
{:ok, mc} = Meshcore.create_ble(adapter: MyApp.BleAdapter, address: "t1000")
%{adv_lat: lat, adv_lon: lon} = Meshcore.self_info(mc)

IO.puts(~s([{"cmd":"prefset_n","args":{"pref":"lat","value":#{lat}}},) <>
          ~s({"cmd":"prefset_n","args":{"pref":"lon","value":#{lon}}}]))
```

## Reboot and factory reset

```elixir
Meshcore.Commands.reboot(mc)

# Factory reset needs a token from a first call:
{:ok, token} = Meshcore.Commands.request_factory_reset(mc)
{:ok, _} = Meshcore.Commands.confirm_factory_reset(mc, token)   # ERASES EVERYTHING
```

## Low level

```elixir
Meshcore.Commands.send_raw_packet(mc, packet_bytes)                # or {:hex, "…"}
Meshcore.Commands.send_raw_data(mc, <<1, 2, 3, 4, 5>>)             # ≥ 4 bytes
Meshcore.Commands.get_allowed_repeat_freq(mc)
Meshcore.Commands.has_connection(mc)
```
