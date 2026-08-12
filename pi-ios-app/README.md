# PiAgentRemote - iOS Remote Client for Pi Agent

SwiftUI iOS App that connects to `pi-ios-extension` via WebSocket.

## Features (Phase 1)
- Chat View: send messages, receive streaming replies
- Live Terminal: see tool output in real time
- Timeline: chronological view of events
- Auto-reconnect
- Settings: change host/port and reconnect

## Architecture
```
iPhone (this app)
   |
WebSocket (ws://IP:3001)
   |
PC: pi-ios-extension
   |
Pi Agent Core
```

## Quick Start

### 1. PC Side (must run first)
```bash
cd pi-ios-extension
npm install
pi -e ./src/index.ts
```
You should see:
```
✅ pi-ios WebSocket listening on ws://0.0.0.0:3001
```

### 2. iOS Side
1. Open Xcode
2. File → New → Project → iOS → App (SwiftUI, Swift)
3. Name it `PiAgentRemote`
4. Delete the default `ContentView.swift` and `PiAgentRemoteApp.swift`
5. Copy the entire `PiAgentRemote/` folder contents into your project
6. Add all `.swift` files to the target

Or simply open the folder in Xcode as a package / drag files in.

### 3. Run
- Simulator: usually connects to `localhost:3001` directly
- Real device: change host in **Settings** tab to your PC's LAN IP (e.g. `192.168.1.105`)

## Testing the Loop
Send from iOS:
```
列出当前目录文件
```
You should see:
- Chat bubbles (user + Pi)
- Terminal output
- Status changes (running → idle)
- Timeline entries

## Project Structure
```
PiAgentRemote/
├── Models/
│   └── Message.swift
├── Networking/
│   ├── ProtocolMessage.swift
│   └── WebSocketManager.swift
├── ViewModels/
│   ├── ChatViewModel.swift
│   └── SettingsStore.swift
└── Views/
    ├── ContentView.swift
    ├── ChatView.swift
    ├── TerminalView.swift
    ├── TimelineView.swift
    ├── SettingsView.swift
    └── QuickActionsView.swift
```

## Protocol (exact match with pi-ios-extension)
```json
{ "type": "agent.input",  "payload": { "text": "..." } }
{ "type": "agent.output", "payload": { "text": "...", "type": "thinking" | "message" } }
{ "type": "tool.start",   "payload": { "tool": "...", "command": "..." } }
{ "type": "tool.output",  "payload": { "data": "..." } }
{ "type": "tool.end",     "payload": { "success": true } }
{ "type": "agent.status", "payload": { "status": "running" | "idle" } }
```

## Tips
- If port 3001 is busy on PC: `taskkill /F /PID <pid>`
- Use `/reload` in Pi TUI after editing extension
- For real device, both devices must be on the same Wi-Fi

## Next Phases (future)
- Session management
- File sync / diff view
- Push notifications
- NAT traversal / relay server

MIT
