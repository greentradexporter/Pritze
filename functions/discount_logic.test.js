const assert = require("node:assert/strict");
const test = require("node:test");
const fs = require("node:fs");
const path = require("node:path");

const {
  calculateDiscountQuote,
  discountBudgetAllows,
  discountCampaignEligible,
  discountCampaignForContext,
  discountCampaignSelectableAtCheckout,
  discountPayoutMultiplier,
} = require("./discount_logic");

const context = {
  customerUid: "customer-1",
  salonId: "salon-1",
  serviceIds: ["haircut"],
  serviceAmounts: {haircut: 100},
  originalAmount: 100,
  completedBookingCount: 0,
  salonCompletedCount: 0,
  nowMillis: Date.parse("2026-08-21T10:00:00Z"),
};

test("a ten-percent discount pays the salon twice the discount", () => {
  const quote = calculateDiscountQuote("campaign", {
    name: "Welcome",
    discountPercent: 10,
    payoutMultiplier: 2,
  }, 100);
  assert.deepEqual(quote, {
    campaignId: "campaign",
    campaignName: "Welcome",
    fundingSource: "salon_promotion_credits",
    discountType: "percent",
    discountPercent: 10,
    fixedDiscountAmount: 0,
    voucherOnly: false,
    voucherMaskedCode: "",
    originalAmount: 100,
    discountBaseAmount: 100,
    discountAmount: 10,
    customerPayableAmount: 90,
    payoutMultiplierApplied: 2,
    salonPayoutPercentApplied: 200,
    cashbackProinAmount: 0,
    cashbackValidityDays: 0,
    cashbackProgramId: "",
    pritzePayoutAmount: 20,
    salonTotalEarning: 110,
  });
});

test("the global vault multiplier controls salon-funded discount burn", () => {
  const salonCampaign = {
    discountType: "fixed",
    fixedDiscountAmount: 10,
    payoutMultiplier: 7,
    fundingSource: "salon_promotion_credits",
  };
  const multiplier = discountPayoutMultiplier(salonCampaign, {
    salonDiscountBurnMultiplier: 1.5,
  });
  const quote = calculateDiscountQuote(
    "salon-campaign",
    salonCampaign,
    100,
    100,
    multiplier,
  );
  assert.equal(multiplier, 1.5);
  assert.equal(quote.payoutMultiplierApplied, 1.5);
  assert.equal(quote.pritzePayoutAmount, 15);
  assert.equal(discountPayoutMultiplier({
    ...salonCampaign,
    fundingSource: "platform_vault",
    payoutMultiplier: 3,
  }, {salonDiscountBurnMultiplier: 1.5}), 3);
});

test("a campaign can vary salon compensation by the customer's booking number", () => {
  const campaign = {
    discountType: "fixed",
    fixedDiscountAmount: 100,
    fundingSource: "salon_promotion_credits",
    salonPayoutPercent: 50,
    salonPayoutPercentByBookingNumber: {1: 100, 2: 0, 3: 2},
  };
  assert.equal(discountPayoutMultiplier(campaign, {}, 1), 1);
  assert.equal(discountPayoutMultiplier(campaign, {}, 2), 0);
  assert.equal(discountPayoutMultiplier(campaign, {}, 3), 0.02);
  assert.equal(discountPayoutMultiplier(campaign, {}, 4), 0.5);

  const secondBooking = calculateDiscountQuote(
    "booking-two", campaign, 200, 200,
    discountPayoutMultiplier(campaign, {}, 2),
  );
  assert.equal(secondBooking.discountAmount, 100);
  assert.equal(secondBooking.pritzePayoutAmount, 0);
  assert.equal(secondBooking.salonPayoutPercentApplied, 0);
  assert.equal(discountBudgetAllows({
    totalPayoutBudget: 0,
    maximumUsesPerCustomer: 2,
  }, secondBooking, {
    campaign: {}, salon: {}, customer: {}, vault: {availableAmount: 0},
  }), true);
});

test("a fixed voucher discounts the configured rupee amount", () => {
  const campaign = {
    active: true,
    name: "SAVE voucher",
    discountType: "fixed",
    fixedDiscountAmount: 75,
    voucherOnly: true,
    voucherMaskedCode: "SA••",
    payoutMultiplier: 2,
    totalPayoutBudget: 1000,
  };
  assert.equal(discountCampaignEligible(campaign, context), true);
  const quote = calculateDiscountQuote("fixed-voucher", campaign, 100);
  assert.equal(quote.discountType, "fixed");
  assert.equal(quote.discountAmount, 75);
  assert.equal(quote.customerPayableAmount, 25);
  assert.equal(quote.pritzePayoutAmount, 150);
  assert.equal(quote.voucherOnly, true);
});

