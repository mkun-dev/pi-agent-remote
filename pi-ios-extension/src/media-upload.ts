import { randomUUID } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;

export type SavedUpload = {
  path: string;
  bytes: number;
  extension: string;
};

/**
 * 只接受受支持的图片，固定写入调用方给定的安全根目录，并使用随机文件名。
 * 客户端的 fileName/dir 不参与路径计算，从根源上消除路径穿越。
 */
export function saveUploadedImage(base64: string, uploadRoot: string): SavedUpload {
  const value = base64.trim();
  if (!value) throw new Error("未收到文件内容");
  const maxEncodedLength = Math.ceil(MAX_UPLOAD_BYTES / 3) * 4 + 4;
  if (value.length > maxEncodedLength) throw new Error("图片超过 10 MB 限制");
  if (value.length % 4 !== 0 || !/^[a-zA-Z0-9+/]*={0,2}$/.test(value)) {
    throw new Error("图片 Base64 格式无效");
  }

  const data = Buffer.from(value, "base64");
  if (data.length === 0) throw new Error("未收到文件内容");
  if (data.length > MAX_UPLOAD_BYTES) throw new Error("图片超过 10 MB 限制");
  const extension = detectImageExtension(data);
  if (!extension) throw new Error("仅支持 JPEG、PNG、GIF、WebP、HEIC 或 BMP 图片");

  const root = resolve(uploadRoot);
  mkdirSync(root, { recursive: true, mode: 0o700 });
  const filePath = resolve(root, `${randomUUID()}.${extension}`);
  if (dirname(filePath) !== root) throw new Error("上传路径校验失败");
  writeFileSync(filePath, data, { flag: "wx", mode: 0o600 });
  return { path: filePath, bytes: data.length, extension };
}

function detectImageExtension(data: Buffer): string | null {
  if (data.length >= 3 && data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff) return "jpg";
  if (data.length >= 8 && data.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "png";
  if (data.length >= 6 && ["GIF87a", "GIF89a"].includes(data.subarray(0, 6).toString("ascii"))) return "gif";
  if (data.length >= 12 && data.subarray(0, 4).toString("ascii") === "RIFF" && data.subarray(8, 12).toString("ascii") === "WEBP") return "webp";
  if (data.length >= 2 && data.subarray(0, 2).toString("ascii") === "BM") return "bmp";
  if (data.length >= 12 && data.subarray(4, 8).toString("ascii") === "ftyp") {
    const brand = data.subarray(8, 12).toString("ascii");
    if (["heic", "heix", "hevc", "hevx", "mif1", "msf1"].includes(brand)) return "heic";
  }
  return null;
}
