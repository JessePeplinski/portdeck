#!/usr/bin/env node

import { lstat, readFile, readdir } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";

const [bundlePath] = process.argv.slice(2);
if (!bundlePath) {
  throw new Error("usage: scan-release-bundle.mjs <PortDeck.app>");
}

const placeholderPattern = /(example|sample|placeholder|redacted|dummy|fake|your[-_]?token|test[-_]?token|abcdef|123456)/i;

const entropy = (value) => {
  const counts = new Map();
  for (const character of value) counts.set(character, (counts.get(character) ?? 0) + 1);
  return [...counts.values()].reduce((sum, count) => {
    const probability = count / value.length;
    return sum - probability * Math.log2(probability);
  }, 0);
};

const looksSecret = (value) => {
  if (value.length < 20 || placeholderPattern.test(value)) return false;
  return entropy(value) >= 3.5;
};

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
const fingerprint = (value) => createHash("sha256").update(value).digest("hex");

// These are exact, checksum-addressed examples or parser fixtures shipped by
// locked third-party runtimes. A dependency update must re-audit the content
// before changing this list; paths or content hashes that drift fail closed.
const auditedThirdPartyFixtures = new Set([
  "Contents/Resources/ProviderRuntimes/fly/bin/flyctl|private key block|1baeac79a6986396ba786d67029f862b71f0a15956527bcb2ae41a99906d806e",
  "Contents/Resources/ProviderRuntimes/node/node_modules/@octokit/auth-token/README.md|GitHub token|25ba5ecff1e53d417d5b4a3c3d1f8b63843045aadc3e4beebe497b8d1dcba65f",
  "Contents/Resources/ProviderRuntimes/node/node_modules/@supabase/cli-darwin-arm64/bin/supabase-go|private key block|fb278edfcf8e17967dd3a1ac5bfb5467e24c366a94e7efcee521dc750effa9ef",
  "Contents/Resources/ProviderRuntimes/node/node_modules/@supabase/cli-darwin-arm64/bin/supabase-go|secret environment assignment|352cae2702d8b3fb38b64bb38639a4346e505ed417e90ea411d032f252cee5e9",
  "Contents/Resources/ProviderRuntimes/node/node_modules/dotenv/README-es.md|private key block|fd6511dca4353a935a308c587dec2bc9beddc85c9c8de9151dd1dc8571e46733",
  "Contents/Resources/ProviderRuntimes/node/node_modules/dotenv/README.md|private key block|3893cbfb2cf07f272582a20227bb6510087bb80519f3d11c6c7149d46d2b8684",
  "Contents/Resources/ProviderRuntimes/node/node_modules/lambda-local/node_modules/dotenv/README-es.md|private key block|25e1aff422b4f5f069c088f683fa04ae7ac917ab500711fe66beb14ceaa45650",
  "Contents/Resources/ProviderRuntimes/node/node_modules/lambda-local/node_modules/dotenv/README.md|private key block|3f9d9d630c55f6d389dbbeeee23b5b795d97875ad59b84f05eaa86bbdaf08b58",
  "Contents/Resources/ProviderRuntimes/node/node_modules/miniflare/dist/src/index.js|private key block|3dd311499b864c12562634af0a469372d46ab2027d2024eeee8177ae20e46157",
  "Contents/Resources/ProviderRuntimes/node/node_modules/node-fetch-native/dist/proxy.cjs|secret environment assignment|2553d781a6d6123e62e855eb72eb3bb3069f5634716fec9d3e29f43d826ff778",
  "Contents/Resources/ProviderRuntimes/node/node_modules/wrangler/wrangler-dist/cli.js|private key block|5269a1238ad7788bef115210f06702ab6e0d18d60efdef5ba0a9a034c2217ad8",
  "Contents/Resources/ProviderRuntimes/node/node_modules/wrangler/wrangler-dist/cli.js|private key block|bc144e5069818db95fc7cdababfdc7467e796cb355d03159146867fa09bb37b2",
]);

const addFinding = (filePath, kind, value) => {
  findings.push({ filePath, kind, fingerprint: fingerprint(value) });
};

const scanFile = async (filePath) => {
  const contents = (await readFile(filePath)).toString("latin1");

  const privateKey = /-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----[\s\S]{100,}?-----END (?:[A-Z ]+ )?PRIVATE KEY-----/g;
  for (const match of contents.matchAll(privateKey)) {
    addFinding(filePath, "private key block", match[0]);
  }

  for (const pattern of credentialPatterns) {
    for (const match of contents.matchAll(pattern.expression)) {
      if (looksSecret(match[0])) {
        addFinding(filePath, pattern.name, match[0]);
        break;
      }
    }
  }

  const credentialURL = /https?:\/\/[^\s/:@]+:([^\s/@]+)@/g;
  for (const match of contents.matchAll(credentialURL)) {
    if (looksSecret(match[1] ?? "")) {
      addFinding(filePath, "credential-bearing URL", match[0]);
      break;
    }
  }

  const secretAssignment = /\b(?:[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE_KEY)[A-Z0-9_]*)=([A-Za-z0-9_+./=-]{20,})/g;
  for (const match of contents.matchAll(secretAssignment)) {
    if (looksSecret(match[1] ?? "")) {
      addFinding(filePath, "secret environment assignment", match[0]);
      break;
    }
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
      if (metadata.isFile()) await scanFile(entryPath);
    }
  }
};

await walk(bundlePath);

const unexpectedFindings = findings.filter((finding) => {
  const relativePath = path.relative(bundlePath, finding.filePath);
  return !auditedThirdPartyFixtures.has(`${relativePath}|${finding.kind}|${finding.fingerprint}`);
});

if (unexpectedFindings.length > 0) {
  for (const finding of unexpectedFindings) {
    const relativePath = path.relative(bundlePath, finding.filePath);
    const suffix = process.env.PORTDECK_PRINT_SECRET_ALLOWLIST === "YES"
      ? ` | ${relativePath}|${finding.kind}|${finding.fingerprint}`
      : "";
    console.error(`${finding.kind}: ${relativePath}${suffix}`);
  }
  throw new Error(`release bundle contains ${unexpectedFindings.length} unexpected high-confidence secret finding(s)`);
}

console.log(
  `Release bundle secret scan: no unexpected findings (${findings.length} exact third-party fixtures audited)`,
);