test("a service-targeted campaign discounts only its matching basket items", () => {
  const campaign = {
    active: true,
    name: "Haircut offer",
    discountPercent: 10,
    payoutMultiplier: 2,
    totalPayoutBudget: 1000,
    serviceIds: ["haircut"],
  };
  const basket = {
    ...context,
    serviceIds: ["haircut", "spa"],
    serviceAmounts: {haircut: 100, spa: 200},
    originalAmount: 300,
  };
  assert.equal(discountCampaignEligible(campaign, basket), true);
  const quote = calculateDiscountQuote("campaign", campaign, 300, 100);
  assert.equal(quote.discountBaseAmount, 100);
  assert.equal(quote.discountAmount, 10);
  assert.equal(quote.customerPayableAmount, 290);
  assert.equal(quote.pritzePayoutAmount, 20);
  assert.equal(quote.salonTotalEarning, 310);
});

test("service-targeted minimum spend uses the eligible service subtotal", () => {
  const campaign = {
    active: true,
    discountPercent: 10,
    totalPayoutBudget: 1000,
    minimumServiceAmount: 200,
    serviceIds: ["haircut"],
  };
  assert.equal(discountCampaignEligible(campaign, {
    ...context,
    serviceIds: ["haircut", "spa"],
    serviceAmounts: {haircut: 100, spa: 1000},
    originalAmount: 1100,
  }), false);
});

test("campaigns can target booking number, salon history, salon and service", () => {
  const firstVisit = {
    active: true,
    discountPercent: 20,
    totalPayoutBudget: 10000,
    eligibleBookingNumbers: [1],
    salonIds: ["salon-1"],
    serviceIds: ["haircut"],
    newToSalonOnly: true,
  };
  assert.equal(discountCampaignEligible(firstVisit, context), true);
  assert.equal(discountCampaignEligible(firstVisit, {
    ...context,
    completedBookingCount: 1,
  }), false);
  assert.equal(discountCampaignEligible(firstVisit, {
    ...context,
    salonCompletedCount: 1,
  }), false);
});

test("one journey campaign resolves different rewards by booking number", () => {
  const campaign = {
    active: true,
    name: "Customer journey",
    journeyCountScope: "platform",
    maximumUsesPerCustomer: 4,
    journeyMilestones: [
      {bookingNumber: 1, rewardType: "discount", discountType: "percent", discountPercent: 10},
      {bookingNumber: 2, rewardType: "discount_proin", discountType: "fixed", fixedDiscountAmount: 20, cashbackProinAmount: 40, cashbackValidityDays: 30},
      {bookingNumber: 3, rewardType: "proin", discountType: "none", cashbackProinAmount: 80, cashbackValidityDays: 45},
      {bookingNumber: 10, rewardType: "discount", discountType: "fixed", fixedDiscountAmount: 50},
    ],
  };
  const first = discountCampaignForContext(campaign, context);
  assert.equal(first.discountPercent, 10);
  assert.equal(first.cashbackProinAmount, 0);
  const second = discountCampaignForContext(campaign, {
    ...context,
    completedBookingCount: 1,
  });
  assert.equal(second.fixedDiscountAmount, 20);
  assert.equal(second.cashbackProinAmount, 40);
  const thirdContext = {...context, completedBookingCount: 2};
  const third = discountCampaignForContext(campaign, thirdContext);
  assert.equal(discountCampaignEligible(campaign, thirdContext), true);
  const proinOnlyQuote = calculateDiscountQuote(
    "journey",
    third,
    100,
  );
  assert.equal(proinOnlyQuote.discountAmount, 0);
  assert.equal(proinOnlyQuote.cashbackProinAmount, 80);
  assert.equal(discountBudgetAllows(campaign, proinOnlyQuote, {
    campaign: {}, salon: {}, customer: {}, vault: {availableAmount: 0},
  }), true);
  assert.equal(discountCampaignEligible(campaign, {
    ...context,
    completedBookingCount: 3,
  }), false);
});

test("salon-scoped journeys count only completed visits at that salon", () => {
  const campaign = {
    active: true,
    journeyCountScope: "salon",
    journeyMilestones: [
      {bookingNumber: 2, rewardType: "discount", discountType: "fixed", fixedDiscountAmount: 25},
    ],
  };
  assert.equal(discountCampaignEligible(campaign, {
    ...context,
    completedBookingCount: 8,
    salonCompletedCount: 1,
  }), true);
});

