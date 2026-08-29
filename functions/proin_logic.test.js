const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const {
  ProinValidationError,
  allocateProinLots,
  normalizeProinProgramInput,
  proinFinanceInvariant,
  proinLotInvariant,
  proinProgramGrantAllowed,
  proinRedemptionPolicyFromProgram,
  proinWalletInvariant,
  proinWalletSummaryFromLots,
  quoteProinRedemption,
} = require("./proin_logic");

const programInput = {
  name: "Customer referral reward",
  sourceType: "referral_customer",
  walletType: "customer_rewards",
  qualificationEvent: "first_completed_booking",
  rewardRecipient: "referred",
  referralInviterRole: "customer",
  active: true,
  rewardAmountProin: 100,
  rewardValidityDays: 90,
  totalBudgetProin: 10000,
  maximumTotalGrants: 100,
  maximumGrantsPerAccount: 1,
  minimumBookingAmount: 100,
  maximumProinPerBooking: 250,
  maximumRedemptionPercent: 25,
  stackableWithDiscount: false,
  startsAtMillis: Date.parse("2026-08-01T00:00:00Z"),
  endsAtMillis: Date.parse("2026-12-31T23:59:59Z"),
  eligibleSalonIds: ["salon-b", "salon-a", "salon-a"],
  eligibleServiceIds: [],
  termsVersion: "proin-v1",
};

test("Proin programs normalize integer, expiry and eligibility controls", () => {
  const normalized = normalizeProinProgramInput(programInput);
  assert.equal(normalized.rewardAmountProin, 100);
  assert.equal(normalized.rewardValidityDays, 90);
  assert.equal(normalized.maximumRedemptionPercent, 25);
  assert.deepEqual(normalized.eligibleSalonIds, ["salon-a", "salon-b"]);
});

test("coupon programs can award salon promotional credits", () => {
  const normalized = normalizeProinProgramInput({
    ...programInput,
    name: "Salon coupon reward",
    sourceType: "coupon",
    walletType: "salon_promotion_credits",
    qualificationEvent: "coupon_claimed",
    rewardRecipient: "account",
    referralInviterRole: "",
    maximumRedemptionPercent: 100,
  });
  assert.equal(normalized.sourceType, "coupon");
  assert.equal(normalized.walletType, "salon_promotion_credits");
  assert.equal(normalized.qualificationEvent, "coupon_claimed");
});

test("Proin programs reject unsafe budgets, percentages and expiries", () => {
  assert.throws(
    () => normalizeProinProgramInput({
      ...programInput,
      totalBudgetProin: 50,
    }),
    ProinValidationError,
  );
  assert.throws(
    () => normalizeProinProgramInput({
      ...programInput,
      maximumRedemptionPercent: 101,
    }),
    ProinValidationError,
  );
  assert.throws(
    () => normalizeProinProgramInput({
      ...programInput,
      rewardValidityDays: 731,
    }),
    ProinValidationError,
  );
  assert.throws(
    () => normalizeProinProgramInput({
      ...programInput,
      rewardRecipient: "inviter",
      referralInviterRole: "owner",
      walletType: "customer_rewards",
    }),
    ProinValidationError,
  );
});

test("grant checks protect active dates, program budget and grant count", () => {
  const program = {
    ...programInput,
    startsAt: programInput.startsAtMillis,
    endsAt: programInput.endsAtMillis,
  };
  const nowMillis = Date.parse("2026-08-21T10:00:00Z");
  assert.equal(proinProgramGrantAllowed({
    program,
    usage: {},
    nowMillis,
  }).allowed, true);
  assert.equal(proinProgramGrantAllowed({
    program,
    usage: {grantedProin: 9950},
    nowMillis,
  }).allowed, false);
  assert.equal(proinProgramGrantAllowed({
    program,
    usage: {grantCount: 100},
    nowMillis,
  }).allowed, false);
});

