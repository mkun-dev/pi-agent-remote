import { readFileSync } from "node:fs";

export type WorkspacePreviewFileType = "image" | "text" | "binary";

export type WorkspaceFileReadResult = {
  path: string;
  fileType: WorkspacePreviewFileType;
  size: number;
  mimeType?: string;
  content?: string;
  base64?: string;
};

const IMAGE_EXTS = new Set(["png", "jpg", "jpeg", "webp"]);
const TEXT_EXTS = new Set([
  "swift", "ts", "tsx", "js", "jsx", "json", "md", "markdown",
  "yml", "yaml", "html", "css", "sh", "bash", "go", "rs", "java",
  "kt", "c", "cpp", "cc", "cxx", "h", "hpp", "sql", "txt", "xml",
  "plist", "log", "py", "rb", "php", "ini", "toml", "gradle", "m", "mm", "svg"
]);

export function classifyWorkspaceFile(path: string): WorkspacePreviewFileType {
  const ext = path.toLowerCase().split(".").pop() ?? "";
  if (IMAGE_EXTS.has(ext)) return "image";
  if (TEXT_EXTS.has(ext)) return "text";
  return "binary";
}

export function imageMimeType(path: string): string | undefined {
  const ext = path.toLowerCase().split(".").pop() ?? "";
  switch (ext) {
    case "png": return "image/png";
    case "jpg":
    case "jpeg": return "image/jpeg";
    case "webp": return "image/webp";
    case "svg": return "image/svg+xml";
    default: return undefined;
  }
}

/**
 * 启发式文本判断：
 * - 含 NUL 字节视为二进制
 * - 控制字符比例过高视为二进制
 */
export function isProbablyTextBuffer(buf: Buffer): boolean {
  if (buf.length === 0) return true;
  let suspicious = 0;
  for (const byte of buf) {
    if (byte === 0) return false;
    const isControl = byte < 0x20 && byte !== 0x09 && byte !== 0x0a && byte !== 0x0d;
    if (isControl) suspicious++;
  }
  return suspicious / buf.length < 0.1;
}

/**
 * 安全读取 Workspace 文件：
 * - 图片：返回 base64 + mimeType
 * - 文本：返回 UTF-8 content
 * - 未知：尽量探测文本，否则标记 binary
 */
export function readWorkspaceFilePayload(
  absPath: string,
  requestPath: string,
  size: number,
  limits: { maxTextBytes: number; maxImageBytes: number },
): WorkspaceFileReadResult {
  const byExt = classifyWorkspaceFile(requestPath);
  if (byExt === "image") {
    if (size > limits.maxImageBytes) {
      throw new Error(`图片过大（${(size / 1024 / 1024).toFixed(1)}MB > ${(limits.maxImageBytes / 1024 / 1024).toFixed(0)}MB）`);
    }
    const data = readFileSync(absPath);
    const mime = imageMimeType(requestPath);
    return {
      path: requestPath,
      fileType: "image",
      ...(mime ? { mimeType: mime } : {}),
      base64: data.toString("base64"),
      size,
    };
  }

  if (size > limits.maxTextBytes) {
    throw new Error(`文件过大（${(size / 1024 / 1024).toFixed(1)}MB > ${(limits.maxTextBytes / 1024 / 1024).toFixed(0)}MB）`);
  }

  const data = readFileSync(absPath);
  if (byExt === "text" || isProbablyTextBuffer(data.subarray(0, Math.min(data.length, 4096)))) {
    const mime = requestPath.toLowerCase().endsWith('.svg') ? 'image/svg+xml' : undefined;
    return {
      path: requestPath,
      fileType: "text",
      ...(mime ? { mimeType: mime } : {}),
      content: data.toString("utf8"),
      size,
    };
  }

  return {
    path: requestPath,
    fileType: "binary",
    size,
  };
}
