defmodule Meshcore.Event do
  @moduledoc """
  An event emitted by a MeshCore device or by the library itself.

  Every command returns its result wrapped in an event, mirroring Python's
  `Event(type, payload, attributes)`:

      {:ok, %Meshcore.Event{type: :msg_sent, payload: payload}} =
        Meshcore.Commands.send_msg(mc, contact, "hello")

  * `:type` – one of `t:type/0` (the Python `EventType` enum, lower-cased).
  * `:payload` – the decoded data. Maps use **atom keys**; keys are the Python
    keys lower-cased (`"SNR"` becomes `:snr`, `"fw ver"` becomes `:fw_ver`).
  * `:attributes` – the subset of values you can filter subscriptions on
    (see `Meshcore.subscribe/3`).

  ## Event types

  Command responses: `:contacts`, `:self_info`, `:contact_msg_recv`,
  `:channel_msg_recv`, `:channel_data_recv`, `:current_time`, `:no_more_msgs`,
  `:contact_uri`, `:battery`, `:device_info`, `:msg_sent`, `:new_contact`,
  `:next_contact`, `:autoadd_config`, `:advert_path`, `:cli_reply`, `:ok`,
  `:error`.

  Push notifications: `:advertisement`, `:path_update`, `:ack`,
  `:messages_waiting`, `:raw_data`, `:login_success`, `:login_failed`,
  `:status_response`, `:log_data`, `:trace_data`, `:rx_log_data`,
  `:telemetry_response`, `:binary_response`, `:mma_response`, `:acl_response`,
  `:custom_vars`, `:stats_core`, `:stats_radio`, `:stats_packets`,
  `:channel_info`, `:path_response`, `:private_key`, `:disabled`,
  `:contact_deleted`, `:contacts_full`, `:tuning_params`, `:control_data`,
  `:discover_response`, `:neighbours_response`, `:sign_start`, `:signature`,
  `:allowed_repeat_freq`, `:default_flood_scope`.

  Connection events: `:connected`, `:disconnected`.
  """

  @types ~w(contacts self_info contact_msg_recv channel_msg_recv channel_data_recv
    current_time no_more_msgs contact_uri battery device_info msg_sent new_contact
    next_contact autoadd_config advert_path cli_reply
    advertisement path_update ack messages_waiting raw_data login_success login_failed
    status_response log_data trace_data rx_log_data telemetry_response binary_response
    mma_response acl_response custom_vars stats_core stats_radio stats_packets
    channel_info path_response private_key disabled contact_deleted contacts_full
    tuning_params control_data discover_response neighbours_response sign_start
    signature allowed_repeat_freq default_flood_scope
    ok error connected disconnected)a

  @type type ::
          :contacts
          | :self_info
          | :contact_msg_recv
          | :channel_msg_recv
          | :channel_data_recv
          | :current_time
          | :no_more_msgs
          | :contact_uri
          | :battery
          | :device_info
          | :msg_sent
          | :new_contact
          | :next_contact
          | :autoadd_config
          | :advert_path
          | :cli_reply
          | :advertisement
          | :path_update
          | :ack
          | :messages_waiting
          | :raw_data
          | :login_success
          | :login_failed
          | :status_response
          | :log_data
          | :trace_data
          | :rx_log_data
          | :telemetry_response
          | :binary_response
          | :mma_response
          | :acl_response
          | :custom_vars
          | :stats_core
          | :stats_radio
          | :stats_packets
          | :channel_info
          | :path_response
          | :private_key
          | :disabled
          | :contact_deleted
          | :contacts_full
          | :tuning_params
          | :control_data
          | :discover_response
          | :neighbours_response
          | :sign_start
          | :signature
          | :allowed_repeat_freq
          | :default_flood_scope
          | :ok
          | :error
          | :connected
          | :disconnected

  @type t :: %__MODULE__{type: type(), payload: any(), attributes: map()}

  @enforce_keys [:type]
  defstruct type: nil, payload: nil, attributes: %{}

  @error_messages %{
    1 => "ERR_CODE_UNSUPPORTED_CMD",
    2 => "ERR_CODE_NOT_FOUND",
    3 => "ERR_CODE_TABLE_FULL",
    4 => "ERR_CODE_BAD_STATE",
    5 => "ERR_CODE_FILE_IO_ERROR",
    6 => "ERR_CODE_ILLEGAL_ARG"
  }

  @doc "All known event types."
  @spec types() :: [type()]
  def types, do: @types

  @doc "Maps a device error code to its firmware constant name."
  @spec error_message(integer()) :: String.t() | nil
  def error_message(code), do: Map.get(@error_messages, code)

  @doc """
  Builds an event.

      iex> Meshcore.Event.new(:ok, %{})
      %Meshcore.Event{type: :ok, payload: %{}, attributes: %{}}
  """
  @spec new(type(), any(), map()) :: t()
  def new(type, payload, attributes \\ %{}) when type in @types and is_map(attributes) do
    %__MODULE__{type: type, payload: payload, attributes: attributes}
  end

  @doc """
  Builds an `:error` event with the given `reason` (stored as `payload.reason`).

      iex> Meshcore.Event.error(:timeout).payload
      %{reason: :timeout}
  """
  @spec error(any(), map()) :: t()
  def error(reason, extra \\ %{}) do
    new(:error, Map.put(extra, :reason, reason))
  end

  @doc """
  Returns `true` for `:error` events.

  An error payload is `%{reason: ...}` (or `%{error_code: ...}` when the
  device rejected a command) – not the keys a successful response carries.
  """
  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{type: :error}), do: true
  def error?(%__MODULE__{}), do: false

  @doc """
  Wraps an event as the conventional command result: `{:ok, event}` or
  `{:error, event}` for `:error` events.
  """
  @spec to_result(t()) :: {:ok, t()} | {:error, t()}
  def to_result(%__MODULE__{type: :error} = event), do: {:error, event}
  def to_result(%__MODULE__{} = event), do: {:ok, event}

  @doc """
  Returns `true` if all `filters` equal the corresponding event attributes.
  """
  @spec match_filters?(t(), map()) :: boolean()
  def match_filters?(%__MODULE__{}, filters) when map_size(filters) == 0, do: true

  def match_filters?(%__MODULE__{attributes: attrs}, filters) do
    Enum.all?(filters, fn {k, v} -> Map.get(attrs, k) == v end)
  end
end
