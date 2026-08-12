// 精确 Swift 大括号平衡检查：去除字符串、行注释、块注释后再计数
const fs = require("fs");
const path = require("path");

function walk(d) {
  let r = [];
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory() && !e.name.includes(".build") && e.name !== "DerivedData") r = r.concat(walk(p));
    else if (e.name.endsWith(".swift")) r.push(p);
  }
  return r;
}

// 状态机：剥离字符串字面量、行注释、块注释
function stripSwift(src) {
  let out = "";
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    const two = src.slice(i, i + 2);
    // 块注释 /* */
    if (two === "/*") {
      const end = src.indexOf("*/", i + 2);
      i = end < 0 ? n : end + 2;
      continue;
    }
    // 行注释 //
    if (two === "//") {
      const end = src.indexOf("\n", i);
      i = end < 0 ? n : end;
      continue;
    }
    // 字符串 "..."（处理转义和插值 \(...)）
    if (c === '"') {
      out += '""';
      i++;
      let depth = 0;
      while (i < n) {
        const ch = src[i];
        if (ch === "\\" && i + 1 < n) {
          // 转义；若是 \( 则进入插值
          if (src.slice(i, i + 2) === "\\(") { depth++; out += " () "; i += 2; continue; }
          i += 2; continue;
        }
        if (ch === "(" && depth >= 0) { depth++; i++; continue; }
        if (ch === ")" && depth > 0) { depth--; i++; continue; }
        if (ch === '"' && depth === 0) { i++; break; }
        i++;
      }
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

const files = walk("pi-ios-app/PiAgentRemote").concat(walk("pi-ios-app/PiAgentRemoteTests"));
let bad = 0;
for (const f of files) {
  const src = fs.readFileSync(f, "utf8");
  const cleaned = stripSwift(src);
  let d = 0;
  for (const c of cleaned) { if (c === "{") d++; if (c === "}") d--; }
  if (d !== 0) { console.log("❌", f.replace(/\\/g, "/"), "depth=" + d); bad++; }
}
console.log(bad === 0 ? `✓ 所有 ${files.length} 个 Swift 文件（精确解析后）大括号平衡` : `发现 ${bad} 个问题`);
