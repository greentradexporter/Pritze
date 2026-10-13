const assert = require("node:assert/strict");
const test = require("node:test");
const admin = require("firebase-admin");
const {HttpsError} = require("firebase-functions/v2/https");
const {createProinBackend} = require("./proin_backend");

test("Proin rewards and Phase 4 controls stay idempotent and balanced", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async () => {
  const app = admin.initializeApp({projectId: "demo-pritze-proin"}, "proin-test");
  const scopedAdmin = {
    firestore: Object.assign(
      () => admin.firestore(app),
      {FieldValue: admin.firestore.FieldValue, Timestamp: admin.firestore.Timestamp},
    ),
  };
  const backend = createProinBackend({admin: scopedAdmin, HttpsError});
  const firestore = admin.firestore(app);
  const nowMillis = Date.now();
  try {
    await firestore.collection("users").doc("customer-proin-1").set({
      role: "customer",
      name: "Proin Test Customer",
    });
    await firestore.collection("users").doc("customer-proin-2").set({
      role: "customer",
      name: "Proin Referral Customer",
    });
    const finance = await backend.setFinanceBudget({
      adminUid: "admin-1",
      data: {approvedBudgetInr: 1000},
      reason: "Approve isolated Proin integration test budget",
    });
    assert.equal(finance.unallocatedBudgetInr, 1000);

    await backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Create isolated manual Proin integration test program",
      data: {
        programId: "manual_integration_test",
        name: "Manual integration test",
        sourceType: "manual",
        walletType: "customer_rewards",
        qualificationEvent: "manual_approval",
        active: true,
        rewardAmountProin: 100,
        rewardValidityDays: 1,
        totalBudgetProin: 1000,
        maximumTotalGrants: 10,
        maximumGrantsPerAccount: 1,
        minimumBookingAmount: 0,
        maximumProinPerBooking: 100,
        maximumRedemptionPercent: 25,
        stackableWithDiscount: false,
        startsAtMillis: nowMillis - 60_000,
        endsAtMillis: nowMillis + 24 * 60 * 60 * 1000,
        eligibleSalonIds: [],
        eligibleServiceIds: [],
        termsVersion: "integration-v1",
      },
    });

    const grantRequest = {
      adminUid: "admin-1",
      reason: "Grant isolated integration test reward",
      data: {
        programId: "manual_integration_test",
        walletType: "customer_rewards",
        accountId: "customer-proin-1",
        sourceId: "integration-case-1",
        idempotencyKey: "integration:manual:customer-proin-1",
      },
    };
    const firstGrant = await backend.grantAsAdmin(grantRequest);
    const duplicateGrant = await backend.grantAsAdmin(grantRequest);
    assert.equal(firstGrant.duplicate, false);
    assert.equal(duplicateGrant.duplicate, true);
    assert.equal(duplicateGrant.lotId, firstGrant.lotId);

    const [lotsBefore, ledgerBefore, walletBefore, financeBefore] =
      await Promise.all([
        firestore.collection("proinLots").get(),
        firestore.collection("proinLedger").get(),
        firestore.collection("proinWallets").doc(firstGrant.walletId).get(),
        firestore.collection("proinFinance").doc("current").get(),
      ]);
    assert.equal(lotsBefore.size, 1);
    assert.equal(ledgerBefore.size, 1);
    assert.equal(walletBefore.data().availableProin, 100);
    assert.equal(financeBefore.data().outstandingLiabilityInr, 100);
    assert.equal(financeBefore.data().unallocatedBudgetInr, 900);

    await firestore.collection("proinLots").doc(firstGrant.lotId).update({
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() - 1),
    });
    const expiry = await backend.expireLots();
    assert.equal(expiry.expiredCount, 1);
    assert.equal(expiry.expiredProin, 100);

    const [walletAfter, financeAfter, ledgerAfter] = await Promise.all([
      firestore.collection("proinWallets").doc(firstGrant.walletId).get(),
      firestore.collection("proinFinance").doc("current").get(),
      firestore.collection("proinLedger").get(),
    ]);
    assert.equal(walletAfter.data().availableProin, 0);
    assert.equal(walletAfter.data().lifetimeExpiredProin, 100);
    assert.equal(financeAfter.data().outstandingLiabilityInr, 0);
    assert.equal(financeAfter.data().unallocatedBudgetInr, 1000);
    assert.equal(ledgerAfter.size, 2);

    await backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Create isolated coupon integration test program",
      data: {
        programId: "coupon_integration_test",
        name: "Coupon integration test",
        sourceType: "coupon",
        walletType: "customer_rewards",
        qualificationEvent: "coupon_claimed",
        active: true,
        rewardAmountProin: 50,
        rewardValidityDays: 30,
        totalBudgetProin: 500,
        maximumTotalGrants: 10,
        maximumGrantsPerAccount: 1,
        minimumBookingAmount: 0,
        maximumProinPerBooking: 50,
        maximumRedemptionPercent: 25,
        stackableWithDiscount: false,
        startsAtMillis: nowMillis - 60_000,
        endsAtMillis: nowMillis + 24 * 60 * 60 * 1000,
        eligibleSalonIds: [],
        eligibleServiceIds: [],
        termsVersion: "coupon-integration-v1",
      },
    });
    const coupon = await backend.upsertCoupon({
      adminUid: "admin-1",
      reason: "Create isolated hashed coupon integration test",
      data: {
        code: "SAVE50",
        programId: "coupon_integration_test",
        active: true,
        claimStartsAtMillis: nowMillis - 60_000,
        claimEndsAtMillis: nowMillis + 24 * 60 * 60 * 1000,
        maximumClaimsTotal: 10,
        eligibleCustomerUids: [],
        termsVersion: "coupon-integration-v1",
      },
    });
    await assert.rejects(
      backend.upsertCoupon({
        adminUid: "admin-1",
        reason: "Reject an accidental coupon identity change",
        data: {
          code: "OTHER50",
          expectedCodeHash: coupon.codeHash,
          programId: "coupon_integration_test",
          active: true,
          claimStartsAtMillis: nowMillis - 60_000,
          claimEndsAtMillis: nowMillis + 24 * 60 * 60 * 1000,
          maximumClaimsTotal: 10,
          eligibleCustomerUids: [],
          termsVersion: "coupon-integration-v1",
        },
      }),
      /does not match the coupon being edited/i,
    );
    const firstCouponClaim = await backend.claimCoupon({
      uid: "customer-proin-1",
      rawCode: "save50",
    });
    const duplicateCouponClaim = await backend.claimCoupon({
      uid: "customer-proin-1",
      rawCode: "SAVE50",
    });
    assert.equal(firstCouponClaim.alreadyClaimed, false);
    assert.equal(duplicateCouponClaim.alreadyClaimed, true);
    assert.equal(duplicateCouponClaim.lotId, firstCouponClaim.lotId);
    assert.equal(firstCouponClaim.amountProin, 50);
    const [storedCoupon, couponUsage, couponClaims] = await Promise.all([
      firestore.collection("proinCoupons").doc(coupon.codeHash).get(),
      firestore.collection("proinCouponUsage").doc(coupon.codeHash).get(),
      firestore.collection("proinCouponClaims").get(),
    ]);
    assert.equal(storedCoupon.data().storesPlaintextCode, false);
    assert.equal(Object.hasOwn(storedCoupon.data(), "code"), false);
    assert.equal(couponUsage.data().claimedCount, 1);
    assert.equal(couponUsage.data().reservedClaims, 0);
    assert.equal(couponClaims.size, 1);
    assert.equal(couponClaims.docs[0].data().status, "awarded");
    const customerWalletView = await backend.customerWalletData({
      uid: "customer-proin-1",
    });
    assert.ok(customerWalletView.expiringLots.some(
      (lot) => lot.lotId === firstCouponClaim.lotId &&
        lot.amountProin === 50 && lot.expiresAtMillis > nowMillis,
    ));

    await backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Create isolated referral integration test program",
      data: {
        programId: "referral_integration_test",
        name: "Referral integration test",
        sourceType: "referral_customer",
        walletType: "customer_rewards",
        qualificationEvent: "first_completed_booking",
        rewardRecipient: "inviter",
        referralInviterRole: "customer",
        active: true,
        rewardAmountProin: 25,
        rewardValidityDays: 30,
        totalBudgetProin: 250,
        maximumTotalGrants: 10,
        maximumGrantsPerAccount: 10,
        minimumBookingAmount: 0,
        maximumProinPerBooking: 25,
        maximumRedemptionPercent: 25,
        stackableWithDiscount: false,
        startsAtMillis: nowMillis - 60_000,
        endsAtMillis: nowMillis + 24 * 60 * 60 * 1000,
        eligibleSalonIds: [],
        eligibleServiceIds: [],
        termsVersion: "referral-integration-v1",
      },
    });
    const referralGrantRequest = {
      data: {
        programId: "referral_integration_test",
        walletType: "customer_rewards",
        accountId: "customer-proin-2",
        sourceId: "referral-integration-1",
        idempotencyKey:
          "referral:referral-integration-1:referral_integration_test:inviter",
        expectedSourceType: "referral_customer",
        expectedQualificationEvent: "first_completed_booking",
        eligibilityAtMillis: nowMillis,
      },
    };
    const firstReferralGrant = await backend.grantQualifiedEvent(
      referralGrantRequest,
    );
    const duplicateReferralGrant = await backend.grantQualifiedEvent(
      referralGrantRequest,
    );
    assert.equal(firstReferralGrant.duplicate, false);
    assert.equal(duplicateReferralGrant.duplicate, true);
    assert.equal(duplicateReferralGrant.lotId, firstReferralGrant.lotId);

    await firestore.collection("salons").doc("salon-proin").set({
      name: "Proin Test Salon",
      ownerUid: "owner-proin",
    });
    let releasableBooking = null;
    await firestore.runTransaction(async (transaction) => {
      releasableBooking = await backend.reserveBookingRedemptionInTransaction({
        transaction,
        bookingId: "booking-proin-release",
        uid: "customer-proin-1",
        salonId: "salon-proin",
        serviceIds: ["haircut"],
        originalAmount: 100,
        discountAmount: 0,
        requestedProin: 20,
      });
    });
    assert.equal(releasableBooking.proinStatus, "reserved");
    assert.equal(releasableBooking.customerPayableAmount, 80);
    const reservedWallet = await firestore.collection("proinWallets")
      .doc(firstGrant.walletId).get();
    const reservedFinance = await firestore.collection("proinFinance")
      .doc("current").get();
    assert.equal(reservedWallet.data().availableProin, 30);
    assert.equal(reservedWallet.data().reservedProin, 20);
    assert.equal(reservedFinance.data().reservedLiabilityInr, 20);

    let releasedBooking = null;
    await firestore.runTransaction(async (transaction) => {
      releasedBooking = await backend.resolveBookingRedemptionInTransaction({
        transaction,
        bookingId: "booking-proin-release",
        booking: {
          customerUid: "customer-proin-1",
          salonId: "salon-proin",
          ...releasableBooking,
        },
        outcome: "released",
      });
    });
    await backend.refreshWalletExpiry(firstGrant.walletId);
    assert.equal(releasedBooking.proinStatus, "released");
    assert.equal(releasedBooking.proinReleasedAmount, 20);
    const restoredWallet = await firestore.collection("proinWallets")
      .doc(firstGrant.walletId).get();
    assert.equal(restoredWallet.data().availableProin, 50);
    assert.equal(restoredWallet.data().reservedProin, 0);

    let redeemableBooking = null;
    await firestore.runTransaction(async (transaction) => {
      redeemableBooking = await backend.reserveBookingRedemptionInTransaction({
        transaction,
        bookingId: "booking-proin-redeem",
        uid: "customer-proin-1",
        salonId: "salon-proin",
        serviceIds: ["haircut"],
        originalAmount: 100,
        discountAmount: 0,
        requestedProin: 25,
      });
    });
    let redeemedBooking = null;
    await firestore.runTransaction(async (transaction) => {
      redeemedBooking = await backend.resolveBookingRedemptionInTransaction({
        transaction,
        bookingId: "booking-proin-redeem",
        booking: {
          customerUid: "customer-proin-1",
          salonId: "salon-proin",
          ...redeemableBooking,
        },
        outcome: "redeemed",
      });
    });
    await backend.refreshWalletExpiry(firstGrant.walletId);
    assert.equal(redeemedBooking.proinStatus, "redeemed");
    assert.equal(redeemedBooking.proinRedeemedAmount, 25);
    assert.equal(redeemedBooking.proinReimbursementStatus, "payable");
    const [reimbursement, salonWallet] = await Promise.all([
      firestore.collection("proinSalonReimbursements")
        .doc("booking-proin-redeem").get(),
      firestore.collection("salonWallets").doc("salon-proin").get(),
    ]);
    assert.equal(reimbursement.data().amountInr, 25);
    assert.equal(reimbursement.data().status, "payable");
    assert.equal(salonWallet.data().payableBalance, 25);

    const statementBeforeAdjustment = await backend.customerStatementData({
      uid: "customer-proin-1",
      limit: 50,
    });
    assert.equal(statementBeforeAdjustment.walletId, firstGrant.walletId);
    assert.ok(statementBeforeAdjustment.entries.some(
      (entry) => entry.type === "reserve" &&
        entry.bookingId === "booking-proin-redeem",
    ));
    assert.ok(statementBeforeAdjustment.entries.some(
      (entry) => entry.type === "release" && entry.restoredProin === 20,
    ));
    assert.ok(statementBeforeAdjustment.entries.some(
      (entry) => entry.type === "redeem" && entry.amountProin === 25,
    ));

    const settlementRequest = {
      adminUid: "admin-1",
      reason: "Record the externally completed integration reimbursement",
      data: {
        bookingId: "booking-proin-redeem",
        paymentReference: "UTR-PROIN-INTEGRATION-001",
        paidAtMillis: Date.now(),
      },
    };
    const firstSettlement =
      await backend.settleSalonReimbursementAsAdmin(settlementRequest);
    const duplicateSettlement =
      await backend.settleSalonReimbursementAsAdmin(settlementRequest);
    assert.equal(firstSettlement.alreadySettled, false);
    assert.equal(duplicateSettlement.alreadySettled, true);
    assert.equal(firstSettlement.amountInr, 25);
    await assert.rejects(
      backend.settleSalonReimbursementAsAdmin({
        ...settlementRequest,
        data: {
          ...settlementRequest.data,
          paymentReference: "UTR-PROIN-CONFLICTING-002",
        },
      }),
      /already settled with another reference/,
    );

    const revocationRequest = {
      adminUid: "admin-1",
      reason: "Remove unused integration reward with an audited correction",
      data: {
        lotId: firstCouponClaim.lotId,
        requestId: "integration-revocation-001",
        amountProin: 25,
      },
    };
    const firstRevocation =
      await backend.revokeAvailableLotAsAdmin(revocationRequest);
    const duplicateRevocation =
      await backend.revokeAvailableLotAsAdmin(revocationRequest);
    assert.equal(firstRevocation.duplicate, false);
    assert.equal(duplicateRevocation.duplicate, true);
    assert.equal(firstRevocation.amountProin, 25);
    await assert.rejects(
      backend.revokeAvailableLotAsAdmin({
        ...revocationRequest,
        data: {
          ...revocationRequest.data,
          requestId: "integration-revocation-after-empty-002",
        },
      }),
      /Only active, unexpired and unused Proin/,
    );

    const statementAfterAdjustment = await backend.customerStatementData({
      uid: "customer-proin-1",
      limit: 50,
    });
    assert.ok(statementAfterAdjustment.entries.some(
      (entry) => entry.type === "revoke" && entry.amountProin === 25,
    ));
    const revokedLot = (await firestore.collection("proinLots")
      .doc(firstCouponClaim.lotId).get()).data();
    assert.equal(revokedLot.availableProin, 0);
    assert.equal(revokedLot.revokedProin, 25);
    // The Control Center lists only lots that can still be adjusted.
    const operationalSnapshot = await backend.phaseOneSnapshot();
    assert.equal(operationalSnapshot.lots.some(
      (item) => item.lotId === firstCouponClaim.lotId,
    ), false);
    assert.ok(operationalSnapshot.reimbursements.some(
      (item) => item.bookingId === "booking-proin-redeem" &&
        item.status === "settled" && item.amountInr === 25,
    ));

    const reconciliation = await backend.reconcile();
    assert.equal(
      reconciliation.status,
      "balanced",
      JSON.stringify(reconciliation),
    );
    assert.equal(reconciliation.walletMismatchCount, 0);
    assert.equal(reconciliation.programUsageMismatchCount, 0);
    assert.equal(reconciliation.couponUsageMismatchCount, 0);
    assert.equal(reconciliation.invalidCouponClaimCount, 0);
    assert.equal(reconciliation.invalidSettlementReferenceCount, 0);
    assert.equal(reconciliation.reimbursementTotalsMatchFinance, true);
    assert.equal(reconciliation.financeBalanced, true);
    assert.equal(reconciliation.financeMatchesLots, true);
    const [allLots, allLedger, finalFinance, finalCustomerWallet,
      finalReimbursement, finalSalonWallet] = await Promise.all([
      firestore.collection("proinLots").get(),
      firestore.collection("proinLedger").get(),
      firestore.collection("proinFinance").doc("current").get(),
      firestore.collection("proinWallets").doc(firstGrant.walletId).get(),
      firestore.collection("proinSalonReimbursements")
        .doc("booking-proin-redeem").get(),
      firestore.collection("salonWallets").doc("salon-proin").get(),
    ]);
    assert.equal(allLots.size, 3);
    assert.equal(allLedger.size, 10);
    assert.equal(finalFinance.data().outstandingLiabilityInr, 25);
    assert.equal(finalFinance.data().reservedLiabilityInr, 0);
    assert.equal(finalFinance.data().redeemedPayableInr, 0);
    assert.equal(finalFinance.data().settledExpenseInr, 25);
    assert.equal(finalFinance.data().unallocatedBudgetInr, 950);
    assert.equal(finalFinance.data().lifetimeRevokedProin, 25);
    assert.equal(finalCustomerWallet.data().availableProin, 0);
    assert.equal(finalCustomerWallet.data().lifetimeRevokedProin, 25);
    assert.equal(finalReimbursement.data().status, "settled");
    assert.equal(finalSalonWallet.data().payableBalance, 0);
    assert.equal(finalSalonWallet.data().paidAmount, 25);

    await firestore.collection("proinCouponUsage").doc(coupon.codeHash).update({
      claimedCount: 2,
    });
    const driftedReconciliation = await backend.reconcile();
    assert.equal(driftedReconciliation.status, "review_required");
    assert.equal(driftedReconciliation.couponUsageMismatchCount, 1);
  } finally {
    await app.delete();
  }
});

