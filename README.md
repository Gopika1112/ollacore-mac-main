# ollacore-mac-main

Native macOS SwiftUI chat client for Ollacore (directory + client planes, chat/RTC WebSockets).

## Notes
- **WebSocket sequence cursor is memory-only.** `ChatWebSocket.highestSeqByRoom`
  tracks the highest processed `event_id` per room for reconnect `catchup`
  (with overlap). It is not persisted: after an app restart the cursor resets
  and the client resyncs from history instead of resuming.
- Secrets (`OLLACORE_APP_ID`, `SIM_URL`, `SIM_TOKEN`) come from the
  environment only and are never committed. See `.gitignore`.