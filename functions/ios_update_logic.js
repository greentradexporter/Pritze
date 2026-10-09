"use strict";

// The iOS mirror of android_update_logic. Both answer the same question: what
// is the newest build a user can actually install right now?
//
// The App Store lookup reports a version *name* ("1.0.25"), never a build
// number, so the released build cannot be read directly the way the Play
// Developer API reports a versionCode. ios_release.json carries the mapping
// for the build being shipped, and the store tells us whether that version is
// live yet. Until it is, the floor is advertised: prompting people to install
// a build the store does not serve yet strands them on a dead "Update" button.

function positiveBuildNumber(value) {
  const parsed = Number.parseInt(String(value || ""), 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function versionAtLeast(value, minimum) {
  const parts = (version) => String(version || "")
      .split(/[+-]/, 1)[0]
      .split(".")
      .map((part) => Number.parseInt(part, 10) || 0);
  const actual = parts(value);
  const required = parts(minimum);
  const length = Math.max(actual.length, required.length);
  for (let index = 0; index < length; index++) {
    const actualPart = actual[index] || 0;
    const requiredPart = required[index] || 0;
    if (actualPart !== requiredPart) {
      return actualPart > requiredPart;
    }
  }
  return true;
}

function resolveIosUpdateVersion({
  lastConfirmedPublicBuild,
  candidateBuild,
  candidateVersionName,
  configuredBuild,
  storeVersionName,
}) {
  const floor = positiveBuildNumber(lastConfirmedPublicBuild) || 1;
  const candidate = Math.max(
      positiveBuildNumber(candidateBuild) || floor,
      positiveBuildNumber(configuredBuild) || floor,
  );
  const store = String(storeVersionName || "").trim();
  const wanted = String(candidateVersionName || "").trim();
  // Lookup failed, or no version name to compare against: stay at the floor.
  if (!store || !wanted) {
    return floor;
  }
  // The store has not published the candidate yet.
  if (!versionAtLeast(store, wanted)) {
    return floor;
  }
  return Math.max(floor, candidate);
}

module.exports = {
  resolveIosUpdateVersion,
  versionAtLeast,
};
