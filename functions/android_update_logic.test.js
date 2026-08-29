const assert = require("node:assert/strict");
const test = require("node:test");

const {
  highestPublishedVersionCode,
  resolveAndroidUpdateVersion,
} = require("./android_update_logic");

test("only a Play-published Android release can activate a candidate", () => {
  const payload = {
    releases: [
      {
        releaseLifecycleState: "RELEASE_LIFECYCLE_STATE_IN_REVIEW",
        activeArtifacts: [{versionCode: 32}],
      },
      {
        releaseLifecycleState: "RELEASE_LIFECYCLE_STATE_PUBLISHED",
        activeArtifacts: [{versionCode: 31}],
      },
    ],
  };

  assert.equal(highestPublishedVersionCode(payload), 31);
  assert.equal(resolveAndroidUpdateVersion({
    lastConfirmedPublicVersion: 30,
    candidateVersion: 32,
    configuredVersion: 32,
    playPublishedVersion: highestPublishedVersionCode(payload),
  }), 31);
});

test("an unavailable build never becomes the mandatory fallback", () => {
  assert.equal(resolveAndroidUpdateVersion({
    lastConfirmedPublicVersion: 30,
    candidateVersion: 32,
    configuredVersion: 32,
    playPublishedVersion: null,
  }), 30);
  assert.equal(resolveAndroidUpdateVersion({
    lastConfirmedPublicVersion: 30,
    candidateVersion: 32,
    configuredVersion: 99,
    playPublishedVersion: 32,
  }), 32);
});