test("salon promotional credits return an owner-facing expiry view", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async () => {
  const app = admin.initializeApp(
    {projectId: "demo-pritze-salon-wallet"},
    "salon-wallet-test",
  );
  const scopedAdmin = {
    firestore: Object.assign(
      () => admin.firestore(app),
      {
        FieldValue: admin.firestore.FieldValue,
        Timestamp: admin.firestore.Timestamp,
      },
    ),
  };
  const backend = createProinBackend({admin: scopedAdmin, HttpsError});
  const firestore = admin.firestore(app);
  const nowMillis = Date.now();
  try {
    await firestore.collection("salons").doc("salon-credit-1").set({
      name: "Salon Credit Test",
      ownerUid: "owner-credit-1",
    });
    await firestore.collection("users").doc("owner-credit-1").set({
      role: "owner",
      name: "Salon Credit Owner",
    });
    await backend.setFinanceBudget({
      adminUid: "admin-1",
      data: {approvedBudgetInr: 1000},
      reason: "Approve isolated salon promotional credit test budget",
    });
    await backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Create isolated salon promotion program",
      data: {
        programId: "salon_credit_integration",
        name: "Salon credit integration",
        sourceType: "manual",
        walletType: "salon_promotion_credits",
        qualificationEvent: "manual_approval",
        active: true,
        rewardAmountProin: 75,
        rewardValidityDays: 14,
        totalBudgetProin: 750,
        maximumTotalGrants: 10,
        maximumGrantsPerAccount: 1,
        minimumBookingAmount: 0,
        maximumProinPerBooking: 75,
        maximumRedemptionPercent: 100,
        stackableWithDiscount: false,
        startsAtMillis: nowMillis - 60_000,
        endsAtMillis: nowMillis + 24 * 60 * 60 * 1000,
        eligibleSalonIds: ["salon-credit-1"],
        eligibleServiceIds: [],
        termsVersion: "salon-credit-integration-v1",
      },
    });
    const grant = await backend.grantAsAdmin({
      adminUid: "admin-1",
      reason: "Grant isolated salon promotional credit",
      data: {
        programId: "salon_credit_integration",
        walletType: "salon_promotion_credits",
        accountId: "salon-credit-1",
        sourceId: "salon-credit-case-1",
        idempotencyKey: "salon-credit:salon-credit-1",
      },
    });
    const view = await backend.salonWalletData({salonId: "salon-credit-1"});
    assert.equal(view.walletType, "salon_promotion_credits");
    assert.equal(view.availableProin, 75);
    assert.equal(view.transferable, false);
    assert.equal(view.cashWithdrawable, false);
    assert.ok(view.expiringLots.some(
      (lot) => lot.lotId === grant.lotId && lot.amountProin === 75 &&
        lot.expiresAtMillis > nowMillis,
    ));

    await backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Create isolated salon coupon program",
      data: {
        programId: "salon_coupon_integration",
        name: "Salon coupon integration",
        sourceType: "coupon",
        walletType: "salon_promotion_credits",
        qualificationEvent: "coupon_claimed",
        rewardRecipient: "account",
        active: true,
        rewardAmountProin: 40,
        rewardValidityDays: 14,
        totalBudgetProin: 400,
        maximumTotalGrants: 10,
        maximumGrantsPerAccount: 1,
        minimumBookingAmount: 0,
        maximumProinPerBooking: 40,
        maximumRedemptionPercent: 100,
        stackableWithDiscount: false,
        startsAtMillis: nowMillis - 60_000,
        endsAtMillis: nowMillis + 24 * 60 * 60 * 1000,
        eligibleSalonIds: ["salon-credit-1"],
        eligibleServiceIds: [],
        termsVersion: "salon-coupon-integration-v1",
      },
    });
    const coupon = await backend.upsertCoupon({
      adminUid: "admin-1",
      reason: "Create isolated salon coupon",
      data: {
        code: "SALON75",
        programId: "salon_coupon_integration",
        active: true,
        claimStartsAtMillis: nowMillis - 60_000,
        claimEndsAtMillis: nowMillis + 24 * 60 * 60 * 1000,
        maximumClaimsTotal: 10,
        eligibleCustomerUids: [],
        eligibleSalonIds: ["salon-credit-1"],
        termsVersion: "salon-coupon-integration-v1",
      },
    });
    const firstClaim = await backend.claimCoupon({
      uid: "owner-credit-1",
      salonId: "salon-credit-1",
      rawCode: "salon75",
    });
    const duplicateClaim = await backend.claimCoupon({
      uid: "owner-credit-1",
      salonId: "salon-credit-1",
      rawCode: "SALON75",
    });
    assert.equal(firstClaim.amountProin, 40);
    assert.equal(firstClaim.alreadyClaimed, false);
    assert.equal(duplicateClaim.alreadyClaimed, true);
    const [couponUsage, salonCouponView] = await Promise.all([
      firestore.collection("proinCouponUsage").doc(coupon.codeHash).get(),
      backend.salonWalletData({salonId: "salon-credit-1"}),
    ]);
    assert.equal(couponUsage.data().claimedCount, 1);
    assert.equal(couponUsage.data().reservedClaims, 0);
    assert.equal(salonCouponView.availableProin, 115);
  } finally {
    await app.delete();
  }
});

