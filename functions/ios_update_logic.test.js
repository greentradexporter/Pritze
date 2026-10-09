const assert = require("node:assert/strict");
const test = require("node:test");
const {resolveIosUpdateVersion} = require("./ios_update_logic");
const iosRelease = require("./ios_release.json");

const resolve = (overrides) => resolveIosUpdateVersion({
  lastConfirmedPublicBuild: 28,
  candidateBuild: 46,
  candidateVersionName: "1.0.25",
  configuredBuild: 28,
  storeVersionName: "1.0.25",
  ...overrides,
});

test("the shipped build is advertised once the App Store serves it", () => {
  assert.equal(resolve({}), 46);
  // A later store version than the one we built still means ours is live.
  assert.equal(resolve({storeVersionName: "1.0.26"}), 46);
});

test("a build the store has not published yet is never advertised", () => {
  // This is the state that was broken: the store sat at 1.0.20 while the
  // constants claimed 1.0.16/29, so every iOS user was pinned to build 29
  // and never prompted again. The floor is correct here; the bug was that
  // the ceiling could never move past it.
  assert.equal(resolve({storeVersionName: "1.0.20"}), 28);
  assert.equal(resolve({storeVersionName: "1.0.24"}), 28);
});

test("a failed or empty App Store lookup falls back to the floor", () => {
  assert.equal(resolve({storeVersionName: ""}), 28);
  assert.equal(resolve({storeVersionName: null}), 28);
  assert.equal(resolve({candidateVersionName: ""}), 28);
});

test("a Firestore override can raise but not lower the advertised build", () => {
  assert.equal(resolve({configuredBuild: 50}), 50);
  assert.equal(resolve({configuredBuild: 1}), 46);
  // Below the floor is ignored entirely.
  assert.equal(resolve({configuredBuild: 5, candidateBuild: 5}), 28);
});

test("malformed inputs degrade to the floor rather than throwing", () => {
  assert.equal(resolve({candidateBuild: "not-a-number"}), 28);
  assert.equal(resolve({candidateBuild: -3, configuredBuild: 0}), 28);
  assert.equal(resolve({lastConfirmedPublicBuild: "x", candidateBuild: 0,
    configuredBuild: 0}), 1);
});

test("ios_release.json stays in step with the build being shipped", () => {
  const fs = require("node:fs");
  const pubspec = fs.readFileSync("../pubspec.yaml", "utf8");
  const match = pubspec.match(/^version:\s*([0-9.]+)\+([0-9]+)/m);
  assert.ok(match, "pubspec.yaml has no version line");
  assert.equal(
      iosRelease.versionName,
      match[1],
      "ios_release.json versionName must match pubspec.yaml",
  );
  assert.equal(
      Number(iosRelease.candidateBuildNumber),
      Number(match[2]),
      "ios_release.json candidateBuildNumber must match pubspec.yaml",
  );
});
