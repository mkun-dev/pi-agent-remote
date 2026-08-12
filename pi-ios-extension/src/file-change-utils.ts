export type FileChangeStats = { additions?: number; deletions?: number };

export function isFileMutationTool(toolName: string): boolean {
  return /(edit|write|create|save|update|patch|delete|remove)/i.test(toolName);
}

export function extractFilePath(args: any): string | null {
  if (typeof args === "string") return args;
  if (!args || typeof args !== "object") return null;
  if (args.file) return String(args.file);
  if (args.file_path) return String(args.file_path);
  if (args.path) return String(args.path);
  if (args.command) {
    const match = String(args.command).match(
      /[\w/.-]+\.(ts|tsx|js|jsx|md|json|txt|mdx|sh|py|swift|css|html|yml|yaml)$/i
    );
    if (match) return match[0];
  }
  return null;
}

export function countTextLines(text: string): number {
  if (!text) return 0;
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines.length;
}

/** 统计 unified patch / display diff 的实际增删行，忽略文件头。 */
export function countPatchChanges(patch: string): FileChangeStats {
  let additions = 0;
  let deletions = 0;
  for (const line of patch.replace(/\r\n/g, "\n").split("\n")) {
    if (line.startsWith("+++ ") || line.startsWith("--- ")) continue;
    if (line.startsWith("+")) additions += 1;
    else if (line.startsWith("-")) deletions += 1;
  }
  return {
    ...(additions > 0 ? { additions } : {}),
    ...(deletions > 0 ? { deletions } : {})
  };
}
