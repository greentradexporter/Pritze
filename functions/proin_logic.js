const MAX_PROIN_AMOUNT = 1_000_000_000;

const PROIN_WALLET_TYPES = Object.freeze([
  "customer_rewards",
  "salon_promotion_credits",
]);

const PROIN_SOURCE_TYPES = Object.freeze([
  "referral_customer",
  "referral_salon",
  "coupon",
  "promotion",
  "manual",
]);

const PROIN_QUALIFICATION_EVENTS = Object.freeze([
  "first_completed_booking",
  "salon_approved_and_first_completed_booking",
  "coupon_claimed",
  "campaign_award",
  "manual_approval",
]);

const PROIN_REWARD_RECIPIENTS = Object.freeze([
  "account",
  "inviter",
  "referred",
]);

const PROIN_REFERRAL_ROLES = Object.freeze(["customer", "owner"]);

class ProinValidationError extends Error {
  constructor(message) {
    super(message);
    this.name = "ProinValidationError";
  }
}

function proinInteger(value, label, {allowZero = true} = {}) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0 ||
      number > MAX_PROIN_AMOUNT || (!allowZero && number === 0)) {
    const requirement = allowZero ? "a non-negative" : "a positive";
    throw new ProinValidationError(`${label} must be ${requirement} integer.`);
  }
  return number;
}

function proinSignedInteger(value, label) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || Math.abs(number) > MAX_PROIN_AMOUNT) {
    throw new ProinValidationError(`${label} must be a whole Proin amount.`);
  }
  return number;
}

function proinMillis(value, label, {allowZero = false} = {}) {
  if (value && typeof value.toMillis === "function") {
    return value.toMillis();
  }
  if (value instanceof Date) return value.getTime();
  const millis = Number(value);
  if (!Number.isSafeInteger(millis) || millis < 0 ||
      (!allowZero && millis === 0)) {
    throw new ProinValidationError(`${label} must be a valid date.`);
  }
  return millis;
}

function requiredProinText(value, label, maximumLength = 120) {
  const text = String(value ?? "").trim();
  if (!text || text.length > maximumLength) {
    throw new ProinValidationError(
      `${label} is required and must be at most ${maximumLength} characters.`,
    );
  }
  return text;
}

function proinIdList(value, label, maximumItems = 200) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) {
    throw new ProinValidationError(`${label} must be a list.`);
  }
  const result = [...new Set(value.map((item) => String(item ?? "").trim())
    .filter(Boolean))];
  if (result.length > maximumItems ||
      result.some((item) => item.length > 160)) {
    throw new ProinValidationError(
      `${label} contains too many or invalid identifiers.`,
    );
  }
  return result.sort();
}

