const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const source = fs.readFileSync(path.join(__dirname, "index.js"), "utf8");
const callable = source.slice(
  source.indexOf("exports.getCompletedBookingUpiPaymentDetails"),
  source.indexOf("exports.getAdminPhaseOneData"),
);

test("completed-booking UPI callable is App Check and customer protected", () => {
  assert.match(callable, /enforceAppCheck: true/);
  assert.match(callable, /requireAuthenticatedUid\(request\)/);
  assert.match(callable, /requireStoredRole\(userSnapshot\.data\(\), "customer"\)/);
  assert.match(callable, /booking\.customerUid/);
  assert.match(callable, /booking\.status !== "completed"/);
  assert.match(callable, /collection\("salonPaymentProfiles"\)/);
});

test("payment-details callable is read-only and does not mark a payment", () => {
  assert.doesNotMatch(callable, /\.set\(|\.update\(|\.create\(|\.delete\(/);
  assert.doesNotMatch(callable, /paymentStatus|payment record|paid/i);
});
