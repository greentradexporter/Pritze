const crypto = require("node:crypto");
const {ProinValidationError, proinInteger} = require("./proin_logic");

// Short campaign names such as SAVE or GLOW are intentionally valid. Requiring
// at least one letter keeps numeric-only values from being mistaken for OTPs.
const PROIN_COUPON_PATTERN = /^(?=.*[A-Z])[A-Z\d]{4,20}$/;

function normalizeProinCouponCode(value) {
  const code = String(value ?? "").trim().toUpperCase();
  return PROIN_COUPON_PATTERN.test(code) ? code : "";
}

function proinCouponHash(code) {
  const normalized = normalizeProinCouponCode(code);
  if (!normalized) return "";
  return crypto.createHash("sha256").update(normalized).digest("hex");
}

function maskProinCouponCode(code) {
  const normalized = normalizeProinCouponCode(code);
  if (!normalized) return "";
  return `${normalized.slice(0, 2)}${"•".repeat(
    Math.max(2, normalized.length - 4),
  )}${normalized.slice(-2)}`;
}

function normalizeProinCouponInput(input = {}) {
  const code = normalizeProinCouponCode(input.code);
  if (!code) {
    throw new ProinValidationError(
      "Coupon codes must contain 4-20 letters or numbers and at least one letter.",
    );
  }
  const programId = requiredCouponText(input.programId, "program id", 80);
  const claimStartsAtMillis = couponMillis(
    input.claimStartsAtMillis,
    "Coupon claim start",
  );
  const claimEndsAtMillis = couponMillis(
    input.claimEndsAtMillis,
    "Coupon claim end",
  );
  if (claimEndsAtMillis <= claimStartsAtMillis) {
    throw new ProinValidationError(
      "Coupon claim end must be after its start.",
    );
  }
  const maximumClaimsTotal = proinInteger(
    input.maximumClaimsTotal,
    "Maximum coupon claims",
    {allowZero: false},
  );
  const eligibleCustomerUids = couponIdList(
    input.eligibleCustomerUids,
    "Eligible customer IDs",
  );
  const eligibleSalonIds = couponIdList(
    input.eligibleSalonIds,
    "Eligible salon IDs",
  );
  return {
    code,
    codeHash: proinCouponHash(code),
    maskedCode: maskProinCouponCode(code),
    programId,
    active: input.active === true,
    claimStartsAtMillis,
    claimEndsAtMillis,
    maximumClaimsTotal,
    maximumClaimsPerAccount: 1,
    eligibleCustomerUids,
    eligibleSalonIds,
    termsVersion: requiredCouponText(
      input.termsVersion,
      "coupon terms version",
      40,
    ),
  };
}

function proinCouponClaimAllowed({
  coupon,
  usage = {},
  uid,
  accountId,
  walletType = "customer_rewards",
  nowMillis,
}) {
  if (coupon?.active !== true) {
    return {allowed: false, reason: "This coupon is not active."};
  }
  const startsAt = couponMillis(coupon.claimStartsAt, "Coupon claim start");
  const endsAt = couponMillis(coupon.claimEndsAt, "Coupon claim end");
  if (nowMillis < startsAt || nowMillis >= endsAt) {
    return {allowed: false, reason: "This coupon cannot be claimed now."};
  }
  const eligibleCustomers = Array.isArray(coupon.eligibleCustomerUids) ?
    coupon.eligibleCustomerUids.map(String) : [];
  const eligibleSalons = Array.isArray(coupon.eligibleSalonIds) ?
    coupon.eligibleSalonIds.map(String) : [];
  const eligible = walletType === "salon_promotion_credits" ?
    eligibleSalons : eligibleCustomers;
  const targetId = walletType === "salon_promotion_credits" ?
    accountId : uid;
  if (eligible.length > 0 && !eligible.includes(String(targetId))) {
    return {allowed: false, reason: "This coupon is not available to you."};
  }
  const claimed = safeStoredInteger(usage.claimedCount);
  const reserved = safeStoredInteger(usage.reservedClaims);
  const maximum = safeStoredInteger(coupon.maximumClaimsTotal);
  if (maximum <= 0 || claimed + reserved >= maximum) {
    return {allowed: false, reason: "This coupon has reached its claim limit."};
  }
  return {allowed: true, reason: ""};
}

function couponMillis(value, label) {
  if (value && typeof value.toMillis === "function") return value.toMillis();
  if (value instanceof Date) return value.getTime();
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number <= 0) {
    throw new ProinValidationError(`${label} must be a valid date.`);
  }
  return number;
}

function requiredCouponText(value, label, maximumLength) {
  const text = String(value ?? "").trim();
  if (!text || text.length > maximumLength || text.includes("/")) {
    throw new ProinValidationError(`Enter a valid ${label}.`);
  }
  return text;
}

function couponIdList(value, label) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) {
    throw new ProinValidationError(`${label} must be a list.`);
  }
  const values = [...new Set(value.map((item) => String(item ?? "").trim())
    .filter(Boolean))].sort();
  if (values.length > 500 || values.some((item) =>
    item.length > 160 || item.includes("/"))) {
    throw new ProinValidationError(`${label} contains invalid identifiers.`);
  }
  return values;
}

function safeStoredInteger(value) {
  const number = Number(value);
  return Number.isSafeInteger(number) && number >= 0 ? number : 0;
}

module.exports = {
  PROIN_COUPON_PATTERN,
  maskProinCouponCode,
  normalizeProinCouponCode,
  normalizeProinCouponInput,
  proinCouponClaimAllowed,
  proinCouponHash,
};