function normalizeProinProgramInput(input = {}) {
  const name = requiredProinText(input.name, "Program name", 100);
  const sourceType = String(input.sourceType ?? "").trim();
  const walletType = String(input.walletType ?? "").trim();
  const qualificationEvent = String(input.qualificationEvent ?? "").trim();
  if (!PROIN_SOURCE_TYPES.includes(sourceType)) {
    throw new ProinValidationError("Choose a supported Proin source type.");
  }
  if (!PROIN_WALLET_TYPES.includes(walletType)) {
    throw new ProinValidationError("Choose a supported Proin wallet type.");
  }
  if (!PROIN_QUALIFICATION_EVENTS.includes(qualificationEvent)) {
    throw new ProinValidationError("Choose a supported qualification event.");
  }
  const requiredQualification = {
    referral_customer: "first_completed_booking",
    referral_salon: "salon_approved_and_first_completed_booking",
    coupon: "coupon_claimed",
    promotion: "campaign_award",
    manual: "manual_approval",
  }[sourceType];
  if (requiredQualification && qualificationEvent !== requiredQualification) {
    throw new ProinValidationError(
      `The ${sourceType} program must use ${requiredQualification}.`,
    );
  }
  const isReferralProgram = sourceType === "referral_customer" ||
    sourceType === "referral_salon";
  const rewardRecipient = String(
    input.rewardRecipient ?? (isReferralProgram ? "" : "account"),
  ).trim();
  if (!PROIN_REWARD_RECIPIENTS.includes(rewardRecipient) ||
      (isReferralProgram && rewardRecipient === "account") ||
      (!isReferralProgram && rewardRecipient !== "account")) {
    throw new ProinValidationError(
      "Choose the correct Proin reward recipient for this program.",
    );
  }
  const referralTargetRole = isReferralProgram ?
    (sourceType === "referral_customer" ? "customer" : "owner") : "";
  const referralInviterRole = isReferralProgram ?
    String(input.referralInviterRole ?? "").trim() : "";
  if (isReferralProgram &&
      !PROIN_REFERRAL_ROLES.includes(referralInviterRole)) {
    throw new ProinValidationError(
      "Referral programs must target a customer or owner inviter role.",
    );
  }
  const rewardedRole = rewardRecipient === "referred" ?
    referralTargetRole : referralInviterRole;
  if (isReferralProgram &&
      ((rewardedRole === "customer" && walletType !== "customer_rewards") ||
       (rewardedRole === "owner" &&
        walletType !== "salon_promotion_credits"))) {
    throw new ProinValidationError(
      "The referral recipient role does not match the selected wallet type.",
    );
  }
  const startsAtMillis = proinMillis(input.startsAtMillis, "Start date");
  const endsAtMillis = proinMillis(input.endsAtMillis, "End date");
  if (endsAtMillis <= startsAtMillis) {
    throw new ProinValidationError("Program end must be after its start.");
  }

  const rewardAmountProin = proinInteger(
    input.rewardAmountProin,
    "Reward amount",
    {allowZero: false},
  );
  const totalBudgetProin = proinInteger(
    input.totalBudgetProin,
    "Program budget",
    {allowZero: false},
  );
  if (totalBudgetProin < rewardAmountProin) {
    throw new ProinValidationError(
      "Program budget cannot be lower than one reward.",
    );
  }

  const rewardValidityDays = proinInteger(
    input.rewardValidityDays,
    "Reward validity",
    {allowZero: false},
  );
  if (rewardValidityDays > 730) {
    throw new ProinValidationError(
      "Reward validity cannot exceed 730 days.",
    );
  }

  const maximumTotalGrants = proinInteger(
    input.maximumTotalGrants,
    "Maximum total grants",
    {allowZero: false},
  );
  const maximumGrantsPerAccount = proinInteger(
    input.maximumGrantsPerAccount,
    "Maximum grants per account",
    {allowZero: false},
  );
  if (maximumGrantsPerAccount > maximumTotalGrants) {
    throw new ProinValidationError(
      "Per-account grants cannot exceed total grants.",
    );
  }

  const maximumRedemptionPercent = proinInteger(
    input.maximumRedemptionPercent,
    "Maximum redemption percent",
    {allowZero: false},
  );
  if (maximumRedemptionPercent > 100) {
    throw new ProinValidationError(
      "Maximum redemption percent cannot exceed 100.",
    );
  }

  return {
    name,
    sourceType,
    walletType,
    qualificationEvent,
    rewardRecipient,
    referralTargetRole,
    referralInviterRole,
    active: input.active === true,
    rewardAmountProin,
    rewardValidityDays,
    totalBudgetProin,
    maximumTotalGrants,
    maximumGrantsPerAccount,
    minimumBookingAmount: proinInteger(
      input.minimumBookingAmount ?? 0,
      "Minimum booking amount",
    ),
    maximumProinPerBooking: proinInteger(
      input.maximumProinPerBooking,
      "Maximum Proin per booking",
      {allowZero: false},
    ),
    maximumRedemptionPercent,
    stackableWithDiscount: input.stackableWithDiscount === true,
    startsAtMillis,
    endsAtMillis,
    eligibleSalonIds: proinIdList(
      input.eligibleSalonIds,
      "Eligible salon IDs",
    ),
    eligibleServiceIds: proinIdList(
      input.eligibleServiceIds,
      "Eligible service IDs",
    ),
    termsVersion: requiredProinText(
      input.termsVersion,
      "Terms version",
      40,
    ),
  };
}

