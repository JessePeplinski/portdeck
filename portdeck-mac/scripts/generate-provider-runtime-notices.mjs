#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import spdxLicenseList from "spdx-license-list/full.js";

const [installRoot, rootLockfile, noticesPath, manifestPath] = process.argv.slice(2);

if (!installRoot || !rootLockfile || !noticesPath || !manifestPath) {
  throw new Error(
    "usage: generate-provider-runtime-notices.mjs <install-root> <root-lockfile> <notices> <manifest>",
  );
}

const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const rootLockfileContents = await readFile(rootLockfile);
const installedLockfilePath = path.join(installRoot, "node_modules", ".package-lock.json");
const installedLockfile = JSON.parse(await readFile(installedLockfilePath, "utf8"));

const normalizeLicense = (license) => {
  if (typeof license === "string" && license.trim()) return license.trim();
  if (Array.isArray(license)) {
    const values = license
      .map((entry) => (typeof entry === "string" ? entry : entry?.type))
      .filter(Boolean);
    if (values.length) return [...new Set(values)].join(" OR ");
  }
  if (license && typeof license === "object") return JSON.stringify(license);
  return "NOASSERTION";
};

const licenseOverrides = new Map([
  ["callsite@1.0.0", "MIT"],
  ["precond@0.2.3", "MIT"],
]);
const licenseEvidenceFiles = new Map([["callsite@1.0.0", ["Readme.md"]]]);
const licenseFilePattern = /^(licen[cs]e|copying|notice)([._-].+)?$/i;
const packages = [];
const noticeSections = [];
const canonicalSPDXLicenses = new Map();

const canonicalLicenseEvidence = (expression, packageKey) => {
  const identifiers = expression.split(/\s+OR\s+/);
  const licenses = identifiers.map((identifier) => {
    const entry = spdxLicenseList[identifier];
    if (!entry?.licenseText) {
      throw new Error(`installed package lacks license files and ${identifier} has no canonical SPDX text: ${packageKey}`);
    }
    const textSha256 = sha256(entry.licenseText);
    canonicalSPDXLicenses.set(identifier, {
      identifier,
      name: entry.name,
      url: entry.url,
      text: entry.licenseText,
      textSha256,
    });
    return { identifier, textSha256 };
  });
  return [{
    kind: "spdx-text",
    expression,
    sourcePackage: "spdx-license-list@6.11.0",
    licenses,
  }];
};

