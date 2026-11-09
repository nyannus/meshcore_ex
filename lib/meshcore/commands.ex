defmodule Meshcore.Commands do
  @moduledoc """
  Every device command in one namespace – the equivalent of Python's
  `meshcore.commands`.

  The functions are thin delegates; the implementation and detailed
  documentation live in the topical modules:

    * `Meshcore.Commands.Device` – device configuration, stats, channels, signing
    * `Meshcore.Commands.Contact` – contact list management
    * `Meshcore.Commands.Messaging` – messages, logins, traces, flood scopes
    * `Meshcore.Commands.Binary` – status/telemetry/ACL/neighbour requests
    * `Meshcore.Commands.ControlData` – node discovery

  All commands take the connection as first argument and return
  `{:ok, %Meshcore.Event{}}` or `{:error, %Meshcore.Event{}}` (see
  `Meshcore.Commands.Base`). Timeouts are in milliseconds.

      {:ok, event} = Meshcore.Commands.send_device_query(mc)
      event.payload.model
  """

  # --- Device commands ---
  @doc "See `Meshcore.Commands.Device.confirm_factory_reset/2`."
  defdelegate confirm_factory_reset(mc, token), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.export_private_key/1`."
  defdelegate export_private_key(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.get_allowed_repeat_freq/1`."
  defdelegate get_allowed_repeat_freq(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.get_bat/1`."
  defdelegate get_bat(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.get_channel/2`."
  defdelegate get_channel(mc, channel_idx), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.get_custom_vars/1`."
  defdelegate get_custom_vars(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.get_path_hash_mode/1`."
  defdelegate get_path_hash_mode(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.get_self_telemetry/1`."
  defdelegate get_self_telemetry(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.get_stats_core/1`."
  defdelegate get_stats_core(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.get_stats_packets/1`."
  defdelegate get_stats_packets(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.get_stats_radio/1`."
  defdelegate get_stats_radio(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.get_time/1`."
  defdelegate get_time(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.get_tuning/1`."
  defdelegate get_tuning(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.has_connection/1`."
  defdelegate has_connection(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.import_private_key/2`."
  defdelegate import_private_key(mc, key), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.reboot/1`."
  defdelegate reboot(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.request_factory_reset/1`."
  defdelegate request_factory_reset(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.run_cli_command/2`."
  defdelegate run_cli_command(mc, cmd), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.send_advert/2`."
  defdelegate send_advert(mc, flood \\ false), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.send_appstart/2`."
  defdelegate send_appstart(mc, opts \\ []), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.send_device_query/1`."
  defdelegate send_device_query(mc), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.send_raw_packet/3`."
  defdelegate send_raw_packet(mc, data, priority \\ 0), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_advert_loc_policy/2`."
  defdelegate set_advert_loc_policy(mc, policy), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_channel/4`."
  defdelegate set_channel(mc, channel_idx, channel_name, channel_secret \\ nil),
    to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_coords/3`."
  defdelegate set_coords(mc, lat, lon), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_custom_var/3`."
  defdelegate set_custom_var(mc, key, value), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_devicepin/2`."
  defdelegate set_devicepin(mc, pin), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_manual_add_contacts/2`."
  defdelegate set_manual_add_contacts(mc, value), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_multi_acks/2`."
  defdelegate set_multi_acks(mc, n), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_name/2`."
  defdelegate set_name(mc, name), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_other_params/6`."
  defdelegate set_other_params(
                mc,
                manual_add_contacts,
                telemetry_base,
                telemetry_loc,
                telemetry_env,
                advert_loc_policy
              ),
              to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_other_params_from_infos/2`."
  defdelegate set_other_params_from_infos(mc, infos), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_path_hash_mode/2`."
  defdelegate set_path_hash_mode(mc, mode), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_radio/6`."
  defdelegate set_radio(mc, freq, bw, sf, cr, repeat \\ nil), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_telemetry_mode_base/2`."
  defdelegate set_telemetry_mode_base(mc, mode), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_telemetry_mode_env/2`."
  defdelegate set_telemetry_mode_env(mc, mode), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_telemetry_mode_loc/2`."
  defdelegate set_telemetry_mode_loc(mc, mode), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_time/2`."
  defdelegate set_time(mc, val), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_tuning/3`."
  defdelegate set_tuning(mc, rx_dly, af), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.set_tx_power/2`."
  defdelegate set_tx_power(mc, val), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.sign/3`."
  defdelegate sign(mc, data, opts \\ []), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.sign_data/2`."
  defdelegate sign_data(mc, chunk), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.sign_finish/2`."
  defdelegate sign_finish(mc, opts \\ []), to: Meshcore.Commands.Device

  @doc "See `Meshcore.Commands.Device.sign_start/1`."
  defdelegate sign_start(mc), to: Meshcore.Commands.Device

  # --- Contact commands ---
  @doc "See `Meshcore.Commands.Contact.add_contact/2`."
  defdelegate add_contact(mc, contact), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.change_contact_flags/3`."
  defdelegate change_contact_flags(mc, contact, flags), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.change_contact_path/4`."
  defdelegate change_contact_path(mc, contact, path, opts \\ []), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.export_contact/2`."
  defdelegate export_contact(mc, key \\ nil), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.get_advert_path/2`."
  defdelegate get_advert_path(mc, key), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.get_autoadd_config/1`."
  defdelegate get_autoadd_config(mc), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.get_contact_by_key/2`."
  defdelegate get_contact_by_key(mc, pubkey), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.get_contacts/2`."
  defdelegate get_contacts(mc, opts \\ []), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.get_contacts_async/2`."
  defdelegate get_contacts_async(mc, lastmod \\ 0), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.import_contact/2`."
  defdelegate import_contact(mc, card_data), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.remove_contact/2`."
  defdelegate remove_contact(mc, key), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.reset_path/2`."
  defdelegate reset_path(mc, key), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.set_autoadd_config/2`."
  defdelegate set_autoadd_config(mc, flag), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.share_contact/2`."
  defdelegate share_contact(mc, key), to: Meshcore.Commands.Contact

  @doc "See `Meshcore.Commands.Contact.update_contact/3`."
  defdelegate update_contact(mc, contact, opts \\ []), to: Meshcore.Commands.Contact

  # --- Messaging commands ---
  @doc "See `Meshcore.Commands.Messaging.force_unscoped/1`."
  defdelegate force_unscoped(mc), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.get_default_flood_scope/1`."
  defdelegate get_default_flood_scope(mc), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.get_msg/2`."
  defdelegate get_msg(mc, opts \\ []), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.reset_default_flood_scope/1`."
  defdelegate reset_default_flood_scope(mc), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.reset_flood_scope/1`."
  defdelegate reset_flood_scope(mc), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_chan_msg/4`."
  defdelegate send_chan_msg(mc, chan, msg, opts \\ []), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_channel_data/5`."
  defdelegate send_channel_data(mc, chan, data_type, payload, opts \\ []),
    to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_cmd/4`."
  defdelegate send_cmd(mc, dst, cmd, opts \\ []), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_login/3`."
  defdelegate send_login(mc, dst, pwd), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_login_sync/4`."
  defdelegate send_login_sync(mc, dst, pwd, opts \\ []), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_logout/2`."
  defdelegate send_logout(mc, dst), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_msg/4`."
  defdelegate send_msg(mc, dst, msg, opts \\ []), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_msg_with_retry/4`."
  defdelegate send_msg_with_retry(mc, dst, msg, opts \\ []), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_path_discovery/2`."
  defdelegate send_path_discovery(mc, dst), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_path_discovery_sync/3`."
  defdelegate send_path_discovery_sync(mc, dst, opts \\ []), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_raw_data/3`."
  defdelegate send_raw_data(mc, payload, path \\ <<>>), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_statusreq/2`."
  defdelegate send_statusreq(mc, dst), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_telemetry_req/2`."
  defdelegate send_telemetry_req(mc, dst), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.send_trace/2`."
  defdelegate send_trace(mc, opts \\ []), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.set_default_flood_scope/2`."
  defdelegate set_default_flood_scope(mc, scope), to: Meshcore.Commands.Messaging

  @doc "See `Meshcore.Commands.Messaging.set_flood_scope/3`."
  defdelegate set_flood_scope(mc, scope, opts \\ []), to: Meshcore.Commands.Messaging

  # --- Binary commands ---
  @doc "See `Meshcore.Commands.Binary.fetch_all_neighbours/3`."
  defdelegate fetch_all_neighbours(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_acl/3`."
  defdelegate req_acl(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_acl_sync/3`."
  defdelegate req_acl_sync(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_basic_async/3`."
  defdelegate req_basic_async(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_basic_sync/3`."
  defdelegate req_basic_sync(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_mma_sync/5`."
  defdelegate req_mma_sync(mc, contact, start_time, end_time, opts \\ []),
    to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_neighbours_async/3`."
  defdelegate req_neighbours_async(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_neighbours_sync/3`."
  defdelegate req_neighbours_sync(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_owner_async/3`."
  defdelegate req_owner_async(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_owner_sync/3`."
  defdelegate req_owner_sync(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_regions_async/3`."
  defdelegate req_regions_async(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_regions_sync/3`."
  defdelegate req_regions_sync(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_status/3`."
  defdelegate req_status(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_status_sync/3`."
  defdelegate req_status_sync(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_telemetry/3`."
  defdelegate req_telemetry(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  @doc "See `Meshcore.Commands.Binary.req_telemetry_sync/3`."
  defdelegate req_telemetry_sync(mc, contact, opts \\ []), to: Meshcore.Commands.Binary

  # --- ControlData commands ---
  @doc "See `Meshcore.Commands.ControlData.send_control_data/3`."
  defdelegate send_control_data(mc, control_type, payload), to: Meshcore.Commands.ControlData

  @doc "See `Meshcore.Commands.ControlData.send_node_discover_req/3`."
  defdelegate send_node_discover_req(mc, filter, opts \\ []), to: Meshcore.Commands.ControlData
end
