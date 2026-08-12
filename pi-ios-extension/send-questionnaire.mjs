// 直接连接 relay，向 iOS 广播 questionnaire.show —— 真机弹窗测试
// 用法: node send-questionnaire.mjs [question]
const WebSocket = await import("ws").then((m) => m.default);

const RELAY = process.env.RELAY_URL || "ws://82.156.158.106:3002";
const TOKEN = process.env.RELAY_TOKEN || "66d11d55379ab5557e58f5862b980b97";
const question =
  process.argv[2] ||
  "这是一个问卷测试：要执行哪个方案？";

const endpoint = new URL(RELAY);
endpoint.searchParams.set("role", "agent");

const ws = new WebSocket(endpoint, {
  headers: { Authorization: `Bearer ${TOKEN}` },
});

const msg = {
  id: `q_test_${Date.now()}`,
  type: "questionnaire.show",
  timestamp: Date.now(),
  payload: {
    questions: [
      {
        question,
        header: "测试弹窗",
        multiSelect: false,
        options: [
          { label: "方案 A", description: "继续推进", hasPreview: false },
          { label: "方案 B", description: "暂停并查看详情", hasPreview: true },
        ],
      },
      {
        question: "完成后要做什么？",
        header: "下一步",
        multiSelect: true,
        options: [
          { label: "推送编译", description: null, hasPreview: false },
          { label: "真机验收", description: null, hasPreview: false },
        ],
      },
    ],
  },
};

const timeout = setTimeout(() => {
  console.error("⏱ 10s 内未连接成功，退出（检查 relay 是否在线、iOS 是否已连接）");
  process.exit(1);
}, 10_000);

ws.on("open", () => {
  clearTimeout(timeout);
  console.log("✓ 已连接 relay:", RELAY);
  console.log("→ 广播 questionnaire.show ...");
  console.log("  问题:", question);
  ws.send(JSON.stringify(msg));
  console.log("✓ 已发送，等待 3s 观察 iOS 弹窗 ...");
  setTimeout(() => {
    ws.close();
    console.log("✓ 完成");
    process.exit(0);
  }, 3000);
});

ws.on("error", (err) => {
  console.error("✗ 连接错误:", err.message);
  process.exit(1);
});

ws.on("close", () => console.log("连接已关闭"));