function salonCreditTestBackend(name) {
  const app = admin.initializeApp({projectId: `demo-pritze-${name}`}, name);
  const scopedAdmin = {
    firestore: Object.assign(
      () => admin.firestore(app),
      {
        FieldValue: admin.firestore.FieldValue,
        Timestamp: admin.firestore.Timestamp,
      },
    ),
  };
  return {
    app,
    firestore: admin.firestore(app),
    backend: createProinBackend({admin: scopedAdmin, HttpsError}),
  };
}

function salonCreditTestProgram(nowMillis, overrides = {}) {
  return {
    name: "Salon credit ledger test",
    sourceType: "manual",
    walletType: "salon_promotion_credits",
    qualificationEvent: "manual_approval",
    active: true,
    rewardAmountProin: 500,
    rewardValidityDays: 14,
    totalBudgetProin: 5000,
    maximumTotalGrants: 10,
    maximumGrantsPerAccount: 5,
    minimumBookingAmount: 0,
    maximumProinPerBooking: 500,
    maximumRedemptionPercent: 100,
    stackableWithDiscount: false,
    startsAtMillis: nowMillis - 60_000,
    endsAtMillis: nowMillis + 24 * 60 * 60 * 1000,
    eligibleSalonIds: [],
    eligibleServiceIds: [],
    termsVersion: "salon-credit-ledger-v1",
    ...overrides,
  };
}

