const assert = require("node:assert/strict");
const test = require("node:test");

// Drives the real booking callables against the Firestore emulator, so the
// salon-credit and Proin ledger steps are checked inside the same
// transactions that run in production. No credentials or network are used.
test("a salon-funded booking keeps the Proin ledger balanced end to end", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async (t) => {
  process.env.GCLOUD_PROJECT = "demo-pritze-booking-ledger";
  const admin = require("firebase-admin");
  const {HttpsError} = require("firebase-functions/v2/https");
  const functions = require("./index");
  const {createProinBackend} = require("./proin_backend");
  const realMessaging = Object.getOwnPropertyDescriptor(admin, "messaging");
  Object.defineProperty(admin, "messaging", {
    configurable: true,
    value: () => ({sendEachForMulticast: async (message) => ({
      successCount: message.tokens.length,
      failureCount: 0,
      responses: message.tokens.map(() => ({success: true})),
    })}),
  });
  t.after(() => {
    if (realMessaging) Object.defineProperty(admin, "messaging", realMessaging);
    else delete admin.messaging;
  });

  const firestore = admin.firestore();
  const backend = createProinBackend({admin, HttpsError});
  const nowMillis = Date.now();
  const set = (path, data) => firestore.doc(path).set(data);
  await Promise.all([
    set("users/customer-1", {
      role: "customer",
      activeRole: "customer",
      name: "Ledger Customer",
      phone: "+919000000001",
      completedBookingCount: 0,
    }),
    set("users/owner-1", {role: "owner", activeRole: "owner"}),
    set("users/barber-1", {role: "barber", activeRole: "barber"}),
    set("platformAdmins/admin-1", {active: true}),
    set("salons/salon-1", {
      ownerUid: "owner-1",
      isOpen: true,
      approvalStatus: "approved",
      instantBookingsEnabled: true,
      openTime: "12:00 AM",
      closeTime: "11:59 PM",
      services: [
        {id: "haircut", name: "Haircut", price: 400, durationMinutes: 30},
      ],
    }),
    set("barbers/barber-1", {
      salonId: "salon-1",
      uid: "barber-1",
      serviceIds: ["haircut"],
    }),
    set("platformFinance/discountVault", {
      availableAmount: 5000,
      reservedAmount: 0,
      spentAmount: 0,
    }),
    set("discountCampaigns/salon-funded", {
      active: true,
      name: "Salon funded offer",
      fundingSource: "salon_promotion_credits",
      discountType: "fixed",
      fixedDiscountAmount: 50,
      totalPayoutBudget: 5000,
      maximumUsesPerCustomer: 10,
    }),
  ]);

  await backend.setFinanceBudget({
    adminUid: "admin-1",
    data: {approvedBudgetInr: 5000},
    reason: "Approve isolated booking ledger test budget",
  });
  const program = (overrides) => backend.upsertProgram({
    adminUid: "admin-1",
    reason: "Create isolated booking ledger test program",
    data: {
      name: "Booking ledger test",
      sourceType: "manual",
      qualificationEvent: "manual_approval",
      active: true,
      rewardValidityDays: 14,
      totalBudgetProin: 5000,
      maximumTotalGrants: 10,
      maximumGrantsPerAccount: 1,
      minimumBookingAmount: 0,
      maximumRedemptionPercent: 100,
      stackableWithDiscount: true,
      startsAtMillis: nowMillis - 60_000,
      endsAtMillis: nowMillis + 24 * 60 * 60 * 1000,
      eligibleSalonIds: [],
      eligibleServiceIds: [],
      termsVersion: "booking-ledger-v1",
      ...overrides,
    },
  });
  await program({
    programId: "ledger_salon_credit",
    walletType: "salon_promotion_credits",
    rewardAmountProin: 120,
    maximumProinPerBooking: 120,
    maximumGrantsPerAccount: 2,
  });
  await program({
    programId: "ledger_customer_reward",
    walletType: "customer_rewards",
    rewardAmountProin: 30,
    maximumProinPerBooking: 30,
  });
  const grant = (programId, walletType, accountId, key = "first") =>
    backend.grantAsAdmin({
      adminUid: "admin-1",
      reason: "Grant isolated booking ledger test reward",
      data: {
        programId,
        walletType,
        accountId,
        idempotencyKey: `booking-ledger:${programId}:${key}`,
      },
    });
  const salonGrant = await grant(
    "ledger_salon_credit",
    "salon_promotion_credits",
    "salon-1",
  );
  await grant("ledger_customer_reward", "customer_rewards", "customer-1");

  const lotRef = firestore.collection("proinLots").doc(salonGrant.lotId);
  const walletRef = firestore.collection("proinWallets")
    .doc(salonGrant.walletId);
  const financeRef = firestore.doc("proinFinance/current");
  const read = async (ref) => (await ref.get()).data();
  const balanced = async () => {
    const report = await backend.reconcile();
    assert.equal(report.status, "balanced", JSON.stringify(report));
  };

  // A locked checkout quote for the salon-funded offer, as the quote callable
  // stores it. The payout is what the salon's promotional credit must cover.
  const book = async (quoteId, pritzePayoutAmount, requestedProin = 0) => {
    await set(`discountQuotes/${quoteId}`, {
      customerUid: "customer-1",
      salonId: "salon-1",
      serviceIds: ["haircut"],
      originalAmount: 400,
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 600_000),
      discountCampaignId: "salon-funded",
      discountCampaignName: "Salon funded offer",
      discountFundingSource: "salon_promotion_credits",
      discountType: "fixed",
      fixedDiscountAmount: 50,
      discountBaseAmount: 400,
      discountAmount: 50,
      customerPayableAmount: 350,
      pritzePayoutAmount,
      salonTotalEarning: 350 + pritzePayoutAmount,
    });
    const result = await functions.createBooking.run({
      auth: {uid: "customer-1"},
      data: {
        salonId: "salon-1",
        serviceId: "haircut",
        isInstant: true,
        arrivalMinutes: 15,
        quoteId,
        requestedProin,
      },
    });
    return result.bookingId;
  };
  const ownerSets = (bookingId, status) => functions.updateBookingStatus.run({
    auth: {uid: "owner-1"},
    data: {bookingId, status},
  });
  const adminSetsCreditLimit = (creditLimitProin) =>
    functions.setSalonPromotionCreditLimitAsAdmin.run({
      auth: {uid: "admin-1", token: {}},
      data: {
        salonId: "salon-1",
        creditLimitProin,
        reason: "Change isolated booking ledger test credit limit",
      },
    });

  // 1. Granted credit covers the whole payout and the customer also uses
  //    Proin, so both ledgers move in the same transactions.
  const first = await book("quote-1", 80, 30);
  const held = await read(firestore.collection("bookings").doc(first));
  assert.equal(held.discountStatus, "reserved");
  assert.equal(held.proinReservedAmount, 30);
  assert.equal(held.customerPayableAmount, 320);
  assert.deepEqual(
    [(await read(lotRef)).availableProin, (await read(lotRef)).reservedProin],
    [40, 80],
  );
  assert.equal((await read(financeRef)).reservedLiabilityInr, 30);
  assert.equal((await read(financeRef)).outstandingLiabilityInr, 150);
  await balanced();

  for (const status of ["confirmed", "inProgress", "completed"]) {
    assert.equal((await ownerSets(first, status)).status, status);
  }
  const completed = await read(firestore.collection("bookings").doc(first));
  assert.equal(completed.discountStatus, "redeemed");
  assert.equal(completed.proinRedeemedAmount, 30);
  const lotAfterFirst = await read(lotRef);
  assert.equal(lotAfterFirst.availableProin, 40);
  assert.equal(lotAfterFirst.reservedProin, 0);
  assert.equal(lotAfterFirst.redeemedProin, 80);
  const financeAfterFirst = await read(financeRef);
  // Customer Proin becomes a salon payable; spent salon credit returns to the
  // unallocated budget because its payout is a discount-vault settlement.
  assert.equal(financeAfterFirst.outstandingLiabilityInr, 40);
  assert.equal(financeAfterFirst.reservedLiabilityInr, 0);
  assert.equal(financeAfterFirst.redeemedPayableInr, 30);
  assert.equal(financeAfterFirst.unallocatedBudgetInr, 4930);
  assert.equal(
    (await read(firestore.doc(`proinSalonReimbursements/${first}`))).amountInr,
    30,
  );
  assert.equal(
    (await read(firestore.doc(`salonSettlements/${first}`))).pritzePayoutAmount,
    80,
  );
  await balanced();

  // 2. The payout is larger than the credit left: the lot is used first and
  //    the credit line covers the rest. Rejecting the booking undoes both.
  const second = await book("quote-2", 100);
  assert.deepEqual(
    [(await read(lotRef)).availableProin, (await read(lotRef)).reservedProin],
    [0, 40],
  );
  assert.equal((await read(walletRef)).availableProin, -60);
  assert.equal((await read(walletRef)).reservedProin, 100);
  await balanced();
  assert.equal((await ownerSets(second, "rejected")).status, "rejected");
  assert.equal((await read(lotRef)).availableProin, 40);
  assert.equal((await read(walletRef)).availableProin, 40);
  assert.equal((await read(walletRef)).reservedProin, 0);
  assert.equal((await read(financeRef)).outstandingLiabilityInr, 40);
  await balanced();

  // 3. The same split, completed: the lot is fully spent and only the
  //    lot-backed part leaves the Proin liability.
  const third = await book("quote-3", 100);
  for (const status of ["confirmed", "inProgress", "completed"]) {
    await ownerSets(third, status);
  }
  const lotAfterThird = await read(lotRef);
  assert.equal(lotAfterThird.availableProin, 0);
  assert.equal(lotAfterThird.redeemedProin, 120);
  const walletAfterThird = await read(walletRef);
  assert.equal(walletAfterThird.availableProin, -60);
  assert.equal(walletAfterThird.lifetimeRedeemedProin, 180);
  const financeAfterThird = await read(financeRef);
  assert.equal(financeAfterThird.outstandingLiabilityInr, 0);
  assert.equal(financeAfterThird.unallocatedBudgetInr, 4970);
  assert.equal(financeAfterThird.redeemedPayableInr, 30);
  await balanced();

  // 4. With the credit line at its limit the offer is withdrawn at checkout
  //    instead of the booking being refused when the credit is reserved.
  await adminSetsCreditLimit(60);
  await assert.rejects(
    book("quote-4", 100),
    /This discount is no longer available/,
  );
  const withoutOffer = await functions.createBooking.run({
    auth: {uid: "customer-1"},
    data: {
      salonId: "salon-1",
      serviceId: "haircut",
      isInstant: true,
      arrivalMinutes: 15,
    },
  });
  const plain = await read(
    firestore.collection("bookings").doc(withoutOffer.bookingId),
  );
  assert.equal(plain.customerPayableAmount, 400);
  await balanced();

  // 5. New credit lifts the balance above zero, but the Rs 60 already used on
  //    the credit line still stands. A limit below it would leave the new
  //    credit unable to expire, so it is refused.
  await grant(
    "ledger_salon_credit",
    "salon_promotion_credits",
    "salon-1",
    "second",
  );
  assert.equal((await read(walletRef)).availableProin, 60);
  await assert.rejects(
    adminSetsCreditLimit(0),
    /already used on its credit line/,
  );
  assert.equal((await adminSetsCreditLimit(60)).creditLimitProin, 60);
  await balanced();
});
