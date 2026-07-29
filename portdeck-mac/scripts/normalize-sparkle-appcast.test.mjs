import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const normalizer = fileURLToPath(new URL("./normalize-sparkle-appcast.mjs", import.meta.url));
const appcastGenerator = fileURLToPath(
  new URL("./generate-sparkle-appcast.sh", import.meta.url)
);
const releaseBuilder = fileURLToPath(
  new URL("./build-github-zip-release.sh", import.meta.url)
);
const releaseConfig = fileURLToPath(new URL("./release-config.sh", import.meta.url));
const releaseVerifier = fileURLToPath(
  new URL("./verify-github-zip-release.sh", import.meta.url)
);

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

test("uses the signed DMG as the Sparkle update enclosure", async () => {
  const generator = await readFile(appcastGenerator, "utf8");

  assert.match(
    generator,
    /release_update="\$artifact_root\/\$release_dmg"/
  );
  assert.match(
    generator,
    /ditto "\$release_update" "\$staging_root\/\$release_dmg"/
  );
  assert.match(
    generator,
    /Enclosure: .*\/\$\{release_dmg\}/
  );
  assert.doesNotMatch(generator, /release_zip/);
});

test("verifies the signed feed with the PortDeck Keychain account", async () => {
  const generator = await readFile(appcastGenerator, "utf8");

  assert.match(
    generator,
    /"\$sign_update"\s+\\\n\s+--account "\$sparkle_keychain_account"\s+\\\n\s+--verify\s+\\/
  );
});

test("pins and verifies the signed-feed recovery window", async () => {
  const configResult = spawnSync(
    "/bin/bash",
    [
      "-c",
      'source "$1"; printf "%s" "$sparkle_signed_feed_failure_expiration_interval"',
      "_",
      releaseConfig
    ],
    { encoding: "utf8" }
  );
  const builder = await readFile(releaseBuilder, "utf8");
  const verifier = await readFile(releaseVerifier, "utf8");

  assert.equal(configResult.status, 0, configResult.stderr);
  assert.equal(configResult.stdout, "1728000");
  assert.match(builder, /SUSignedFeedFailureExpirationInterval/);
  assert.match(verifier, /SUSignedFeedFailureExpirationInterval/);
});

test("pins the PortDeck Sparkle public key in release configuration", () => {
  const configResult = spawnSync(
    "/bin/bash",
    [
      "-c",
      'source "$1"; printf "%s" "$sparkle_public_ed_key"',
      "_",
      releaseConfig
    ],
    { encoding: "utf8" }
  );

  assert.equal(configResult.status, 0, configResult.stderr);
  assert.equal(
    configResult.stdout,
    "ItVdh8w/+EkY1dkgwY0/6NJeK3QKlXzhrrSk/JeMgRw="
  );
});