test("a salon keeps its credit line when it first receives credits", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async () => {
  const {app, firestore, backend} = salonCreditTestBackend("salon-credit-line");
  const nowMillis = Date.now();
  try {
    await firestore.collection("salons").doc("salon-line-1").set({
      name: "Credit Line Salon",
      ownerUid: "owner-line-1",
    });
    await backend.setFinanceBudget({
      adminUid: "admin-1",
      data: {approvedBudgetInr: 5000},
      reason: "Approve isolated salon credit line test budget",
    });
    await backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Create isolated salon credit line program",
      data: salonCreditTestProgram(nowMillis, {
        programId: "salon_credit_line",
        rewardAmountProin: 100,
        maximumProinPerBooking: 100,
      }),
    });
    const grant = (key) => backend.grantAsAdmin({
      adminUid: "admin-1",
      reason: "Grant isolated salon credit line test credit",
      data: {
        programId: "salon_credit_line",
        walletType: "salon_promotion_credits",
        accountId: "salon-line-1",
        idempotencyKey: key,
      },
    });

    const untouched = await backend.salonWalletData({salonId: "salon-line-1"});
    assert.equal(untouched.creditLimitProin, 1000);
    assert.equal(untouched.spendableProin, 1000);

    const first = await grant("salon-line:grant-1");
    const walletRef = firestore.collection("proinWallets").doc(first.walletId);
    assert.equal("creditLimitProin" in (await walletRef.get()).data(), false);
    const afterGrant = await backend.salonWalletData({salonId: "salon-line-1"});
    assert.equal(afterGrant.availableProin, 100);
    assert.equal(afterGrant.creditLimitProin, 1000);
    assert.equal(afterGrant.spendableProin, 1100);

    await firestore.collection("platformFinance").doc("discountVault").set({
      salonCreditLimitAmount: 2500,
    });
    const platformLine = await backend.salonWalletData({
      salonId: "salon-line-1",
    });
    assert.equal(platformLine.creditLimitProin, 2500);
    assert.equal(platformLine.spendableProin, 2600);

    await walletRef.set({creditLimitProin: 400}, {merge: true});
    await grant("salon-line:grant-2");
    assert.equal((await walletRef.get()).data().creditLimitProin, 400);
    const ownLine = await backend.salonWalletData({salonId: "salon-line-1"});
    assert.equal(ownLine.availableProin, 200);
    assert.equal(ownLine.creditLimitProin, 400);
    assert.equal(ownLine.spendableProin, 600);
  } finally {
    await app.delete();
  }
});

