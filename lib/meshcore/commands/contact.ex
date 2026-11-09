defmodule Meshcore.Commands.Contact do
  @moduledoc """
  Commands for managing the device's contact list.

  A *contact* is a map with the keys the device reports in `:contacts` and
  `:next_contact` events: `:public_key` (hex), `:type`, `:flags`,
  `:out_path_len`, `:out_path_hash_mode`, `:out_path` (hex), `:adv_name`,
  `:last_advert`, `:adv_lat`, `:adv_lon`, `:lastmod`.
  """

  require Logger
  import Meshcore.Util
  import Meshcore.Commands.Base

  alias Meshcore.Commands.Device
  alias Meshcore.Event

  @type mc :: GenServer.server()
  @type result :: {:ok, Event.t()} | {:error, Event.t()}
  @type contact :: map()

  @doc """
  Asks for the contact list without waiting (the `:contacts` event follows).
  """
  @spec get_contacts_async(mc(), non_neg_integer()) :: result()
  def get_contacts_async(mc, lastmod \\ 0), do: send_command(mc, contacts_request(lastmod))

  defp contacts_request(lastmod) when lastmod > 0, do: <<0x04>> <> u(lastmod, 4)
  defp contacts_request(_), do: <<0x04>>

  @doc """
  Fetches the contact list and waits for the `:contacts` event, whose payload
  is a map `public_key_hex => contact`.

  The timeout restarts every time another contact arrives, so large lists don't
  time out. Options: `:lastmod` (only contacts changed since, default `0`),
  `:timeout` (ms of silence tolerated, default `5_000`).
  """
  @spec get_contacts(mc(), keyword()) :: result()
  def get_contacts(mc, opts \\ []) do
    lastmod = Keyword.get(opts, :lastmod, 0)

    send_command(mc, contacts_request(lastmod), [:contacts, :error],
      timeout: Keyword.get(opts, :timeout, 5_000),
      touch_on: [:next_contact]
    )
  end

  @doc "Resets the stored path of a contact (it will be reached by flooding)."
  @spec reset_path(mc(), Meshcore.Util.destination()) :: result()
  def reset_path(mc, key) do
    key_bytes = to_key(key, 32)
    update_local_contact(mc, hex(key_bytes), %{out_path_len: -1, out_path: ""})
    send_ok(mc, <<0x0D>> <> key_bytes)
  end

  @doc "Shares a contact with the mesh."
  @spec share_contact(mc(), Meshcore.Util.destination()) :: result()
  def share_contact(mc, key), do: send_ok(mc, <<0x10>> <> to_key(key, 32))

  @doc """
  Exports a contact (or, with `nil`, this node) as a `meshcore://` URI
  (`:contact_uri`).
  """
  @spec export_contact(mc(), Meshcore.Util.destination() | nil) :: result()
  def export_contact(mc, key \\ nil)
  def export_contact(mc, nil), do: send_command(mc, <<0x11>>, [:contact_uri, :error])

  def export_contact(mc, key),
    do: send_command(mc, <<0x11>> <> to_key(key, 32), [:contact_uri, :error])

  @doc "Imports a contact card (raw bytes, as found after `meshcore://`)."
  @spec import_contact(mc(), binary()) :: result()
  def import_contact(mc, card_data), do: send_ok(mc, <<0x12>> <> card_data)

  @doc "Removes a contact."
  @spec remove_contact(mc(), Meshcore.Util.destination()) :: result()
  def remove_contact(mc, key), do: send_ok(mc, <<0x0F>> <> to_key(key, 32))

  @doc """
  Writes a contact to the device (add or update).

  Options:

    * `:path` – new out path as a hex string, optionally suffixed with `":" <> mode`
      (`"aabbcc:1"`); `""` makes it a zero-hop path
    * `:path_hash_mode` – hash mode for `:path`; when neither it nor a suffix is
      given the device's current mode is queried
    * `:flags` – new contact flags

  The stored copy of the contact in the client is updated on success.
  """
  @spec update_contact(mc(), contact(), keyword()) :: result()
  def update_contact(mc, contact, opts \\ []) do
    path = opts[:path]

    {out_path_hex, out_path_len, out_path_hash_mode} =
      if is_nil(path) do
        {contact.out_path, contact.out_path_len, Map.get(contact, :out_path_hash_mode, 0)}
      else
        {path_hex, mode} = split_path(mc, path, opts[:path_hash_mode])
        Logger.debug("Setting #{contact.adv_name} path to #{path_hex} with mode #{mode}")
        {path_hex, div(byte_size(path_hex), 2 * (mode + 1)), mode}
      end

    flags = opts[:flags] || contact.flags

    encoded_len =
      if out_path_len == -1,
        do: 255,
        else: Bitwise.bor(out_path_len, Bitwise.bsl(out_path_hash_mode, 6))

    path_bytes = pad_to(Base.decode16!(out_path_hex, case: :mixed), 64)
    name = contact.adv_name |> binary_part(0, min(32, byte_size(contact.adv_name))) |> pad_to(32)

    data =
      <<0x09>> <>
        Base.decode16!(contact.public_key, case: :mixed) <>
        <<contact.type, flags, encoded_len>> <>
        path_bytes <>
        name <>
        u(contact.last_advert, 4) <>
        s(trunc(contact.adv_lat * 1.0e6), 4) <> s(trunc(contact.adv_lon * 1.0e6), 4)

    with {:ok, _} = ok <- send_ok(mc, data) do
      changes = %{flags: flags}

      changes =
        if path,
          do:
            Map.merge(changes, %{
              out_path: out_path_hex,
              out_path_len: out_path_len,
              out_path_hash_mode: out_path_hash_mode
            }),
          else: changes

      update_local_contact(mc, contact.public_key, changes)
      ok
    end
  end

  defp split_path(mc, path, mode_opt) do
    case {String.split(path, ":", parts: 2), mode_opt} do
      {[hex, mode], nil} ->
        {hex, String.to_integer(mode)}

      {[hex | _], nil} ->
        {hex, Device.get_path_hash_mode(mc)}

      {[hex | _], mode} ->
        {hex, mode}
    end
  end

  defp pad_to(bin, size) when byte_size(bin) >= size, do: binary_part(bin, 0, size)
  defp pad_to(bin, size), do: bin <> :binary.copy(<<0>>, size - byte_size(bin))

  @doc "Alias for `update_contact/3` with no changes: adds `contact` to the device."
  @spec add_contact(mc(), contact()) :: result()
  def add_contact(mc, contact), do: update_contact(mc, contact)

  @doc "Changes a contact's out path. See `update_contact/3` for the path format."
  @spec change_contact_path(mc(), contact(), String.t(), keyword()) :: result()
  def change_contact_path(mc, contact, path, opts \\ []),
    do: update_contact(mc, contact, Keyword.put(opts, :path, path))

  @doc "Changes a contact's flags."
  @spec change_contact_flags(mc(), contact(), non_neg_integer()) :: result()
  def change_contact_flags(mc, contact, flags), do: update_contact(mc, contact, flags: flags)

  @doc "Sets the auto-add configuration bit field."
  @spec set_autoadd_config(mc(), 0..255) :: result()
  def set_autoadd_config(mc, flag), do: send_ok(mc, <<0x3A, flag>>)

  @doc "Reads the auto-add configuration (`:autoadd_config`)."
  @spec get_autoadd_config(mc()) :: result()
  def get_autoadd_config(mc), do: send_command(mc, <<0x3B>>, [:autoadd_config, :error])

  @doc """
  Fetches a single contact by its 32 byte public key (`:next_contact`), or an
  error if it is unknown.
  """
  @spec get_contact_by_key(mc(), binary()) :: result()
  def get_contact_by_key(mc, pubkey) when is_binary(pubkey) do
    key = binary_part(pubkey, 0, min(32, byte_size(pubkey)))
    send_command(mc, <<0x1E>> <> key, [:next_contact, :error])
  end

  @doc "Reads the last known advert path of a contact (`:advert_path`)."
  @spec get_advert_path(mc(), Meshcore.Util.destination()) :: result()
  def get_advert_path(mc, key),
    do: send_command(mc, <<0x2A, 0>> <> to_key(key, 32), [:advert_path, :error])
end