test("Proin redemption allocation spends the earliest-expiring lots first", () => {
  const allocation = allocateProinLots([
    {
      id: "later",
      status: "active",
      availableProin: 100,
      earnedAt: 2,
      expiresAt: 500,
    },
    {
      id: "expired",
      status: "active",
      availableProin: 100,
      earnedAt: 1,
      expiresAt: 50,
    },
    {
      id: "sooner",
      status: "active",
      availableProin: 40,
      earnedAt: 1,
      expiresAt: 300,
    },
  ], 120, 100);
  assert.deepEqual(allocation.allocations.map((item) => [
    item.lotId,
    item.amountProin,
  ]), [
    ["sooner", 40],
    ["later", 80],
  ]);
  assert.equal(allocation.shortfallProin, 0);
});

test("booking redemption quotes enforce immutable reward restrictions", () => {
  const policy = proinRedemptionPolicyFromProgram(programInput);
  const lots = [
    {
      id: "eligible-sooner",
      programId: "referral-v1",
      status: "active",
      availableProin: 80,
      earnedAt: 100,
      expiresAt: 500,
      redemptionPolicy: policy,
    },
    {
      id: "eligible-later",
      programId: "referral-v1",
      status: "active",
      availableProin: 80,
      earnedAt: 200,
      expiresAt: 800,
      redemptionPolicy: policy,
    },
  ];
  const quote = quoteProinRedemption({
    lots,
    originalAmount: 1000,
    discountAmount: 0,
    salonId: "salon-a",
    serviceIds: ["service-1"],
    nowMillis: 250,
  });
  assert.equal(quote.maximumRedeemableProin, 160);
  assert.equal(quote.customerPayableAmount, 840);
  assert.deepEqual(quote.allocations.map((allocation) => allocation.lotId), [
    "eligible-sooner",
    "eligible-later",
  ]);

  const discounted = quoteProinRedemption({
    lots,
    originalAmount: 1000,
    discountAmount: 100,
    salonId: "salon-a",
    serviceIds: ["service-1"],
    nowMillis: 250,
  });
  assert.equal(discounted.maximumRedeemableProin, 0);
  assert.equal(discounted.customerPayableAmount, 900);

  const wrongSalon = quoteProinRedemption({
    lots,
    originalAmount: 1000,
    salonId: "salon-c",
    serviceIds: ["service-1"],
    nowMillis: 250,
  });
  assert.equal(wrongSalon.maximumRedeemableProin, 0);
});

test("booking redemption respects service, minimum-price and selected limits", () => {
  const restrictedPolicy = proinRedemptionPolicyFromProgram({
    ...programInput,
    eligibleSalonIds: [],
    eligibleServiceIds: ["haircut", "wash"],
    minimumBookingAmount: 200,
    maximumProinPerBooking: 40,
    maximumRedemptionPercent: 20,
    stackableWithDiscount: true,
  });
  const lots = [{
    id: "restricted",
    programId: "restricted-program",
    status: "active",
    availableProin: 100,
    earnedAt: 100,
    expiresAt: 1000,
    redemptionPolicy: restrictedPolicy,
  }];
  const quote = quoteProinRedemption({
    lots,
    originalAmount: 250,
    discountAmount: 50,
    salonId: "any-salon",
    serviceIds: ["haircut", "wash"],
    nowMillis: 200,
    requestedProin: 30,
  });
  assert.equal(quote.allocatedProin, 30);
  assert.equal(quote.shortfallProin, 0);
  assert.equal(quote.customerPayableAmount, 170);

  const unavailableService = quoteProinRedemption({
    lots,
    originalAmount: 250,
    salonId: "any-salon",
    serviceIds: ["haircut", "colour"],
    nowMillis: 200,
  });
  assert.equal(unavailableService.allocatedProin, 0);

  const belowMinimum = quoteProinRedemption({
    lots,
    originalAmount: 199,
    salonId: "any-salon",
    serviceIds: ["haircut"],
    nowMillis: 200,
  });
  assert.equal(belowMinimum.allocatedProin, 0);
});

