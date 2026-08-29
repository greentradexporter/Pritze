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
    const operationalSnapshot = await backend.phaseOneSnapshot();
    assert.ok(operationalSnapshot.lots.some(
      (item) => item.lotId === firstCouponClaim.lotId &&
        item.availableProin === 0 && item.revokedProin === 25,
    ));
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
