"use strict";

function positiveVersionCode(value) {
  const parsed = Number.parseInt(String(value || ""), 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function highestPublishedVersionCode(payload) {
  const releases = Array.isArray(payload?.releases) ? payload.releases : [];
  let highest = null;
  for (const release of releases) {
    if (release?.releaseLifecycleState !==
        "RELEASE_LIFECYCLE_STATE_PUBLISHED") {
      continue;
    }
    const artifacts = Array.isArray(release.activeArtifacts) ?
      release.activeArtifacts : [];
    for (const artifact of artifacts) {
      const versionCode = positiveVersionCode(artifact?.versionCode);
      if (versionCode !== null &&
          (highest === null || versionCode > highest)) {
        highest = versionCode;
      }
    }
  }
  return highest;
}

function resolveAndroidUpdateVersion({
  lastConfirmedPublicVersion,
  candidateVersion,
  configuredVersion,
  playPublishedVersion,
}) {
  const lastConfirmed = positiveVersionCode(lastConfirmedPublicVersion) || 1;
  const candidate = Math.max(
    positiveVersionCode(candidateVersion) || lastConfirmed,
    positiveVersionCode(configuredVersion) || lastConfirmed,
  );
  const published = positiveVersionCode(playPublishedVersion);
  if (published === null) {
    return lastConfirmed;
  }
  return Math.max(lastConfirmed, Math.min(candidate, published));
}

module.exports = {
  highestPublishedVersionCode,
  resolveAndroidUpdateVersion,
};
