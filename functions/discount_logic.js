function money(value) {
  const amount = Number(value);
  return Number.isFinite(amount) ? Math.max(0, Math.floor(amount)) : 0;
}

function signedMoney(value) {
  const amount = Number(value);
  return Number.isFinite(amount) ? Math.floor(amount) : 0;
}

const DEFAULT_SALON_PROMOTION_CREDIT_LIMIT = 1000;
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

function discountCampaignEligible(campaign, context) {
  if (campaign?.active !== true) return false;
  const discountType = campaign.discountType === "fixed" ? "fixed" : "percent";
  const percent = Number(campaign.discountPercent);
  const fixedAmount = money(campaign.fixedDiscountAmount);
  if (discountType === "percent" &&
      (!Number.isFinite(percent) || percent <= 0 || percent > 100)) return false;
  if (discountType === "fixed" && fixedAmount <= 0) return false;
  if (money(campaign.totalPayoutBudget) <= 0) return false;
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
  const payoutMultiplier = Number(campaign.payoutMultiplier) > 0 ?
    Number(campaign.payoutMultiplier) : 2;
  const pritzePayoutAmount = Math.floor(discountAmount * payoutMultiplier);
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
    pritzePayoutAmount,
    salonTotalEarning: original - discountAmount + pritzePayoutAmount,
  };
}

function discountBudgetAllows(campaign, quote, usage) {
  if (quote.discountAmount <= 0 || quote.pritzePayoutAmount <= 0) return false;
  const totalUsed = money(usage.campaign?.reservedPayoutAmount) +
    money(usage.campaign?.realizedPayoutAmount);
  if (totalUsed + quote.pritzePayoutAmount > money(campaign.totalPayoutBudget)) {
    return false;
  }
  const salonBudget = money(campaign.perSalonPayoutBudget);
  const salonUsed = money(usage.salon?.reservedPayoutAmount) +
    money(usage.salon?.realizedPayoutAmount);
  if (salonBudget > 0 && salonUsed + quote.pritzePayoutAmount > salonBudget) {
    return false;
  }
  const customerBudget = money(campaign.perCustomerPayoutBudget);
  const customerUsed = money(usage.customer?.reservedPayoutAmount) +
    money(usage.customer?.realizedPayoutAmount);
  if (
    customerBudget > 0 &&
    customerUsed + quote.pritzePayoutAmount > customerBudget
  ) {
    return false;
  }
  const maximumUses = Math.max(1, money(campaign.maximumUsesPerCustomer) || 1);
  const customerUses = money(usage.customer?.reservedUses) +
    money(usage.customer?.realizedUses);
  if (customerUses >= maximumUses) return false;
  const vaultAllows =
    money(usage.vault?.availableAmount) >= quote.pritzePayoutAmount;
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
      quote.pritzePayoutAmount;
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
    pritzePayoutAmount: 0,
    salonTotalEarning: original,
  };
}

module.exports = {
  calculateDiscountQuote,
  DEFAULT_SALON_PROMOTION_CREDIT_LIMIT,
  DISCOUNT_FUNDING_SOURCES,
  discountBaseAmount,
  discountBudgetAllows,
  discountCampaignEligible,
  discountCampaignSelectableAtCheckout,
  discountFundingSource,
  emptyDiscountQuote,
  money,
  signedMoney,
};
