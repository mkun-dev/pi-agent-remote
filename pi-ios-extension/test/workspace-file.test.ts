import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
// @ts-ignore Node 22 strip-types
import { classifyWorkspaceFile, imageMimeType, isProbablyTextBuffer, readWorkspaceFilePayload } from "../src/workspace-file.ts";

test("classifyWorkspaceFile: image/text/binary", () => {
  assert.equal(classifyWorkspaceFile("a.png"), "image");
  assert.equal(classifyWorkspaceFile("a.JPG"), "image");
  assert.equal(classifyWorkspaceFile("main.swift"), "text");
  assert.equal(classifyWorkspaceFile("icon.svg"), "text");
  assert.equal(classifyWorkspaceFile("blob.bin"), "binary");
});

test("imageMimeType maps supported images", () => {
  assert.equal(imageMimeType("a.png"), "image/png");
  assert.equal(imageMimeType("a.jpg"), "image/jpeg");
  assert.equal(imageMimeType("a.jpeg"), "image/jpeg");
  assert.equal(imageMimeType("a.webp"), "image/webp");
  assert.equal(imageMimeType("a.svg"), "image/svg+xml");
});

test("isProbablyTextBuffer rejects NUL-heavy binary", () => {
  assert.equal(isProbablyTextBuffer(Buffer.from([0x00, 0x01, 0x02])), false);
  assert.equal(isProbablyTextBuffer(Buffer.from("hello\nworld", "utf8")), true);
});

test("readWorkspaceFilePayload returns text content for text file", () => {
  const root = mkdtempSync(join(tmpdir(), "wsfile-"));
  const p = join(root, "a.swift");
  writeFileSync(p, "import SwiftUI\n");
  const file = readWorkspaceFilePayload(p, "a.swift", 15, { maxTextBytes: 1024, maxImageBytes: 2048 });
  assert.equal(file.fileType, "text");
  assert.equal(file.content, "import SwiftUI\n");
  assert.equal(file.base64, undefined);
});

test("readWorkspaceFilePayload keeps svg as text with mime", () => {
  const root = mkdtempSync(join(tmpdir(), "wssvg-"));
  const p = join(root, "icon.svg");
  writeFileSync(p, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"></svg>');
  const file = readWorkspaceFilePayload(p, "icon.svg", 67, { maxTextBytes: 1024, maxImageBytes: 2048 });
  assert.equal(file.fileType, "text");
  assert.equal(file.mimeType, "image/svg+xml");
  assert.ok(file.content?.includes("<svg"));
});

test("readWorkspaceFilePayload returns image base64 for png", () => {
  const root = mkdtempSync(join(tmpdir(), "wsimg-"));
  const p = join(root, "pixel.png");
  // 1x1 transparent png
  const base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4////fwAJ+wP9KobjigAAAABJRU5ErkJggg==";
  writeFileSync(p, Buffer.from(base64, "base64"));
  const file = readWorkspaceFilePayload(p, "pixel.png", Buffer.from(base64, "base64").length, { maxTextBytes: 1024, maxImageBytes: 2048 });
  assert.equal(file.fileType, "image");
  assert.equal(file.mimeType, "image/png");
  assert.equal(file.base64, base64);
  assert.equal(file.content, undefined);
});

test("readWorkspaceFilePayload returns binary for unknown binary file", () => {
  const root = mkdtempSync(join(tmpdir(), "wsbin-"));
  const p = join(root, "blob.dat");
  writeFileSync(p, Buffer.from([0x00, 0xff, 0x10, 0x88]));
  const file = readWorkspaceFilePayload(p, "blob.dat", 4, { maxTextBytes: 1024, maxImageBytes: 2048 });
  assert.equal(file.fileType, "binary");
  assert.equal(file.content, undefined);
  assert.equal(file.base64, undefined);
});

test("readWorkspaceFilePayload falls back to text for unknown but textual file", () => {
  const root = mkdtempSync(join(tmpdir(), "wstxt-"));
  const p = join(root, "README");
  writeFileSync(p, "hello world\n");
  const file = readWorkspaceFilePayload(p, "README", 12, { maxTextBytes: 1024, maxImageBytes: 2048 });
  assert.equal(file.fileType, "text");
  assert.equal(file.content, "hello world\n");
});

test("readWorkspaceFilePayload rejects oversized image", () => {
  const root = mkdtempSync(join(tmpdir(), "wshuge-"));
  const p = join(root, "big.webp");
  mkdirSync(root, { recursive: true });
  writeFileSync(p, Buffer.alloc(3000));
  assert.throws(
    () => readWorkspaceFilePayload(p, "big.webp", 3000, { maxTextBytes: 1024, maxImageBytes: 2048 }),
    /图片过大/,
  );
});
