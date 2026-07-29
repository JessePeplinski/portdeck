#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";

const [feedPath, bundleVersion, releaseVersion] = process.argv.slice(2);
if (!feedPath || !bundleVersion || !releaseVersion) {
  throw new Error(
    "usage: normalize-sparkle-appcast.mjs <appcast.xml> <bundle-version> <release-version>"
  );
}

const escapeXML = (value) =>
  value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");

const feed = await readFile(feedPath, "utf8");
const itemPattern = /<item>[\s\S]*?<\/item>/g;
const items = feed.match(itemPattern) ?? [];
const versionPattern = new RegExp(
  `<sparkle:version>\\s*${bundleVersion.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*</sparkle:version>`
);
const matchingItems = items.filter((item) => versionPattern.test(item));

if (matchingItems.length !== 1) {
  throw new Error(
    `expected one appcast item for bundle version ${bundleVersion}; found ${matchingItems.length}`
  );
}

const originalItem = matchingItems[0];
const displayVersion = escapeXML(releaseVersion);
let normalizedItem = originalItem.replace(
  /<title>[\s\S]*?<\/title>/,
  `<title>PortDeck ${displayVersion}</title>`
);

if (/<sparkle:shortVersionString>[\s\S]*?<\/sparkle:shortVersionString>/.test(normalizedItem)) {
  normalizedItem = normalizedItem.replace(
    /<sparkle:shortVersionString>[\s\S]*?<\/sparkle:shortVersionString>/,
    `<sparkle:shortVersionString>${displayVersion}</sparkle:shortVersionString>`
  );
} else {
  normalizedItem = normalizedItem.replace(
    versionPattern,
    (versionElement) =>
      `${versionElement}\n            <sparkle:shortVersionString>${displayVersion}</sparkle:shortVersionString>`
  );
}

const normalizedFeed = feed.replace(originalItem, normalizedItem);
await writeFile(feedPath, normalizedFeed);
