#!/usr/bin/env node
// logicstar, first-time install script (Node).
//
// Detects platform, fetches the latest release, downloads the matching binary, verifies its SHA-256
// against the published checksums.txt, and places it at ~/.local/bin/logicstar.
//
// Subsequent updates are handled by `logicstar update` (auto-checks every 4 hours during Claude
// Code SessionStart) and use Ed25519 signature verification on top of SHA-256.
//
// Usage:
//   npx github:logic-star-ai/logicstar-cli-releases

import { createHash } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const REPO = "logic-star-ai/logicstar-cli-releases";
const BIN_DIR = join(homedir(), ".local", "bin");
const BIN_PATH = join(BIN_DIR, "logicstar");

const die = (msg) => {
  process.stderr.write(`logicstar install: ${msg}\n`);
  process.exit(1);
};

// ---- Platform detection -------------------------------------------------
const ARCH_MAP = { x64: "x64", arm64: "arm64" };
const arch = ARCH_MAP[process.arch];
if (!arch) {
  die(`unsupported architecture: ${process.arch}`);
}

const PLATFORM_MAP = { darwin: "darwin", linux: "linux" };
const os = PLATFORM_MAP[process.platform];
if (!os) {
  die(`unsupported OS: ${process.platform} (logicstar ships for macOS and Linux)`);
}

const ASSET = `logicstar-${os}-${arch}`;

// ---- Resolve latest release --------------------------------------------
const apiUrl = `https://api.github.com/repos/${REPO}/releases/latest`;
const apiResponse = await fetch(apiUrl, { headers: { accept: "application/vnd.github+json" } }).catch((error) => {
  die(`could not reach ${apiUrl}: ${error.message}`);
});
if (!apiResponse.ok) {
  die(`${apiUrl} returned ${apiResponse.status}`);
}
const release = await apiResponse.json();

const findAsset = (name) => release.assets?.find((asset) => asset.name === name);

const binAsset = findAsset(ASSET);
const sumAsset = findAsset("checksums.txt");

if (!binAsset) {
  die(`no binary for ${os}-${arch} in ${release.tag_name ?? "latest release"}`);
}
if (!sumAsset) {
  die("release is missing checksums.txt, refusing to install unverified binary");
}

process.stdout.write(`logicstar: installing ${release.tag_name} for ${os}-${arch}\n`);

// ---- Download ----------------------------------------------------------
const tmp = mkdtempSync(join(tmpdir(), "logicstar-install-"));
const cleanup = () => {
  try {
    rmSync(tmp, { recursive: true, force: true });
  } catch {}
};
process.on("exit", cleanup);

const downloadTo = async (url, path) => {
  const response = await fetch(url, { headers: { accept: "application/octet-stream" } });
  if (!response.ok) {
    die(`download failed (${response.status}): ${url}`);
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  writeFileSync(path, bytes);
};

const stagedBin = join(tmp, ASSET);
const stagedSums = join(tmp, "checksums.txt");
await downloadTo(binAsset.browser_download_url, stagedBin);
await downloadTo(sumAsset.browser_download_url, stagedSums);

// ---- Verify SHA-256 ----------------------------------------------------
const expected = readFileSync(stagedSums, "utf-8")
  .split("\n")
  .map((line) => line.trim())
  .filter(Boolean)
  .find((line) => line.endsWith(`  ${ASSET}`))
  ?.split(/\s+/)[0];

if (!expected) {
  die(`no checksum entry for ${ASSET}, release is malformed`);
}

const actual = createHash("sha256").update(readFileSync(stagedBin)).digest("hex");
if (actual !== expected) {
  die(`checksum mismatch, refusing to install (expected ${expected}, got ${actual})`);
}

// ---- Install -----------------------------------------------------------
// Refuse to overwrite a `logicstar init --dev` symlink (would clobber the source file it points at).
if (existsSync(BIN_PATH) && lstatSync(BIN_PATH).isSymbolicLink()) {
  die(`${BIN_PATH} is a symlink (likely a dev install), remove it first if you want a binary install`);
}

mkdirSync(BIN_DIR, { recursive: true });
chmodSync(stagedBin, 0o755);
renameSync(stagedBin, BIN_PATH);

process.stdout.write(`logicstar: installed at ${BIN_PATH}\n`);

// ---- PATH hint ---------------------------------------------------------
const path = process.env.PATH ?? "";
const onPath = path.split(":").includes(BIN_DIR);
if (!onPath) {
  process.stdout.write(`\nNote: ${BIN_DIR} is not on your PATH.\n`);
  process.stdout.write("Add to your shell profile:\n");
  process.stdout.write(`  export PATH="${BIN_DIR}:$PATH"\n`);
}

// Run the binary's `init` to wire Claude Code integration and ask for telemetry consent.
// Inherit stdio so the consent prompt is interactive.
const { spawnSync } = await import("node:child_process");
const initResult = spawnSync(BIN_PATH, ["init"], { stdio: "inherit" });
if (initResult.status !== 0) {
  process.stderr.write("\nlogicstar: 'logicstar init' did not complete cleanly. Run it manually to finish setup.\n");
  process.exit(1);
}
