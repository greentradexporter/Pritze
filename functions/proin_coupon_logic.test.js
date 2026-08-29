const assert = require("node:assert/strict");
const test = require("node:test");
const {
  maskProinCouponCode,
  normalizeProinCouponCode,
  normalizeProinCouponInput,
  proinCouponClaimAllowed,
  proinCouponHash,
} = require("./proin_coupon_logic");

test("coupon codes normalize, hash and mask without storing plaintext", () => {
  assert.equal(normalizeProinCouponCode(" save50 "), "SAVE50");
  assert.equal(normalizeProinCouponCode("SAVE"), "SAVE");
  assert.equal(normalizeProinCouponCode("ONLYLETTERS"), "ONLYLETTERS");
  assert.equal(normalizeProinCouponCode("ABC"), "");
  assert.equal(normalizeProinCouponCode("123456"), "");
  assert.match(proinCouponHash("SAVE50"), /^[a-f0-9]{64}$/);
  assert.equal(maskProinCouponCode("SAVE50"), "SA••50");
});

test("coupon configuration separates claim dates from reward validity", () => {
  const normalized = normalizeProinCouponInput({
    code: "WELCOME25",
    programId: "coupon_welcome",
    active: true,
    claimStartsAtMillis: 100,
    claimEndsAtMillis: 1000,
    maximumClaimsTotal: 500,
    eligibleCustomerUids: ["customer-b", "customer-a"],
    eligibleSalonIds: ["salon-b", "salon-a"],
    termsVersion: "coupon-v1",
  });
  assert.equal(normalized.codeHash, proinCouponHash("WELCOME25"));
  assert.equal(normalized.maximumClaimsPerAccount, 1);
  assert.deepEqual(
    normalized.eligibleCustomerUids,
    ["customer-a", "customer-b"],
  );
  assert.deepEqual(normalized.eligibleSalonIds, ["salon-a", "salon-b"]);
});

test("coupon eligibility protects dates, audience and concurrent limits", () => {
  const coupon = {
    active: true,
    claimStartsAt: 100,
    claimEndsAt: 1000,
    maximumClaimsTotal: 2,
    eligibleCustomerUids: ["customer-1"],
  };
  assert.equal(proinCouponClaimAllowed({
    coupon,
    usage: {claimedCount: 1},
    uid: "customer-1",
    nowMillis: 500,
  }).allowed, true);
  assert.equal(proinCouponClaimAllowed({
    coupon,
    usage: {claimedCount: 1, reservedClaims: 1},
    uid: "customer-1",
    nowMillis: 500,
  }).allowed, false);
  assert.equal(proinCouponClaimAllowed({
    coupon,
    usage: {},
    uid: "customer-2",
    nowMillis: 500,
  }).allowed, false);
});

test("coupon eligibility can target selected salons", () => {
  const coupon = {
    active: true,
    claimStartsAt: 100,
    claimEndsAt: 1000,
    maximumClaimsTotal: 5,
    eligibleSalonIds: ["salon-1"],
  };
  assert.equal(proinCouponClaimAllowed({
    coupon,
    usage: {},
    uid: "owner-1",
    accountId: "salon-1",
    walletType: "salon_promotion_credits",
    nowMillis: 500,
  }).allowed, true);
  assert.equal(proinCouponClaimAllowed({
    coupon,
    usage: {},
    uid: "owner-2",
    accountId: "salon-2",
    walletType: "salon_promotion_credits",
    nowMillis: 500,
  }).allowed, false);
});
