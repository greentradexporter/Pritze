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
  const journeyMilestones = normalizeJourneyMilestones(
    input.journeyMilestones,
  );
  const hasJourneyMilestones = journeyMilestones.length > 0;
  const journeyCountScope = input.journeyCountScope === "salon" ?
    "salon" : "platform";
  const discountType = input.discountType === "fixed" ? "fixed" : "percent";
  const discountPercent = !hasJourneyMilestones && discountType === "percent" ? decimal(
    input.discountPercent,
    "Discount percent",
    {minimum: 0.01, maximum: 100},
  ) : 0;
  const fixedDiscountAmount = !hasJourneyMilestones && discountType === "fixed" ? integer(
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
  // New campaigns express the salon's compensation directly as a percentage
  // of the customer's discount.  Keep payoutMultiplier in the stored record
  // for backwards-compatible ledgers and completed booking receipts.
  const salonPayoutPercent = decimal(
    Object.prototype.hasOwnProperty.call(input, "salonPayoutPercent") ?
      input.salonPayoutPercent : Number(input.payoutMultiplier ?? 2) * 100,
    "Salon compensation percentage",
    {minimum: 0, maximum: 1000},
  );
  const salonPayoutPercentByBookingNumber = payoutPercentByBookingNumber(
    input.salonPayoutPercentByBookingNumber,
  );
  const payoutMultiplier = Math.round(salonPayoutPercent * 100) / 10000;
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
  const cashbackProinAmount = hasJourneyMilestones ?
    Math.max(0, ...journeyMilestones.map((item) =>
      item.cashbackProinAmount,
    )) : integer(input.cashbackProinAmount ?? 0, "Proin cashback amount");
  const cashbackValidityDays = hasJourneyMilestones ?
    Math.max(0, ...journeyMilestones.map((item) =>
      item.cashbackValidityDays,
    )) : integer(
      input.cashbackValidityDays ?? 30,
      "Proin cashback validity",
      {minimum: cashbackProinAmount > 0 ? 1 : 0},
    );
  if (cashbackValidityDays > 730) {
    throw new DiscountAdminValidationError(
      "Proin cashback validity cannot exceed 730 days.",
    );
  }
  const cashbackTotalBudgetProin = integer(
    input.cashbackTotalBudgetProin ?? 0,
    "Proin cashback budget",
  );
  if (cashbackProinAmount > 0 &&
      cashbackTotalBudgetProin < cashbackProinAmount) {
    throw new DiscountAdminValidationError(
      "Proin cashback budget must cover at least one cashback reward.",
    );
  }
  if (cashbackProinAmount > 0 && endsAtMillis <= 0) {
    throw new DiscountAdminValidationError(
      "A campaign with Proin cashback must have an end date.",
    );
  }
  const maximumUsesPerCustomer = integer(
    input.maximumUsesPerCustomer,
    "Maximum uses per customer",
    {minimum: 1},
  );
  if (hasJourneyMilestones &&
      maximumUsesPerCustomer < journeyMilestones.length) {
    throw new DiscountAdminValidationError(
      "Maximum uses per customer must cover every configured journey milestone.",
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
    salonPayoutPercent,
    salonPayoutPercentByBookingNumber,
    cashbackProinAmount,
    cashbackValidityDays,
    cashbackTotalBudgetProin,
    journeyCountScope,
    journeyMilestones,
    totalPayoutBudget: integer(
      input.totalPayoutBudget ?? 0,
      "Total payout budget",
    ),
    maximumUsesPerCustomer,
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

function normalizeJourneyMilestones(value) {
  if (value === undefined || value === null || value === "") return [];
  if (!Array.isArray(value)) {
    throw new DiscountAdminValidationError(
      "Journey milestones must be a list.",
    );
  }
  if (value.length > 50) {
    throw new DiscountAdminValidationError(
      "A journey campaign can contain at most 50 milestones.",
    );
  }
  const milestones = value.map((raw, index) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new DiscountAdminValidationError(
        `Journey milestone ${index + 1} is invalid.`,
      );
    }
    const bookingNumber = integer(
      raw.bookingNumber,
      `Journey milestone ${index + 1} booking number`,
      {minimum: 1},
    );
    if (bookingNumber > 100000) {
      throw new DiscountAdminValidationError(
        "Journey booking numbers cannot exceed 100000.",
      );
    }
    const rewardType = ["discount", "discount_proin", "proin"]
      .includes(raw.rewardType) ? raw.rewardType : "";
    if (!rewardType) {
      throw new DiscountAdminValidationError(
        `Choose a reward type for booking ${bookingNumber}.`,
      );
    }
    const includesDiscount = rewardType !== "proin";
    const includesProin = rewardType !== "discount";
    const milestoneDiscountType = includesDiscount &&
      raw.discountType === "fixed" ? "fixed" :
      includesDiscount ? "percent" : "none";
    const discountPercent = milestoneDiscountType === "percent" ? decimal(
      raw.discountPercent,
      `Discount percent for booking ${bookingNumber}`,
      {minimum: 0.01, maximum: 100},
    ) : 0;
    const fixedDiscountAmount = milestoneDiscountType === "fixed" ? integer(
      raw.fixedDiscountAmount,
      `Fixed discount for booking ${bookingNumber}`,
      {minimum: 1},
    ) : 0;
    const cashbackProinAmount = includesProin ? integer(
      raw.cashbackProinAmount,
      `Proin reward for booking ${bookingNumber}`,
      {minimum: 1},
    ) : 0;
    const cashbackValidityDays = includesProin ? integer(
      raw.cashbackValidityDays ?? 30,
      `Proin validity for booking ${bookingNumber}`,
      {minimum: 1},
    ) : 0;
    if (cashbackValidityDays > 730) {
      throw new DiscountAdminValidationError(
        `Proin validity for booking ${bookingNumber} cannot exceed 730 days.`,
      );
    }
    return {
      bookingNumber,
      rewardType,
      discountType: milestoneDiscountType,
      discountPercent,
      fixedDiscountAmount,
      maximumDiscountAmount: includesDiscount ? integer(
        raw.maximumDiscountAmount ?? 0,
        `Maximum discount for booking ${bookingNumber}`,
      ) : 0,
      cashbackProinAmount,
      cashbackValidityDays,
    };
  });
  const bookingNumbers = milestones.map((item) => item.bookingNumber);
  if (new Set(bookingNumbers).size !== bookingNumbers.length) {
    throw new DiscountAdminValidationError(
      "Each journey milestone must use a different booking number.",
    );
  }
  return milestones.sort((left, right) =>
    left.bookingNumber - right.bookingNumber,
  );
}

function payoutPercentByBookingNumber(value) {
  if (value === null || value === undefined || value === "") return {};
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new DiscountAdminValidationError(
      "Salon booking compensation rules must be booking-number and percentage pairs.",
    );
  }
  const result = {};
  for (const [bookingNumber, percent] of Object.entries(value)) {
    if (!/^\d+$/.test(String(bookingNumber))) {
      throw new DiscountAdminValidationError(
        "Salon booking compensation rules need whole booking numbers.",
      );
    }
    const normalizedBookingNumber = Number(bookingNumber);
    if (!Number.isSafeInteger(normalizedBookingNumber) ||
        normalizedBookingNumber < 1 || normalizedBookingNumber > 100000) {
      throw new DiscountAdminValidationError(
        "Salon booking compensation rules support booking numbers from 1 to 100000.",
      );
    }
    result[String(normalizedBookingNumber)] = decimal(
      percent,
      `Salon compensation for booking ${normalizedBookingNumber}`,
      {minimum: 0, maximum: 1000},
    );
  }
  return Object.fromEntries(Object.entries(result).sort((left, right) =>
    Number(left[0]) - Number(right[0]),
  ));
}

function normalizeDiscountVaultBudget(value) {
  return integer(value, "Approved discount budget");
}

function normalizeSalonPromotionCreditLimit(value) {
  return integer(value ?? 1000, "Salon promotion credit line");
}

function normalizeSalonDiscountBurnMultiplier(value) {
  return decimal(value ?? 2, "Salon discount burn multiplier", {
    minimum: 1,
    maximum: 10,
  });
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
  normalizeSalonDiscountBurnMultiplier,
  normalizeSalonPromotionCreditLimit,
  normalizeDiscountVaultBudget,
};
