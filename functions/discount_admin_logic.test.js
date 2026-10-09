const assert = require("node:assert/strict");
const test = require("node:test");
const {
  normalizeDiscountCampaignInput,
  normalizeSalonDiscountBurnMultiplier,
  normalizeDiscountVaultBudget,
} = require("./discount_admin_logic");

function validCampaign(overrides = {}) {
  const now = Date.now();
  return {
    campaignId: "first_visit_2026",
    name: "First visit reward",
    active: false,
    priority: 100,
    discountPercent: 10,
    payoutMultiplier: 2,
    totalPayoutBudget: 50000,
    maximumUsesPerCustomer: 1,
    maximumDiscountAmount: 250,
    minimumServiceAmount: 100,
    perSalonPayoutBudget: 5000,
    perCustomerPayoutBudget: 500,
    startsAtMillis: now,
    endsAtMillis: now + 30 * 24 * 60 * 60 * 1000,
    salonIds: [],
    excludedSalonIds: [],
    customerUids: [],
    serviceIds: [],
    eligibleBookingNumbers: [1],
    minimumBookingNumber: 1,
    maximumBookingNumber: 1,
    newToSalonOnly: false,
    returningToSalonOnly: false,
    termsVersion: "discount-v1",
    ...overrides,
  };
}

test("discount administrator input normalizes all burn and expiry controls", () => {
  const campaign = normalizeDiscountCampaignInput(validCampaign({
    salonIds: ["salon-b", "salon-a", "salon-a"],
    discountPercent: "10.5",
  }));
  assert.equal(campaign.discountPercent, 10.5);
  assert.equal(campaign.payoutMultiplier, 2);
  assert.deepEqual(campaign.salonIds, ["salon-a", "salon-b"]);
  assert.equal(campaign.maximumBookingNumber, 1);
  const cashbackCampaign = normalizeDiscountCampaignInput(validCampaign({
    cashbackProinAmount: 10,
    cashbackValidityDays: 14,
    cashbackTotalBudgetProin: 1000,
  }));
  assert.equal(cashbackCampaign.cashbackProinAmount, 10);
  assert.equal(cashbackCampaign.cashbackValidityDays, 14);
  assert.equal(cashbackCampaign.cashbackTotalBudgetProin, 1000);
  assert.equal(normalizeDiscountVaultBudget("100000"), 100000);
  assert.equal(normalizeSalonDiscountBurnMultiplier("1.5"), 1.5);
  assert.throws(() => normalizeSalonDiscountBurnMultiplier(0.5), /between 1 and 10/i);
});

test("discount administrator supports a capped coupon and booking-specific salon compensation", () => {
  const campaign = normalizeDiscountCampaignInput(validCampaign({
    salonPayoutPercent: "25.5",
    salonPayoutPercentByBookingNumber: {3: "2", 1: "100", 2: "0"},
    totalPayoutBudget: 0,
    maximumDiscountAmount: 75,
  }));
  assert.equal(campaign.maximumDiscountAmount, 75);
  assert.equal(campaign.salonPayoutPercent, 25.5);
  assert.equal(campaign.payoutMultiplier, 0.255);
  assert.deepEqual(campaign.salonPayoutPercentByBookingNumber, {
    1: 100,
    2: 0,
    3: 2,
  });
  assert.equal(campaign.totalPayoutBudget, 0);
  assert.throws(() => normalizeDiscountCampaignInput(validCampaign({
    salonPayoutPercentByBookingNumber: {0: 10},
  })), /booking numbers/i);
});

test("discount administrator input rejects unsafe dates and audiences", () => {
  assert.throws(
    () => normalizeDiscountCampaignInput(validCampaign({
      startsAtMillis: Date.now() + 1000,
      endsAtMillis: Date.now(),
    })),
    /end must be after/i,
  );
  assert.throws(
    () => normalizeDiscountCampaignInput(validCampaign({
      newToSalonOnly: true,
      returningToSalonOnly: true,
    })),
    /cannot be both/i,
  );
  assert.throws(
    () => normalizeDiscountCampaignInput(validCampaign({
      customerUids: ["invalid/path"],
    })),
    /invalid IDs/i,
  );
});

test("discount administrator accepts fixed checkout vouchers", () => {
  const campaign = normalizeDiscountCampaignInput(validCampaign({
    discountType: "fixed",
    fixedDiscountAmount: 150,
    voucherOnly: true,
    visibleAtCheckout: true,
    voucherCode: "GLOW",
  }));
  assert.equal(campaign.discountType, "fixed");
  assert.equal(campaign.discountPercent, 0);
  assert.equal(campaign.fixedDiscountAmount, 150);
  assert.equal(campaign.voucherOnly, true);
  assert.equal(campaign.visibleAtCheckout, true);
  assert.match(campaign.voucherCodeHash, /^[a-f0-9]{64}$/);
  assert.equal(campaign.voucherMaskedCode, "GL••OW");
});

test("visible checkout offers must be voucher campaigns", () => {
  assert.throws(
    () => normalizeDiscountCampaignInput(validCampaign({
      voucherOnly: false,
      visibleAtCheckout: true,
    })),
    /only voucher campaigns/i,
  );
  const hidden = normalizeDiscountCampaignInput(validCampaign({
    voucherOnly: true,
    visibleAtCheckout: false,
    voucherCode: "QUIET",
  }));
  assert.equal(hidden.visibleAtCheckout, false);
});

test("one journey campaign validates independent booking rewards", () => {
  const campaign = normalizeDiscountCampaignInput(validCampaign({
    maximumUsesPerCustomer: 4,
    eligibleBookingNumbers: [],
    maximumBookingNumber: 0,
    journeyCountScope: "salon",
    journeyMilestones: [
      {bookingNumber: 1, rewardType: "discount", discountType: "percent", discountPercent: 10, maximumDiscountAmount: 100},
      {bookingNumber: 2, rewardType: "discount_proin", discountType: "fixed", fixedDiscountAmount: 50, maximumDiscountAmount: 50, cashbackProinAmount: 20, cashbackValidityDays: 30},
      {bookingNumber: 3, rewardType: "proin", discountType: "none", cashbackProinAmount: 40, cashbackValidityDays: 60},
      {bookingNumber: 10, rewardType: "discount", discountType: "fixed", fixedDiscountAmount: 100, maximumDiscountAmount: 100},
    ],
    cashbackTotalBudgetProin: 1000,
  }));
  assert.equal(campaign.discountPercent, 0);
  assert.equal(campaign.journeyCountScope, "salon");
  assert.equal(campaign.journeyMilestones.length, 4);
  assert.equal(campaign.cashbackProinAmount, 40);
  assert.equal(campaign.cashbackValidityDays, 60);
  assert.throws(() => normalizeDiscountCampaignInput(validCampaign({
    maximumUsesPerCustomer: 2,
    journeyMilestones: campaign.journeyMilestones,
    cashbackTotalBudgetProin: 1000,
  })), /cover every configured journey milestone/i);
  assert.throws(() => normalizeDiscountCampaignInput(validCampaign({
    maximumUsesPerCustomer: 2,
    journeyMilestones: [
      {bookingNumber: 1, rewardType: "discount", discountType: "percent", discountPercent: 10},
      {bookingNumber: 1, rewardType: "proin", cashbackProinAmount: 10, cashbackValidityDays: 30},
    ],
    cashbackTotalBudgetProin: 100,
  })), /different booking number/i);
});
