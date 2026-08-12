// 探针：观察 turn_end / message_update 事件的实际结构（不注册任何工具避免冲突）
export default function (pi) {
  pi.on("turn_end", async (event) => {
    const m = event?.message;
    console.error("🔍 turn_end.message:", m ? `keys=${Object.keys(m)}` : "undefined");
    console.error("🔍 message.usage:", JSON.stringify(m?.usage ?? null)?.slice(0, 300));
    console.error("🔍 message.model:", m?.model ?? m?.responseModel ?? "?");
  });
  pi.on("message_update", async (event) => {
    const m = event?.message;
    if (m && !probed) {
      console.error("🔍 message_update.message keys:", Object.keys(m));
      console.error("🔍 message_update usage:", JSON.stringify(m?.usage ?? null)?.slice(0, 200));
      probed = true;
    }
  });
  let probed = false;
}
