defmodule Meshcore.Packets do
  @moduledoc """
  Protocol constants: command codes, response/push codes and the various
  request/advert/text type enumerations of the MeshCore companion protocol.

  All lookups work with atoms named like the Python enum members, lower-cased
  (`CommandType.SEND_TXT_MSG` is `:send_txt_msg`).
  """

  @adv_types %{none: 0x00, chat: 0x01, repeater: 0x02, room: 0x03, sensor: 0x04}
  @txt_types %{plain: 0x00, cli_data: 0x01, signed_plain: 0x02, cli_cmd: 0x03}
  @anon_req_types %{regions: 0x01, owner: 0x02, basic: 0x03}
  @binary_req_types %{
    status: 0x01,
    keep_alive: 0x02,
    telemetry: 0x03,
    mma: 0x04,
    acl: 0x05,
    neighbours: 0x06
  }
  @control_types %{node_discover_req: 0x80, node_discover_resp: 0x90}

  @command_types %{
    app_start: 1,
    send_txt_msg: 2,
    send_channel_txt_msg: 3,
    get_contacts: 4,
    get_device_time: 5,
    set_device_time: 6,
    send_self_advert: 7,
    set_advert_name: 8,
    add_update_contact: 9,
    sync_next_message: 10,
    set_radio_params: 11,
    set_radio_tx_power: 12,
    reset_path: 13,
    set_advert_latlon: 14,
    remove_contact: 15,
    share_contact: 16,
    export_contact: 17,
    import_contact: 18,
    reboot: 19,
    get_batt_and_storage: 20,
    set_tuning_params: 21,
    device_qeury: 22,
    export_private_key: 23,
    import_private_key: 24,
    send_raw_data: 25,
    send_login: 26,
    send_status_req: 27,
    has_connection: 28,
    logout: 29,
    get_contact_by_key: 30,
    get_channel: 31,
    set_channel: 32,
    sign_start: 33,
    sign_data: 34,
    sign_finish: 35,
    send_trace_path: 36,
    set_device_pin: 37,
    set_other_params: 38,
    send_telemetry_req: 39,
    get_custom_vars: 40,
    set_custom_var: 41,
    get_advert_path: 42,
    get_tuning_params: 43,
    binary_req: 50,
    factory_reset: 51,
    path_discovery: 52,
    set_flood_scope: 54,
    send_control_data: 55,
    get_stats: 56,
    send_anon_req: 57,
    set_autoadd_config: 58,
    get_autoadd_config: 59,
    get_allowed_repeat_freq: 60,
    set_path_hash_mode: 61,
    send_channel_data: 62,
    set_default_flood_scope: 63,
    get_default_flood_scope: 64,
    send_raw_packet: 65,
    run_cli_command: 66
  }

  @packet_types %{
    ok: 0,
    error: 1,
    contact_start: 2,
    contact: 3,
    contact_end: 4,
    self_info: 5,
    msg_sent: 6,
    contact_msg_recv: 7,
    channel_msg_recv: 8,
    current_time: 9,
    no_more_msgs: 10,
    contact_uri: 11,
    battery: 12,
    device_info: 13,
    private_key: 14,
    disabled: 15,
    contact_msg_recv_v3: 16,
    channel_msg_recv_v3: 17,
    channel_info: 18,
    sign_start: 19,
    signature: 20,
    custom_vars: 21,
    advert_path: 22,
    tuning_params: 23,
    stats: 24,
    autoadd_config: 25,
    allowed_repeat_freq: 26,
    channel_data_recv: 27,
    default_flood_scope: 28,
    cli_reply: 29,
    advertisement: 0x80,
    path_update: 0x81,
    ack: 0x82,
    messages_waiting: 0x83,
    raw_data: 0x84,
    login_success: 0x85,
    login_failed: 0x86,
    status_response: 0x87,
    log_data: 0x88,
    trace_data: 0x89,
    push_code_new_advert: 0x8A,
    telemetry_response: 0x8B,
    binary_response: 0x8C,
    path_discovery_response: 0x8D,
    control_data: 0x8E,
    contact_deleted: 0x8F,
    contacts_full: 0x90
  }

  @doc "Advert/contact type code (`:none | :chat | :repeater | :room | :sensor`)."
  @spec adv_type(atom()) :: non_neg_integer()
  def adv_type(name), do: Map.fetch!(@adv_types, name)

  @doc "Text message type code (`:plain | :cli_data | :signed_plain | :cli_cmd`)."
  @spec txt_type(atom()) :: non_neg_integer()
  def txt_type(name), do: Map.fetch!(@txt_types, name)

  @doc "Anonymous request type code (`:regions | :owner | :basic`)."
  @spec anon_req_type(atom()) :: non_neg_integer()
  def anon_req_type(name), do: Map.fetch!(@anon_req_types, name)

  @doc "Binary request type code."
  @spec binary_req_type(atom()) :: non_neg_integer()
  def binary_req_type(name), do: Map.fetch!(@binary_req_types, name)

  @doc "Control data type code."
  @spec control_type(atom()) :: non_neg_integer()
  def control_type(name), do: Map.fetch!(@control_types, name)

  @doc "Command code sent to the device."
  @spec command(atom()) :: non_neg_integer()
  def command(name), do: Map.fetch!(@command_types, name)

  @doc "Response / push packet code."
  @spec packet_type(atom()) :: non_neg_integer()
  def packet_type(name), do: Map.fetch!(@packet_types, name)

  @doc "Reverse lookup of a response / push code, `nil` if unknown."
  @spec packet_type_name(non_neg_integer()) :: atom() | nil
  def packet_type_name(code) do
    Enum.find_value(@packet_types, fn {name, c} -> if c == code, do: name end)
  end

  @doc "Reverse lookup of an advert type code, `nil` if unknown."
  @spec adv_type_name(non_neg_integer()) :: atom() | nil
  def adv_type_name(code), do: Enum.find_value(@adv_types, fn {n, c} -> if c == code, do: n end)
end
