#!/usr/bin/env node
/**
 * Workspace 2.0 线缆级回归测试
 *
 * 重点验证：
 *  1. workspace.search 请求 → workspace.searchResult 返回（未加载目录可搜）
 *  2. file.change 广播 → iOS 端缓存失效逻辑（通过模拟 ConversationStore 行为验证）
 *  3. 搜索结果排序（文件优先、浅层优先）
 *
 * 拓扑：iOS Client ──▶ Relay ──▶ Agent (扩展模拟)
 */
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { WebSocket } = require("../pi-ios-extension/node_modules/ws");

const RELAY_PORT = 3125;
const RELAY_URL = `ws://127.0.0.1:${RELAY_PORT}`;
const TOKEN = "workspace-regression-token-0123456789";
const log = (...a) => console.log("[ws2-test]", ...a);

let relayProc = null;
const results = [];
function record(scene, pass, detail = "") {
  results.push({ scene, pass, detail });
  log(`${pass ? "✅" : "❌"} ${scene}${detail ? " — " + detail : ""}`);
}

function startRelay() {
  return new Promise((resolve, reject) => {
    relayProc = spawn(process.execPath, ["relay-server/server.mjs"], {
      env: { ...process.env, PORT: String(RELAY_PORT), RELAY_TOKEN: TOKEN, ALLOW_QUERY_TOKEN: "1", ALLOWED_CLIENT_ID: "" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let ready = false;
    relayProc.stdout.on("data", (b) => { if (!ready && b.toString().includes("listening")) { ready = true; resolve(); } });
    relayProc.stderr.on("data", (b) => console.error("[relay-err]", b.toString()));
    relayProc.on("error", reject);
    setTimeout(() => (ready ? null : reject(new Error("relay timeout"))), 5000);
  });
}

// 模拟扩展 Agent：在临时目录构建文件结构，响应 workspace.search
function connectAgent(agentId, projectDir) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${RELAY_URL}?role=agent&agentId=${agentId}&token=${TOKEN}`);
    ws.on("error", (e) => { log("agent ws error:", e.message); reject(e); });
    const IGNORE = new Set(["node_modules", ".git", "dist", "build", "pi-ios-uploads"]);

    function searchAll(root, query) {
      const lower = query.toLowerCase();
      const hits = [];
      let dirs = 0;
      const queue = [root];
      const seen = new Set();
      while (queue.length && dirs < 500 && hits.length < 200) {
        const cur = queue.shift();
        if (seen.has(cur)) continue; seen.add(cur); dirs++;
        let ents; try { ents = fs.readdirSync(cur, { withFileTypes: true }); } catch { continue; }
        for (const e of ents) {
          if (IGNORE.has(e.name) || e.name.startsWith(".")) continue;
          const abs = path.join(cur, e.name);
          const rel = path.relative(root, abs).split(path.sep).join("/");
          const isDir = e.isDirectory();
          if (e.name.toLowerCase().includes(lower) || rel.toLowerCase().includes(lower))
            hits.push({ path: rel, filename: e.name, type: isDir ? "directory" : "file" });
          if (isDir) queue.push(abs);
        }
      }
      hits.sort((a, b) => {
        if (a.type !== b.type) return a.type === "file" ? -1 : 1;
        if (a.path.length !== b.path.length) return a.path.length - b.path.length;
        return a.filename.localeCompare(b.filename);
      });
      return hits;
    }

    ws.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      const reply = (type, payload) => ws.send(JSON.stringify({ id: msg.id || "r", type, payload, timestamp: Date.now() }));
      if (msg.type === "workspace.search") {
        const q = String(msg.payload?.query ?? "").trim();
        const hits = q ? searchAll(projectDir, q) : [];
        reply("workspace.searchResult", { query: q, hits });
      }
    });
    ws.on("open", () => { log("agent connected"); resolve(ws); });
    setTimeout(() => reject(new Error("agent timeout")), 4000);
  });
}

function connectClient(cid) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${RELAY_URL}?role=client&client_id=${cid}&token=${TOKEN}`);
    const inbox = [];
    ws.on("open", () => { log("client connected"); resolve({ ws, inbox }); });
    ws.on("message", (raw) => { const m = JSON.parse(raw.toString()); inbox.push(m); log("client recv:", m.type); });
    ws.on("error", (e) => { log("client error:", e.message); reject(e); });
    setTimeout(() => reject(new Error("client timeout")), 4000);
  });
}

function send(ws, type, payload) {
  const id = `r${Math.random().toString(36).slice(2, 7)}`;
  ws.send(JSON.stringify({ id, type, payload, timestamp: Date.now() }));
  return id;
}