test("a program can reward more than its per-booking spending limit", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async () => {
  const {app, firestore, backend} = salonCreditTestBackend("reward-above-cap");
  const nowMillis = Date.now();
  try {
    await firestore.collection("users").doc("customer-cap-1").set({
      role: "customer",
    });
    await backend.setFinanceBudget({
      adminUid: "admin-1",
      data: {approvedBudgetInr: 5000},
      reason: "Approve isolated reward cap test budget",
    });
    await backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Create isolated earn-more-than-spend program",
      data: salonCreditTestProgram(nowMillis, {
        programId: "earn_200_spend_50",
        walletType: "customer_rewards",
        rewardAmountProin: 200,
        maximumProinPerBooking: 50,
      }),
    });
    const request = (key, extra = {}) => ({
      adminUid: "admin-1",
      reason: "Grant isolated reward cap test reward",
      data: {
        programId: "earn_200_spend_50",
        walletType: "customer_rewards",
        accountId: "customer-cap-1",
        idempotencyKey: key,
        ...extra,
      },
    });
    const granted = await backend.grantAsAdmin(request("reward-cap:grant-1"));
    assert.equal(granted.amountProin, 200);
    await assert.rejects(
      backend.grantAsAdmin(request("reward-cap:grant-2", {amountProin: 250})),
      /exceeds the program limit/,
    );
    const quote = await backend.quoteBookingRedemption({
      uid: "customer-cap-1",
      salonId: "salon-cap-1",
      serviceIds: ["haircut"],
      originalAmount: 400,
      discountAmount: 0,
    });
    assert.equal(quote.allocatedProin, 50);
  } finally {
    await app.delete();
  }
});

