const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const indexSource = fs.readFileSync(path.join(__dirname, "index.js"), "utf8");
const backendSource = fs.readFileSync(
  path.join(__dirname, "proin_backend.js"),
  "utf8",
);

test("Phase 2 coupon writes stay server-only and idempotent", () => {
  assert.match(indexSource, /exports\.upsertProinCouponAsAdmin = onCall/);
  assert.match(indexSource, /exports\.claimProinCoupon = onMobileCall/);
  assert.match(indexSource, /collection: "proinCouponAttempts"/);
  assert.match(backendSource, /collection\("proinCouponClaims"\)/);
  assert.match(backendSource, /collection\("proinCouponUsage"\)/);
  assert.match(backendSource, /idempotencyKey = `coupon:/);
  assert.match(backendSource, /storesPlaintextCode: false/);
  assert.doesNotMatch(backendSource, /plaintextCode:/);
});

test("qualified referrals are role-separated and retry safely", () => {
  assert.match(indexSource, /exports\.awardProinOnReferralQualified/);
  assert.match(indexSource, /exports\.awardSalonReferralAfterFirstCompletedBooking/);
  assert.match(indexSource, /exports\.awardSalonReferralAfterAdminApproval/);
  assert.match(indexSource, /proinReferralApproved !== true/);
  assert.match(indexSource, /waiting_for_first_completed_booking/);
  assert.match(indexSource, /referral:\$\{referralId\}:\$\{program\.id\}/);
  assert.match(indexSource, /rewardRecipient === "inviter"/);
  assert.match(indexSource, /rewardRecipient === "referred"/);
  assert.match(indexSource, /exports\.retryPendingProinReferralAwards/);
});

test("reward and expiry notifications are one-time server jobs", () => {
  assert.match(indexSource, /sendProinRewardNotification/);
  assert.match(indexSource, /exports\.sendProinExpiryReminders = onSchedule/);
  assert.match(indexSource, /expiryReminder\$\{reminderTier\}dClaimedAt/);
  assert.match(indexSource, /expiryReminder\$\{reminderTier\}dSentAt/);
  assert.match(indexSource, /destination: "profile"/);
});