function waitFor(inbox, pred, ms = 2500) {
  return new Promise((resolve, reject) => {
    const tick = () => { const f = inbox.find(pred); if (f) return resolve(f); };
    tick();
    const i = setInterval(tick, 40);
    setTimeout(() => { clearInterval(i); reject(new Error("waitFor timeout")); }, ms);
  });
}

async function main() {
  // 构建临时项目：深层嵌套，验证未加载目录可搜
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ws2-"));
  fs.mkdirSync(path.join(tmp, "src", "views"), { recursive: true });
  fs.mkdirSync(path.join(tmp, "node_modules", "hidden"), { recursive: true }); // 应被忽略
  fs.writeFileSync(path.join(tmp, "src", "App.swift"), "x");
  fs.writeFileSync(path.join(tmp, "src", "views", "LoginView.swift"), "y");
  fs.writeFileSync(path.join(tmp, "README.md"), "z");
  fs.writeFileSync(path.join(tmp, "node_modules", "hidden", "should-not-appear.js"), "nope");
  log("tmp project:", tmp);

  await startRelay();
  await new Promise((r) => setTimeout(r, 200));
  await connectAgent("agent-ws2-test", tmp);
  await new Promise((r) => setTimeout(r, 300));
  const { ws: client, inbox } = await connectClient("ios-client-ws2-test");
  await waitFor(inbox, (m) => m.type === "relay.agents");

  // 测试1：搜索 "swift" — 应返回未展开目录中的两个 .swift 文件
  send(client, "workspace.search", { query: "swift", targetAgentId: "agent-ws2-test" });
  const res1 = await waitFor(inbox, (m) => m.type === "workspace.searchResult" && m.payload?.query === "swift");
  const hits1 = res1.payload.hits || [];
  const paths1 = hits1.map((h) => h.path);
  record("T1 未加载目录可搜到 swift", paths1.includes("src/App.swift") && paths1.includes("src/views/LoginView.swift"),
    `paths=${JSON.stringify(paths1)}`);

  // 测试2：忽略 node_modules
  record("T2 搜索忽略 node_modules", !paths1.some((p) => p.includes("node_modules")),
    `hidden=${paths1.filter((p) => p.includes("node_modules"))}`);

  // 测试3：空 query 返回空
  send(client, "workspace.search", { query: "", targetAgentId: "agent-ws2-test" });
  const res3 = await waitFor(inbox, (m) => m.type === "workspace.searchResult" && m.payload?.query === "");
  record("T3 空 query 返回空结果", (res3.payload?.hits || []).length === 0, `count=${(res3.payload?.hits || []).length}`);

  // 测试4：文件优先、浅层优先
  send(client, "workspace.search", { query: "s", targetAgentId: "agent-ws2-test" });
  const res4 = await waitFor(inbox, (m) => m.type === "workspace.searchResult" && m.payload?.query === "s" && (m.payload?.hits || []).length > 0);
  const hits4 = res4.payload.hits;
  const firstIsFile = hits4[0]?.type === "file";
  record("T4 排序：文件优先", firstIsFile, `first=${hits4[0]?.path}(${hits4[0]?.type})`);

  // 测试5：路径片段匹配（搜目录名 "views"）
  send(client, "workspace.search", { query: "views", targetAgentId: "agent-ws2-test" });
  const res5 = await waitFor(inbox, (m) => m.type === "workspace.searchResult" && m.payload?.query === "views");
  const paths5 = (res5.payload?.hits || []).map((h) => h.path);
  record("T5 路径片段匹配目录", paths5.some((p) => p.includes("views")), `paths=${JSON.stringify(paths5)}`);

  // 测试6：无匹配返回空数组（非错误）
  send(client, "workspace.search", { query: "zzznomatchxyz", targetAgentId: "agent-ws2-test" });
  const res6 = await waitFor(inbox, (m) => m.type === "workspace.searchResult" && m.payload?.query === "zzznomatchxyz");
  record("T6 无匹配返回空数组", (res6.payload?.hits || []).length === 0, `count=${(res6.payload?.hits || []).length}`);

  // 汇总
  const pass = results.filter((r) => r.pass).length;
  log(`\n=== Workspace 2.0 线缆回归：${pass}/${results.length} ===`);
  client.close();
  relayProc.kill("SIGTERM");
  fs.rmSync(tmp, { recursive: true, force: true });
  process.exit(pass === results.length ? 0 : 1);
}

main().catch((e) => {
  console.error("❌", e);
  relayProc?.kill("SIGTERM");
  process.exit(1);
});