test("salon credits expire and revoke while the credit line is in use", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async () => {
  const {app, firestore, backend} = salonCreditTestBackend("salon-credit-use");
  const nowMillis = Date.now();
  try {
    await firestore.collection("salons").doc("salon-use-1").set({
      name: "Credit Use Salon",
      ownerUid: "owner-use-1",
    });
    await backend.setFinanceBudget({
      adminUid: "admin-1",
      data: {approvedBudgetInr: 5000},
      reason: "Approve isolated salon credit use test budget",
    });
    await backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Create isolated salon credit use program",
      data: salonCreditTestProgram(nowMillis, {programId: "salon_credit_use"}),
    });
    // The wallet a salon-funded discount leaves behind after Rs 300 was
    // redeemed purely on the credit line, before any credit was granted.
    const walletId = require("node:crypto").createHash("sha256")
      .update("salon_promotion_credits:salon-use-1").digest("hex");
    const walletRef = firestore.collection("proinWallets").doc(walletId);
    await walletRef.set({
      walletId,
      walletType: "salon_promotion_credits",
      accountId: "salon-use-1",
      availableProin: -300,
      reservedProin: 0,
      lifetimeGrantedProin: 0,
      lifetimeRedeemedProin: 300,
      lifetimeExpiredProin: 0,
      lifetimeRevokedProin: 0,
      creditLimitProin: 1000,
      negativeBalanceAllowed: true,
    });
    await firestore.collection("salonPromotionCreditUsage").doc(walletId).set({
      walletId,
      walletType: "salon_promotion_credits",
      salonId: "salon-use-1",
      reservedProin: 0,
      redeemedProin: 300,
      redeemedUses: 1,
    });
    const grant = await backend.grantAsAdmin({
      adminUid: "admin-1",
      reason: "Grant isolated salon credit use test credit",
      data: {
        programId: "salon_credit_use",
        walletType: "salon_promotion_credits",
        accountId: "salon-use-1",
        idempotencyKey: "salon-use:grant-1",
      },
    });
    assert.equal(grant.availableProin, 200);
    const revoke = (requestId, amountProin) =>
      backend.revokeAvailableLotAsAdmin({
        adminUid: "admin-1",
        reason: "Revoke isolated salon credit use test credit",
        data: {lotId: grant.lotId, requestId, amountProin},
      });

    const revoked = await revoke("salon-use-revoke-1", 100);
    assert.equal(revoked.amountProin, 100);
    assert.equal(revoked.availableProin, 100);

    await walletRef.set({creditLimitProin: 200}, {merge: true});
    await assert.rejects(
      revoke("salon-use-revoke-2", 400),
      /past its credit line/,
    );
    await firestore.collection("proinLots").doc(grant.lotId).update({
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() - 1),
    });
    const blocked = await backend.expireLots();
    assert.equal(blocked.expiredCount, 0);
    assert.match(blocked.failures[0].message, /salon-use-1 past its credit line/);
    const alerts = await firestore.collection("adminOperationalAlerts").get();
    assert.match(alerts.docs[0].data().detail, /Raise that salon's credit limit/);

    await walletRef.set({creditLimitProin: 1000}, {merge: true});
    const expiry = await backend.expireLots();
    assert.equal(expiry.failureCount, 0);
    assert.equal(expiry.expiredProin, 400);
    const wallet = (await walletRef.get()).data();
    assert.equal(wallet.availableProin, -300);
    assert.equal(wallet.lifetimeExpiredProin, 400);
    assert.equal(wallet.lifetimeRevokedProin, 100);
    assert.equal((await backend.reconcile()).status, "balanced");
  } finally {
    await app.delete();
  }
});

