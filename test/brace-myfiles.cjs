const fs = require("fs");
const files = [
  "ViewModels/ConversationStore.swift",
  "ViewModels/ChatViewModel.swift",
  "Networking/WebSocketManager.swift",
  "Views/AgentStatusHeader.swift",
  "Services/BackgroundAudioService.swift",
  "Services/RemoteLogger.swift",
];
for (const f of files) {
  const s = fs.readFileSync("pi-ios-app/PiAgentRemote/" + f, "utf8");
  let d = 0;
  for (const c of s) { if (c === "{") d++; if (c === "}") d--; }
  console.log(f.padEnd(48) + " depth=" + d);
}