test("lot, wallet and finance totals preserve double-entry invariants", () => {
  const lots = [
    {
      id: "lot-1",
      status: "active",
      originalProin: 100,
      availableProin: 50,
      reservedProin: 20,
      redeemedProin: 10,
      expiredProin: 15,
      revokedProin: 5,
      expiresAt: 1000,
    },
  ];
  assert.equal(proinLotInvariant(lots[0]), true);
  const wallet = proinWalletSummaryFromLots(lots);
  assert.equal(proinWalletInvariant(wallet), true);
  assert.deepEqual(wallet, {
    availableProin: 50,
    reservedProin: 20,
    lifetimeGrantedProin: 100,
    lifetimeRedeemedProin: 10,
    lifetimeExpiredProin: 15,
    lifetimeRevokedProin: 5,
    nextExpiryAtMillis: 1000,
  });
  assert.equal(proinFinanceInvariant({
    approvedBudgetInr: 1000,
    unallocatedBudgetInr: 800,
    outstandingLiabilityInr: 100,
    reservedLiabilityInr: 20,
    redeemedPayableInr: 50,
    settledExpenseInr: 50,
  }), true);
});

test("salon promotional wallets can use a bounded negative credit line", () => {
  assert.equal(proinWalletInvariant({
    walletType: "salon_promotion_credits",
    availableProin: -1000,
    reservedProin: 0,
    creditLimitProin: 1000,
    lifetimeGrantedProin: 0,
    lifetimeRedeemedProin: 1000,
    lifetimeExpiredProin: 0,
    lifetimeRevokedProin: 0,
  }), true);
  assert.equal(proinWalletInvariant({
    walletType: "salon_promotion_credits",
    availableProin: -1001,
    reservedProin: 0,
    creditLimitProin: 1000,
    lifetimeGrantedProin: 0,
    lifetimeRedeemedProin: 1001,
    lifetimeExpiredProin: 0,
    lifetimeRevokedProin: 0,
  }), false);
  assert.throws(() => proinWalletInvariant({
    walletType: "customer_rewards",
    availableProin: -1,
    reservedProin: 0,
    lifetimeGrantedProin: 0,
    lifetimeRedeemedProin: 1,
    lifetimeExpiredProin: 0,
    lifetimeRevokedProin: 0,
  }), ProinValidationError);
});

test("Phase 1 backend is server-only, idempotent and auditable", () => {
  const indexSource = fs.readFileSync(
    path.join(__dirname, "index.js"),
    "utf8",
  );
  const backendSource = fs.readFileSync(
    path.join(__dirname, "proin_backend.js"),
    "utf8",
  );
  for (const callable of [
    "getProinPhaseOneDataAsAdmin",
    "upsertProinProgramAsAdmin",
    "setProinFinanceBudgetAsAdmin",
    "grantProinAsAdmin",
    "runProinReconciliationAsAdmin",
  ]) {
    assert.match(indexSource, new RegExp(`exports\\.${callable} = onCall`));
  }
  assert.match(indexSource, /requirePlatformAdministrator\(request\)/);
  assert.match(indexSource, /exports\.expireProinLots = onSchedule/);
  assert.match(indexSource, /exports\.reconcileProinFinancialState = onSchedule/);
  assert.match(backendSource, /collection\("proinIdempotencyKeys"\)/);
  assert.match(backendSource, /transaction\.create\(ledgerRef/);
  assert.match(backendSource, /regulatoryMode: "promotional_reward_only"/);
  assert.match(backendSource, /cashWithdrawable: false/);
  assert.match(backendSource, /transferable: false/);
  assert.match(backendSource, /purchasable: false/);
  assert.match(backendSource, /collection\("adminAuditLogs"\)/);
});
