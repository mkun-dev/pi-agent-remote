import assert from "node:assert/strict";
import { existsSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
// @ts-ignore Node 22 测试运行器直接执行 erasable TypeScript。
import { MAX_UPLOAD_BYTES, saveUploadedImage } from "../src/media-upload.ts";

function temporaryRoot(): string {
  return join(tmpdir(), `pi-ios-upload-test-${Date.now()}-${Math.random().toString(16).slice(2)}`);
}

const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);

test("图片只能写入固定目录并使用随机文件名", () => {
  const root = temporaryRoot();
  try {
    const first = saveUploadedImage(jpeg.toString("base64"), root);
    const second = saveUploadedImage(jpeg.toString("base64"), root);
    assert.equal(dirname(first.path), resolve(root));
    assert.equal(dirname(second.path), resolve(root));
    assert.notEqual(first.path, second.path);
    assert.match(first.path, /[0-9a-f-]{36}\.jpg$/i);
    assert.ok(existsSync(first.path));
    assert.deepEqual(readFileSync(first.path), jpeg);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("拒绝无效 Base64 和非图片内容", () => {
  const root = temporaryRoot();
  try {
    assert.throws(() => saveUploadedImage("../../not-base64", root), /Base64/);
    assert.throws(() => saveUploadedImage(Buffer.from("plain text").toString("base64"), root), /仅支持/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("拒绝超过大小限制的图片", () => {
  const root = temporaryRoot();
  const oversized = Buffer.alloc(MAX_UPLOAD_BYTES + 1);
  oversized[0] = 0xff;
  oversized[1] = 0xd8;
  oversized[2] = 0xff;
  try {
    assert.throws(() => saveUploadedImage(oversized.toString("base64"), root), /10 MB/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