function proinProgramGrantAllowed({program, usage = {}, nowMillis}) {
  if (program?.active !== true) {
    return {allowed: false, reason: "This Proin program is paused."};
  }
  const startsAtMillis = proinMillis(program.startsAt, "Start date");
  const endsAtMillis = proinMillis(program.endsAt, "End date");
  if (nowMillis < startsAtMillis || nowMillis >= endsAtMillis) {
    return {allowed: false, reason: "This Proin program is not currently open."};
  }
  const reward = proinInteger(
    program.rewardAmountProin,
    "Reward amount",
    {allowZero: false},
  );
  const granted = proinInteger(
    usage.grantedProin ?? 0,
    "Granted Proin",
  );
  if (granted + reward > proinInteger(
    program.totalBudgetProin,
    "Program budget",
    {allowZero: false},
  )) {
    return {allowed: false, reason: "This Proin program budget is exhausted."};
  }
  const grantCount = proinInteger(usage.grantCount ?? 0, "Grant count");
  if (grantCount >= proinInteger(
    program.maximumTotalGrants,
    "Maximum total grants",
    {allowZero: false},
  )) {
    return {allowed: false, reason: "This Proin program reached its grant limit."};
  }
  return {allowed: true, reason: ""};
}

function allocateProinLots(lots, requestedProin, nowMillis) {
  const requested = proinInteger(
    requestedProin,
    "Requested Proin",
    {allowZero: false},
  );
  const eligible = (Array.isArray(lots) ? lots : [])
    .map((lot) => ({
      ...lot,
      availableProin: proinInteger(
        lot.availableProin ?? 0,
        "Lot available Proin",
      ),
      expiresAtMillis: proinMillis(lot.expiresAt, "Lot expiry"),
      earnedAtMillis: proinMillis(
        lot.earnedAt,
        "Lot earned date",
        {allowZero: true},
      ),
    }))
    .filter((lot) => lot.status === "active" && lot.availableProin > 0 &&
      lot.expiresAtMillis > nowMillis)
    .sort((left, right) =>
      left.expiresAtMillis - right.expiresAtMillis ||
      left.earnedAtMillis - right.earnedAtMillis ||
      String(left.id ?? "").localeCompare(String(right.id ?? "")),
    );

  const allocations = [];
  let remaining = requested;
  for (const lot of eligible) {
    if (remaining === 0) break;
    const amountProin = Math.min(remaining, lot.availableProin);
    allocations.push({
      lotId: requiredProinText(lot.id, "Lot ID", 160),
      amountProin,
      expiresAtMillis: lot.expiresAtMillis,
    });
    remaining -= amountProin;
  }
  return {
    requestedProin: requested,
    allocatedProin: requested - remaining,
    shortfallProin: remaining,
    allocations,
  };
}

function proinRedemptionPolicyFromProgram(program = {}) {
  return {
    minimumBookingAmount: proinInteger(
      program.minimumBookingAmount ?? 0,
      "Minimum booking amount",
    ),
    maximumProinPerBooking: proinInteger(
      program.maximumProinPerBooking,
      "Maximum Proin per booking",
      {allowZero: false},
    ),
    maximumRedemptionPercent: proinInteger(
      program.maximumRedemptionPercent,
      "Maximum redemption percent",
      {allowZero: false},
    ),
    stackableWithDiscount: program.stackableWithDiscount === true,
    eligibleSalonIds: proinIdList(
      program.eligibleSalonIds,
      "Eligible salon IDs",
    ),
    eligibleServiceIds: proinIdList(
      program.eligibleServiceIds,
      "Eligible service IDs",
    ),
    termsVersion: requiredProinText(
      program.termsVersion,
      "Terms version",
      40,
    ),
  };
}

