const fs = require("fs");
const files = [
  "Models/RemoteEvent.swift",
  "Networking/ProtocolMessage.swift",
  "Networking/WebSocketManager.swift",
  "ViewModels/ConversationStore.swift",
  "ViewModels/ChatViewModel.swift",
  "Views/ContentView.swift",
  "Views/FileViewerView.swift",
  "Views/DiffViewer.swift",
  "Views/WorkspaceExplorerView.swift",
];
let ok = 0;
for (const f of files) {
  const s = fs.readFileSync("pi-ios-app/PiAgentRemote/" + f, "utf8");
  let d = 0; for (const c of s) { if (c === "{") d++; if (c === "}") d--; }
  const status = d === 0 ? "✓" : "❌";
  if (d === 0) ok++;
  console.log(status + " " + f.padEnd(44) + " depth=" + d);
}
console.log("\n" + ok + "/" + files.length + " balanced");
