import {readFileSync, writeFileSync} from "node:fs";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";
import {dirname, join, resolve} from "node:path";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = resolve(scriptDirectory, "..");
const pubspec = readFileSync(join(projectDirectory, "pubspec.yaml"), "utf8");
const versionMatch = pubspec.match(/^version:\s*([^+\s]+)\+(\d+)\s*$/m);

if (!versionMatch) {
  throw new Error("pubspec.yaml must contain version: <name>+<build number>.");
}

const [, versionName, buildNumberText] = versionMatch;
const buildNumber = Number.parseInt(buildNumberText, 10);
const releaseMetadataPath = join(
  projectDirectory,
  "functions",
  "android_release.json",
);

writeFileSync(
  releaseMetadataPath,
  `${JSON.stringify({
    candidateVersionCode: buildNumber,
    versionName,
  }, null, 2)}\n`,
);

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: projectDirectory,
    stdio: "inherit",
  });
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

run("flutter", ["build", "appbundle", "--release"]);
run("firebase", [
  "deploy",
  "--only",
  "functions:getAndroidAppUpdate",
  "--project",
  "trimtime-46539",
]);

console.log(
  `Android ${versionName} (${buildNumber}) is built and registered as the ` +
    "next update candidate. It will activate only after Google Play reports " +
    "the production release as published.",
);
