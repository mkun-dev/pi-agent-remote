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
