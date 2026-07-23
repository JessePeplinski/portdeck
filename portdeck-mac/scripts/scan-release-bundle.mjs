#!/usr/bin/env node

import { lstat, readFile, readdir } from "node:fs/promises";
import path from "node:path";

const [bundlePath] = process.argv.slice(2);
if (!bundlePath) {
  throw new Error("usage: scan-release-bundle.mjs <PortDeck.app>");
}

const placeholderPattern =
  /(example|sample|placeholder|redacted|dummy|fake|your[-_]?token|test[-_]?token|abcdef|123456)/i;

const entropy = (value) => {
  const counts = new Map();
  for (const character of value) {
    counts.set(character, (counts.get(character) ?? 0) + 1);
  }
  return [...counts.values()].reduce((sum, count) => {
    const probability = count / value.length;
    return sum - probability * Math.log2(probability);
  }, 0);
};

const looksSecret = (value) =>
  value.length >= 20 && !placeholderPattern.test(value) && entropy(value) >= 3.5;

const credentialPatterns = [
  {
    name: "GitHub token",
    expression: /\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,})\b/g,
  },
  {
    name: "Stripe live key",
    expression: /\bsk_live_[A-Za-z0-9]{16,}\b/g,
  },
  {
    name: "Slack token",
    expression: /\bxox[baprs]-[A-Za-z0-9-]{20,}\b/g,
  },
  {
    name: "AWS access key",
    expression: /\bAKIA[0-9A-Z]{16}\b/g,
  },
];

const findings = [];
const addFinding = (filePath, kind) => findings.push({ filePath, kind });

const scanFile = async (filePath) => {
  const contents = (await readFile(filePath)).toString("latin1");
  const privateKey =
    /-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----[\s\S]{100,}?-----END (?:[A-Z ]+ )?PRIVATE KEY-----/g;
  if (privateKey.test(contents)) {
    addFinding(filePath, "private key block");
  }

  for (const pattern of credentialPatterns) {
    if ([...contents.matchAll(pattern.expression)].some((match) => looksSecret(match[0]))) {
      addFinding(filePath, pattern.name);
    }
  }

  const credentialURL = /https?:\/\/[^\s/:@]+:([^\s/@]+)@/g;
  if ([...contents.matchAll(credentialURL)].some((match) => looksSecret(match[1] ?? ""))) {
    addFinding(filePath, "credential-bearing URL");
  }

  const secretAssignment =
    /\b(?:[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE_KEY)[A-Z0-9_]*)=([A-Za-z0-9_+./=-]{20,})/g;
  if ([...contents.matchAll(secretAssignment)].some((match) => looksSecret(match[1] ?? ""))) {
    addFinding(filePath, "secret environment assignment");
  }
};

const walk = async (directory) => {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      await walk(entryPath);
    } else if (entry.isFile()) {
      await scanFile(entryPath);
    } else if (!entry.isSymbolicLink()) {
      const metadata = await lstat(entryPath);
      if (metadata.isFile()) {
        await scanFile(entryPath);
      }
    }
  }
};

await walk(bundlePath);

if (findings.length > 0) {
  for (const finding of findings) {
    console.error(`${finding.kind}: ${path.relative(bundlePath, finding.filePath)}`);
  }
  throw new Error(`release bundle contains ${findings.length} high-confidence secret finding(s)`);
}

console.log("Release bundle secret scan: no findings");
