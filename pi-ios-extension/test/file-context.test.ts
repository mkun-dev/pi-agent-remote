import assert from "node:assert/strict";
import { test } from "node:test";
// @ts-ignore Node 22 直接执行 erasable TypeScript；测试运行器需要 .ts 扩展。
import { injectFileContext } from "../src/file-context.ts";

test("injectFileContext: 无 context 时原样返回", () => {
  assert.equal(injectFileContext("你好", null), "你好");
  assert.equal(injectFileContext("你好", undefined), "你好");
  assert.equal(injectFileContext("你好", "string" as never), "你好");
});

test("injectFileContext: 空 workspaceFiles 时原样返回", () => {
  assert.equal(injectFileContext("问题", { workspaceFiles: [] }), "问题");
  assert.equal(injectFileContext("问题", { workspaceFiles: ["  "] }), "问题");
  assert.equal(injectFileContext("问题", {}), "问题");
});

test("injectFileContext: 单文件注入路径块", () => {
  const out = injectFileContext("这个函数做什么？", { workspaceFiles: ["src/Auth.swift"] });
  assert.ok(out.startsWith("📁 文件上下文"));
  assert.ok(out.includes("- src/Auth.swift"));
  assert.ok(out.endsWith("\n\n这个函数做什么？"));
});

test("injectFileContext: 多文件逐行列出", () => {
  const out = injectFileContext("检查一下", { workspaceFiles: ["a.swift", "b.ts"] });
  assert.ok(out.includes("- a.swift"));
  assert.ok(out.includes("- b.ts"));
  assert.equal(out.split("\n").filter((l) => l.startsWith("- ")).length, 2);
});

test("injectFileContext: 附带选区", () => {
  const out = injectFileContext("这段对吗？", { workspaceFiles: ["x.py"], selection: "第 12-20 行" });
  assert.ok(out.includes("[选区] 第 12-20 行"));
  assert.ok(out.includes("- x.py"));
});

test("injectFileContext: 过滤非字符串/空字符串文件", () => {
  const out = injectFileContext("q", {
    workspaceFiles: [123 as never, "valid.swift", "  ", ""],
  });
  assert.ok(out.includes("- valid.swift"));
  assert.ok(!out.includes("- 123"));
  assert.ok(!out.includes("-   "));
});

test("injectFileContext: 用户消息顺序保持（上下文在前）", () => {
  const out = injectFileContext("用户消息", { workspaceFiles: ["f"] });
  const ctxIdx = out.indexOf("📁");
  const msgIdx = out.indexOf("用户消息");
  assert.ok(ctxIdx < msgIdx, "上下文块应在用户消息之前");
});
