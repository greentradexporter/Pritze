const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const projectRoot = path.join(__dirname, "..");
const functionSource = fs.readFileSync(path.join(__dirname, "index.js"), "utf8");
const ruleSource = fs.readFileSync(
  path.join(projectRoot, "firestore.rules"),
  "utf8",
);
const androidManifest = fs.readFileSync(
  path.join(projectRoot, "android/app/src/main/AndroidManifest.xml"),
  "utf8",
);
const iosInfo = fs.readFileSync(
  path.join(projectRoot, "ios/Runner/Info.plist"),
  "utf8",
);

test("Phase 4 arrival writes stay behind customer-owned callables", () => {
  for (const callable of [
    "updateCustomerArrivalStatus",
    "startCustomerArrivalSharing",
    "updateCustomerArrivalLocation",
    "stopCustomerArrivalSharing",
  ]) {
    assert.match(
      functionSource,
      new RegExp(`exports\\.${callable} = onMobileCall`),
    );
  }
  assert.match(functionSource, /requireCustomerArrivalBooking\(booking, uid\)/);
  assert.match(functionSource, /exports\.expireCustomerArrivalSharing = onSchedule/);
  assert.match(
    ruleSource,
    /match \/bookingArrivalSessions\/\{bookingId\} \{\s*allow read, write: if false;/,
  );
});

test("native permissions are foreground-only", () => {
  assert.match(androidManifest, /android\.permission\.ACCESS_FINE_LOCATION/);
  assert.doesNotMatch(androidManifest, /ACCESS_BACKGROUND_LOCATION/);
  assert.match(iosInfo, /NSLocationWhenInUseUsageDescription/);
  assert.doesNotMatch(iosInfo, /<string>location<\/string>/);
});