for (const relativePackagePath of Object.keys(installedLockfile.packages ?? {}).sort()) {
  if (!relativePackagePath.startsWith("node_modules/")) continue;

  const packageDirectory = path.join(installRoot, relativePackagePath);
  const packageJsonPath = path.join(packageDirectory, "package.json");
  let packageJson;
  try {
    packageJson = JSON.parse(await readFile(packageJsonPath, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") continue;
    throw new Error(`installed package is missing readable metadata: ${relativePackagePath}`);
  }

  if (!packageJson.name || !packageJson.version) {
    throw new Error(`installed package has incomplete metadata: ${relativePackagePath}`);
  }

  const packageKey = `${packageJson.name}@${packageJson.version}`;
  const license = normalizeLicense(
    packageJson.license
      ?? packageJson.licenses
      ?? installedLockfile.packages[relativePackagePath].license
      ?? licenseOverrides.get(packageKey),
  );
  if (license === "NOASSERTION") {
    throw new Error(`installed package has no auditable license declaration: ${packageKey}`);
  }
  const entries = await readdir(packageDirectory, { withFileTypes: true });
  const licenseFiles = [...new Set([
    ...entries
    .filter((entry) => entry.isFile() && licenseFilePattern.test(entry.name))
    .map((entry) => entry.name),
    ...(licenseEvidenceFiles.get(packageKey) ?? []),
  ])].sort();
  const licenseEvidence = licenseFiles.length > 0
    ? licenseFiles.map((licenseFile) => ({ kind: "package-file", path: licenseFile }))
    : canonicalLicenseEvidence(license, packageKey);

  packages.push({
    name: packageJson.name,
    version: packageJson.version,
    license,
    path: relativePackagePath,
    licenseFiles,
    licenseEvidence,
  });

  const section = [
    "=".repeat(80),
    `${packageJson.name}@${packageJson.version}`,
    `License: ${license}`,
    `Installed path: ${relativePackagePath}`,
  ];
  if (licenseFiles.length === 0) {
    section.push(
      "License file: not included by the upstream npm package",
      `License evidence: canonical SPDX text for ${license}`,
    );
  }
  for (const licenseFile of licenseFiles) {
    section.push("", `--- ${licenseFile} ---`, await readFile(path.join(packageDirectory, licenseFile), "utf8"));
  }
  noticeSections.push(section.join("\n"));
}

const requiredPackages = {
  convex: { path: "node_modules/convex", version: "1.42.1" },
  supabase: { path: "node_modules/supabase", version: "2.109.1" },
  wrangler: { path: "node_modules/wrangler", version: "4.111.0" },
  railway: { path: "node_modules/@railway/cli", version: "5.26.2" },
  netlify: { path: "node_modules/netlify-cli", version: "26.2.0" },
};

for (const [provider, required] of Object.entries(requiredPackages)) {
  const installedPackage = packages.find((candidate) => candidate.path === required.path);
  if (!installedPackage || installedPackage.version !== required.version) {
    throw new Error(`${provider} is not installed at the required version ${required.version}`);
  }
}

const manifest = {
  schemaVersion: "1",
  spdxLicenseListVersion: "6.11.0",
  rootLockfileSha256: sha256(rootLockfileContents),
  packageCount: packages.length,
  providerVersions: Object.fromEntries(
    Object.entries(requiredPackages).map(([provider, value]) => [provider, value.version]),
  ),
  nativeRuntimes: {
    railway: {
      version: "5.26.2",
      architecture: "arm64",
      archiveSha256: "816414da5f182d8ee7ed66f6cf607bf5d37f8e55d367395e8133ef321e9f8ee4",
      licenseFile: "Railway-LICENSE.txt",
    },
    flyctl: {
      version: "0.4.71",
      architecture: "arm64",
      archiveSha256: "a89085595d7da7d4ee3a8647feb700a52702eb835591e78feae47fcd2d98bfbe",
      licenseFile: "flyctl-LICENSE.txt",
    },
  },
  prunedPackages: [
    {
      name: "@netlify/ai",
      version: "0.4.2",
      reason: "Not used by PortDeck's sites:list or listSiteDeploys allowlist; upstream package has no license declaration or license file.",
    },
    {
      name: "fsevents",
      version: "2.3.3",
      reason: "Optional watcher dependency; not used by PortDeck's read-only provider commands and upstream binary is universal.",
    },
  ],
  packages,
};

const noticeHeader = [
  "PortDeck managed provider runtime third-party notices",
  "",
  "This file is generated from the production-only npm install created directly",
  "from PortDeck's root lockfile. Package license files are reproduced below when",
  "the upstream package includes them. When an upstream npm package contains only",
  "an SPDX declaration, the matching canonical SPDX text from spdx-license-list",
  "6.11.0 is reproduced in the appendix. Railway and flyctl native licenses are",
  "shipped as separate files beside this notice.",
  "",
].join("\n");

const spdxAppendix = [...canonicalSPDXLicenses.values()]
  .sort((left, right) => left.identifier.localeCompare(right.identifier))
  .map((entry) => [
    "=".repeat(80),
    `Canonical SPDX license text: ${entry.identifier}`,
    `Name: ${entry.name}`,
    `Source: ${entry.url}`,
    `SHA-256: ${entry.textSha256}`,
    "",
    entry.text,
  ].join("\n"))
  .join("\n\n");

await writeFile(
  noticesPath,
  `${noticeHeader}${noticeSections.join("\n\n")}\n\n${spdxAppendix}\n`,
);
await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