function quoteProinRedemption({
  lots,
  programsById = {},
  originalAmount,
  discountAmount = 0,
  salonId,
  serviceIds,
  nowMillis,
  requestedProin,
}) {
  const original = proinInteger(originalAmount, "Service amount");
  const discount = proinInteger(discountAmount, "Discount amount");
  const payableBeforeProin = Math.max(0, original - discount);
  const normalizedSalonId = requiredProinText(salonId, "Salon ID", 160);
  const normalizedServiceIds = proinIdList(
    serviceIds,
    "Selected service IDs",
    6,
  );
  if (normalizedServiceIds.length === 0) {
    throw new ProinValidationError("Choose at least one service.");
  }
  const requested = requestedProin === undefined || requestedProin === null ?
    null : proinInteger(requestedProin, "Requested Proin");
  const candidates = (Array.isArray(lots) ? lots : [])
    .map((lot) => {
      let policy = null;
      try {
        policy = proinRedemptionPolicyFromProgram(
          lot.redemptionPolicy || programsById[String(lot.programId || "")],
        );
      } catch (_) {
        return null;
      }
      return {
        ...lot,
        id: requiredProinText(lot.id, "Lot ID", 160),
        programId: requiredProinText(lot.programId, "Program ID", 80),
        availableProin: proinInteger(
          lot.availableProin ?? 0,
          "Lot available Proin",
        ),
        expiresAtMillis: proinMillis(lot.expiresAt, "Lot expiry"),
        earnedAtMillis: proinMillis(
          lot.earnedAt,
          "Lot earned date",
          {allowZero: true},
        ),
        policy,
      };
    })
    .filter((lot) => lot && lot.status === "active" &&
      lot.availableProin > 0 && lot.expiresAtMillis > nowMillis)
    .filter((lot) => {
      const policy = lot.policy;
      return original >= policy.minimumBookingAmount &&
        (discount === 0 || policy.stackableWithDiscount) &&
        (policy.eligibleSalonIds.length === 0 ||
          policy.eligibleSalonIds.includes(normalizedSalonId)) &&
        (policy.eligibleServiceIds.length === 0 ||
          normalizedServiceIds.every((id) =>
            policy.eligibleServiceIds.includes(id)));
    })
    .sort((left, right) =>
      left.expiresAtMillis - right.expiresAtMillis ||
      left.earnedAtMillis - right.earnedAtMillis ||
      left.id.localeCompare(right.id));

  const allocations = [];
  const usedByProgram = new Map();
  let remaining = requested ?? payableBeforeProin;
  for (const lot of candidates) {
    if (remaining <= 0) break;
    const percentageCap = Math.floor(
      payableBeforeProin * lot.policy.maximumRedemptionPercent / 100,
    );
    const programCap = Math.min(
      lot.policy.maximumProinPerBooking,
      percentageCap,
    );
    const alreadyUsed = usedByProgram.get(lot.programId) || 0;
    const programRemaining = Math.max(0, programCap - alreadyUsed);
    const globalRemaining = Math.max(
      0,
      payableBeforeProin - allocations.reduce(
        (total, allocation) => total + allocation.amountProin,
        0,
      ),
    );
    const amountProin = Math.min(
      lot.availableProin,
      programRemaining,
      globalRemaining,
      remaining,
    );
    if (amountProin <= 0) continue;
    allocations.push({
      lotId: lot.id,
      programId: lot.programId,
      amountProin,
      expiresAtMillis: lot.expiresAtMillis,
    });
    usedByProgram.set(lot.programId, alreadyUsed + amountProin);
    remaining -= amountProin;
  }
  const allocatedProin = allocations.reduce(
    (total, allocation) => total + allocation.amountProin,
    0,
  );
  return {
    originalAmount: original,
    discountAmount: discount,
    payableBeforeProin,
    requestedProin: requested ?? allocatedProin,
    maximumRedeemableProin: requested === null ? allocatedProin :
      allocatedProin + Math.max(0, remaining),
    allocatedProin,
    shortfallProin: Math.max(0, remaining),
    customerPayableAmount: payableBeforeProin - allocatedProin,
    allocations,
  };
}

function proinLotInvariant(lot = {}) {
  const original = proinInteger(lot.originalProin ?? 0, "Original Proin");
  const components = [
    "availableProin",
    "reservedProin",
    "redeemedProin",
    "expiredProin",
    "revokedProin",
  ].map((field) => proinInteger(lot[field] ?? 0, field));
  return original === components.reduce((sum, value) => sum + value, 0);
}

