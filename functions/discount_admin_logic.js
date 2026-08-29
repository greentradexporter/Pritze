const MAX_MONEY = 1_000_000_000;
const CAMPAIGN_ID_PATTERN = /^[A-Za-z0-9_-]{1,80}$/;
const {
  DISCOUNT_FUNDING_SOURCES,
  discountFundingSource,
} = require("./discount_logic");
const {
  maskProinCouponCode,
  normalizeProinCouponCode,
  proinCouponHash,
} = require("./proin_coupon_logic");

class DiscountAdminValidationError extends Error {
  constructor(message) {
    super(message);
    this.name = "DiscountAdminValidationError";
  }
}

function normalizeDiscountCampaignInput(input = {}) {
  const campaignId = String(input.campaignId ?? "").trim();
  if (!CAMPAIGN_ID_PATTERN.test(campaignId)) {
    throw new DiscountAdminValidationError(
      "Campaign ID must contain only letters, numbers, underscores or hyphens.",
    );
  }
  const name = requiredText(input.name, "Campaign name", 100);
  const discountType = input.discountType === "fixed" ? "fixed" : "percent";
  const discountPercent = discountType === "percent" ? decimal(
    input.discountPercent,
    "Discount percent",
    {minimum: 0.01, maximum: 100},
  ) : 0;
  const fixedDiscountAmount = discountType === "fixed" ? integer(
    input.fixedDiscountAmount,
    "Fixed discount amount",
    {minimum: 1},
  ) : 0;
  const voucherOnly = input.voucherOnly === true;
  const visibleAtCheckout = input.visibleAtCheckout === true;
  if (visibleAtCheckout && !voucherOnly) {
    throw new DiscountAdminValidationError(
      "Only voucher campaigns can be shown as checkout apply buttons.",
    );
  }
  const fundingSource = discountFundingSource(input);
  if (!DISCOUNT_FUNDING_SOURCES.includes(fundingSource)) {
    throw new DiscountAdminValidationError(
      "Choose a supported discount funding source.",
    );
  }
  const suppliedVoucherCode = String(input.voucherCode ?? "").trim();
  const voucherCode = suppliedVoucherCode ?
    normalizeProinCouponCode(suppliedVoucherCode) : "";
  if (suppliedVoucherCode && !voucherCode) {
    throw new DiscountAdminValidationError(
      "Voucher codes must contain 4-20 letters or numbers and at least one letter.",
    );
  }
  const expectedVoucherCodeHash = String(
    input.expectedVoucherCodeHash ?? "",
  ).trim();
  if (voucherOnly && !voucherCode && !expectedVoucherCodeHash) {
    throw new DiscountAdminValidationError(
      "Enter a voucher code for a code-required campaign.",
    );
  }
  const payoutMultiplier = decimal(
    input.payoutMultiplier,
    "Pritze payout multiplier",
    {minimum: 1, maximum: 10},
  );
  const startsAtMillis = optionalMillis(input.startsAtMillis, "Start date");
  const endsAtMillis = optionalMillis(input.endsAtMillis, "End date");
  if (startsAtMillis > 0 && endsAtMillis > 0 && endsAtMillis <= startsAtMillis) {
    throw new DiscountAdminValidationError(
      "Campaign end must be after its start.",
    );
  }
  if (input.active === true && endsAtMillis > 0 && endsAtMillis <= Date.now()) {
    throw new DiscountAdminValidationError(
      "An active discount campaign cannot end in the past.",
    );
  }
  const newToSalonOnly = input.newToSalonOnly === true;
  const returningToSalonOnly = input.returningToSalonOnly === true;
  if (newToSalonOnly && returningToSalonOnly) {
    throw new DiscountAdminValidationError(
      "A campaign cannot be both new-to-salon-only and returning-to-salon-only.",
    );
  }
  const minimumBookingNumber = integer(
    input.minimumBookingNumber ?? 1,
    "Minimum booking number",
    {minimum: 1},
  );
  const maximumBookingNumber = integer(
    input.maximumBookingNumber ?? 0,
    "Maximum booking number",
  );
  if (maximumBookingNumber > 0 && maximumBookingNumber < minimumBookingNumber) {
    throw new DiscountAdminValidationError(
      "Maximum booking number cannot be below the minimum booking number.",
    );
  }
  return {
    campaignId,
    name,
    active: input.active === true,
    priority: integer(input.priority ?? 0, "Priority"),
    discountType,
    discountPercent,
    fixedDiscountAmount,
    voucherOnly,
    visibleAtCheckout,
    fundingSource,
    voucherCode,
    voucherCodeHash: voucherCode ? proinCouponHash(voucherCode) : "",
    voucherMaskedCode: voucherCode ? maskProinCouponCode(voucherCode) : "",
    expectedVoucherCodeHash,
    payoutMultiplier,
    totalPayoutBudget: integer(
      input.totalPayoutBudget,
      "Total payout budget",
      {minimum: 1},
    ),
    maximumUsesPerCustomer: integer(
      input.maximumUsesPerCustomer,
      "Maximum uses per customer",
      {minimum: 1},
    ),
    maximumDiscountAmount: integer(
      input.maximumDiscountAmount ?? 0,
      "Maximum discount amount",
    ),
    minimumServiceAmount: integer(
      input.minimumServiceAmount ?? 0,
      "Minimum service amount",
    ),
    perSalonPayoutBudget: integer(
      input.perSalonPayoutBudget ?? 0,
      "Per-salon payout budget",
    ),
    perCustomerPayoutBudget: integer(
      input.perCustomerPayoutBudget ?? 0,
      "Per-customer payout budget",
    ),
    startsAtMillis,
    endsAtMillis,
    salonIds: idList(input.salonIds, "Salon IDs"),
    excludedSalonIds: idList(input.excludedSalonIds, "Excluded salon IDs"),
    customerUids: idList(input.customerUids, "Customer IDs", 500),
    serviceIds: idList(input.serviceIds, "Service IDs"),
    eligibleBookingNumbers: numberList(input.eligibleBookingNumbers),
    minimumBookingNumber,
    maximumBookingNumber,
    newToSalonOnly,
    returningToSalonOnly,
    termsVersion: requiredText(input.termsVersion, "Terms version", 40),
  };
}

