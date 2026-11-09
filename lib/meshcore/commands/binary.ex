defmodule Meshcore.Commands.Binary do
  @moduledoc """
  Binary and anonymous requests to remote nodes: status, telemetry,
  min/max/avg telemetry, ACL, neighbours, regions, owner info and basic info.

  Every `*_sync` function sends the request, waits for the matching response
  and returns `{:ok, data}` or `{:error, event}`; they are serialised through
  the per-connection mesh request lock (only one request is in flight at a
  time, as the radio can only handle one anyway).

  The `*_async` variants return as soon as the request is queued (`:msg_sent`);
  the response then arrives as an event you can `Meshcore.subscribe/3` to or
  `Meshcore.wait_for_event/3` for, filtered by `tag:` (see the
  `expected_ack` in the returned payload).

  Common options for all of them: `:timeout` and `:min_timeout` in
  milliseconds (by default derived from the device's suggestion).
  """

  require Logger
  import Meshcore.Util
  import Meshcore.Commands.Base

  alias Meshcore.{Client, Event}
  alias Meshcore.Commands.Messaging

  @type mc :: GenServer.server()
  @type result :: {:ok, Event.t()} | {:error, Event.t()}

  defp then_tag(types, opts), do: Messaging.then_spec(types, opts, %{tag_filter: true})

  defp payload_result({:ok, %Event{payload: payload}}, key), do: {:ok, Map.fetch!(payload, key)}
  defp payload_result({:error, _} = error, _key), do: error

  @doc "Deprecated alias of `req_status_sync/3`."
  @spec req_status(mc(), Meshcore.Util.destination(), keyword()) ::
          {:ok, map()} | {:error, Event.t()}
  def req_status(mc, contact, opts \\ []) do
    Logger.error("*** please consider using req_status_sync instead of req_status")
    req_status_sync(mc, contact, opts)
  end

  @doc """
  Requests the status of a repeater/room (battery, noise floor, airtime, packet
  counters…). Returns the parsed `:status_response` payload.
  """
  @spec req_status_sync(mc(), Meshcore.Util.destination(), keyword()) ::
          {:ok, map()} | {:error, Event.t()}
  def req_status_sync(mc, contact, opts \\ []) do
    Client.with_lock(mc, fn ->
      mc
      |> send_binary_req(
        contact,
        :status,
        nil,
        Keyword.put(opts, :then, then_tag([:status_response], opts))
      )
      |> unwrap_payload()
    end)
  end

  @doc "Deprecated alias of `req_telemetry_sync/3`."
  @spec req_telemetry(mc(), Meshcore.Util.destination(), keyword()) ::
          {:ok, list()} | {:error, Event.t()}
  def req_telemetry(mc, contact, opts \\ []) do
    Logger.error("*** please consider using req_telemetry_sync instead of req_telemetry")
    req_telemetry_sync(mc, contact, opts)
  end

  @doc """
  Requests the sensor telemetry of a node. Returns the decoded LPP readings,
  e.g. `[%{channel: 1, type: "temperature", value: 21.5}]`.
  """
  @spec req_telemetry_sync(mc(), Meshcore.Util.destination(), keyword()) ::
          {:ok, list()} | {:error, Event.t()}
  def req_telemetry_sync(mc, contact, opts \\ []) do
    Client.with_lock(mc, fn ->
      mc
      |> send_binary_req(
        contact,
        :telemetry,
        nil,
        Keyword.put(opts, :then, then_tag([:telemetry_response], opts))
      )
      |> payload_result(:lpp)
    end)
  end

  @doc """
  Requests min/max/average telemetry between Unix times `start_time` and
  `end_time`. Returns a list of `%{channel:, type:, min:, max:, avg:}`.
  """
  @spec req_mma_sync(
          mc(),
          Meshcore.Util.destination(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) ::
          {:ok, list()} | {:error, Event.t()}
  def req_mma_sync(mc, contact, start_time, end_time, opts \\ []) do
    Client.with_lock(mc, fn ->
      req = u(start_time, 4) <> u(end_time, 4) <> <<0, 0>>

      mc
      |> send_binary_req(
        contact,
        :mma,
        req,
        Keyword.put(opts, :then, then_tag([:mma_response], opts))
      )
      |> payload_result(:mma_data)
    end)
  end

  @doc "Deprecated alias of `req_acl_sync/3`."
  @spec req_acl(mc(), Meshcore.Util.destination(), keyword()) ::
          {:ok, list()} | {:error, Event.t()}
  def req_acl(mc, contact, opts \\ []) do
    Logger.error("*** please consider using req_acl_sync instead of req_acl")
    req_acl_sync(mc, contact, opts)
  end

  @doc "Requests the access control list. Returns a list of `%{key: hex_prefix, perm: integer}`."
  @spec req_acl_sync(mc(), Meshcore.Util.destination(), keyword()) ::
          {:ok, list()} | {:error, Event.t()}
  def req_acl_sync(mc, contact, opts \\ []) do
    Client.with_lock(mc, fn ->
      mc
      |> send_binary_req(
        contact,
        :acl,
        <<0, 0>>,
        Keyword.put(opts, :then, then_tag([:acl_response], opts))
      )
      |> payload_result(:acl_data)
    end)
  end

  @doc """
  Requests a node's neighbour table and returns once queued.

  Options: `:count` (255), `:offset` (0), `:order_by` (0), `:pubkey_prefix_length` (4).
  """
  @spec req_neighbours_async(mc(), Meshcore.Util.destination(), keyword()) :: result()
  def req_neighbours_async(mc, contact, opts \\ []) do
    {req, ctx} = neighbours_request(opts)
    send_binary_req(mc, contact, :neighbours, req, Keyword.merge(opts, context: ctx))
  end

  defp neighbours_request(opts) do
    count = Keyword.get(opts, :count, 255)
    offset = Keyword.get(opts, :offset, 0)
    order_by = Keyword.get(opts, :order_by, 0)
    prefix_len = Keyword.get(opts, :pubkey_prefix_length, 4)

    req = <<0, count>> <> u(offset, 2) <> <<order_by, prefix_len>> <> u(random_u32(), 4)
    Logger.debug("Sending binary neighbours req, count: #{count}, offset: #{offset} #{hex(req)}")
    {req, %{pubkey_prefix_length: prefix_len}}
  end

  @doc """
  Requests a node's neighbour table and waits for it. Returns a map with
  `:neighbours_count` (total), `:results_count` (received in this answer) and
  `:neighbours` – a list of `%{pubkey:, secs_ago:, snr:}`. See
  `fetch_all_neighbours/3` to page through large tables.
  """
  @spec req_neighbours_sync(mc(), Meshcore.Util.destination(), keyword()) ::
          {:ok, map()} | {:error, Event.t()}
  def req_neighbours_sync(mc, contact, opts \\ []) do
    Client.with_lock(mc, fn ->
      {req, ctx} = neighbours_request(opts)
      then = then_tag([:neighbours_response], opts)

      mc
      |> send_binary_req(contact, :neighbours, req, Keyword.merge(opts, context: ctx, then: then))
      |> unwrap_payload()
    end)
  end

  @doc """
  Fetches the complete neighbour table, issuing several requests when needed.

  If a follow-up page fails twice in a row the partial result is returned –
  compare `:results_count` with `:neighbours_count`.
  """
  @spec fetch_all_neighbours(mc(), Meshcore.Util.destination(), keyword()) ::
          {:ok, map()} | {:error, Event.t()}
  def fetch_all_neighbours(mc, contact, opts \\ []) do
    opts = Keyword.drop(opts, [:count, :offset])

    with {:ok, res} <-
           req_neighbours_sync(mc, contact, Keyword.merge(opts, count: 255, offset: 0)) do
      res = Map.delete(res, :tag)
      fetch_pages(mc, contact, opts, res, 0)
    end
  end

  defp fetch_pages(
         _mc,
         _contact,
         _opts,
         %{results_count: got, neighbours_count: total} = res,
         _tries
       )
       when got >= total,
       do: {:ok, res}

  defp fetch_pages(mc, contact, opts, res, tries) do
    # requests are close together and responses big: allow extra time for the duty cycle
    page_opts =
      opts
      |> Keyword.put(:count, 255)
      |> Keyword.put(:offset, res.results_count)
      |> Keyword.update(:min_timeout, 25_000, &(&1 + 25_000))

    case req_neighbours_sync(mc, contact, page_opts) do
      {:ok, next} ->
        res = %{
          res
          | results_count: res.results_count + next.results_count,
            neighbours: res.neighbours ++ next.neighbours
        }

        fetch_pages(mc, contact, opts, res, 0)

      {:error, _} when tries > 0 ->
        {:ok, res}

      {:error, _} ->
        fetch_pages(mc, contact, opts, res, tries + 1)
    end
  end

  @doc "Requests the regions configured on a node (async variant)."
  @spec req_regions_async(mc(), Meshcore.Util.destination(), keyword()) :: result()
  def req_regions_async(mc, contact, opts \\ []), do: send_anon_req(mc, contact, :regions, opts)

  @doc "Requests the regions configured on a node. Returns the region string."
  @spec req_regions_sync(mc(), Meshcore.Util.destination(), keyword()) ::
          {:ok, String.t()} | {:error, Event.t()}
  def req_regions_sync(mc, contact, opts \\ []) do
    Client.with_lock(mc, fn ->
      mc
      |> req_anon_sync(contact, :regions, opts)
      |> case do
        {:ok, data} -> {:ok, data |> strip_tag() |> utf8() |> String.trim("\0")}
        error -> error
      end
    end)
  end

  @doc "Requests a node's name and owner info (async variant)."
  @spec req_owner_async(mc(), Meshcore.Util.destination(), keyword()) :: result()
  def req_owner_async(mc, contact, opts \\ []), do: send_anon_req(mc, contact, :owner, opts)

  @doc "Requests a node's name and owner info. Returns `%{name: String.t(), owner: String.t()}`."
  @spec req_owner_sync(mc(), Meshcore.Util.destination(), keyword()) ::
          {:ok, map()} | {:error, Event.t()}
  def req_owner_sync(mc, contact, opts \\ []) do
    Client.with_lock(mc, fn ->
      case req_anon_sync(mc, contact, :owner, opts) do
        {:ok, data} ->
          text = data |> strip_tag() |> utf8()

          case String.split(text, "\n", parts: 2) do
            [name, owner] -> {:ok, %{name: name, owner: String.trim(owner, "\0")}}
            [name] -> {:ok, %{name: name, owner: ""}}
          end

        error ->
          error
      end
    end)
  end

  @doc "Requests a node's basic info, i.e. its clock (async variant)."
  @spec req_basic_async(mc(), Meshcore.Util.destination(), keyword()) :: result()
  def req_basic_async(mc, contact, opts \\ []), do: send_anon_req(mc, contact, :basic, opts)

  @doc "Requests a node's basic info. Returns the `:binary_response` payload (`%{tag:, data: hex}`)."
  @spec req_basic_sync(mc(), Meshcore.Util.destination(), keyword()) ::
          {:ok, map()} | {:error, Event.t()}
  def req_basic_sync(mc, contact, opts \\ []) do
    Client.with_lock(mc, fn ->
      mc
      |> send_anon_req(
        contact,
        :basic,
        Keyword.put(opts, :then, then_tag([:binary_response], opts))
      )
      |> unwrap_payload()
    end)
  end

  # Anonymous requests answer with a raw :binary_response (4 byte tag + data).
  defp req_anon_sync(mc, contact, type, opts) do
    mc
    |> send_anon_req(contact, type, Keyword.put(opts, :then, then_tag([:binary_response], opts)))
    |> payload_result(:data)
    |> case do
      {:ok, data_hex} -> {:ok, Base.decode16!(data_hex, case: :mixed)}
      error -> error
    end
  end

  defp strip_tag(<<_tag::binary-4, rest::binary>>), do: rest
  defp strip_tag(other), do: other

  defp unwrap_payload({:ok, %Event{payload: payload}}), do: {:ok, payload}
  defp unwrap_payload({:error, _} = error), do: error
end
