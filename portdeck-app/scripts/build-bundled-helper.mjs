import { build } from "esbuild";
import { chmod, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

export async function buildBundledHelper({ outfile, noticesFile }) {
  const resolvedOutput = path.resolve(outfile);
  const resolvedNotices = path.resolve(noticesFile);
  await mkdir(path.dirname(resolvedOutput), { recursive: true });
  await mkdir(path.dirname(resolvedNotices), { recursive: true });

  const result = await build({
    absWorkingDir: packageRoot,
    entryPoints: ["src/cli.ts"],
    outfile: resolvedOutput,
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node24",
    banner: {
      js: 'import { createRequire as __portdeckCreateRequire } from "node:module"; const require = __portdeckCreateRequire(import.meta.url);'
    },
    charset: "utf8",
    legalComments: "none",
    metafile: true,
    sourcemap: false,
    treeShaking: true
  });

  await chmod(resolvedOutput, 0o755);
  await writeFile(resolvedNotices, await thirdPartyNotices(result.metafile.inputs), "utf8");
}

async function thirdPartyNotices(inputs) {
  const packageRoots = new Set();
  for (const input of Object.keys(inputs)) {
    const absoluteInput = path.resolve(packageRoot, input);
    const segments = absoluteInput.split(path.sep);
    const nodeModulesIndex = segments.lastIndexOf("node_modules");
    if (nodeModulesIndex < 0 || nodeModulesIndex + 1 >= segments.length) continue;
    const packageEnd = segments[nodeModulesIndex + 1].startsWith("@")
      ? nodeModulesIndex + 3
      : nodeModulesIndex + 2;
    packageRoots.add(segments.slice(0, packageEnd).join(path.sep));
  }

  const packages = [];
  for (const root of packageRoots) {
    const manifest = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));
    const licenseFiles = (await readdir(root))
      .filter((name) => /^(license|licence|copying|notice)(\..*)?$/i.test(name))
      .sort(compareText);
    if (licenseFiles.length === 0) {
      throw new Error(`Bundled package ${manifest.name}@${manifest.version} has no license or notice file.`);
    }
    packages.push({
      name: manifest.name,
      version: manifest.version,
      license: manifest.license ?? "Not declared",
      files: await Promise.all(licenseFiles.map(async (name) => ({
        name,
        contents: normalize(await readFile(path.join(root, name), "utf8"))
      })))
    });
  }

  packages.sort((left, right) => compareText(left.name, right.name));
  const sections = packages.map((item) => [
    "================================================================================",
    `${item.name} ${item.version}`,
    `Declared license: ${item.license}`,
    "",
    ...item.files.flatMap((file) => [`--- ${file.name} ---`, file.contents])
  ].join("\n"));

  return normalize([
    "PortDeck bundled helper third-party notices",
    "",
    "This file contains the license and notice material for packages included",
    "in the bundled PortDeck local discovery helper.",
    "",
    ...sections
  ].join("\n"));
}

function normalize(value) {
  return `${value.replaceAll("\r\n", "\n").trimEnd()}\n`;
}

function compareText(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  if (!value) throw new Error(`Missing required ${name} argument.`);
  return value;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await buildBundledHelper({
    outfile: argumentValue("--outfile"),
    noticesFile: argumentValue("--notices-file")
  });
}
