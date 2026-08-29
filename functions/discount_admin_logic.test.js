const assert = require("node:assert/strict");
const test = require("node:test");
const {
  normalizeDiscountCampaignInput,
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
  assert.equal(normalizeDiscountVaultBudget("100000"), 100000);
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