test("checkout offers require selection and hide private vouchers", () => {
  const automaticCampaign = {
    active: true,
    discountPercent: 10,
    totalPayoutBudget: 1000,
  };
  const visibleVoucher = {
    ...automaticCampaign,
    voucherOnly: true,
    visibleAtCheckout: true,
  };
  const privateVoucher = {
    ...visibleVoucher,
    visibleAtCheckout: false,
  };

  assert.equal(
    discountCampaignSelectableAtCheckout(automaticCampaign, context),
    true,
  );
  assert.equal(
    discountCampaignSelectableAtCheckout(visibleVoucher, context),
    true,
  );
  assert.equal(
    discountCampaignSelectableAtCheckout(privateVoucher, context),
    false,
  );
});

test("campaign, salon, customer and vault limits all protect burn", () => {
  const campaign = {
    totalPayoutBudget: 100,
    perSalonPayoutBudget: 50,
    perCustomerPayoutBudget: 30,
    maximumUsesPerCustomer: 1,
  };
  const quote = calculateDiscountQuote("campaign", {
    discountPercent: 10,
    payoutMultiplier: 2,
  }, 100);
  const available = {
    campaign: {},
    salon: {},
    customer: {},
    vault: {availableAmount: 100},
  };
  assert.equal(discountBudgetAllows(campaign, quote, available), true);
  assert.equal(discountBudgetAllows(campaign, quote, {
    ...available,
    customer: {reservedUses: 1},
  }), false);
  assert.equal(discountBudgetAllows(campaign, quote, {
    ...available,
    vault: {availableAmount: 19},
  }), false);
});

test("salon-funded discounts can use a configurable negative credit line", () => {
  const campaign = {
    totalPayoutBudget: 2000,
    fundingSource: "salon_promotion_credits",
    maximumUsesPerCustomer: 10,
  };
  const quote = calculateDiscountQuote("campaign", {
    discountType: "fixed",
    fixedDiscountAmount: 500,
    payoutMultiplier: 2,
    fundingSource: "salon_promotion_credits",
  }, 1000);
  const usage = {
    campaign: {},
    salon: {},
    customer: {},
    vault: {availableAmount: 1000, salonCreditLimitAmount: 1000},
    salonCreditWallet: {availableProin: 0},
  };
  assert.equal(quote.pritzePayoutAmount, 1000);
  assert.equal(discountBudgetAllows(campaign, quote, usage), true);
  assert.equal(discountBudgetAllows(campaign, quote, {
    ...usage,
    salonCreditWallet: {availableProin: -1},
  }), false);
  assert.equal(discountBudgetAllows(campaign, quote, {
    ...usage,
    vault: {availableAmount: 1000, salonCreditLimitAmount: 0},
  }), false);
});

test("platform-funded discounts still use the central vault only", () => {
  const campaign = {
    totalPayoutBudget: 2000,
    fundingSource: "platform_vault",
    maximumUsesPerCustomer: 10,
  };
  const quote = calculateDiscountQuote("campaign", {
    discountType: "fixed",
    fixedDiscountAmount: 500,
    payoutMultiplier: 2,
    fundingSource: "platform_vault",
  }, 1000);
  assert.equal(discountBudgetAllows(campaign, quote, {
    campaign: {},
    salon: {},
    customer: {},
    vault: {availableAmount: 1000, salonCreditLimitAmount: 0},
    salonCreditWallet: {availableProin: -1000},
  }), true);
});

test("shown quotes are consumed and financial totals are tracked server-side", () => {
  const source = fs.readFileSync(path.join(__dirname, "index.js"), "utf8");
  assert.match(source, /exports\.listCheckoutDiscountOffers = onMobileCall/);
  assert.match(source, /exports\.applyVisibleCheckoutDiscount = onMobileCall/);
  assert.match(source, /visibleAtCheckout === true/);
  assert.match(source, /collection\("discountQuotes"\)\.doc/);
  assert.match(source, /lockedDiscountQuoteError/);
  assert.match(source, /consumedByBookingId: bookingRef\.id/);
  assert.match(source, /discountGlobalTotalsTracked/);
  assert.match(source, /collection\("discountPlatformTotals"\)/);
  assert.match(source, /collection\("discountSalonPromotionCreditReservations"\)/);
  assert.match(source, /collection\("salonPromotionCreditUsage"\)/);
  assert.match(source, /loadDiscountCandidateFunding/);
  assert.match(source, /firestore\.getAll\(/);
});
