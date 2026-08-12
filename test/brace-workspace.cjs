const fs = require("fs");
const files = [
  "Models/RemoteEvent.swift",
  "Networking/RemoteEventDecoder.swift",
  "Networking/ProtocolMessage.swift",
  "Networking/WebSocketManager.swift",
  "ViewModels/ConversationStore.swift",
  "ViewModels/ChatViewModel.swift",
  "Views/WorkspaceExplorerView.swift",
];
for (const f of files) {
  const s = fs.readFileSync("pi-ios-app/PiAgentRemote/" + f, "utf8");
  let d = 0; for (const c of s) { if (c === "{") d++; if (c === "}") d--; }
  console.log(f.padEnd(44) + " depth=" + d);
}
const t = "PiAgentRemoteTests/WorkspaceExplorerTests.swift";
const st = fs.readFileSync("pi-ios-app/" + t, "utf8");
let dt = 0; for (const c of st) { if (c === "{") dt++; if (c === "}") dt--; }
console.log(t.padEnd(44) + " depth=" + dt);
