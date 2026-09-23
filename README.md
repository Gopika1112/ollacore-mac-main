# ollacore-mac-main

Native macOS SwiftUI chat client for Ollacore (directory + client planes, chat/RTC WebSockets).

## Notes
- **WebSocket sequence cursor is memory-only.** `ChatWebSocket.highestSeqByRoom`
  tracks the highest processed `event_id` per room for reconnect `catchup`
  (with overlap). It is not persisted: after an app restart the cursor resets
  and the client resyncs from history instead of resuming.
- **Device ID is per-install, not per-account.** It survives logout by design
  (server device registration identifies the installation), as does the
  memory-only room-token cache policy: short-lived room tokens are never
  written to disk. Call history is versioned (`call_log_v1`); corrupt data is
  quarantined to `call_log_corrupt_backup` and the log restarts empty.
- Secrets (`OLLACORE_APP_ID`, `SIM_URL`, `SIM_TOKEN`) come from the
  environment only and are never committed. See `.gitignore`.
- **Token transport (S-02).** Session/room credentials travel in the
  `Authorization` header and the `Sec-WebSocket-Protocol` subprotocol only,
  never in URL query strings (enforced in code). Operators must still ensure
  proxies and diagnostics do not log websocket headers, and must terminate
  TLS correctly — header redaction is an infrastructure duty this repo cannot
  perform.