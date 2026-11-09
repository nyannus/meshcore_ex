# Fault tolerance

Radios are flaky: cables get pulled, WiFi bridges stall, BLE writes hang, frames arrive
truncated. This is how the library keeps working.

## Process layout

```
Meshcore.Supervisor
├── Meshcore.TaskSupervisor        helper tasks (message fetching, contact refresh)
└── Meshcore.ConnectionSupervisor  DynamicSupervisor for create_* connections
      └── Meshcore.Client          one per radio: state, subscribers, waiters, lock
            └── transport (linked) TCP | Serial | BLE | yours
```

Or, in your own tree, `{Meshcore, opts}` → `Meshcore.Client` → transport.

* The **transport** is linked to the client; the client traps exits. A transport that crashes or
  stops is "just a lost connection": waiters fail, `auto_reconnect` starts a fresh transport.
* The **client** never blocks on I/O: transports are driven by casts and report back with
  messages; connecting is asynchronous.
* A crashing **subscriber** is demonitored/dropped; it can't affect the client or other
  subscribers.
* A crashing **caller** holding the mesh lock releases it (the client monitors the holder).

## Every wait has a deadline

A command registers a *waiter* with a timer inside the client. If the radio stays silent the
caller gets `{:error, %Event{payload: %{reason: :timeout}}}` – never a hang. If the link drops,
all waiters are failed immediately with `reason: :disconnected`; sending while disconnected
yields `reason: :not_connected`.

`get_contacts/2` is the one exception to "fixed deadline": its timer restarts each time another
contact arrives.

## Malformed input is contained

`Meshcore.Reader` decodes inside `try/rescue`: a truncated or corrupted frame is logged and
dropped, never crashing the client. The `Meshcore.Frame` decoder resynchronises on the next
start marker after garbage (some radios print console output on the same UART) and discards
frames that announce an impossible length. Telemetry that fails to decode produces a log line
instead of an event.

## Reconnecting

```elixir
Meshcore.create_tcp(host, port, auto_reconnect: true, max_reconnect_attempts: 5)
```

Backoff doubles from 1 s up to 8 s. After a successful reconnect the `CMD_APP_START` handshake is
repeated before `:connected` (with `reconnected: true`) is emitted. When the attempts run out a
`:disconnected` event with `max_attempts_exceeded: true` is emitted. A manual `disconnect/1`
cancels pending reconnect attempts and is final.

Transport-level safety nets:

* **TCP**: five consecutive sends with no frame received in between declare the link dead.
* **BLE**: a write that takes longer than `:write_timeout` (default 10 s) tears the link down
  rather than letting a second write race it.
* **Serial**: write errors and port closure are reported as disconnects.

## No lost responses

For `*_sync` requests the response handler is installed in the same step that processes the
`:msg_sent` acknowledgement, inside the client process, so a reply cannot arrive "in between".
The Python library registers its wait afterwards and can miss a fast reply.

Concurrent commands are answered in send order (the firmware processes them in order), so a
late response can't be mistaken for the answer to the next command of the same kind… with one
caveat: an `ERROR` response is attributed to the oldest waiting command. Issue commands
concurrently only if you can live with that.

## Supervising your own consumers

Subscriptions end when the subscriber dies, so a restarted consumer must re-subscribe in
`init/1`. Use `:rest_for_one` (see the [bots guide](bots.md)) so consumers are restarted after
the connection process they depend on.