test("redeemed salon credits leave the Proin liability and reconcile", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async () => {
  const {app, firestore, backend} = salonCreditTestBackend("salon-credit-spend");
  const nowMillis = Date.now();
  try {
    await firestore.collection("salons").doc("salon-spend-1").set({
      name: "Credit Spend Salon",
      ownerUid: "owner-spend-1",
    });
    await backend.setFinanceBudget({
      adminUid: "admin-1",
      data: {approvedBudgetInr: 5000},
      reason: "Approve isolated salon credit spend test budget",
    });
    await backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Create isolated salon credit spend program",
      data: salonCreditTestProgram(nowMillis, {programId: "salon_credit_spend"}),
    });
    const grant = await backend.grantAsAdmin({
      adminUid: "admin-1",
      reason: "Grant isolated salon credit spend test credit",
      data: {
        programId: "salon_credit_spend",
        walletType: "salon_promotion_credits",
        accountId: "salon-spend-1",
        idempotencyKey: "salon-spend:grant-1",
      },
    });
    const lotRef = firestore.collection("proinLots").doc(grant.lotId);
    const walletRef = firestore.collection("proinWallets").doc(grant.walletId);
    const financeRef = firestore.collection("proinFinance").doc("current");

    // A salon-funded booking holds Rs 200 of the lot. These are the lot and
    // wallet writes the booking transaction makes for that hold.
    await firestore.runTransaction(async (transaction) => {
      transaction.update(lotRef, {availableProin: 300, reservedProin: 200});
      transaction.set(walletRef, {
        availableProin: 300,
        reservedProin: 200,
        creditLimitProin: 1000,
      }, {merge: true});
    });
    const held = await backend.reconcile();
    assert.equal(held.status, "balanced");
    assert.equal((await financeRef.get()).data().outstandingLiabilityInr, 500);

    // The booking completes. A customer Proin resolution in the same
    // transaction would set the finance totals before this step increments.
    await firestore.runTransaction(async (transaction) => {
      const finance = (await transaction.get(financeRef)).data();
      transaction.set(financeRef, {
        outstandingLiabilityInr: finance.outstandingLiabilityInr,
        unallocatedBudgetInr: finance.unallocatedBudgetInr,
      }, {merge: true});
      transaction.update(lotRef, {reservedProin: 0, redeemedProin: 200});
      transaction.set(walletRef, {
        reservedProin: 0,
        lifetimeRedeemedProin: 200,
      }, {merge: true});
      assert.equal(backend.redeemSalonCreditLotsInTransaction({
        transaction,
        walletId: grant.walletId,
        allocations: [{programId: "salon_credit_spend", amountProin: 200}],
      }), 200);
    });
    const [finance, programUsage, accountUsage] = await Promise.all([
      financeRef.get(),
      firestore.collection("proinProgramUsage").doc("salon_credit_spend").get(),
      firestore.collection("proinProgramAccountUsage")
        .doc(`salon_credit_spend__${grant.walletId}`).get(),
    ]);
    assert.equal(finance.data().outstandingLiabilityInr, 300);
    assert.equal(finance.data().unallocatedBudgetInr, 4700);
    assert.equal(finance.data().redeemedPayableInr, 0);
    assert.equal(finance.data().reservedLiabilityInr, 0);
    for (const usage of [programUsage, accountUsage]) {
      assert.equal(usage.data().availableProin, 300);
      assert.equal(usage.data().redeemedProin, 200);
      assert.equal(usage.data().grantedProin, 500);
    }
    assert.equal((await backend.reconcile()).status, "balanced");

    await lotRef.update({
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() - 1),
    });
    const expiry = await backend.expireLots();
    assert.equal(expiry.failureCount, 0);
    assert.equal(expiry.expiredProin, 300);
    assert.equal((await financeRef.get()).data().unallocatedBudgetInr, 5000);
    assert.equal((await backend.reconcile()).status, "balanced");
  } finally {
    await app.delete();
  }
});

test("credit handed back after a lot expired still expires", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async () => {
  const {app, firestore, backend} = salonCreditTestBackend("salon-credit-late");
  const nowMillis = Date.now();
  try {
    await firestore.collection("salons").doc("salon-late-1").set({
      name: "Late Release Salon",
      ownerUid: "owner-late-1",
    });
    await backend.setFinanceBudget({
      adminUid: "admin-1",
      data: {approvedBudgetInr: 5000},
      reason: "Approve isolated late release test budget",
    });
    await backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Create isolated late release program",
      data: salonCreditTestProgram(nowMillis, {programId: "salon_credit_late"}),
    });
    const grant = await backend.grantAsAdmin({
      adminUid: "admin-1",
      reason: "Grant isolated late release test credit",
      data: {
        programId: "salon_credit_late",
        walletType: "salon_promotion_credits",
        accountId: "salon-late-1",
        idempotencyKey: "salon-late:grant-1",
      },
    });
    const lotRef = firestore.collection("proinLots").doc(grant.lotId);
    const walletRef = firestore.collection("proinWallets").doc(grant.walletId);

    // A salon-funded booking holds Rs 200 while the lot passes its expiry.
    await lotRef.update({
      availableProin: 300,
      reservedProin: 200,
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() - 1),
    });
    await walletRef.set({availableProin: 300, reservedProin: 200}, {merge: true});
    const first = await backend.expireLots();
    assert.equal(first.expiredProin, 300);
    assert.equal((await lotRef.get()).data().status, "reserved_after_expiry");

    // The booking is then cancelled, which hands the held credit back.
    await lotRef.update({availableProin: 200, reservedProin: 0, status: "active"});
    await walletRef.set({availableProin: 200, reservedProin: 0}, {merge: true});
    const second = await backend.expireLots();
    assert.equal(second.failureCount, 0);
    assert.equal(second.expiredProin, 200);
    const lot = (await lotRef.get()).data();
    assert.equal(lot.availableProin, 0);
    assert.equal(lot.expiredProin, 500);
    assert.equal(lot.status, "expired");
    assert.equal((await walletRef.get()).data().availableProin, 0);
    assert.equal((await backend.reconcile()).status, "balanced");
  } finally {
    await app.delete();
  }
});

