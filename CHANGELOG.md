# Changelog

## 0.1.0

Initial release: a port of `meshcore_py` 2.3.x.

* `Meshcore` / `Meshcore.Client` session process with serial, TCP and (adapter based) BLE transports
* all command groups: device, contact, messaging, binary/anonymous requests, control data
* complete frame decoder (`Meshcore.Reader`), RX-log packet parser with optional channel decryption
* Cayenne LPP telemetry decoder
* process-message event subscriptions with attribute filters
* auto-reconnect with exponential backoff