function proinWalletSummaryFromLots(lots = []) {
  const summary = {
    availableProin: 0,
    reservedProin: 0,
    lifetimeGrantedProin: 0,
    lifetimeRedeemedProin: 0,
    lifetimeExpiredProin: 0,
    lifetimeRevokedProin: 0,
    nextExpiryAtMillis: 0,
  };
  for (const lot of lots) {
    if (!proinLotInvariant(lot)) {
      throw new ProinValidationError(
        `Proin lot ${String(lot.id ?? "")} is not balanced.`,
      );
    }
    const available = proinInteger(
      lot.availableProin ?? 0,
      "Available Proin",
    );
    summary.availableProin += available;
    summary.reservedProin += proinInteger(
      lot.reservedProin ?? 0,
      "Reserved Proin",
    );
    summary.lifetimeGrantedProin += proinInteger(
      lot.originalProin ?? 0,
      "Original Proin",
    );
    summary.lifetimeRedeemedProin += proinInteger(
      lot.redeemedProin ?? 0,
      "Redeemed Proin",
    );
    summary.lifetimeExpiredProin += proinInteger(
      lot.expiredProin ?? 0,
      "Expired Proin",
    );
    summary.lifetimeRevokedProin += proinInteger(
      lot.revokedProin ?? 0,
      "Revoked Proin",
    );
    if (available > 0 && lot.status === "active") {
      const expiresAtMillis = proinMillis(lot.expiresAt, "Lot expiry");
      if (summary.nextExpiryAtMillis === 0 ||
          expiresAtMillis < summary.nextExpiryAtMillis) {
        summary.nextExpiryAtMillis = expiresAtMillis;
      }
    }
  }
  return summary;
}

function proinWalletInvariant(wallet = {}) {
  const walletType = String(wallet.walletType ?? "").trim();
  const creditLimit = walletType === "salon_promotion_credits" ?
    proinInteger(wallet.creditLimitProin ?? 1000, "Salon credit limit") : 0;
  const available = walletType === "salon_promotion_credits" ?
    proinSignedInteger(wallet.availableProin ?? 0, "Available Proin") :
    proinInteger(wallet.availableProin ?? 0, "Available Proin");
  if (available < -creditLimit) return false;
  const granted = proinInteger(
    wallet.lifetimeGrantedProin ?? 0,
    "Lifetime granted Proin",
  );
  const accounted = available + [
    wallet.reservedProin,
    wallet.lifetimeRedeemedProin,
    wallet.lifetimeExpiredProin,
    wallet.lifetimeRevokedProin,
  ].reduce(
    (total, value) => total + proinInteger(value ?? 0, "Wallet Proin"),
    0,
  );
  return granted === accounted;
}

function proinFinanceInvariant(finance = {}) {
  const approved = proinInteger(
    finance.approvedBudgetInr ?? 0,
    "Approved budget",
  );
  const accounted = [
    finance.unallocatedBudgetInr,
    finance.outstandingLiabilityInr,
    finance.redeemedPayableInr,
    finance.settledExpenseInr,
  ].reduce(
    (total, value) => total + proinInteger(value ?? 0, "Finance amount"),
    0,
  );
  const reserved = proinInteger(
    finance.reservedLiabilityInr ?? 0,
    "Reserved liability",
  );
  return approved === accounted &&
    reserved <= proinInteger(
      finance.outstandingLiabilityInr ?? 0,
      "Outstanding liability",
    );
}

module.exports = {
  MAX_PROIN_AMOUNT,
  PROIN_QUALIFICATION_EVENTS,
  PROIN_REFERRAL_ROLES,
  PROIN_REWARD_RECIPIENTS,
  PROIN_SOURCE_TYPES,
  PROIN_WALLET_TYPES,
  ProinValidationError,
  allocateProinLots,
  normalizeProinProgramInput,
  proinFinanceInvariant,
  proinInteger,
  proinLotInvariant,
  proinMillis,
  proinProgramGrantAllowed,
  proinRedemptionPolicyFromProgram,
  proinSignedInteger,
  proinWalletInvariant,
  proinWalletSummaryFromLots,
  quoteProinRedemption,
};