test("the referral award scan works through a queue of stuck referrals", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async () => {
  const {app, firestore, backend} = salonCreditTestBackend("referral-scan");
  try {
    const referral = (id, fields) =>
      firestore.collection("referrals").doc(id).set({
        referredUid: id,
        status: "qualified",
        proinAwardPending: true,
        ...fields,
      });
    await Promise.all([
      referral("ref-a"),
      referral("ref-b"),
      referral("ref-c"),
      referral("ref-d"),
      referral("ref-e"),
      referral("ref-done", {proinAwardPending: false}),
      referral("ref-new", {status: "pending"}),
    ]);
    const page = async (options) =>
      (await backend.nextReferralAwardScanPage(options)).map((doc) => doc.id);

    // The first two never clear, yet every later referral is still reached.
    assert.deepEqual(await page({limit: 2}), ["ref-a", "ref-b"]);
    assert.deepEqual(await page({limit: 2}), ["ref-c", "ref-d"]);
    assert.deepEqual(await page({limit: 2}), ["ref-e"]);
    assert.deepEqual(await page({limit: 2}), ["ref-a", "ref-b"]);

    // A full last page is followed straight away by the start of the queue.
    await firestore.collection("referrals").doc("ref-e").delete();
    assert.deepEqual(await page({limit: 2}), ["ref-c", "ref-d"]);
    assert.deepEqual(await page({limit: 2}), ["ref-a", "ref-b"]);

    // The administrator backfill keeps its own place and includes settled ones.
    assert.deepEqual(
      await page({includePreviouslyProcessed: true, limit: 3}),
      ["ref-a", "ref-b", "ref-c"],
    );
    assert.deepEqual(
      await page({includePreviouslyProcessed: true, limit: 3}),
      ["ref-d", "ref-done"],
    );

    // The cashback retry rotates the same way past bookings it cannot award.
    const booking = (id, discountCashbackStatus) =>
      firestore.collection("bookings").doc(id)
        .set({status: "completed", discountCashbackStatus});
    await Promise.all([
      booking("book-a", "pending"),
      booking("book-b", "pending"),
      booking("book-c", "pending"),
      booking("book-paid", "awarded"),
    ]);
    const cashbackPage = async () =>
      (await backend.nextPendingCashbackScanPage({limit: 2}))
        .map((doc) => doc.id);
    assert.deepEqual(await cashbackPage(), ["book-a", "book-b"]);
    assert.deepEqual(await cashbackPage(), ["book-c"]);
    assert.deepEqual(await cashbackPage(), ["book-a", "book-b"]);
  } finally {
    await app.delete();
  }
});

test("the Control Center snapshot stays useful and protects campaign programs", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async () => {
  const {app, firestore, backend} = salonCreditTestBackend("admin-snapshot");
  const nowMillis = Date.now();
  try {
    await firestore.collection("salons").doc("salon-snap-1").set({
      name: "Snapshot Salon",
      ownerUid: "owner-snap-1",
    });
    await firestore.collection("users").doc("customer-snap-1").set({
      role: "customer",
    });
    await backend.setFinanceBudget({
      adminUid: "admin-1",
      data: {approvedBudgetInr: 5000},
      reason: "Approve isolated snapshot test budget",
    });
    await backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Create isolated snapshot salon program",
      data: salonCreditTestProgram(nowMillis, {programId: "snapshot_salon"}),
    });
    await backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Create isolated snapshot customer program",
      data: salonCreditTestProgram(nowMillis, {
        programId: "snapshot_customer",
        walletType: "customer_rewards",
        rewardAmountProin: 100,
        maximumProinPerBooking: 100,
      }),
    });
    const grant = (programId, walletType, accountId, key) =>
      backend.grantAsAdmin({
        adminUid: "admin-1",
        reason: "Grant isolated snapshot test reward",
        data: {programId, walletType, accountId, idempotencyKey: key},
      });
    const salonGrant = await grant(
      "snapshot_salon",
      "salon_promotion_credits",
      "salon-snap-1",
      "snapshot:salon",
    );
    const expiring = await grant(
      "snapshot_customer",
      "customer_rewards",
      "customer-snap-1",
      "snapshot:customer-1",
    );
    const kept = await grant(
      "snapshot_customer",
      "customer_rewards",
      "customer-snap-1",
      "snapshot:customer-2",
    );
    await firestore.collection("proinLots").doc(expiring.lotId).update({
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() - 1),
    });
    await backend.expireLots();
    await firestore.collection("proinSalonReimbursements").doc("booking-a").set({
      salonId: "salon-snap-1",
      amountInr: 40,
      status: "payable",
    });
    await firestore.collection("proinSalonReimbursements").doc("booking-b").set({
      salonId: "salon-snap-1",
      amountInr: 60,
      status: "settled",
      paidAt: admin.firestore.Timestamp.fromMillis(nowMillis),
    });

    const snapshot = await backend.phaseOneSnapshot();
    assert.deepEqual(
      snapshot.lots.map((lot) => lot.lotId).sort(),
      [kept.lotId, salonGrant.lotId].sort(),
    );
    assert.deepEqual(
      snapshot.wallets.map((wallet) => wallet.accountId).sort(),
      ["customer-snap-1", "salon-snap-1"],
    );
    const salonWallet = snapshot.wallets.find(
      (wallet) => wallet.accountId === "salon-snap-1",
    );
    assert.equal(salonWallet.creditLimitProin, 1000);
    assert.equal(salonWallet.spendableProin, 1500);
    assert.deepEqual(
      snapshot.reimbursements.map((item) => [item.bookingId, item.status]),
      [["booking-a", "payable"], ["booking-b", "settled"]],
    );
    assert.ok(Object.values(snapshot.truncated).every((cut) => cut === false));

    // A cashback program created by a discount campaign is edited there only.
    await firestore.collection("proinPrograms").doc("snapshot_customer").set({
      systemManaged: true,
      linkedDiscountCampaignId: "campaign-1",
    }, {merge: true});
    await assert.rejects(backend.upsertProgram({
      adminUid: "admin-1",
      reason: "Try to edit a campaign cashback program",
      data: salonCreditTestProgram(nowMillis, {
        programId: "snapshot_customer",
        walletType: "customer_rewards",
        active: false,
      }),
    }), /belongs to a discount campaign/);
    const managed = (await backend.phaseOneSnapshot()).programs.find(
      (program) => program.programId === "snapshot_customer",
    );
    assert.equal(managed.systemManaged, true);
    assert.equal(managed.active, true);
    assert.equal(managed.linkedDiscountCampaignId, "campaign-1");

    // Reading the ledger a page at a time reaches the same verdict.
    await firestore.collection("proinSalonReimbursements").doc("booking-a")
      .delete();
    await firestore.collection("proinSalonReimbursements").doc("booking-b")
      .delete();
    assert.equal((await backend.reconcile({pageSize: 1})).status, "balanced");
    assert.equal((await backend.reconcile()).status, "balanced");
  } finally {
    await app.delete();
  }
});
