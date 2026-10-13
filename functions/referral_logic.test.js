const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const {
  REFERRAL_CODE_PATTERN,
  generateReferralCode,
  normalizeReferralCode,
  referralRewardSummary,
  referralTargetAllowed,
  salonReferralsAwaitingReward,
} = require("./referral_logic");

test("referral codes are six characters with letters and numbers", () => {
  for (let index = 0; index < 100; index += 1) {
    assert.match(generateReferralCode(), REFERRAL_CODE_PATTERN);
  }
});

test("referral input is normalized and malformed codes are rejected", () => {
  assert.equal(normalizeReferralCode(" ab12cd "), "AB12CD");
  assert.equal(normalizeReferralCode("ABCDEF"), "");
  assert.equal(normalizeReferralCode("123456"), "");
  assert.equal(normalizeReferralCode("AB-123"), "");
});

test("customer codes cannot register salons and salon codes cannot register customers", () => {
  assert.equal(referralTargetAllowed("customer", "customer"), true);
  assert.equal(referralTargetAllowed("owner", "owner"), true);
  assert.equal(referralTargetAllowed("customer", "owner"), false);
  assert.equal(referralTargetAllowed("owner", "customer"), false);
});

test("active referral campaigns provide dynamic rewards and earned totals", () => {
  const nowMillis = 1_000_000;
  const summary = referralRewardSummary({
    inviterUid: "customer-1",
    inviterRole: "customer",
    nowMillis,
    programs: [
      {
        sourceType: "referral_customer",
        active: true,
        referralInviterRole: "customer",
        rewardRecipient: "inviter",
        rewardAmountProin: 55,
        startsAtMillis: nowMillis - 1,
        endsAtMillis: nowMillis + 1,
      },
      {
        sourceType: "referral_customer",
        active: true,
        referralInviterRole: "customer",
        rewardRecipient: "referred",
        rewardAmountProin: 35,
        startsAtMillis: nowMillis - 1,
        endsAtMillis: nowMillis + 1,
      },
      {
        sourceType: "referral_customer",
        active: false,
        referralInviterRole: "customer",
        rewardRecipient: "inviter",
        rewardAmountProin: 999,
        startsAtMillis: nowMillis - 1,
        endsAtMillis: nowMillis + 1,
      },
    ],
    referrals: [{
      referralId: "referral-1",
      inviterUid: "customer-1",
      referredUid: "customer-2",
      referredRole: "customer",
      proinAwards: [
        {recipient: "inviter", amountProin: 55},
        {recipient: "referred", amountProin: 35},
      ],
    }],
  });

  assert.equal(summary.customerInviterRewardProin, 55);
  assert.equal(summary.customerReferredRewardProin, 35);
  assert.equal(summary.earnedCustomerReferralProin, 55);
  assert.equal(summary.earnedReferralProin, 55);
});

test("referral rewards exclude expired campaigns and other recipients", () => {
  const summary = referralRewardSummary({
    inviterUid: "owner-1",
    inviterRole: "owner",
    nowMillis: 5_000,
    programs: [{
      sourceType: "referral_salon",
      active: true,
      referralInviterRole: "owner",
      rewardRecipient: "inviter",
      rewardAmountProin: 500,
      startsAtMillis: 1_000,
      endsAtMillis: 4_999,
    }],
    referrals: [{
      referralId: "referral-2",
      inviterUid: "owner-2",
      referredUid: "owner-1",
      referredRole: "owner",
      proinAwards: [
        {recipient: "inviter", amountProin: 500},
        {recipient: "referred", amountProin: 500},
      ],
    }],
  });

  assert.equal(summary.salonInviterRewardProin, 0);
  assert.equal(summary.earnedSalonReferralProin, 500);
  assert.equal(summary.earnedReferralProin, 500);
});

test("a referred salon stays pending until its reward can be paid", () => {
  const salon = (proinAwardStatus, extra = {}) => ({
    inviterUid: "owner-1",
    referredRole: "owner",
    status: "qualified",
    proinAwardStatus,
    ...extra,
  });
  assert.equal(salonReferralsAwaitingReward({
    inviterUid: "owner-1",
    referrals: [
      salon(undefined),
      salon("waiting_for_admin_approval"),
      salon("waiting_for_first_completed_booking"),
      salon("awarded"),
      salon("waiting_for_program"),
      salon("partial_or_retry"),
      salon("waiting_for_admin_approval", {inviterUid: "owner-2"}),
      salon("waiting_for_admin_approval", {status: "pending"}),
      salon(undefined, {referredRole: "customer"}),
    ],
  }), 3);
  assert.equal(salonReferralsAwaitingReward(), 0);

  const source = fs.readFileSync(path.join(__dirname, "index.js"), "utf8");
  assert.match(source, /money\(data\.pendingSalonCount\) \+ salonsAwaitingReward/);
  assert.match(source, /money\(data\.qualifiedSalonCount\) - salonsAwaitingReward/);
  assert.match(source, /proinBackend\.nextReferralAwardScanPage\(/);
  assert.match(source, /proinBackend\.nextPendingCashbackScanPage\(/);
});

test("referral codes and one-time redemptions are reserved transactionally", () => {
  const source = fs.readFileSync(path.join(__dirname, "index.js"), "utf8");
  assert.match(source, /exports\.getReferralCodes[\s\S]*runTransaction/);
  assert.match(source, /collection\("referralCodes"\)\.doc/);
  assert.match(source, /exports\.completeReferralOnboarding[\s\S]*runTransaction/);
  assert.match(source, /collection\("referrals"\)\.doc\(uid\)/);
  assert.match(source, /referralOnboardingCompleted: true/);
  assert.match(source, /referralOnboardingCompleted !== false/);
  assert.match(source, /status: "pending"/);
  assert.match(source, /qualifySalonReferralOnSalonCreated/);
  assert.match(source, /qualificationBookingId/);
  assert.match(source, /enforceReferralAttemptLimit/);
  assert.match(source, /referralInviteLimit/);
  assert.match(source, /maximumInvitesPerAccount/);
  assert.match(source, /pendingCustomerCount/);
  assert.match(source, /pendingSalonCount/);
});

test("administrators can edit referral codes only through an audited callable", () => {
  const source = fs.readFileSync(path.join(__dirname, "index.js"), "utf8");
  assert.match(source, /exports\.updateReferralCodeAsAdmin = onCall/);
  assert.match(source, /requirePlatformAdministrator\(request\)/);
  assert.match(source, /requiredAdminReason\(request\.data\?\.reason\)/);
  assert.match(source, /function referralCodeUserField/);
  assert.match(source, /customerReferralCode/);
  assert.match(source, /ownerCustomerReferralCode/);
  assert.match(source, /ownerSalonReferralCode/);
  assert.match(source, /"This referral code is already assigned to another account\."/);
  assert.match(source, /replacedByCode: newCode/);
  assert.match(source, /transaction\.create\(newRef, after\)/);
  assert.match(source, /action: currentCode === newCode \?/);
  assert.match(source, /"referral\.code_updated" : "referral\.code_replaced"/);
});