function normalizeDiscountVaultBudget(value) {
  return integer(value, "Approved discount budget");
}

function normalizeSalonPromotionCreditLimit(value) {
  return integer(value ?? 1000, "Salon promotion credit line");
}

function integer(value, label, {minimum = 0} = {}) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > MAX_MONEY) {
    throw new DiscountAdminValidationError(
      `${label} must be a whole number of at least ${minimum}.`,
    );
  }
  return parsed;
}

function decimal(value, label, {minimum, maximum}) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < minimum || parsed > maximum) {
    throw new DiscountAdminValidationError(
      `${label} must be between ${minimum} and ${maximum}.`,
    );
  }
  return Math.round(parsed * 100) / 100;
}

function optionalMillis(value, label) {
  if (value === undefined || value === null || value === "") return 0;
  if (value && typeof value.toMillis === "function") return value.toMillis();
  if (value instanceof Date) return value.getTime();
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new DiscountAdminValidationError(`${label} must be a valid date.`);
  }
  return parsed;
}

function requiredText(value, label, maximumLength) {
  const text = String(value ?? "").trim();
  if (!text || text.length > maximumLength) {
    throw new DiscountAdminValidationError(
      `${label} is required and must be at most ${maximumLength} characters.`,
    );
  }
  return text;
}

function idList(value, label, maximumItems = 200) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) {
    throw new DiscountAdminValidationError(`${label} must be a list.`);
  }
  const values = [...new Set(value.map((item) => String(item ?? "").trim())
    .filter(Boolean))].sort();
  if (values.length > maximumItems || values.some((item) =>
    item.length > 160 || item.includes("/"))) {
    throw new DiscountAdminValidationError(`${label} contains invalid IDs.`);
  }
  return values;
}

function numberList(value) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) {
    throw new DiscountAdminValidationError(
      "Eligible booking numbers must be a list.",
    );
  }
  const values = [...new Set(value.map(Number))].sort((a, b) => a - b);
  if (values.length > 100 || values.some((item) =>
    !Number.isSafeInteger(item) || item < 1 || item > 10_000)) {
    throw new DiscountAdminValidationError(
      "Eligible booking numbers contains invalid values.",
    );
  }
  return values;
}

module.exports = {
  DiscountAdminValidationError,
  normalizeDiscountCampaignInput,
  normalizeSalonPromotionCreditLimit,
  normalizeDiscountVaultBudget,
};
