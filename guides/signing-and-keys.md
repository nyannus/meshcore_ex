# Signing & keys

## Signing data with the device key (`ble_sign_example`)

The radio signs with its Ed25519 private key; the key never leaves the device.

```elixir
{:ok, mc} = Meshcore.create_ble(adapter: MyApp.BleAdapter, address: "AA:BB:CC:DD:EE:FF", pin: "123456")

data = "Hello from Elixir!"

case Meshcore.Commands.sign(mc, data, chunk_size: 120) do
  {:ok, %{payload: %{signature: signature}}} ->
    IO.puts("Signature (#{byte_size(signature)} bytes): #{Base.encode16(signature, case: :lower)}")

    # verify against the device's public key – plain OTP, no extra deps
    public_key = mc |> Meshcore.self_info() |> Map.fetch!(:public_key) |> Base.decode16!(case: :lower)

    if :crypto.verify(:eddsa, :none, data, signature, [public_key, :ed25519]) do
      IO.puts("✅ signature valid")
    else
      IO.puts("❌ signature INVALID")
    end

  {:error, event} ->
    IO.puts("sign failed: #{inspect(event.payload)}")
end
```

`sign/3` runs `sign_start` → chunked `sign_data` → `sign_finish`. Chunks of 120 bytes suit BLE
(frames under 128 bytes); serial/TCP can use e.g. `chunk_size: 512`. It returns
`{:error, %{payload: %{reason: :data_too_large, max_length: n}}}` if the data exceeds the
device buffer (8 KB on current firmware). The final wait scales with the data size; override
with `timeout:` (ms). The individual steps (`sign_start/1`, `sign_data/2`, `sign_finish/2`) are
public too.

## Private key export/import (`ble_private_key_export`)

The firmware only allows this when compiled with `ENABLE_PRIVATE_KEY_EXPORT=1`, and you should
use an authenticated (PIN-paired) BLE link.

```elixir
{:ok, mc} = Meshcore.create_ble(adapter: MyApp.BleAdapter, address: "AA:BB:CC:DD:EE:FF", pin: "123456")

case Meshcore.Commands.export_private_key(mc) do
  {:ok, %{type: :private_key, payload: %{private_key: key}}} ->
    File.write!("private_key.bin", key)
    IO.puts("exported #{byte_size(key)} bytes")

  {:ok, %{type: :disabled}} ->
    IO.puts("❌ export is disabled on this device")

  {:error, event} ->
    IO.puts("failed: #{inspect(event.payload)}")
end

# and back (64 bytes):
Meshcore.Commands.import_private_key(mc, File.read!("private_key.bin"))
```

Treat the exported file like a password.
