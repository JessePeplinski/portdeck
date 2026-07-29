import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const normalizer = fileURLToPath(new URL("./normalize-sparkle-appcast.mjs", import.meta.url));

const item = (version, shortVersion = "0.1.0") => `
  <item>
    <title>PortDeck ${shortVersion}</title>
    <sparkle:version>${version}</sparkle:version>
    <sparkle:shortVersionString>${shortVersion}</sparkle:shortVersionString>
  </item>`;

const feed = (...items) => `<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>${items.join("")}
  </channel>
</rss>
`;

test("normalizes only the matching prerelease item", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "portdeck-appcast-"));
  const appcastPath = path.join(directory, "appcast.xml");

  try {
    await writeFile(appcastPath, feed(item("12"), item("13")));

    const result = spawnSync(
      process.execPath,
      [normalizer, appcastPath, "13", "0.1.0-beta.13"],
      { encoding: "utf8" }
    );

    assert.equal(result.status, 0, result.stderr);
    const normalized = await readFile(appcastPath, "utf8");
    assert.match(normalized, /<title>PortDeck 0\.1\.0-beta\.13<\/title>/);
    assert.match(
      normalized,
      /<sparkle:shortVersionString>0\.1\.0-beta\.13<\/sparkle:shortVersionString>/
    );
    assert.match(normalized, /<sparkle:shortVersionString>0\.1\.0<\/sparkle:shortVersionString>/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("rejects an ambiguous bundle version", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "portdeck-appcast-"));
  const appcastPath = path.join(directory, "appcast.xml");

  try {
    await writeFile(appcastPath, feed(item("13"), item("13")));

    const result = spawnSync(
      process.execPath,
      [normalizer, appcastPath, "13", "0.1.0-beta.13"],
      { encoding: "utf8" }
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /expected one appcast item for bundle version 13; found 2/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
