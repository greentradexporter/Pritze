function money(value) {
  const amount = Number(value);
  return Number.isFinite(amount) ? Math.max(0, Math.floor(amount)) : 0;
}

function signedMoney(value) {
  const amount = Number(value);
  return Number.isFinite(amount) ? Math.floor(amount) : 0;
}

const DEFAULT_SALON_PROMOTION_CREDIT_LIMIT = 1000;
const DEFAULT_SALON_DISCOUNT_BURN_MULTIPLIER = 2;
const DISCOUNT_FUNDING_SOURCES = Object.freeze([
  "salon_promotion_credits",
  "platform_vault",
]);

function discountFundingSource(source = "") {
  const value = String(
    typeof source === "object" && source !== null ?
      source.fundingSource ?? source.discountFundingSource ?? "" : source,
  ).trim();
  return DISCOUNT_FUNDING_SOURCES.includes(value) ?
    value : "salon_promotion_credits";
}

function numberList(value) {
  return Array.isArray(value) ?
    value.map(Number).filter((item) => Number.isFinite(item)) : [];
}

function stringList(value) {
  return Array.isArray(value) ?
    value.map((item) => String(item ?? "").trim()).filter(Boolean) : [];
}

function timestampMillis(value) {
  if (value?.toMillis) return value.toMillis();
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function discountJourneyBookingNumber(campaign, context) {
  return campaign?.journeyCountScope === "salon" ?
    money(context.salonCompletedCount) + 1 :
    money(context.completedBookingCount) + 1;
}

function discountCampaignForContext(campaign, context) {
  const milestones = Array.isArray(campaign?.journeyMilestones) ?
    campaign.journeyMilestones : [];
  if (milestones.length === 0) return campaign;
  const bookingNumber = discountJourneyBookingNumber(campaign, context);
  const milestone = milestones.find((item) =>
    money(item?.bookingNumber) === bookingNumber,
  );
  if (!milestone) return null;
  const rewardType = ["discount", "discount_proin", "proin"]
    .includes(milestone.rewardType) ? milestone.rewardType : "discount";
  const includesDiscount = rewardType !== "proin";
  const includesProin = rewardType !== "discount";
  return {
    ...campaign,
    discountType: includesDiscount && milestone.discountType === "percent" ?
      "percent" : "fixed",
    discountPercent: includesDiscount ?
      Number(milestone.discountPercent) || 0 : 0,
    fixedDiscountAmount: includesDiscount ?
      money(milestone.fixedDiscountAmount) : 0,
    maximumDiscountAmount: includesDiscount ?
      money(milestone.maximumDiscountAmount) : 0,
    cashbackProinAmount: includesProin ?
      money(milestone.cashbackProinAmount) : 0,
    cashbackValidityDays: includesProin ?
      money(milestone.cashbackValidityDays) : 0,
    journeyMilestoneBookingNumber: bookingNumber,
    journeyCountScope: campaign.journeyCountScope === "salon" ?
      "salon" : "platform",
  };
}

function discountCampaignEligible(campaign, context) {
  if (campaign?.active !== true) return false;
  const eligibleBase = discountBaseAmount(campaign, context);
  if (eligibleBase < money(campaign.minimumServiceAmount)) return false;

  const startMillis = timestampMillis(campaign.startsAt);
  const endMillis = timestampMillis(campaign.endsAt);
  if (startMillis > 0 && context.nowMillis < startMillis) return false;
  if (endMillis > 0 && context.nowMillis >= endMillis) return false;

  const salonIds = stringList(campaign.salonIds);
  if (salonIds.length > 0 && !salonIds.includes(context.salonId)) return false;
  if (stringList(campaign.excludedSalonIds).includes(context.salonId)) {
    return false;
  }
  const customerUids = stringList(campaign.customerUids);
  if (customerUids.length > 0 && !customerUids.includes(context.customerUid)) {
    return false;
  }
  const serviceIds = stringList(campaign.serviceIds);
  if (serviceIds.length > 0 && eligibleBase <= 0) {
    return false;
  }

  const bookingNumber = context.completedBookingCount + 1;
  const bookingNumbers = numberList(campaign.eligibleBookingNumbers);
  if (bookingNumbers.length > 0 && !bookingNumbers.includes(bookingNumber)) {
    return false;
  }
  const minimumBookingNumber = Math.max(
    1,
    money(campaign.minimumBookingNumber) || 1,
  );
  const maximumBookingNumber = money(campaign.maximumBookingNumber);
  if (bookingNumber < minimumBookingNumber) return false;
  if (maximumBookingNumber > 0 && bookingNumber > maximumBookingNumber) {
    return false;
  }
  if (campaign.newToSalonOnly === true && context.salonCompletedCount > 0) {
    return false;
  }
  if (
    campaign.returningToSalonOnly === true &&
    context.salonCompletedCount === 0
  ) {
    return false;
  }
  const effectiveCampaign = discountCampaignForContext(campaign, context);
  if (!effectiveCampaign) return false;
  const discountType = effectiveCampaign.discountType === "fixed" ?
    "fixed" : "percent";
  const percent = Number(effectiveCampaign.discountPercent);
  const fixedAmount = money(effectiveCampaign.fixedDiscountAmount);
  const proinAmount = money(effectiveCampaign.cashbackProinAmount);
  const hasDiscount = discountType === "percent" ?
    Number.isFinite(percent) && percent > 0 && percent <= 100 :
    fixedAmount > 0;
  if (!hasDiscount && proinAmount <= 0) return false;
  return true;
}

function discountCampaignSelectableAtCheckout(campaign, context) {
  if (!discountCampaignEligible(campaign, context)) return false;
  if (campaign?.voucherOnly === true) {
    return campaign?.visibleAtCheckout === true;
  }
  return true;
}

function discountBaseAmount(campaign, context) {
  const targetedServiceIds = stringList(campaign.serviceIds);
  if (targetedServiceIds.length === 0) {
    return money(context.originalAmount);
  }
  const serviceAmounts = context.serviceAmounts ?? {};
  return context.serviceIds
    .filter((serviceId) => targetedServiceIds.includes(serviceId))
    .reduce(
      (total, serviceId) => total + money(serviceAmounts[serviceId]),
      0,
    );
}

function calculateDiscountQuote(
  campaignId,
  campaign,
  originalAmount,
  discountBase = originalAmount,
  payoutMultiplierOverride = null,
) {
  const original = money(originalAmount);
  const eligibleAmount = Math.min(original, money(discountBase));
  const discountType = campaign.discountType === "fixed" ? "fixed" : "percent";
  const percent = discountType === "percent" ? Number(campaign.discountPercent) : 0;
  const calculatedDiscount = discountType === "fixed" ?
    money(campaign.fixedDiscountAmount) :
    Math.floor(eligibleAmount * percent / 100);
  const maximumDiscount = money(campaign.maximumDiscountAmount);
  const discountAmount = Math.min(
    original,
    eligibleAmount,
    maximumDiscount > 0 ? Math.min(calculatedDiscount, maximumDiscount) :
      calculatedDiscount,
  );
  const configuredMultiplier = Number(payoutMultiplierOverride);
  const campaignMultiplier = Number(campaign.payoutMultiplier);
  const payoutMultiplier = payoutMultiplierOverride !== null &&
    payoutMultiplierOverride !== undefined &&
    Number.isFinite(configuredMultiplier) &&
    configuredMultiplier >= 0 ? configuredMultiplier :
    Number.isFinite(campaignMultiplier) && campaignMultiplier > 0 ?
      campaignMultiplier : DEFAULT_SALON_DISCOUNT_BURN_MULTIPLIER;
  const pritzePayoutAmount = Math.floor(discountAmount * payoutMultiplier);
  const cashbackProinAmount = money(campaign.cashbackProinAmount);
  return {
    campaignId,
    campaignName: String(campaign.name ?? "Pritze discount").trim() ||
      "Pritze discount",
    fundingSource: discountFundingSource(campaign),
    discountType,
    discountPercent: percent,
    fixedDiscountAmount: discountType === "fixed" ?
      money(campaign.fixedDiscountAmount) : 0,
    voucherOnly: campaign.voucherOnly === true,
    voucherMaskedCode: String(campaign.voucherMaskedCode ?? "").trim(),
    originalAmount: original,
    discountBaseAmount: eligibleAmount,
    discountAmount,
    customerPayableAmount: original - discountAmount,
    payoutMultiplierApplied: payoutMultiplier,
    salonPayoutPercentApplied: Math.round(payoutMultiplier * 10000) / 100,
    cashbackProinAmount,
    cashbackValidityDays: cashbackProinAmount > 0 ?
      money(campaign.cashbackValidityDays) : 0,
    cashbackProgramId: cashbackProinAmount > 0 ?
      String(campaign.cashbackProgramId ?? "").trim() : "",
    ...(money(campaign.journeyMilestoneBookingNumber) > 0 ? {
      journeyMilestoneBookingNumber:
        money(campaign.journeyMilestoneBookingNumber),
      journeyCountScope: campaign.journeyCountScope === "salon" ?
        "salon" : "platform",
    } : {}),
    pritzePayoutAmount,
    salonTotalEarning: original - discountAmount + pritzePayoutAmount,
  };
}

function discountBudgetAllows(campaign, quote, usage) {
  if (quote.discountAmount <= 0 && money(quote.cashbackProinAmount) <= 0) {
    return false;
  }
  const payoutAmount = money(quote.pritzePayoutAmount);
  const totalUsed = money(usage.campaign?.reservedPayoutAmount) +
    money(usage.campaign?.realizedPayoutAmount);
  if (payoutAmount > 0 &&
      totalUsed + payoutAmount > money(campaign.totalPayoutBudget)) {
    return false;
  }
  const salonBudget = money(campaign.perSalonPayoutBudget);
  const salonUsed = money(usage.salon?.reservedPayoutAmount) +
    money(usage.salon?.realizedPayoutAmount);
  if (payoutAmount > 0 && salonBudget > 0 &&
      salonUsed + payoutAmount > salonBudget) {
    return false;
  }
  const customerBudget = money(campaign.perCustomerPayoutBudget);
  const customerUsed = money(usage.customer?.reservedPayoutAmount) +
    money(usage.customer?.realizedPayoutAmount);
  if (
    customerBudget > 0 &&
    payoutAmount > 0 && customerUsed + payoutAmount > customerBudget
  ) {
    return false;
  }
  const maximumUses = Math.max(1, money(campaign.maximumUsesPerCustomer) || 1);
  const customerUses = money(usage.customer?.reservedUses) +
    money(usage.customer?.realizedUses);
  if (customerUses >= maximumUses) return false;
  if (payoutAmount === 0) return true;
  const vaultAllows = money(usage.vault?.availableAmount) >= payoutAmount;
  if (discountFundingSource(quote || campaign) === "platform_vault") {
    return vaultAllows;
  }
  const creditLimit = Object.prototype.hasOwnProperty.call(
    usage.vault || {},
    "salonCreditLimitAmount",
  ) ?
    money(usage.vault?.salonCreditLimitAmount) :
    DEFAULT_SALON_PROMOTION_CREDIT_LIMIT;
  return vaultAllows &&
    signedMoney(usage.salonCreditWallet?.availableProin) + creditLimit >=
      payoutAmount;
}

function emptyDiscountQuote(originalAmount) {
  const original = money(originalAmount);
  return {
    campaignId: "",
    campaignName: "",
    discountType: "percent",
    discountPercent: 0,
    fixedDiscountAmount: 0,
    fundingSource: "salon_promotion_credits",
    voucherOnly: false,
    voucherMaskedCode: "",
    originalAmount: original,
    discountBaseAmount: 0,
    discountAmount: 0,
    customerPayableAmount: original,
    payoutMultiplierApplied: 0,
    salonPayoutPercentApplied: 0,
    cashbackProinAmount: 0,
    cashbackValidityDays: 0,
    cashbackProgramId: "",
    pritzePayoutAmount: 0,
    salonTotalEarning: original,
  };
}

function discountPayoutMultiplier(campaign, vault = {}, bookingNumber = null) {
  const hasExplicitPercent = Object.prototype.hasOwnProperty.call(
    campaign || {},
    "salonPayoutPercent",
  );
  const perBooking = campaign?.salonPayoutPercentByBookingNumber;
  const rulePercent = bookingNumber !== null && perBooking &&
    Object.prototype.hasOwnProperty.call(perBooking, String(bookingNumber)) ?
    Number(perBooking[String(bookingNumber)]) : Number.NaN;
  const defaultPercent = Number(campaign?.salonPayoutPercent);
  const payoutPercent = Number.isFinite(rulePercent) ? rulePercent :
    defaultPercent;
  if ((hasExplicitPercent || Number.isFinite(rulePercent)) &&
      Number.isFinite(payoutPercent) && payoutPercent >= 0 &&
      payoutPercent <= 1000) {
    return Math.round(payoutPercent * 100) / 10000;
  }
  if (discountFundingSource(campaign) === "salon_promotion_credits") {
    const configured = Number(vault?.salonDiscountBurnMultiplier);
    return Number.isFinite(configured) && configured >= 1 && configured <= 10 ?
      Math.round(configured * 100) / 100 :
      DEFAULT_SALON_DISCOUNT_BURN_MULTIPLIER;
  }
  const campaignMultiplier = Number(campaign?.payoutMultiplier);
  return Number.isFinite(campaignMultiplier) && campaignMultiplier > 0 ?
    campaignMultiplier : DEFAULT_SALON_DISCOUNT_BURN_MULTIPLIER;
}

module.exports = {
  calculateDiscountQuote,
  DEFAULT_SALON_DISCOUNT_BURN_MULTIPLIER,
  DEFAULT_SALON_PROMOTION_CREDIT_LIMIT,
  DISCOUNT_FUNDING_SOURCES,
  discountBaseAmount,
  discountBudgetAllows,
  discountCampaignEligible,
  discountCampaignForContext,
  discountCampaignSelectableAtCheckout,
  discountJourneyBookingNumber,
  discountFundingSource,
  discountPayoutMultiplier,
  emptyDiscountQuote,
  money,
  signedMoney,
};
