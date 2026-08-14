export type UsageAccumulator = {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  reasoning: number;
  totalTokens: number;
  cost: number;
};

function numberOrZero(value: unknown): number {
  const n = typeof value === "number" ? value : Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
}

export function zeroUsageAccumulator(): UsageAccumulator {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    reasoning: 0,
    totalTokens: 0,
    cost: 0,
  };
}

export function addUsage(acc: UsageAccumulator, usage: any): UsageAccumulator {
  if (!usage || typeof usage !== "object") return { ...acc };
  return {
    input: acc.input + numberOrZero(usage.input),
    output: acc.output + numberOrZero(usage.output),
    cacheRead: acc.cacheRead + numberOrZero(usage.cacheRead),
    cacheWrite: acc.cacheWrite + numberOrZero(usage.cacheWrite),
    reasoning: acc.reasoning + numberOrZero(usage.reasoning),
    totalTokens: acc.totalTokens + numberOrZero(usage.totalTokens ?? usage.total),
    cost: acc.cost + numberOrZero(usage.cost?.total),
  };
}

export function maxUsage(a: UsageAccumulator, b: UsageAccumulator): UsageAccumulator {
  return {
    input: Math.max(a.input, b.input),
    output: Math.max(a.output, b.output),
    cacheRead: Math.max(a.cacheRead, b.cacheRead),
    cacheWrite: Math.max(a.cacheWrite, b.cacheWrite),
    reasoning: Math.max(a.reasoning, b.reasoning),
    totalTokens: Math.max(a.totalTokens, b.totalTokens),
    cost: Math.max(a.cost, b.cost),
  };
}

export function summarizeBranchUsage(branch: any[]): { usage: UsageAccumulator; discoveredModel: string | null } {
  let usage = zeroUsageAccumulator();
  let discoveredModel: string | null = null;
  for (const entry of branch) {
    if (entry?.type !== "message") continue;
    const message = entry.message;
    if (message?.role !== "assistant") continue;
    usage = addUsage(usage, message.usage);
    if (typeof message.model === "string" && message.model) {
      discoveredModel = message.model;
    }
  }
  return { usage, discoveredModel };
}

/**
 * 判定一次 turn_end 是否为重复触发（N2）：
 * - messageId 非空且与上次相同 → 重复，应跳过累计；
 * - messageId 为空（无法判定）→ 不跳过，保守累计；
 * - messageId 非空且不同 → 正常，应累计并更新上次记录。
 * 返回 [shouldSkip, newLastSeen]。
 */
export function shouldSkipDuplicateTurnEnd(
  messageId: string | null | undefined,
  lastSeen: string | null
): [boolean, string | null] {
  const id = typeof messageId === "string" ? messageId.trim() : "";
  if (!id) return [false, lastSeen];
  if (id === lastSeen) return [true, lastSeen];
  return [false, id];
}
