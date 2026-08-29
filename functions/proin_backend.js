const crypto = require("node:crypto");
const {
  ProinValidationError,
  normalizeProinProgramInput,
  proinFinanceInvariant,
  proinInteger,
  proinLotInvariant,
  proinProgramGrantAllowed,
  proinRedemptionPolicyFromProgram,
  proinSignedInteger,
  proinWalletInvariant,
  proinWalletSummaryFromLots,
  quoteProinRedemption,
} = require("./proin_logic");
const {
  normalizeProinCouponInput,
  proinCouponClaimAllowed,
  proinCouponHash,
} = require("./proin_coupon_logic");

const DAY_MS = 24 * 60 * 60 * 1000;
const RECONCILIATION_WALLET_LIMIT = 500;
const RECONCILIATION_LOT_LIMIT = 5000;
const RECONCILIATION_COUPON_LIMIT = 500;
const RECONCILIATION_COUPON_CLAIM_LIMIT = 5000;
const RECONCILIATION_RESERVATION_LIMIT = 5000;
const RECONCILIATION_REIMBURSEMENT_LIMIT = 5000;
const RECONCILIATION_SETTLEMENT_REFERENCE_LIMIT = 5000;
const RECONCILIATION_SALON_PROMOTION_USAGE_LIMIT = 1000;
const DEFAULT_SALON_PROMOTION_CREDIT_LIMIT = 1000;

function createProinBackend({admin, HttpsError}) {
  const fieldValue = admin.firestore.FieldValue;
  const Timestamp = admin.firestore.Timestamp;

  function firestore() {
    return admin.firestore();
  }

  function asHttpsError(error) {
    if (error instanceof HttpsError) return error;
    if (error instanceof ProinValidationError) {
      return new HttpsError("invalid-argument", error.message);
    }
    return error;
  }

  async function upsertProgram({adminUid, data, reason}) {
    let normalized;
    try {
      normalized = normalizeProinProgramInput(data);
    } catch (error) {
      throw asHttpsError(error);
    }
    const nowMillis = Date.now();
    if (normalized.active && normalized.endsAtMillis <= nowMillis) {
      throw new HttpsError(
        "invalid-argument",
        "An active Proin program must end in the future.",
      );
    }
    const programId = proinDocumentId(data.programId, "program id");
    const db = firestore();
    const programRef = db.collection("proinPrograms").doc(programId);
    const usageRef = db.collection("proinProgramUsage").doc(programId);
    const auditRef = db.collection("adminAuditLogs").doc();
    let response = null;

    await db.runTransaction(async (transaction) => {
      const [programSnapshot, usageSnapshot] = await Promise.all([
        transaction.get(programRef),
        transaction.get(usageRef),
      ]);
      const before = programSnapshot.data() || null;
      const usage = usageSnapshot.data() || {};
      const grantedProin = storedProin(usage.grantedProin);
      const grantCount = storedProin(usage.grantCount);
      if (grantedProin > normalized.totalBudgetProin) {
        throw new HttpsError(
          "failed-precondition",
          "The new budget is below Proin already granted by this program.",
        );
      }
      if (grantCount > normalized.maximumTotalGrants) {
        throw new HttpsError(
          "failed-precondition",
          "The new grant limit is below grants already made.",
        );
      }
      if (before && before.walletType !== normalized.walletType &&
          grantedProin > 0) {
        throw new HttpsError(
          "failed-precondition",
          "A program with existing grants cannot change wallet type.",
        );
      }

      const version = storedPositiveInteger(before?.version, 0) + 1;
      const versionRef = db.collection("proinProgramVersions")
        .doc(`${programId}__v${version}`);
      const versionSnapshot = await transaction.get(versionRef);
      if (versionSnapshot.exists) {
        throw new HttpsError(
          "already-exists",
          "This Proin program version already exists.",
        );
      }
      const record = proinProgramRecord({
        normalized,
        version,
        adminUid,
        previous: before,
        Timestamp,
        fieldValue,
      });
      transaction.set(programRef, record);
      transaction.create(versionRef, {
        ...record,
        programId,
        versionCreatedAt: fieldValue.serverTimestamp(),
      });
      transaction.create(auditRef, proinAuditRecord({
        adminUid,
        action: before ? "proin.program_updated" : "proin.program_created",
        targetType: "proinProgram",
        targetId: programId,
        reason,
        before: before ? proinProgramView(programId, before) : {},
        after: proinProgramView(programId, record),
        fieldValue,
      }));
      response = proinProgramView(programId, record);
    });
    return response;
  }

  async function setFinanceBudget({adminUid, data, reason}) {
    let approvedBudgetInr;
    try {
      approvedBudgetInr = proinInteger(
        data.approvedBudgetInr,
        "Approved Proin budget",
      );
    } catch (error) {
      throw asHttpsError(error);
    }
    const db = firestore();
    const financeRef = db.collection("proinFinance").doc("current");
    const auditRef = db.collection("adminAuditLogs").doc();
    let response = null;
    await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(financeRef);
      const before = proinFinanceState(snapshot.data());
      if (snapshot.exists && !proinFinanceInvariant(before)) {
        throw new HttpsError(
          "data-loss",
          "Proin finance totals are not balanced. Reconcile before editing.",
        );
      }
      const committed = before.outstandingLiabilityInr +
        before.redeemedPayableInr + before.settledExpenseInr;
      if (approvedBudgetInr < committed) {
        throw new HttpsError(
          "failed-precondition",
          "Approved budget cannot be below committed Proin liability.",
        );
      }
      const after = {
        ...before,
        approvedBudgetInr,
        unallocatedBudgetInr: approvedBudgetInr - committed,
        budgetVersion: before.budgetVersion + 1,
      };
      if (!proinFinanceInvariant(after)) {
        throw new HttpsError("internal", "Proin budget would not balance.");
      }
      transaction.set(financeRef, {
        ...after,
        proinToInrRate: 1,
        regulatoryMode: "promotional_reward_only",
        createdAt: snapshot.data()?.createdAt || fieldValue.serverTimestamp(),
        updatedAt: fieldValue.serverTimestamp(),
        updatedByAdminUid: adminUid,
      });
      transaction.create(auditRef, proinAuditRecord({
        adminUid,
        action: "proin.finance_budget_changed",
        targetType: "proinFinance",
        targetId: "current",
        reason,
        before,
        after,
        fieldValue,
      }));
      response = after;
    });
    return response;
  }

  async function grantAsAdmin({
    adminUid,
    data,
    reason,
    systemContext = null,
  }) {
    const programId = proinDocumentId(data.programId, "program id");
    const accountId = requiredText(data.accountId, "account id", 160);
    const walletType = requiredText(data.walletType, "wallet type", 80);
    const idempotencyKey = requiredText(
      data.idempotencyKey,
      "idempotency key",
      200,
    );
    const sourceId = String(data.sourceId ?? programId).trim().slice(0, 160) ||
      programId;
    const idempotencyHash = sha256(idempotencyKey);
    const walletId = proinWalletId(walletType, accountId);
    const db = firestore();
    const nowMillis = Date.now();
    const programRef = db.collection("proinPrograms").doc(programId);
    const programUsageRef = db.collection("proinProgramUsage").doc(programId);
    const accountUsageRef = db.collection("proinProgramAccountUsage")
      .doc(`${programId}__${walletId}`);
    const financeRef = db.collection("proinFinance").doc("current");
    const walletRef = db.collection("proinWallets").doc(walletId);
    const idempotencyRef = db.collection("proinIdempotencyKeys")
      .doc(idempotencyHash);
    const lotRef = db.collection("proinLots").doc();
    const ledgerRef = db.collection("proinLedger").doc();
    const auditRef = db.collection("adminAuditLogs").doc();
    const targetRef = walletType === "customer_rewards" ?
      db.collection("users").doc(accountId) :
      db.collection("salons").doc(accountId);
    let response = null;

    await db.runTransaction(async (transaction) => {
      const idempotencySnapshot = await transaction.get(idempotencyRef);
      if (idempotencySnapshot.exists) {
        const stored = idempotencySnapshot.data() || {};
        response = {
          duplicate: true,
          lotId: String(stored.lotId || ""),
          ledgerId: String(stored.ledgerId || ""),
          walletId: String(stored.walletId || walletId),
          amountProin: storedProin(stored.amountProin),
          expiresAtMillis: timestampMillis(stored.expiresAt),
          availableProin: storedProin(stored.availableProinAfter),
        };
        return;
      }
      const [
        programSnapshot,
        programUsageSnapshot,
        accountUsageSnapshot,
        financeSnapshot,
        walletSnapshot,
        targetSnapshot,
      ] = await Promise.all([
        transaction.get(programRef),
        transaction.get(programUsageRef),
        transaction.get(accountUsageRef),
        transaction.get(financeRef),
        transaction.get(walletRef),
        transaction.get(targetRef),
      ]);
      const program = programSnapshot.data();
      if (!program) {
        throw new HttpsError("not-found", "Proin program not found.");
      }
      if (program.walletType !== walletType) {
        throw new HttpsError(
          "failed-precondition",
          "This program cannot grant to the selected wallet type.",
        );
      }
      if (systemContext) {
        if (program.sourceType !== systemContext.sourceType ||
            program.qualificationEvent !==
              systemContext.qualificationEvent) {
          throw new HttpsError(
            "failed-precondition",
            "This Proin program does not match the qualified reward event.",
          );
        }
      } else if (program.sourceType !== "manual" ||
                 program.qualificationEvent !== "manual_approval") {
          throw new HttpsError(
            "failed-precondition",
            "Administrative grants require a manual-approval Proin program.",
          );
        }
      if (!targetSnapshot.exists) {
        throw new HttpsError("not-found", "Reward account not found.");
      }
      if (walletType === "customer_rewards" &&
          targetSnapshot.data()?.role !== "customer") {
        throw new HttpsError(
          "failed-precondition",
          "Customer Proin can only be granted to a customer account.",
        );
      }
      const programUsage = proinProgramUsageState(
        programUsageSnapshot.data(),
      );
      const grantDecision = proinProgramGrantAllowed({
        program,
        usage: programUsage,
        nowMillis: systemContext?.eligibilityAtMillis || nowMillis,
      });
      if (!grantDecision.allowed) {
        throw new HttpsError("failed-precondition", grantDecision.reason);
      }
      const accountUsage = proinProgramUsageState(accountUsageSnapshot.data());
      if (accountUsage.grantCount >=
          storedProin(program.maximumGrantsPerAccount)) {
        throw new HttpsError(
          "resource-exhausted",
          "This account reached the program reward limit.",
        );
      }
      const amountProin = storedPositiveInteger(program.rewardAmountProin, 0);
      if (amountProin <= 0) {
        throw new HttpsError("data-loss", "Program reward is invalid.");
      }
      const finance = proinFinanceState(financeSnapshot.data());
      if (!financeSnapshot.exists || !proinFinanceInvariant(finance)) {
        throw new HttpsError(
          "failed-precondition",
          "Fund and reconcile the Proin promotion budget first.",
        );
      }
      if (finance.unallocatedBudgetInr < amountProin) {
        throw new HttpsError(
          "resource-exhausted",
          "The Proin promotion budget does not cover this reward.",
        );
      }
      const wallet = proinWalletState(walletSnapshot.data());
      if (walletSnapshot.exists && !proinWalletInvariant(wallet)) {
        throw new HttpsError(
          "data-loss",
          "This Proin wallet is not balanced. Reconcile it before granting.",
        );
      }
      const validityDays = storedPositiveInteger(
        program.rewardValidityDays,
        0,
      );
      if (validityDays <= 0 || validityDays > 730) {
        throw new HttpsError("data-loss", "Program reward validity is invalid.");
      }
      const expiresAtMillis = nowMillis + validityDays * DAY_MS;
      const nextExpiryAtMillis = wallet.nextExpiryAtMillis > 0 ?
        Math.min(wallet.nextExpiryAtMillis, expiresAtMillis) : expiresAtMillis;
      const walletAfter = {
        ...wallet,
        availableProin: wallet.availableProin + amountProin,
        lifetimeGrantedProin:
          wallet.lifetimeGrantedProin + amountProin,
        nextExpiryAtMillis,
      };
      const financeAfter = {
        ...finance,
        unallocatedBudgetInr:
          finance.unallocatedBudgetInr - amountProin,
        outstandingLiabilityInr:
          finance.outstandingLiabilityInr + amountProin,
        lifetimeGrantedProin:
          finance.lifetimeGrantedProin + amountProin,
      };
      if (!proinWalletInvariant(walletAfter) ||
          !proinFinanceInvariant(financeAfter)) {
        throw new HttpsError("internal", "The Proin grant would not balance.");
      }
      const programUsageAfter = grantUsage(programUsage, amountProin);
      const accountUsageAfter = grantUsage(accountUsage, amountProin);
      const timestamp = fieldValue.serverTimestamp();
      transaction.set(walletRef, {
        ...walletAfter,
        walletId,
        walletType,
        accountId,
        proinToInrRate: 1,
        nextExpiryAt: Timestamp.fromMillis(nextExpiryAtMillis),
        needsExpiryRefresh: false,
        createdAt: walletSnapshot.data()?.createdAt || timestamp,
        updatedAt: timestamp,
      });
      transaction.create(lotRef, {
        lotId: lotRef.id,
        walletId,
        walletType,
        accountId,
        programId,
        programVersion: storedProin(program.version),
        redemptionPolicy: proinRedemptionPolicyFromProgram(program),
        sourceType: String(program.sourceType || "manual"),
        sourceId,
        originalProin: amountProin,
        availableProin: amountProin,
        reservedProin: 0,
        redeemedProin: 0,
        expiredProin: 0,
        revokedProin: 0,
        status: "active",
        earnedAt: timestamp,
        expiresAt: Timestamp.fromMillis(expiresAtMillis),
        createdByAdminUid: systemContext ? null : adminUid,
        idempotencyKeyHash: idempotencyHash,
        createdAt: timestamp,
        updatedAt: timestamp,
      });
      transaction.create(ledgerRef, {
        transactionId: ledgerRef.id,
        walletId,
        walletType,
        accountId,
        type: "grant",
        direction: "credit",
        amountProin,
        programId,
        sourceType: String(program.sourceType || "manual"),
        sourceId,
        lotAllocations: [{lotId: lotRef.id, amountProin}],
        idempotencyKeyHash: idempotencyHash,
        createdByType: systemContext ? "system" : "platform_admin",
        createdByUid: systemContext ? "" : adminUid,
        balanceAfter: {
          availableProin: walletAfter.availableProin,
          reservedProin: walletAfter.reservedProin,
        },
        createdAt: timestamp,
      });
      transaction.set(programUsageRef, {
        ...programUsageAfter,
        programId,
        updatedAt: timestamp,
      });
      transaction.set(accountUsageRef, {
        ...accountUsageAfter,
        programId,
        walletId,
        walletType,
        accountId,
        updatedAt: timestamp,
      });
      transaction.set(financeRef, {
        ...financeAfter,
        proinToInrRate: 1,
        regulatoryMode: "promotional_reward_only",
        createdAt: financeSnapshot.data()?.createdAt || timestamp,
        updatedAt: timestamp,
      });
      transaction.create(idempotencyRef, {
        operation: "grant",
        walletId,
        programId,
        lotId: lotRef.id,
        ledgerId: ledgerRef.id,
        amountProin,
        expiresAt: Timestamp.fromMillis(expiresAtMillis),
        availableProinAfter: walletAfter.availableProin,
        createdAt: timestamp,
      });
      if (!systemContext) {
        transaction.create(auditRef, proinAuditRecord({
          adminUid,
          action: "proin.manual_grant",
          targetType: "proinWallet",
          targetId: walletId,
          reason,
          before: proinWalletView(wallet),
          after: {
            ...proinWalletView(walletAfter),
            programId,
            lotId: lotRef.id,
          },
          fieldValue,
        }));
      }
      response = {
        duplicate: false,
        walletId,
        lotId: lotRef.id,
        ledgerId: ledgerRef.id,
        amountProin,
        expiresAtMillis,
        availableProin: walletAfter.availableProin,
      };
    });
    return response;
  }

  async function grantQualifiedEvent({data}) {
    const sourceType = requiredText(
      data.expectedSourceType,
      "expected source type",
      80,
    );
    const qualificationEvent = requiredText(
      data.expectedQualificationEvent,
      "expected qualification event",
      100,
    );
    return grantAsAdmin({
      adminUid: "",
      data,
      reason: "",
      systemContext: {
        sourceType,
        qualificationEvent,
        eligibilityAtMillis: timestampMillis(data.eligibilityAtMillis) ||
          Date.now(),
      },
    });
  }

  async function upsertCoupon({adminUid, data, reason}) {
    let normalized;
    try {
      normalized = normalizeProinCouponInput(data);
    } catch (error) {
      throw asHttpsError(error);
    }
    const expectedCodeHash = String(data.expectedCodeHash || "").trim();
    if (expectedCodeHash && expectedCodeHash !== normalized.codeHash) {
      throw new HttpsError(
        "invalid-argument",
        "The full coupon code does not match the coupon being edited.",
      );
    }
    if (normalized.active && normalized.claimEndsAtMillis <= Date.now()) {
      throw new HttpsError(
        "invalid-argument",
        "An active Proin coupon must end in the future.",
      );
    }
    const db = firestore();
    const couponRef = db.collection("proinCoupons").doc(normalized.codeHash);
    const usageRef = db.collection("proinCouponUsage")
      .doc(normalized.codeHash);
    const programRef = db.collection("proinPrograms")
      .doc(normalized.programId);
    const registryRef = db.collection("voucherCodeRegistry")
      .doc(normalized.codeHash);
    const duplicateDiscountQuery = db.collection("discountCampaigns")
      .where("voucherCodeHash", "==", normalized.codeHash)
      .limit(1);
    const auditRef = db.collection("adminAuditLogs").doc();
    let response = null;
    await db.runTransaction(async (transaction) => {
      const [
        couponSnapshot,
        usageSnapshot,
        programSnapshot,
        registrySnapshot,
        duplicateDiscounts,
      ] =
        await Promise.all([
          transaction.get(couponRef),
          transaction.get(usageRef),
          transaction.get(programRef),
          transaction.get(registryRef),
          transaction.get(duplicateDiscountQuery),
        ]);
      const registry = registrySnapshot.data();
      if (registry && (registry.kind !== "proin" ||
          registry.targetId !== normalized.codeHash)) {
        throw new HttpsError(
          "already-exists",
          "This code is already assigned to another voucher campaign.",
        );
      }
      if (!duplicateDiscounts.empty) {
        throw new HttpsError(
          "already-exists",
          "This code is already assigned to a discount voucher.",
        );
      }
      const program = programSnapshot.data();
      if (!program || program.sourceType !== "coupon" ||
          !["customer_rewards", "salon_promotion_credits"]
            .includes(String(program.walletType || "")) ||
          program.qualificationEvent !== "coupon_claimed") {
        throw new HttpsError(
          "failed-precondition",
          "Choose a coupon Proin program.",
        );
      }
      const before = couponSnapshot.data() || null;
      const usage = proinCouponUsageState(usageSnapshot.data());
      if (usage.claimedCount + usage.reservedClaims >
          normalized.maximumClaimsTotal) {
        throw new HttpsError(
          "failed-precondition",
          "The claim limit is below claims already awarded or reserved.",
        );
      }
      if (before && before.programId !== normalized.programId &&
          usage.claimedCount + usage.reservedClaims > 0) {
        throw new HttpsError(
          "failed-precondition",
          "A coupon with existing claims cannot change Proin program.",
        );
      }
      const version = storedPositiveInteger(before?.version, 0) + 1;
      const versionRef = db.collection("proinCouponVersions")
        .doc(`${normalized.codeHash}__v${version}`);
      const versionSnapshot = await transaction.get(versionRef);
      if (versionSnapshot.exists) {
        throw new HttpsError(
          "already-exists",
          "This Proin coupon version already exists.",
        );
      }
      const {
        code,
        claimStartsAtMillis,
        claimEndsAtMillis,
        ...storedFields
      } = normalized;
      const timestamp = fieldValue.serverTimestamp();
      const record = {
        ...storedFields,
        version,
        claimStartsAt: Timestamp.fromMillis(claimStartsAtMillis),
        claimEndsAt: Timestamp.fromMillis(claimEndsAtMillis),
        storesPlaintextCode: false,
        createdAt: before?.createdAt || timestamp,
        createdByAdminUid: before?.createdByAdminUid || adminUid,
        updatedAt: timestamp,
        updatedByAdminUid: adminUid,
      };
      transaction.set(couponRef, record);
      transaction.set(registryRef, {
        codeHash: normalized.codeHash,
        maskedCode: normalized.maskedCode,
        kind: "proin",
        targetId: normalized.codeHash,
        updatedAt: timestamp,
      }, {merge: true});
      transaction.create(versionRef, {
        ...record,
        versionCreatedAt: timestamp,
      });
      transaction.create(auditRef, proinAuditRecord({
        adminUid,
        action: before ? "proin.coupon_updated" : "proin.coupon_created",
        targetType: "proinCoupon",
        targetId: normalized.codeHash,
        reason,
        before: before ? proinCouponView(before) : {},
        after: proinCouponView(record),
        fieldValue,
      }));
      response = {
        ...proinCouponView(record),
        codeHash: normalized.codeHash,
      };
    });
    return response;
  }

  async function claimCoupon({uid, rawCode, salonId = ""}) {
    const codeHash = proinCouponHash(rawCode);
    if (!codeHash) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a 4-20 character coupon code with at least one letter.",
      );
    }
    const db = firestore();
    const requestedSalonId = String(salonId || "").trim();
    const walletType = requestedSalonId ?
      "salon_promotion_credits" : "customer_rewards";
    const accountId = requestedSalonId || uid;
    const walletId = proinWalletId(walletType, accountId);
    const couponRef = db.collection("proinCoupons").doc(codeHash);
    const usageRef = db.collection("proinCouponUsage").doc(codeHash);
    const claimRef = db.collection("proinCouponClaims")
      .doc(`${codeHash}__${walletId}`);
    const nowMillis = Date.now();
    const reservation = await db.runTransaction(async (transaction) => {
      const userRef = db.collection("users").doc(uid);
      const salonRef = requestedSalonId ?
        db.collection("salons").doc(requestedSalonId) : null;
      const snapshots = await Promise.all([
        transaction.get(couponRef),
        transaction.get(usageRef),
        transaction.get(claimRef),
        transaction.get(userRef),
        ...(salonRef ? [transaction.get(salonRef)] : []),
      ]);
      const [
        couponSnapshot,
        usageSnapshot,
        claimSnapshot,
        userSnapshot,
        salonSnapshot,
      ] = snapshots;
      if (walletType === "customer_rewards") {
        if (userSnapshot.data()?.role !== "customer") {
          throw new HttpsError(
            "permission-denied",
            "Only customer accounts can claim customer Proin coupons.",
          );
        }
      } else {
        if (userSnapshot.data()?.role !== "owner") {
          throw new HttpsError(
            "permission-denied",
            "Only salon owner accounts can claim salon coupons.",
          );
        }
        const salon = salonSnapshot?.data();
        if (!salon) {
          throw new HttpsError("not-found", "Salon not found.");
        }
        if (String(salon.ownerUid || "").trim() !== uid) {
          throw new HttpsError(
            "permission-denied",
            "Only this salon's owner can claim this coupon.",
          );
        }
      }
      const existingClaim = claimSnapshot.data();
      if (existingClaim?.status === "awarded") {
        return {
          alreadyClaimed: true,
          programId: String(existingClaim.programId || ""),
          lotId: String(existingClaim.lotId || ""),
          amountProin: storedProin(existingClaim.amountProin),
          expiresAtMillis: timestampMillis(existingClaim.rewardExpiresAt),
        };
      }
      const coupon = couponSnapshot.data();
      if (!coupon) {
        throw new HttpsError("not-found", "This coupon code is not valid.");
      }
      const usage = proinCouponUsageState(usageSnapshot.data());
      if (existingClaim?.status !== "pending") {
        const decision = proinCouponClaimAllowed({
          coupon,
          usage,
          uid,
          accountId,
          walletType,
          nowMillis,
        });
        if (!decision.allowed) {
          throw new HttpsError("failed-precondition", decision.reason);
        }
      }
      const programId = proinDocumentId(coupon.programId, "program id");
      const programSnapshot = await transaction.get(
        db.collection("proinPrograms").doc(programId),
      );
      const program = programSnapshot.data();
      if (!program || program.sourceType !== "coupon" ||
          program.walletType !== walletType ||
          program.qualificationEvent !== "coupon_claimed") {
        throw new HttpsError(
          "failed-precondition",
          "This coupon reward is not currently configured.",
        );
      }
      if (existingClaim?.status !== "pending") {
        transaction.set(usageRef, {
          ...usage,
          couponHash: codeHash,
          reservedClaims: usage.reservedClaims + 1,
          updatedAt: fieldValue.serverTimestamp(),
        });
      }
      transaction.set(claimRef, {
        couponHash: codeHash,
        maskedCode: String(coupon.maskedCode || ""),
        uid,
        accountId,
        salonId: requestedSalonId,
        walletId,
        walletType,
        programId,
        status: "pending",
        attemptCount: storedProin(existingClaim?.attemptCount) + 1,
        createdAt: existingClaim?.createdAt || fieldValue.serverTimestamp(),
        updatedAt: fieldValue.serverTimestamp(),
      }, {merge: true});
      return {alreadyClaimed: false, programId};
    });
    if (reservation.alreadyClaimed) return reservation;

    const idempotencyKey = `coupon:${codeHash}:${walletId}`;
    let award;
    try {
      award = await grantQualifiedEvent({
        data: {
          programId: reservation.programId,
          walletType,
          accountId,
          sourceId: codeHash,
          idempotencyKey,
          expectedSourceType: "coupon",
          expectedQualificationEvent: "coupon_claimed",
        },
      });
    } catch (error) {
      await releaseFailedCouponClaim({
        claimRef,
        usageRef,
        errorMessage: String(error.message || "Coupon reward failed."),
      });
      throw error;
    }

    await db.runTransaction(async (transaction) => {
      const [claimSnapshot, usageSnapshot] = await Promise.all([
        transaction.get(claimRef),
        transaction.get(usageRef),
      ]);
      const claim = claimSnapshot.data();
      if (claim?.status === "awarded") return;
      if (claim?.status !== "pending") {
        throw new HttpsError(
          "aborted",
          "Coupon claim changed while the reward was being issued. Try again.",
        );
      }
      const usage = proinCouponUsageState(usageSnapshot.data());
      if (usage.reservedClaims <= 0) {
        throw new HttpsError(
          "data-loss",
          "Coupon reservation totals are not balanced.",
        );
      }
      transaction.update(claimRef, {
        status: "awarded",
        lotId: award.lotId,
        ledgerId: award.ledgerId,
        amountProin: award.amountProin,
        rewardExpiresAt: Timestamp.fromMillis(award.expiresAtMillis),
        awardedAt: fieldValue.serverTimestamp(),
        updatedAt: fieldValue.serverTimestamp(),
      });
      transaction.set(usageRef, {
        ...usage,
        reservedClaims: usage.reservedClaims - 1,
        claimedCount: usage.claimedCount + 1,
        updatedAt: fieldValue.serverTimestamp(),
      });
    });
    return {
      alreadyClaimed: award.duplicate === true,
      programId: reservation.programId,
      lotId: award.lotId,
      amountProin: award.amountProin,
      expiresAtMillis: award.expiresAtMillis,
      availableProin: award.availableProin,
    };
  }

  async function releaseFailedCouponClaim({
    claimRef,
    usageRef,
    errorMessage,
  }) {
    const db = firestore();
    await db.runTransaction(async (transaction) => {
      const [claimSnapshot, usageSnapshot] = await Promise.all([
        transaction.get(claimRef),
        transaction.get(usageRef),
      ]);
      if (claimSnapshot.data()?.status !== "pending") return;
      const usage = proinCouponUsageState(usageSnapshot.data());
      transaction.update(claimRef, {
        status: "failed",
        failureMessage: errorMessage.slice(0, 300),
        failedAt: fieldValue.serverTimestamp(),
        updatedAt: fieldValue.serverTimestamp(),
      });
      transaction.set(usageRef, {
        ...usage,
        reservedClaims: Math.max(0, usage.reservedClaims - 1),
        updatedAt: fieldValue.serverTimestamp(),
      });
    });
  }

  async function customerWalletData({uid}) {
    const accountId = requiredText(uid, "customer id", 160);
    const db = firestore();
    const userSnapshot = await db.collection("users").doc(accountId).get();
    if (userSnapshot.data()?.role !== "customer") {
      throw new HttpsError(
        "permission-denied",
        "Customer Proin is available only to customer accounts.",
      );
    }
    const walletId = proinWalletId("customer_rewards", accountId);
    const [walletSnapshot, lotsSnapshot] = await Promise.all([
      db.collection("proinWallets").doc(walletId).get(),
      db.collection("proinLots")
        .where("walletId", "==", walletId)
        .where("status", "==", "active")
        .orderBy("expiresAt", "asc")
        .limit(50)
        .get(),
    ]);
    const wallet = proinWalletState(walletSnapshot.data());
    if (walletSnapshot.exists && !proinWalletInvariant(wallet)) {
      throw new HttpsError(
        "data-loss",
        "Your Proin balance needs review. Please contact support.",
      );
    }
    return {
      walletId,
      ...proinWalletView(wallet),
      proinToInrRate: 1,
      purchasable: false,
      transferable: false,
      cashWithdrawable: false,
      expiringLots: lotsSnapshot.docs
        .map((document) => ({id: document.id, ...document.data()}))
        .filter((lot) => storedProin(lot.availableProin) > 0)
        .slice(0, 20)
        .map((lot) => ({
          lotId: lot.id,
          amountProin: storedProin(lot.availableProin),
          expiresAtMillis: timestampMillis(lot.expiresAt),
          sourceType: String(lot.sourceType || ""),
        })),
    };
  }

  async function salonWalletData({salonId}) {
    const accountId = requiredText(salonId, "salon id", 160);
    const db = firestore();
    const salonSnapshot = await db.collection("salons").doc(accountId).get();
    if (!salonSnapshot.exists) {
      throw new HttpsError("not-found", "Salon not found.");
    }
    const walletId = proinWalletId("salon_promotion_credits", accountId);
    const [walletSnapshot, lotsSnapshot] = await Promise.all([
      db.collection("proinWallets").doc(walletId).get(),
      db.collection("proinLots")
        .where("walletId", "==", walletId)
        .where("status", "==", "active")
        .orderBy("expiresAt", "asc")
        .limit(50)
        .get(),
    ]);
    const wallet = proinWalletState(walletSnapshot.data());
    if (walletSnapshot.exists && !proinWalletInvariant(wallet)) {
      throw new HttpsError(
        "data-loss",
        "This salon's promotional credit balance needs administrator review.",
      );
    }
    return {
      walletId,
      walletType: "salon_promotion_credits",
      accountId,
      ...proinWalletView(wallet),
      proinToInrRate: 1,
      purchasable: false,
      transferable: false,
      cashWithdrawable: false,
      expiringLots: lotsSnapshot.docs
        .map((document) => ({id: document.id, ...document.data()}))
        .filter((lot) => storedProin(lot.availableProin) > 0)
        .slice(0, 20)
        .map((lot) => ({
          lotId: lot.id,
          amountProin: storedProin(lot.availableProin),
          expiresAtMillis: timestampMillis(lot.expiresAt),
          sourceType: String(lot.sourceType || ""),
        })),
    };
  }

  async function customerStatementData({
    uid,
    limit = 50,
    beforeMillis = 0,
  }) {
    const accountId = requiredText(uid, "customer id", 160);
    const db = firestore();
    const userSnapshot = await db.collection("users").doc(accountId).get();
    if (userSnapshot.data()?.role !== "customer") {
      throw new HttpsError(
        "permission-denied",
        "Customer Proin activity is available only to customer accounts.",
      );
    }
    const pageSize = Math.max(1, Math.min(50, Number(limit) || 50));
    const cursorMillis = Number(beforeMillis) || 0;
    const walletId = proinWalletId("customer_rewards", accountId);
    let query = db.collection("proinLedger")
      .where("walletId", "==", walletId)
      .orderBy("createdAt", "desc");
    if (cursorMillis > 0) {
      query = query.where("createdAt", "<", Timestamp.fromMillis(cursorMillis));
    }
    const snapshot = await query.limit(pageSize + 1).get();
    const documents = snapshot.docs.slice(0, pageSize);
    const entries = documents.map((document) => {
      const data = document.data() || {};
      return {
        transactionId: document.id,
        type: String(data.type || ""),
        direction: String(data.direction || ""),
        amountProin: storedProin(data.amountProin),
        restoredProin: storedProin(data.restoredProin),
        expiredProin: storedProin(data.expiredProin),
        sourceType: String(data.sourceType || ""),
        bookingId: String(data.bookingId || ""),
        createdAtMillis: timestampMillis(data.createdAt),
      };
    });
    return {
      walletId,
      entries,
      hasMore: snapshot.size > pageSize,
      nextBeforeMillis: entries.length === 0 ? 0 :
        entries[entries.length - 1].createdAtMillis,
    };
  }

  async function quoteBookingRedemption({
    uid,
    salonId,
    serviceIds,
    originalAmount,
    discountAmount,
  }) {
    const accountId = requiredText(uid, "customer id", 160);
    const walletId = proinWalletId("customer_rewards", accountId);
    const db = firestore();
    const [userSnapshot, walletSnapshot, lotsSnapshot] = await Promise.all([
      db.collection("users").doc(accountId).get(),
      db.collection("proinWallets").doc(walletId).get(),
      db.collection("proinLots")
        .where("walletId", "==", walletId)
        .where("status", "==", "active")
        .orderBy("expiresAt", "asc")
        .limit(500)
        .get(),
    ]);
    if (userSnapshot.data()?.role !== "customer") {
      throw new HttpsError(
        "permission-denied",
        "Only customers can use Proin for a booking.",
      );
    }
    const wallet = proinWalletState(walletSnapshot.data());
    if (walletSnapshot.exists && !proinWalletInvariant(wallet)) {
      throw new HttpsError(
        "data-loss",
        "Your Proin balance needs review. Please contact support.",
      );
    }
    const lots = lotsSnapshot.docs.map((document) => ({
      id: document.id,
      ...document.data(),
    }));
    const programsById = await loadRedemptionPrograms({db, lots});
    try {
      const quote = quoteProinRedemption({
        lots,
        programsById,
        originalAmount,
        discountAmount,
        salonId,
        serviceIds,
        nowMillis: Date.now(),
      });
      return {
        ...quote,
        availableProin: wallet.availableProin,
      };
    } catch (error) {
      throw asHttpsError(error);
    }
  }

  async function reserveBookingRedemptionInTransaction({
    transaction,
    bookingId,
    uid,
    salonId,
    serviceIds,
    originalAmount,
    discountAmount,
    requestedProin,
  }) {
    let requested;
    try {
      requested = proinInteger(requestedProin ?? 0, "Requested Proin");
    } catch (error) {
      throw asHttpsError(error);
    }
    const payableBeforeProin = Math.max(
      0,
      storedProin(originalAmount) - storedProin(discountAmount),
    );
    if (requested === 0) {
      return emptyBookingProinFields(payableBeforeProin);
    }
    const db = firestore();
    const walletType = "customer_rewards";
    const walletId = proinWalletId(walletType, uid);
    const walletRef = db.collection("proinWallets").doc(walletId);
    const financeRef = db.collection("proinFinance").doc("current");
    const reservationRef = db.collection("proinReservations").doc(bookingId);
    const lotsQuery = db.collection("proinLots")
      .where("walletId", "==", walletId)
      .where("status", "==", "active")
      .orderBy("expiresAt", "asc")
      .limit(500);
    const [walletSnapshot, financeSnapshot, reservationSnapshot, lotsSnapshot] =
      await Promise.all([
        transaction.get(walletRef),
        transaction.get(financeRef),
        transaction.get(reservationRef),
        transaction.get(lotsQuery),
      ]);
    if (reservationSnapshot.exists) {
      throw new HttpsError(
        "already-exists",
        "Proin is already reserved for this booking.",
      );
    }
    const wallet = proinWalletState(walletSnapshot.data());
    const finance = proinFinanceState(financeSnapshot.data());
    if (!walletSnapshot.exists || !proinWalletInvariant(wallet) ||
        !financeSnapshot.exists || !proinFinanceInvariant(finance)) {
      throw new HttpsError(
        "failed-precondition",
        "Your Proin balance cannot be used right now. Please try again later.",
      );
    }
    const lots = lotsSnapshot.docs.map((document) => ({
      id: document.id,
      ref: document.ref,
      ...document.data(),
    }));
    for (const lot of lots) {
      if (!proinLotInvariant(lot)) {
        throw new HttpsError(
          "data-loss",
          "A Proin reward lot needs review before it can be used.",
        );
      }
    }
    const programsById = await loadRedemptionPrograms({
      db,
      lots,
      transaction,
    });
    let maximumQuote;
    let selectedQuote;
    try {
      maximumQuote = quoteProinRedemption({
        lots,
        programsById,
        originalAmount,
        discountAmount,
        salonId,
        serviceIds,
        nowMillis: Date.now(),
      });
      if (requested > maximumQuote.allocatedProin) {
        throw new ProinValidationError(
          `Only ${maximumQuote.allocatedProin} Proin can be used for this booking.`,
        );
      }
      selectedQuote = quoteProinRedemption({
        lots,
        programsById,
        originalAmount,
        discountAmount,
        salonId,
        serviceIds,
        nowMillis: Date.now(),
        requestedProin: requested,
      });
    } catch (error) {
      throw asHttpsError(error);
    }
    if (selectedQuote.allocatedProin !== requested ||
        selectedQuote.shortfallProin !== 0) {
      throw new HttpsError(
        "failed-precondition",
        "Your available Proin changed. Refresh the price and try again.",
      );
    }
    if (wallet.availableProin < requested ||
        finance.outstandingLiabilityInr < requested ||
        finance.reservedLiabilityInr + requested >
          finance.outstandingLiabilityInr) {
      throw new HttpsError(
        "failed-precondition",
        "Your Proin balance changed. Refresh the price and try again.",
      );
    }
    const usageContexts = await loadReservationUsageContexts({
      db,
      transaction,
      allocations: selectedQuote.allocations,
      walletId,
    });
    const timestamp = fieldValue.serverTimestamp();
    const allocationByLot = new Map(selectedQuote.allocations.map(
      (allocation) => [allocation.lotId, allocation.amountProin],
    ));
    let nextExpiryAtMillis = 0;
    for (const lot of lots) {
      const amount = allocationByLot.get(lot.id) || 0;
      const availableAfter = storedProin(lot.availableProin) - amount;
      if (availableAfter < 0) {
        throw new HttpsError("data-loss", "Proin allocation is not balanced.");
      }
      if (amount > 0) {
        transaction.update(lot.ref, {
          availableProin: availableAfter,
          reservedProin: storedProin(lot.reservedProin) + amount,
          status: availableAfter > 0 ? "active" : "reserved",
          updatedAt: timestamp,
        });
      }
      if (availableAfter > 0) {
        const expiry = timestampMillis(lot.expiresAt);
        if (!nextExpiryAtMillis || expiry < nextExpiryAtMillis) {
          nextExpiryAtMillis = expiry;
        }
      }
    }
    const walletAfter = {
      ...wallet,
      availableProin: wallet.availableProin - requested,
      reservedProin: wallet.reservedProin + requested,
      nextExpiryAtMillis,
    };
    const financeAfter = {
      ...finance,
      reservedLiabilityInr: finance.reservedLiabilityInr + requested,
    };
    if (!proinWalletInvariant(walletAfter) ||
        !proinFinanceInvariant(financeAfter)) {
      throw new HttpsError("internal", "The Proin reservation would not balance.");
    }
    transaction.set(walletRef, {
      ...walletAfter,
      nextExpiryAt: nextExpiryAtMillis ?
        Timestamp.fromMillis(nextExpiryAtMillis) : null,
      needsExpiryRefresh: false,
      updatedAt: timestamp,
    }, {merge: true});
    transaction.set(financeRef, {...financeAfter, updatedAt: timestamp}, {
      merge: true,
    });
    applyReservationUsageUpdates({
      transaction,
      contexts: usageContexts,
      allocations: selectedQuote.allocations,
      outcome: "reserve",
      timestamp,
    });
    const ledgerRef = db.collection("proinLedger")
      .doc(`reserve_${bookingId}`);
    transaction.create(reservationRef, {
      reservationId: bookingId,
      bookingId,
      walletId,
      walletType,
      accountId: uid,
      salonId,
      serviceIds,
      status: "reserved",
      amountProin: requested,
      allocations: selectedQuote.allocations,
      payableBeforeProin: selectedQuote.payableBeforeProin,
      customerPayableAmount: selectedQuote.customerPayableAmount,
      createdAt: timestamp,
      updatedAt: timestamp,
    });
    transaction.create(ledgerRef, {
      transactionId: ledgerRef.id,
      walletId,
      walletType,
      accountId: uid,
      type: "reserve",
      direction: "hold",
      amountProin: requested,
      bookingId,
      salonId,
      lotAllocations: selectedQuote.allocations,
      createdByType: "customer",
      createdByUid: uid,
      balanceAfter: {
        availableProin: walletAfter.availableProin,
        reservedProin: walletAfter.reservedProin,
      },
      createdAt: timestamp,
    });
    return {
      proinStatus: "reserved",
      proinRequestedAmount: requested,
      proinReservedAmount: requested,
      proinRedeemedAmount: 0,
      proinReleasedAmount: 0,
      proinExpiredOnReleaseAmount: 0,
      customerPayableBeforeProin: selectedQuote.payableBeforeProin,
      customerPayableAmount: selectedQuote.customerPayableAmount,
    };
  }

  async function resolveBookingRedemptionInTransaction({
    transaction,
    bookingId,
    booking,
    outcome,
    nowMillis = Date.now(),
  }) {
    const reservedAmount = storedProin(booking.proinReservedAmount);
    if (booking.proinStatus !== "reserved" || reservedAmount <= 0) {
      return null;
    }
    if (!['redeemed', 'released'].includes(outcome)) {
      throw new HttpsError("invalid-argument", "Invalid Proin outcome.");
    }
    const db = firestore();
    const reservationRef = db.collection("proinReservations").doc(bookingId);
    const reservationSnapshot = await transaction.get(reservationRef);
    const reservation = reservationSnapshot.data();
    if (!reservation || reservation.status !== "reserved" ||
        storedProin(reservation.amountProin) !== reservedAmount) {
      throw new HttpsError(
        "data-loss",
        "The booking's Proin reservation is not balanced.",
      );
    }
    const walletId = requiredText(reservation.walletId, "wallet id", 160);
    const walletRef = db.collection("proinWallets").doc(walletId);
    const financeRef = db.collection("proinFinance").doc("current");
    const allocations = Array.isArray(reservation.allocations) ?
      reservation.allocations.map((allocation) => ({
        lotId: requiredText(allocation.lotId, "lot id", 160),
        programId: proinDocumentId(allocation.programId, "program id"),
        amountProin: storedPositiveInteger(allocation.amountProin, 0),
      })) : [];
    if (allocations.length === 0 || allocations.reduce(
      (total, allocation) => total + allocation.amountProin,
      0,
    ) !== reservedAmount) {
      throw new HttpsError("data-loss", "Proin allocations are not balanced.");
    }
    const lotRefs = allocations.map((allocation) =>
      db.collection("proinLots").doc(allocation.lotId));
    const [walletSnapshot, financeSnapshot, ...lotSnapshots] =
      await Promise.all([
        transaction.get(walletRef),
        transaction.get(financeRef),
        ...lotRefs.map((ref) => transaction.get(ref)),
      ]);
    const wallet = proinWalletState(walletSnapshot.data());
    const finance = proinFinanceState(financeSnapshot.data());
    if (!walletSnapshot.exists || !proinWalletInvariant(wallet) ||
        !financeSnapshot.exists || !proinFinanceInvariant(finance) ||
        wallet.reservedProin < reservedAmount ||
        finance.reservedLiabilityInr < reservedAmount) {
      throw new HttpsError("data-loss", "Reserved Proin totals are not balanced.");
    }
    const lots = lotSnapshots.map((snapshot, index) => ({
      id: snapshot.id,
      ref: snapshot.ref,
      allocation: allocations[index],
      ...snapshot.data(),
    }));
    for (const lot of lots) {
      if (!lot.ref || !proinLotInvariant(lot) ||
          storedProin(lot.reservedProin) < lot.allocation.amountProin ||
          String(lot.programId || "") !== lot.allocation.programId) {
        throw new HttpsError("data-loss", "A reserved Proin lot is not balanced.");
      }
    }
    const usageContexts = await loadReservationUsageContexts({
      db,
      transaction,
      allocations,
      walletId,
    });
    const timestamp = fieldValue.serverTimestamp();
    let restoredProin = 0;
    let expiredProin = 0;
    let expiredReservedProin = 0;
    let expiredAvailableProin = 0;
    for (const lot of lots) {
      const amount = lot.allocation.amountProin;
      const reservedAfter = storedProin(lot.reservedProin) - amount;
      const isExpiredRelease = outcome === "released" &&
        timestampMillis(lot.expiresAt) <= nowMillis;
      const availableBefore = storedProin(lot.availableProin);
      const availableExpiringNow = isExpiredRelease ? availableBefore : 0;
      const availableAfter = isExpiredRelease ? 0 : availableBefore +
        (outcome === "released" ? amount : 0);
      const redeemedAfter = storedProin(lot.redeemedProin) +
        (outcome === "redeemed" ? amount : 0);
      const expiredAfter = storedProin(lot.expiredProin) +
        (isExpiredRelease ? amount + availableExpiringNow : 0);
      restoredProin += outcome === "released" && !isExpiredRelease ? amount : 0;
      expiredProin += isExpiredRelease ? amount + availableExpiringNow : 0;
      expiredReservedProin += isExpiredRelease ? amount : 0;
      expiredAvailableProin += availableExpiringNow;
      transaction.update(lot.ref, {
        availableProin: availableAfter,
        reservedProin: reservedAfter,
        redeemedProin: redeemedAfter,
        expiredProin: expiredAfter,
        status: resolvedLotStatus({
          availableProin: availableAfter,
          reservedProin: reservedAfter,
          redeemedProin: redeemedAfter,
          expiredProin: expiredAfter,
          expiresAtMillis: timestampMillis(lot.expiresAt),
          nowMillis,
        }),
        updatedAt: timestamp,
      });
    }
    const walletAfter = {
      ...wallet,
      availableProin:
        wallet.availableProin + restoredProin - expiredAvailableProin,
      reservedProin: wallet.reservedProin - reservedAmount,
      lifetimeRedeemedProin: wallet.lifetimeRedeemedProin +
        (outcome === "redeemed" ? reservedAmount : 0),
      lifetimeExpiredProin: wallet.lifetimeExpiredProin + expiredProin,
      nextExpiryAtMillis: 0,
    };
    const financeAfter = {
      ...finance,
      reservedLiabilityInr: finance.reservedLiabilityInr - reservedAmount,
      outstandingLiabilityInr: finance.outstandingLiabilityInr -
        (outcome === "redeemed" ? reservedAmount : expiredProin),
      redeemedPayableInr: finance.redeemedPayableInr +
        (outcome === "redeemed" ? reservedAmount : 0),
      unallocatedBudgetInr: finance.unallocatedBudgetInr + expiredProin,
      lifetimeRedeemedProin: finance.lifetimeRedeemedProin +
        (outcome === "redeemed" ? reservedAmount : 0),
      lifetimeExpiredProin: finance.lifetimeExpiredProin + expiredProin,
    };
    if (!proinWalletInvariant(walletAfter) ||
        !proinFinanceInvariant(financeAfter)) {
      throw new HttpsError("internal", "The Proin resolution would not balance.");
    }
    transaction.set(walletRef, {
      ...walletAfter,
      nextExpiryAt: null,
      needsExpiryRefresh: true,
      updatedAt: timestamp,
    }, {merge: true});
    transaction.set(financeRef, {...financeAfter, updatedAt: timestamp}, {
      merge: true,
    });
    applyReservationUsageUpdates({
      transaction,
      contexts: usageContexts,
      allocations,
      outcome,
      expiredProinByLot: new Map(lots.map((lot) => [
        lot.id,
        outcome === "released" && timestampMillis(lot.expiresAt) <= nowMillis ?
          lot.allocation.amountProin + storedProin(lot.availableProin) : 0,
      ])),
      timestamp,
    });
    const ledgerRef = db.collection("proinLedger")
      .doc(`${outcome === "redeemed" ? "redeem" : "release"}_${bookingId}`);
    transaction.create(ledgerRef, {
      transactionId: ledgerRef.id,
      walletId,
      walletType: "customer_rewards",
      accountId: booking.customerUid,
      type: outcome === "redeemed" ? "redeem" : "release",
      direction: outcome === "redeemed" ? "debit" : "credit",
      amountProin: reservedAmount,
      restoredProin,
      expiredProin,
      expiredReservedProin,
      expiredAvailableProin,
      bookingId,
      salonId: booking.salonId,
      lotAllocations: allocations,
      createdByType: "system",
      createdByUid: "",
      balanceAfter: {
        availableProin: walletAfter.availableProin,
        reservedProin: walletAfter.reservedProin,
      },
      createdAt: timestamp,
    });
    transaction.update(reservationRef, {
      status: outcome,
      restoredProin,
      expiredProin: expiredReservedProin,
      additionalExpiredProin: expiredAvailableProin,
      resolvedAt: timestamp,
      updatedAt: timestamp,
    });
    if (outcome === "redeemed") {
      const salonId = requiredText(booking.salonId, "salon id", 160);
      transaction.set(db.collection("salonWallets").doc(salonId), {
        salonId,
        payableBalance: fieldValue.increment(reservedAmount),
        lifetimeProinReimbursement: fieldValue.increment(reservedAmount),
        updatedAt: timestamp,
      }, {merge: true});
      transaction.create(
        db.collection("proinSalonReimbursements").doc(bookingId),
        {
          bookingId,
          salonId,
          customerUid: booking.customerUid,
          amountInr: reservedAmount,
          redeemedProin: reservedAmount,
          status: "payable",
          createdAt: timestamp,
          updatedAt: timestamp,
        },
      );
    }
    return outcome === "redeemed" ? {
      walletId,
      proinStatus: "redeemed",
      proinReservedAmount: 0,
      proinRedeemedAmount: reservedAmount,
      proinReleasedAmount: 0,
      proinExpiredOnReleaseAmount: 0,
      proinReimbursementStatus: "payable",
    } : {
      walletId,
      proinStatus: "released",
      proinReservedAmount: 0,
      proinRedeemedAmount: 0,
      proinReleasedAmount: restoredProin,
      proinExpiredOnReleaseAmount: expiredReservedProin,
      proinReimbursementStatus: "none",
    };
  }

  async function revokeAvailableLotAsAdmin({adminUid, data, reason}) {
    const lotId = requiredText(data.lotId, "Proin lot id", 160);
    const requestId = requiredText(data.requestId, "revocation request id", 160);
    if (requestId.length < 6) {
      throw new HttpsError(
        "invalid-argument",
        "Revocation request ID must contain at least 6 characters.",
      );
    }
    const db = firestore();
    const idempotencyHash = sha256(`revoke:${lotId}:${requestId}`);
    const idempotencyRef = db.collection("proinIdempotencyKeys")
      .doc(idempotencyHash);
    const lotRef = db.collection("proinLots").doc(lotId);
    const ledgerRef = db.collection("proinLedger")
      .doc(`revoke_${idempotencyHash}`);
    const auditRef = db.collection("adminAuditLogs").doc();
    let response = null;
    let walletToRefresh = "";
    await db.runTransaction(async (transaction) => {
      const idempotencySnapshot = await transaction.get(idempotencyRef);
      if (idempotencySnapshot.exists) {
        const stored = idempotencySnapshot.data() || {};
        if (stored.operation !== "revoke" || stored.lotId !== lotId) {
          throw new HttpsError(
            "already-exists",
            "This revocation request ID is already used.",
          );
        }
        response = {
          duplicate: true,
          lotId,
          walletId: String(stored.walletId || ""),
          accountId: String(stored.accountId || ""),
          walletType: String(stored.walletType || ""),
          amountProin: storedProin(stored.amountProin),
          availableProin: storedProin(stored.availableProinAfter),
        };
        return;
      }
      const lotSnapshot = await transaction.get(lotRef);
      const lot = lotSnapshot.data();
      if (!lot) throw new HttpsError("not-found", "Proin lot not found.");
      if (!proinLotInvariant(lot)) {
        throw new HttpsError(
          "data-loss",
          "This Proin lot is not balanced. Reconcile before revoking it.",
        );
      }
      const nowMillis = Date.now();
      const availableBefore = storedProin(lot.availableProin);
      if (lot.status !== "active" || availableBefore <= 0 ||
          timestampMillis(lot.expiresAt) <= nowMillis) {
        throw new HttpsError(
          "failed-precondition",
          "Only active, unexpired and unused Proin can be revoked.",
        );
      }
      let amountProin = availableBefore;
      if (data.amountProin !== undefined && data.amountProin !== null) {
        try {
          amountProin = proinInteger(
            data.amountProin,
            "Revocation amount",
            {allowZero: false},
          );
        } catch (error) {
          throw asHttpsError(error);
        }
      }
      if (amountProin > availableBefore) {
        throw new HttpsError(
          "failed-precondition",
          `Only ${availableBefore} unused Proin can be revoked from this lot.`,
        );
      }
      const walletId = requiredText(lot.walletId, "wallet id", 160);
      const programId = proinDocumentId(lot.programId, "program id");
      const walletRef = db.collection("proinWallets").doc(walletId);
      const financeRef = db.collection("proinFinance").doc("current");
      const programUsageRef = db.collection("proinProgramUsage").doc(programId);
      const accountUsageRef = db.collection("proinProgramAccountUsage")
        .doc(`${programId}__${walletId}`);
      const [walletSnapshot, financeSnapshot, programUsageSnapshot,
        accountUsageSnapshot] = await Promise.all([
        transaction.get(walletRef),
        transaction.get(financeRef),
        transaction.get(programUsageRef),
        transaction.get(accountUsageRef),
      ]);
      const wallet = proinWalletState(walletSnapshot.data());
      const finance = proinFinanceState(financeSnapshot.data());
      const programUsage = proinProgramUsageState(programUsageSnapshot.data());
      const accountUsage = proinProgramUsageState(accountUsageSnapshot.data());
      if (!walletSnapshot.exists || !proinWalletInvariant(wallet) ||
          !financeSnapshot.exists || !proinFinanceInvariant(finance) ||
          wallet.availableProin < amountProin ||
          finance.outstandingLiabilityInr < amountProin ||
          programUsage.availableProin < amountProin ||
          accountUsage.availableProin < amountProin) {
        throw new HttpsError(
          "data-loss",
          "Proin totals are not balanced. Reconcile before revoking.",
        );
      }
      const availableAfter = availableBefore - amountProin;
      const revokedAfter = storedProin(lot.revokedProin) + amountProin;
      const walletAfter = {
        ...wallet,
        availableProin: wallet.availableProin - amountProin,
        lifetimeRevokedProin: wallet.lifetimeRevokedProin + amountProin,
        nextExpiryAtMillis: 0,
      };
      const financeAfter = {
        ...finance,
        outstandingLiabilityInr:
          finance.outstandingLiabilityInr - amountProin,
        unallocatedBudgetInr: finance.unallocatedBudgetInr + amountProin,
        lifetimeRevokedProin: finance.lifetimeRevokedProin + amountProin,
      };
      if (!proinWalletInvariant(walletAfter) ||
          !proinFinanceInvariant(financeAfter)) {
        throw new HttpsError("internal", "The Proin revocation would not balance.");
      }
      const timestamp = fieldValue.serverTimestamp();
      const revokeUsage = (usage) => ({
        ...usage,
        availableProin: usage.availableProin - amountProin,
        revokedProin: usage.revokedProin + amountProin,
        updatedAt: timestamp,
      });
      transaction.update(lotRef, {
        availableProin: availableAfter,
        revokedProin: revokedAfter,
        status: availableAfter > 0 ? "active" :
          storedProin(lot.reservedProin) > 0 ? "reserved" : "revoked",
        lastRevokedAt: timestamp,
        lastRevocationRequestIdHash: sha256(requestId),
        updatedAt: timestamp,
      });
      transaction.set(walletRef, {
        ...walletAfter,
        nextExpiryAt: null,
        needsExpiryRefresh: true,
        updatedAt: timestamp,
      }, {merge: true});
      transaction.set(financeRef, {...financeAfter, updatedAt: timestamp}, {
        merge: true,
      });
      transaction.set(programUsageRef, revokeUsage(programUsage), {merge: true});
      transaction.set(accountUsageRef, revokeUsage(accountUsage), {merge: true});
      transaction.create(ledgerRef, {
        transactionId: ledgerRef.id,
        walletId,
        walletType: String(lot.walletType || ""),
        accountId: String(lot.accountId || ""),
        type: "revoke",
        direction: "debit",
        amountProin,
        programId,
        sourceType: String(lot.sourceType || ""),
        sourceId: String(lot.sourceId || ""),
        lotAllocations: [{lotId, amountProin}],
        idempotencyKeyHash: idempotencyHash,
        createdByType: "platform_admin",
        createdByUid: adminUid,
        balanceAfter: {
          availableProin: walletAfter.availableProin,
          reservedProin: walletAfter.reservedProin,
        },
        createdAt: timestamp,
      });
      transaction.create(idempotencyRef, {
        operation: "revoke",
        lotId,
        walletId,
        walletType: String(lot.walletType || ""),
        accountId: String(lot.accountId || ""),
        amountProin,
        availableProinAfter: walletAfter.availableProin,
        ledgerId: ledgerRef.id,
        createdAt: timestamp,
      });
      transaction.create(auditRef, proinAuditRecord({
        adminUid,
        action: "proin.available_lot_revoked",
        targetType: "proinLot",
        targetId: lotId,
        reason,
        before: {
          availableProin: availableBefore,
          revokedProin: storedProin(lot.revokedProin),
        },
        after: {availableProin: availableAfter, revokedProin: revokedAfter},
        fieldValue,
      }));
      walletToRefresh = walletId;
      response = {
        duplicate: false,
        lotId,
        walletId,
        accountId: String(lot.accountId || ""),
        walletType: String(lot.walletType || ""),
        amountProin,
        availableProin: walletAfter.availableProin,
      };
    });
    if (walletToRefresh) await refreshWalletExpiry(walletToRefresh);
    return response;
  }

  async function settleSalonReimbursementAsAdmin({adminUid, data, reason}) {
    const bookingId = requiredText(data.bookingId, "booking id", 160);
    const paymentReference = requiredText(
      data.paymentReference,
      "external payment reference",
      120,
    );
    if (paymentReference.length < 4) {
      throw new HttpsError(
        "invalid-argument",
        "External payment reference must contain at least 4 characters.",
      );
    }
    const paidAtMillis = Number(data.paidAtMillis) || Date.now();
    if (!Number.isSafeInteger(paidAtMillis) || paidAtMillis <= 0 ||
        paidAtMillis > Date.now() + 5 * 60 * 1000) {
      throw new HttpsError("invalid-argument", "Enter a valid payment date.");
    }
    const db = firestore();
    const reimbursementRef = db.collection("proinSalonReimbursements")
      .doc(bookingId);
    const referenceHash = sha256(paymentReference.toUpperCase());
    const paymentReferenceRef = db.collection("proinSettlementPaymentReferences")
      .doc(referenceHash);
    const financeRef = db.collection("proinFinance").doc("current");
    const ledgerRef = db.collection("proinLedger").doc(`settle_${bookingId}`);
    const auditRef = db.collection("adminAuditLogs").doc();
    let response = null;
    await db.runTransaction(async (transaction) => {
      const [reimbursementSnapshot, paymentReferenceSnapshot,
        financeSnapshot] = await Promise.all([
        transaction.get(reimbursementRef),
        transaction.get(paymentReferenceRef),
        transaction.get(financeRef),
      ]);
      const reimbursement = reimbursementSnapshot.data();
      if (!reimbursement) {
        throw new HttpsError("not-found", "Proin reimbursement not found.");
      }
      const salonId = requiredText(reimbursement.salonId, "salon id", 160);
      const amountInr = storedPositiveInteger(reimbursement.amountInr, 0);
      if (amountInr <= 0 || storedProin(reimbursement.redeemedProin) !== amountInr) {
        throw new HttpsError("data-loss", "Proin reimbursement is not balanced.");
      }
      if (reimbursement.status === "settled") {
        if (reimbursement.paymentReferenceHash !== referenceHash ||
            paymentReferenceSnapshot.data()?.bookingId !== bookingId) {
          throw new HttpsError(
            "already-exists",
            "This reimbursement was already settled with another reference.",
          );
        }
        response = {
          alreadySettled: true,
          bookingId,
          salonId,
          amountInr,
          status: "settled",
        };
        return;
      }
      if (reimbursement.status !== "payable") {
        throw new HttpsError(
          "failed-precondition",
          "Only payable Proin reimbursements can be settled.",
        );
      }
      if (paymentReferenceSnapshot.exists) {
        throw new HttpsError(
          "already-exists",
          "This external payment reference is already used.",
        );
      }
      const walletRef = db.collection("salonWallets").doc(salonId);
      const walletSnapshot = await transaction.get(walletRef);
      const payableBalance = storedProin(walletSnapshot.data()?.payableBalance);
      const finance = proinFinanceState(financeSnapshot.data());
      if (!financeSnapshot.exists || !proinFinanceInvariant(finance) ||
          payableBalance < amountInr || finance.redeemedPayableInr < amountInr) {
        throw new HttpsError(
          "data-loss",
          "Salon and Proin payable totals do not match this reimbursement.",
        );
      }
      const financeAfter = {
        ...finance,
        redeemedPayableInr: finance.redeemedPayableInr - amountInr,
        settledExpenseInr: finance.settledExpenseInr + amountInr,
      };
      if (!proinFinanceInvariant(financeAfter)) {
        throw new HttpsError("internal", "The Proin settlement would not balance.");
      }
      const timestamp = fieldValue.serverTimestamp();
      transaction.update(reimbursementRef, {
        status: "settled",
        paymentReference,
        paymentReferenceHash: referenceHash,
        paidAt: Timestamp.fromMillis(paidAtMillis),
        paidByAdminUid: adminUid,
        updatedAt: timestamp,
      });
      transaction.set(walletRef, {
        payableBalance: fieldValue.increment(-amountInr),
        paidAmount: fieldValue.increment(amountInr),
        lifetimeProinReimbursementPaid: fieldValue.increment(amountInr),
        lastProinPaidBookingId: bookingId,
        lastProinPaymentReference: paymentReference,
        updatedAt: timestamp,
      }, {merge: true});
      transaction.set(financeRef, {...financeAfter, updatedAt: timestamp}, {
        merge: true,
      });
      transaction.create(paymentReferenceRef, {
        bookingId,
        salonId,
        amountInr,
        paymentReference,
        paymentReferenceHash: referenceHash,
        paidAt: Timestamp.fromMillis(paidAtMillis),
        createdAt: timestamp,
      });
      transaction.create(ledgerRef, {
        transactionId: ledgerRef.id,
        walletId: "",
        walletType: "salon_reimbursement",
        accountId: salonId,
        type: "settlement",
        direction: "settlement",
        amountProin: amountInr,
        bookingId,
        salonId,
        paymentReferenceHash: referenceHash,
        createdByType: "platform_admin",
        createdByUid: adminUid,
        createdAt: timestamp,
      });
      transaction.create(auditRef, proinAuditRecord({
        adminUid,
        action: "proin.reimbursement_settled",
        targetType: "booking",
        targetId: bookingId,
        reason,
        before: {status: reimbursement.status, paymentReference: ""},
        after: {status: "settled", paymentReference, amountInr},
        fieldValue,
      }));
      response = {
        alreadySettled: false,
        bookingId,
        salonId,
        amountInr,
        status: "settled",
      };
    });
    return response;
  }

  async function expireLots({limit = 200} = {}) {
    const db = firestore();
    const nowMillis = Date.now();
    const snapshot = await db.collection("proinLots")
      .where("status", "==", "active")
      .where("expiresAt", "<=", Timestamp.fromMillis(nowMillis))
      .orderBy("expiresAt", "asc")
      .limit(Math.max(1, Math.min(500, Number(limit) || 200)))
      .get();
    const refreshedWalletIds = new Set();
    const failures = [];
    let expiredCount = 0;
    let expiredProin = 0;
    for (const document of snapshot.docs) {
      try {
        const result = await expireSingleLot(document.ref, nowMillis);
        if (result.expired) {
          expiredCount += 1;
          expiredProin += result.amountProin;
          refreshedWalletIds.add(result.walletId);
        }
      } catch (error) {
        failures.push({lotId: document.id, message: String(error.message)});
      }
    }
    await Promise.all([...refreshedWalletIds].map(refreshWalletExpiry));
    if (failures.length > 0) {
      await recordOperationalFailure({
        type: "proin_expiry_failure",
        title: "Proin expiry processing needs review",
        detail: `${failures.length} Proin lots could not be expired.`,
      });
    }
    return {
      scannedCount: snapshot.size,
      expiredCount,
      expiredProin,
      failureCount: failures.length,
      failures: failures.slice(0, 20),
      processedAtMillis: nowMillis,
    };
  }

  async function expireSingleLot(lotRef, nowMillis) {
    const db = firestore();
    let result = {expired: false, amountProin: 0, walletId: ""};
    await db.runTransaction(async (transaction) => {
      const lotSnapshot = await transaction.get(lotRef);
      const lot = lotSnapshot.data();
      if (!lot || lot.status !== "active" ||
          timestampMillis(lot.expiresAt) > nowMillis) {
        return;
      }
      const amountProin = storedProin(lot.availableProin);
      if (amountProin <= 0) return;
      const walletId = requiredText(lot.walletId, "wallet id", 160);
      const programId = proinDocumentId(lot.programId, "program id");
      const walletRef = db.collection("proinWallets").doc(walletId);
      const programUsageRef = db.collection("proinProgramUsage").doc(programId);
      const accountUsageRef = db.collection("proinProgramAccountUsage")
        .doc(`${programId}__${walletId}`);
      const financeRef = db.collection("proinFinance").doc("current");
      const ledgerRef = db.collection("proinLedger")
        .doc(`expiry_${lotRef.id}`);
      const [
        walletSnapshot,
        programUsageSnapshot,
        accountUsageSnapshot,
        financeSnapshot,
        ledgerSnapshot,
      ] = await Promise.all([
        transaction.get(walletRef),
        transaction.get(programUsageRef),
        transaction.get(accountUsageRef),
        transaction.get(financeRef),
        transaction.get(ledgerRef),
      ]);
      if (ledgerSnapshot.exists) return;
      const wallet = proinWalletState(walletSnapshot.data());
      const finance = proinFinanceState(financeSnapshot.data());
      if (!walletSnapshot.exists || !proinWalletInvariant(wallet) ||
          !financeSnapshot.exists || !proinFinanceInvariant(finance)) {
        throw new Error("Proin wallet or finance state is not balanced.");
      }
      if (wallet.availableProin < amountProin ||
          finance.outstandingLiabilityInr < amountProin) {
        throw new Error("Proin expiry exceeds its recorded liability.");
      }
      const programUsage = proinProgramUsageState(
        programUsageSnapshot.data(),
      );
      const accountUsage = proinProgramUsageState(accountUsageSnapshot.data());
      if (programUsage.availableProin < amountProin ||
          accountUsage.availableProin < amountProin) {
        throw new Error("Proin usage totals do not cover this expiry.");
      }
      const reservedProin = storedProin(lot.reservedProin);
      const walletAfter = {
        ...wallet,
        availableProin: wallet.availableProin - amountProin,
        lifetimeExpiredProin:
          wallet.lifetimeExpiredProin + amountProin,
        nextExpiryAtMillis: 0,
      };
      const financeAfter = {
        ...finance,
        unallocatedBudgetInr:
          finance.unallocatedBudgetInr + amountProin,
        outstandingLiabilityInr:
          finance.outstandingLiabilityInr - amountProin,
        lifetimeExpiredProin:
          finance.lifetimeExpiredProin + amountProin,
      };
      if (!proinWalletInvariant(walletAfter) ||
          !proinFinanceInvariant(financeAfter)) {
        throw new Error("Proin expiry would not balance.");
      }
      const timestamp = fieldValue.serverTimestamp();
      transaction.update(lotRef, {
        availableProin: 0,
        expiredProin: storedProin(lot.expiredProin) + amountProin,
        status: reservedProin > 0 ? "reserved_after_expiry" : "expired",
        expiredAt: timestamp,
        updatedAt: timestamp,
      });
      transaction.set(walletRef, {
        ...walletAfter,
        nextExpiryAt: null,
        needsExpiryRefresh: true,
        updatedAt: timestamp,
      }, {merge: true});
      transaction.set(programUsageRef, expireUsage(
        programUsage,
        amountProin,
        timestamp,
      ), {merge: true});
      transaction.set(accountUsageRef, expireUsage(
        accountUsage,
        amountProin,
        timestamp,
      ), {merge: true});
      transaction.set(financeRef, {
        ...financeAfter,
        updatedAt: timestamp,
      }, {merge: true});
      transaction.create(ledgerRef, {
        transactionId: ledgerRef.id,
        walletId,
        walletType: String(lot.walletType || ""),
        accountId: String(lot.accountId || ""),
        type: "expire",
        direction: "debit",
        amountProin,
        programId,
        sourceType: String(lot.sourceType || ""),
        sourceId: String(lot.sourceId || ""),
        lotAllocations: [{lotId: lotRef.id, amountProin}],
        createdByType: "system",
        createdByUid: "",
        balanceAfter: {
          availableProin: walletAfter.availableProin,
          reservedProin: walletAfter.reservedProin,
        },
        createdAt: timestamp,
      });
      result = {expired: true, amountProin, walletId};
    });
    return result;
  }

  async function refreshWalletExpiry(walletId) {
    const db = firestore();
    const snapshot = await db.collection("proinLots")
      .where("walletId", "==", walletId)
      .where("status", "==", "active")
      .orderBy("expiresAt", "asc")
      .limit(1)
      .get();
    const nextExpiryAt = snapshot.docs[0]?.data()?.expiresAt || null;
    await db.collection("proinWallets").doc(walletId).set({
      nextExpiryAt,
      nextExpiryAtMillis: timestampMillis(nextExpiryAt),
      needsExpiryRefresh: false,
      updatedAt: fieldValue.serverTimestamp(),
    }, {merge: true});
  }

  async function reconcile() {
    const db = firestore();
    const nowMillis = Date.now();
    const [
      walletsSnapshot,
      lotsSnapshot,
      financeSnapshot,
      programUsageSnapshot,
      couponUsageSnapshot,
      couponClaimsSnapshot,
      reservationsSnapshot,
      reimbursementsSnapshot,
      settlementReferencesSnapshot,
      salonPromotionUsageSnapshot,
    ] = await Promise.all([
      db.collection("proinWallets")
        .limit(RECONCILIATION_WALLET_LIMIT + 1).get(),
      db.collection("proinLots")
        .limit(RECONCILIATION_LOT_LIMIT + 1).get(),
      db.collection("proinFinance").doc("current").get(),
      db.collection("proinProgramUsage").limit(501).get(),
      db.collection("proinCouponUsage")
        .limit(RECONCILIATION_COUPON_LIMIT + 1).get(),
      db.collection("proinCouponClaims")
        .limit(RECONCILIATION_COUPON_CLAIM_LIMIT + 1).get(),
      db.collection("proinReservations")
        .limit(RECONCILIATION_RESERVATION_LIMIT + 1).get(),
      db.collection("proinSalonReimbursements")
        .limit(RECONCILIATION_REIMBURSEMENT_LIMIT + 1).get(),
      db.collection("proinSettlementPaymentReferences")
        .limit(RECONCILIATION_SETTLEMENT_REFERENCE_LIMIT + 1).get(),
      db.collection("salonPromotionCreditUsage")
        .limit(RECONCILIATION_SALON_PROMOTION_USAGE_LIMIT + 1).get(),
    ]);
    const walletScanTruncated =
      walletsSnapshot.size > RECONCILIATION_WALLET_LIMIT;
    const lotScanTruncated = lotsSnapshot.size > RECONCILIATION_LOT_LIMIT;
    const walletDocuments = walletsSnapshot.docs
      .slice(0, RECONCILIATION_WALLET_LIMIT);
    const lotDocuments = lotsSnapshot.docs.slice(0, RECONCILIATION_LOT_LIMIT);
    const programUsageScanTruncated = programUsageSnapshot.size > 500;
    const couponUsageScanTruncated =
      couponUsageSnapshot.size > RECONCILIATION_COUPON_LIMIT;
    const couponClaimScanTruncated =
      couponClaimsSnapshot.size > RECONCILIATION_COUPON_CLAIM_LIMIT;
    const reservationScanTruncated =
      reservationsSnapshot.size > RECONCILIATION_RESERVATION_LIMIT;
    const reimbursementScanTruncated =
      reimbursementsSnapshot.size > RECONCILIATION_REIMBURSEMENT_LIMIT;
    const settlementReferenceScanTruncated =
      settlementReferencesSnapshot.size >
        RECONCILIATION_SETTLEMENT_REFERENCE_LIMIT;
    const salonPromotionUsageScanTruncated =
      salonPromotionUsageSnapshot.size >
        RECONCILIATION_SALON_PROMOTION_USAGE_LIMIT;
    const salonPromotionUsageByWallet = new Map(
      salonPromotionUsageSnapshot.docs
        .slice(0, RECONCILIATION_SALON_PROMOTION_USAGE_LIMIT)
        .map((document) => [
          String(document.data()?.walletId || ""),
          document.data() || {},
        ])
        .filter(([walletId]) => walletId),
    );
    const lotsByWallet = new Map();
    for (const document of lotDocuments) {
      const lot = {id: document.id, ...document.data()};
      const values = lotsByWallet.get(lot.walletId) || [];
      values.push(lot);
      lotsByWallet.set(lot.walletId, values);
    }
    const walletMismatches = [];
    const scannedWalletIds = new Set(walletDocuments.map(
      (document) => document.id,
    ));
    for (const document of walletDocuments) {
      const actual = proinWalletState(document.data());
      try {
        const expected = proinWalletSummaryFromLots(
          lotsByWallet.get(document.id) || [],
        );
        const promotionUsage = salonPromotionUsageByWallet.get(document.id);
        if (String(actual.walletType || "") === "salon_promotion_credits" &&
            promotionUsage) {
          const reservedSpend = storedProin(promotionUsage.reservedProin);
          const redeemedSpend = storedProin(promotionUsage.redeemedProin);
          expected.walletType = "salon_promotion_credits";
          expected.accountId = actual.accountId;
          expected.creditLimitProin = actual.creditLimitProin;
          expected.availableProin -= reservedSpend + redeemedSpend;
          expected.reservedProin += reservedSpend;
          expected.lifetimeRedeemedProin += redeemedSpend;
        }
        if (!sameWalletState(actual, expected)) {
          walletMismatches.push({
            walletId: document.id,
            actual: proinWalletView(actual),
            expected: proinWalletView(expected),
          });
        }
      } catch (error) {
        walletMismatches.push({
          walletId: document.id,
          error: String(error.message),
        });
      }
    }
    const missingWalletIds = walletScanTruncated ? [] :
      [...lotsByWallet.keys()].filter((walletId) =>
        !scannedWalletIds.has(walletId));

    const lotsByProgram = new Map();
    for (const document of lotDocuments) {
      const lot = {id: document.id, ...document.data()};
      const programId = String(lot.programId || "");
      const values = lotsByProgram.get(programId) || [];
      values.push(lot);
      lotsByProgram.set(programId, values);
    }
    const programUsageById = new Map(programUsageSnapshot.docs
      .slice(0, 500)
      .map((document) => [document.id, document.data()]));
    const programUsageMismatches = [];
    if (!lotScanTruncated && !programUsageScanTruncated) {
      const programIds = new Set([
        ...lotsByProgram.keys(),
        ...programUsageById.keys(),
      ]);
      for (const programId of programIds) {
        const expected = summarizeLots(lotsByProgram.get(programId) || []);
        const actual = proinProgramUsageState(
          programUsageById.get(programId),
        );
        const expectedUsage = {
          grantCount: (lotsByProgram.get(programId) || []).length,
          grantedProin: expected.originalProin,
          availableProin: expected.availableProin,
          reservedProin: expected.reservedProin,
          redeemedProin: expected.redeemedProin,
          expiredProin: expected.expiredProin,
          revokedProin: expected.revokedProin,
        };
        if (!sameProgramUsage(actual, expectedUsage) ||
            expected.invalidLotCount > 0) {
          programUsageMismatches.push({programId, actual, expected: expectedUsage});
        }
      }
    }

    const couponUsageByHash = new Map(couponUsageSnapshot.docs
      .slice(0, RECONCILIATION_COUPON_LIMIT)
      .map((document) => [document.id, document.data()]));
    const couponClaimTotals = new Map();
    const invalidCouponClaims = [];
    for (const document of couponClaimsSnapshot.docs
      .slice(0, RECONCILIATION_COUPON_CLAIM_LIMIT)) {
      const claim = document.data() || {};
      const couponHash = String(claim.couponHash || "");
      const status = String(claim.status || "");
      if (!couponHash || !["pending", "awarded", "failed"].includes(status)) {
        invalidCouponClaims.push({claimId: document.id, couponHash, status});
        continue;
      }
      const totals = couponClaimTotals.get(couponHash) || {
        reservedClaims: 0,
        claimedCount: 0,
      };
      if (status === "pending") totals.reservedClaims += 1;
      if (status === "awarded") totals.claimedCount += 1;
      couponClaimTotals.set(couponHash, totals);
    }
    const couponUsageMismatches = [];
    if (!couponUsageScanTruncated && !couponClaimScanTruncated) {
      const couponHashes = new Set([
        ...couponUsageByHash.keys(),
        ...couponClaimTotals.keys(),
      ]);
      for (const couponHash of couponHashes) {
        const actual = proinCouponUsageState(couponUsageByHash.get(couponHash));
        const expected = couponClaimTotals.get(couponHash) || {
          reservedClaims: 0,
          claimedCount: 0,
        };
        if (actual.reservedClaims !== expected.reservedClaims ||
            actual.claimedCount !== expected.claimedCount) {
          couponUsageMismatches.push({couponHash, actual, expected});
        }
      }
    }

    const finance = proinFinanceState(financeSnapshot.data());
    const invalidReservations = [];
    let reservedFromReservations = 0;
    for (const document of reservationsSnapshot.docs
      .slice(0, RECONCILIATION_RESERVATION_LIMIT)) {
      const reservation = document.data() || {};
      const status = String(reservation.status || "");
      const amountProin = storedProin(reservation.amountProin);
      const allocationTotal = (Array.isArray(reservation.allocations) ?
        reservation.allocations : []).reduce(
        (total, allocation) => total + storedProin(allocation?.amountProin),
        0,
      );
      const restoredProin = storedProin(reservation.restoredProin);
      const expiredProin = storedProin(reservation.expiredProin);
      const validStatus = ["reserved", "released", "redeemed"].includes(status);
      const validResolution = status !== "released" ||
        restoredProin + expiredProin === amountProin;
      if (amountProin <= 0 || allocationTotal !== amountProin ||
          !validStatus || !validResolution) {
        invalidReservations.push({
          reservationId: document.id,
          status,
          amountProin,
          allocationTotal,
          restoredProin,
          expiredProin,
        });
      }
      if (status === "reserved") reservedFromReservations += amountProin;
    }
    let payableFromReimbursements = 0;
    let settledFromReimbursements = 0;
    const invalidReimbursements = [];
    const reimbursementDocuments = reimbursementsSnapshot.docs
      .slice(0, RECONCILIATION_REIMBURSEMENT_LIMIT);
    const reimbursementsById = new Map(reimbursementDocuments.map(
      (document) => [document.id, document.data() || {}],
    ));
    for (const document of reimbursementDocuments) {
      const reimbursement = document.data() || {};
      const status = String(reimbursement.status || "");
      const amountInr = storedProin(reimbursement.amountInr);
      const paymentReferenceHash = String(
        reimbursement.paymentReferenceHash || "",
      );
      if (amountInr <= 0 || !["payable", "settled"].includes(status) ||
          storedProin(reimbursement.redeemedProin) !== amountInr ||
          (status === "settled" && !paymentReferenceHash)) {
        invalidReimbursements.push({
          reimbursementId: document.id,
          status,
          amountInr,
        });
      }
      if (status === "payable") payableFromReimbursements += amountInr;
      if (status === "settled") settledFromReimbursements += amountInr;
    }
    const invalidSettlementReferences = [];
    const settlementReferencesByHash = new Map(
      settlementReferencesSnapshot.docs
        .slice(0, RECONCILIATION_SETTLEMENT_REFERENCE_LIMIT)
        .map((document) => [document.id, document.data() || {}]),
    );
    if (!reimbursementScanTruncated && !settlementReferenceScanTruncated) {
      for (const [bookingId, reimbursement] of reimbursementsById) {
        if (reimbursement.status !== "settled") continue;
        const referenceHash = String(reimbursement.paymentReferenceHash || "");
        const reference = settlementReferencesByHash.get(referenceHash);
        if (!reference || reference.bookingId !== bookingId ||
            reference.salonId !== reimbursement.salonId ||
            storedProin(reference.amountInr) !==
              storedProin(reimbursement.amountInr)) {
          invalidSettlementReferences.push({bookingId, referenceHash});
        }
      }
      for (const [referenceHash, reference] of settlementReferencesByHash) {
        const bookingId = String(reference.bookingId || "");
        const reimbursement = reimbursementsById.get(bookingId);
        if (!reimbursement || reimbursement.status !== "settled" ||
            reimbursement.paymentReferenceHash !== referenceHash ||
            reimbursement.salonId !== reference.salonId ||
            storedProin(reimbursement.amountInr) !==
              storedProin(reference.amountInr)) {
          invalidSettlementReferences.push({bookingId, referenceHash});
        }
      }
    }
    const reservationTotalsMatchFinance = !reservationScanTruncated &&
      reservedFromReservations === finance.reservedLiabilityInr;
    const reimbursementTotalsMatchFinance = !reimbursementScanTruncated &&
      payableFromReimbursements === finance.redeemedPayableInr &&
      settledFromReimbursements === finance.settledExpenseInr;
    const lotTotals = summarizeLots(lotDocuments.map((document) => ({
      id: document.id,
      ...document.data(),
    })));
    const financeMatchesLots = !lotScanTruncated &&
      lotTotals.invalidLotCount === 0 &&
      finance.outstandingLiabilityInr ===
        lotTotals.availableProin + lotTotals.reservedProin &&
      finance.reservedLiabilityInr === lotTotals.reservedProin &&
      finance.redeemedPayableInr + finance.settledExpenseInr ===
        lotTotals.redeemedProin &&
      finance.lifetimeGrantedProin === lotTotals.originalProin &&
      finance.lifetimeExpiredProin === lotTotals.expiredProin &&
      finance.lifetimeRevokedProin === lotTotals.revokedProin;
    const financeBalanced = proinFinanceInvariant(finance);
    const status = !walletScanTruncated && !lotScanTruncated &&
      !programUsageScanTruncated && !couponUsageScanTruncated &&
      !couponClaimScanTruncated && !reservationScanTruncated &&
      !reimbursementScanTruncated && !settlementReferenceScanTruncated &&
      !salonPromotionUsageScanTruncated &&
      missingWalletIds.length === 0 &&
      walletMismatches.length === 0 && programUsageMismatches.length === 0 &&
      couponUsageMismatches.length === 0 && invalidCouponClaims.length === 0 &&
      invalidReservations.length === 0 && invalidReimbursements.length === 0 &&
      invalidSettlementReferences.length === 0 &&
      reservationTotalsMatchFinance && reimbursementTotalsMatchFinance &&
      financeBalanced && financeMatchesLots ?
      "balanced" : "review_required";
    const reportRef = db.collection("proinReconciliationReports").doc();
    const report = {
      reportId: reportRef.id,
      status,
      walletCount: walletDocuments.length,
      lotCount: lotDocuments.length,
      walletScanTruncated,
      lotScanTruncated,
      programUsageScanTruncated,
      couponUsageScanTruncated,
      couponClaimScanTruncated,
      reservationScanTruncated,
      reimbursementScanTruncated,
      settlementReferenceScanTruncated,
      salonPromotionUsageScanTruncated,
      walletMismatchCount: walletMismatches.length,
      walletMismatches: walletMismatches.slice(0, 100),
      missingWalletCount: missingWalletIds.length,
      missingWalletIds: missingWalletIds.slice(0, 100),
      programUsageMismatchCount: programUsageMismatches.length,
      programUsageMismatches: programUsageMismatches.slice(0, 100),
      couponUsageMismatchCount: couponUsageMismatches.length,
      couponUsageMismatches: couponUsageMismatches.slice(0, 100),
      invalidCouponClaimCount: invalidCouponClaims.length,
      invalidCouponClaims: invalidCouponClaims.slice(0, 100),
      invalidReservationCount: invalidReservations.length,
      invalidReservations: invalidReservations.slice(0, 100),
      invalidReimbursementCount: invalidReimbursements.length,
      invalidReimbursements: invalidReimbursements.slice(0, 100),
      invalidSettlementReferenceCount: invalidSettlementReferences.length,
      invalidSettlementReferences: invalidSettlementReferences.slice(0, 100),
      reservedFromReservations,
      payableFromReimbursements,
      settledFromReimbursements,
      reservationTotalsMatchFinance,
      reimbursementTotalsMatchFinance,
      financeBalanced,
      financeMatchesLots,
      finance: proinFinanceView(finance),
      lotTotals,
      createdAt: fieldValue.serverTimestamp(),
      createdAtMillis: nowMillis,
    };
    await reportRef.create(report);
    await updateReconciliationAlert({
      status,
      reportId: reportRef.id,
      walletMismatchCount: walletMismatches.length,
      missingWalletCount: missingWalletIds.length,
      programUsageMismatchCount: programUsageMismatches.length,
      couponUsageMismatchCount: couponUsageMismatches.length,
      invalidCouponClaimCount: invalidCouponClaims.length,
      invalidReservationCount: invalidReservations.length,
      invalidReimbursementCount: invalidReimbursements.length,
      invalidSettlementReferenceCount: invalidSettlementReferences.length,
      walletScanTruncated,
      lotScanTruncated,
      programUsageScanTruncated,
      couponUsageScanTruncated,
      couponClaimScanTruncated,
      reservationScanTruncated,
      reimbursementScanTruncated,
      settlementReferenceScanTruncated,
      salonPromotionUsageScanTruncated,
    });
    return {
      reportId: reportRef.id,
      status,
      walletCount: walletDocuments.length,
      lotCount: lotDocuments.length,
      walletMismatchCount: walletMismatches.length,
      missingWalletCount: missingWalletIds.length,
      programUsageMismatchCount: programUsageMismatches.length,
      couponUsageMismatchCount: couponUsageMismatches.length,
      invalidCouponClaimCount: invalidCouponClaims.length,
      invalidReservationCount: invalidReservations.length,
      invalidReimbursementCount: invalidReimbursements.length,
      invalidSettlementReferenceCount: invalidSettlementReferences.length,
      reservationTotalsMatchFinance,
      reimbursementTotalsMatchFinance,
      financeBalanced,
      financeMatchesLots,
      walletScanTruncated,
      lotScanTruncated,
      programUsageScanTruncated,
      couponUsageScanTruncated,
      couponClaimScanTruncated,
      reservationScanTruncated,
      reimbursementScanTruncated,
      settlementReferenceScanTruncated,
      salonPromotionUsageScanTruncated,
      createdAtMillis: nowMillis,
    };
  }

  async function phaseOneSnapshot() {
    const db = firestore();
    const [
      programs,
      usage,
      wallets,
      lots,
      finance,
      reports,
      coupons,
      couponUsage,
      reimbursements,
      referralCodes,
      referrals,
      referralStats,
    ] = await Promise.all([
      db.collection("proinPrograms").limit(200).get(),
      db.collection("proinProgramUsage").limit(200).get(),
      db.collection("proinWallets").limit(500).get(),
      db.collection("proinLots").limit(5000).get(),
      db.collection("proinFinance").doc("current").get(),
      db.collection("proinReconciliationReports")
        .orderBy("createdAt", "desc").limit(20).get(),
      db.collection("proinCoupons").limit(500).get(),
      db.collection("proinCouponUsage").limit(500).get(),
      db.collection("proinSalonReimbursements").limit(1000).get(),
      db.collection("referralCodes").limit(1000).get(),
      db.collection("referrals").limit(1000).get(),
      db.collection("referralStats").limit(1000).get(),
    ]);
    return {
      generatedAtMillis: Date.now(),
      programs: programs.docs.map((document) =>
        proinProgramView(document.id, document.data())),
      programUsage: usage.docs.map((document) => ({
        programId: document.id,
        ...proinProgramUsageState(document.data()),
      })),
      wallets: wallets.docs.map((document) => ({
        walletId: document.id,
        walletType: String(document.data()?.walletType || ""),
        accountId: String(document.data()?.accountId || ""),
        ...proinWalletView(proinWalletState(document.data())),
      })),
      lots: lots.docs.map((document) => ({
        lotId: document.id,
        walletId: String(document.data()?.walletId || ""),
        walletType: String(document.data()?.walletType || ""),
        accountId: String(document.data()?.accountId || ""),
        programId: String(document.data()?.programId || ""),
        sourceType: String(document.data()?.sourceType || ""),
        status: String(document.data()?.status || ""),
        originalProin: storedProin(document.data()?.originalProin),
        availableProin: storedProin(document.data()?.availableProin),
        reservedProin: storedProin(document.data()?.reservedProin),
        redeemedProin: storedProin(document.data()?.redeemedProin),
        expiredProin: storedProin(document.data()?.expiredProin),
        revokedProin: storedProin(document.data()?.revokedProin),
        earnedAtMillis: timestampMillis(document.data()?.earnedAt),
        expiresAtMillis: timestampMillis(document.data()?.expiresAt),
      })),
      finance: proinFinanceView(proinFinanceState(finance.data())),
      coupons: coupons.docs.map((document) => ({
        codeHash: document.id,
        ...proinCouponView(document.data()),
      })),
      couponUsage: couponUsage.docs.map((document) => ({
        codeHash: document.id,
        ...proinCouponUsageState(document.data()),
      })),
      referralCodes: referralCodes.docs.map((document) =>
        referralCodeView(document.id, document.data())),
      referrals: referrals.docs.map((document) =>
        referralRecordView(document.id, document.data())),
      referralStats: referralStats.docs.map((document) =>
        referralStatsView(document.id, document.data())),
      reimbursements: reimbursements.docs.map((document) => ({
        bookingId: document.id,
        salonId: String(document.data()?.salonId || ""),
        amountInr: storedProin(document.data()?.amountInr),
        status: String(document.data()?.status || ""),
        paymentReference: String(document.data()?.paymentReference || ""),
        paidAtMillis: timestampMillis(document.data()?.paidAt),
        createdAtMillis: timestampMillis(document.data()?.createdAt),
      })),
      reconciliationReports: reports.docs.map((document) => ({
        reportId: document.id,
        status: String(document.data()?.status || ""),
        walletMismatchCount:
          storedProin(document.data()?.walletMismatchCount),
        financeBalanced: document.data()?.financeBalanced === true,
        financeMatchesLots: document.data()?.financeMatchesLots === true,
        createdAtMillis: timestampMillis(document.data()?.createdAt) ||
          Number(document.data()?.createdAtMillis) || 0,
      })),
    };
  }

  async function updateReconciliationAlert({
    status,
    reportId,
    walletMismatchCount,
    missingWalletCount = 0,
    programUsageMismatchCount = 0,
    couponUsageMismatchCount = 0,
    invalidCouponClaimCount = 0,
    invalidReservationCount = 0,
    invalidReimbursementCount = 0,
    invalidSettlementReferenceCount = 0,
    walletScanTruncated,
    lotScanTruncated,
    programUsageScanTruncated = false,
    couponUsageScanTruncated = false,
    couponClaimScanTruncated = false,
    reservationScanTruncated = false,
    reimbursementScanTruncated = false,
    settlementReferenceScanTruncated = false,
    salonPromotionUsageScanTruncated = false,
  }) {
    const db = firestore();
    const alertId = sha256("proin_reconciliation:platform:proin");
    const alertRef = db.collection("adminOperationalAlerts").doc(alertId);
    if (status === "balanced") {
      const snapshot = await alertRef.get();
      if (snapshot.exists && snapshot.data()?.status !== "resolved") {
        await alertRef.set({
          status: "resolved",
          resolvedAt: fieldValue.serverTimestamp(),
          updatedAt: fieldValue.serverTimestamp(),
        }, {merge: true});
      }
      return;
    }
    await alertRef.set({
      key: "proin_reconciliation:platform:proin",
      type: "proin_reconciliation",
      severity: "critical",
      status: "active",
      targetType: "platform",
      targetId: "proin",
      title: "Proin financial reconciliation needs review",
      detail: walletScanTruncated || lotScanTruncated ||
          programUsageScanTruncated || couponUsageScanTruncated ||
          couponClaimScanTruncated || reservationScanTruncated ||
          reimbursementScanTruncated || settlementReferenceScanTruncated ||
          salonPromotionUsageScanTruncated ?
        "The Proin reconciliation scan exceeded its safe review limit." :
        `${walletMismatchCount} wallet, ${missingWalletCount} missing-wallet, ` +
          `${programUsageMismatchCount} program-usage, ` +
          `${couponUsageMismatchCount} coupon-usage, ` +
          `${invalidCouponClaimCount} invalid coupon-claim, ` +
          `${invalidReservationCount} invalid reservation, ` +
          `${invalidReimbursementCount} invalid reimbursement, and ` +
          `${invalidSettlementReferenceCount} invalid settlement-reference ` +
          "issues were found.",
      recommendedAction:
        `Review Proin reconciliation report ${reportId} before issuing rewards.`,
      lastDetectedAt: fieldValue.serverTimestamp(),
      occurrenceCount: fieldValue.increment(1),
      updatedAt: fieldValue.serverTimestamp(),
    }, {merge: true});
  }

  async function recordOperationalFailure({type, title, detail}) {
    const db = firestore();
    const alertRef = db.collection("adminOperationalAlerts")
      .doc(sha256(`${type}:platform:proin`));
    await alertRef.set({
      key: `${type}:platform:proin`,
      type,
      severity: "critical",
      status: "active",
      targetType: "platform",
      targetId: "proin",
      title,
      detail,
      recommendedAction: "Review the Proin ledger before issuing rewards.",
      lastDetectedAt: fieldValue.serverTimestamp(),
      occurrenceCount: fieldValue.increment(1),
      updatedAt: fieldValue.serverTimestamp(),
    }, {merge: true});
  }

  return {
    claimCoupon,
    customerStatementData,
    customerWalletData,
    salonWalletData,
    expireLots,
    grantAsAdmin,
    grantQualifiedEvent,
    phaseOneSnapshot,
    quoteBookingRedemption,
    reconcile,
    refreshWalletExpiry,
    revokeAvailableLotAsAdmin,
    reserveBookingRedemptionInTransaction,
    resolveBookingRedemptionInTransaction,
    settleSalonReimbursementAsAdmin,
    setFinanceBudget,
    upsertCoupon,
    upsertProgram,
  };
}

async function loadRedemptionPrograms({db, lots, transaction = null}) {
  const programIds = [...new Set((lots || [])
    .filter((lot) => !lot.redemptionPolicy)
    .map((lot) => String(lot.programId || "").trim())
    .filter(Boolean))];
  const snapshots = await Promise.all(programIds.map((programId) => {
    const ref = db.collection("proinPrograms").doc(programId);
    return transaction ? transaction.get(ref) : ref.get();
  }));
  return Object.fromEntries(snapshots
    .filter((snapshot) => snapshot.exists)
    .map((snapshot) => [snapshot.id, snapshot.data()]));
}

async function loadReservationUsageContexts({
  db,
  transaction,
  allocations,
  walletId,
}) {
  const programIds = [...new Set((allocations || [])
    .map((allocation) => String(allocation.programId || "").trim())
    .filter(Boolean))];
  const contexts = [];
  for (const programId of programIds) {
    const programUsageRef = db.collection("proinProgramUsage").doc(programId);
    const accountUsageRef = db.collection("proinProgramAccountUsage")
      .doc(`${programId}__${walletId}`);
    const [programUsageSnapshot, accountUsageSnapshot] = await Promise.all([
      transaction.get(programUsageRef),
      transaction.get(accountUsageRef),
    ]);
    contexts.push({
      programId,
      programUsageRef,
      accountUsageRef,
      programUsage: proinProgramUsageState(programUsageSnapshot.data()),
      accountUsage: proinProgramUsageState(accountUsageSnapshot.data()),
    });
  }
  return contexts;
}

function applyReservationUsageUpdates({
  transaction,
  contexts,
  allocations,
  outcome,
  expiredProinByLot = new Map(),
  timestamp,
}) {
  const totalsByProgram = new Map();
  for (const allocation of allocations || []) {
    const current = totalsByProgram.get(allocation.programId) || {
      amountProin: 0,
      expiredProin: 0,
    };
    current.amountProin += storedProin(allocation.amountProin);
    current.expiredProin += storedProin(
      expiredProinByLot.get(allocation.lotId),
    );
    totalsByProgram.set(allocation.programId, current);
  }
  for (const context of contexts || []) {
    const totals = totalsByProgram.get(context.programId) || {
      amountProin: 0,
      expiredProin: 0,
    };
    const apply = (usage) => {
      if (outcome === "reserve") {
        if (usage.availableProin < totals.amountProin) {
          throw new Error(
            "Proin program totals do not cover this reservation.",
          );
        }
        return {
          ...usage,
          availableProin: usage.availableProin - totals.amountProin,
          reservedProin: usage.reservedProin + totals.amountProin,
          updatedAt: timestamp,
        };
      }
      if (usage.reservedProin < totals.amountProin) {
        throw new Error(
          "Proin program totals do not cover this resolution.",
        );
      }
      if (outcome === "redeemed") {
        return {
          ...usage,
          reservedProin: usage.reservedProin - totals.amountProin,
          redeemedProin: usage.redeemedProin + totals.amountProin,
          updatedAt: timestamp,
        };
      }
      const expiredReservedProin = Math.min(
        totals.amountProin,
        totals.expiredProin,
      );
      const expiredAvailableProin = Math.max(
        0,
        totals.expiredProin - expiredReservedProin,
      );
      const restoredProin = totals.amountProin - expiredReservedProin;
      if (usage.availableProin + restoredProin < expiredAvailableProin) {
        throw new Error(
          "Proin program totals do not cover this expiry resolution.",
        );
      }
      return {
        ...usage,
        availableProin:
          usage.availableProin + restoredProin - expiredAvailableProin,
        reservedProin: usage.reservedProin - totals.amountProin,
        expiredProin: usage.expiredProin + totals.expiredProin,
        updatedAt: timestamp,
      };
    };
    transaction.set(context.programUsageRef, apply(context.programUsage), {
      merge: true,
    });
    transaction.set(context.accountUsageRef, apply(context.accountUsage), {
      merge: true,
    });
  }
}

function emptyBookingProinFields(payableBeforeProin) {
  return {
    proinStatus: "none",
    proinRequestedAmount: 0,
    proinReservedAmount: 0,
    proinRedeemedAmount: 0,
    proinReleasedAmount: 0,
    proinExpiredOnReleaseAmount: 0,
    proinReimbursementStatus: "none",
    customerPayableBeforeProin: payableBeforeProin,
    customerPayableAmount: payableBeforeProin,
  };
}

function resolvedLotStatus({
  availableProin,
  reservedProin,
  redeemedProin,
  expiredProin,
  expiresAtMillis,
  nowMillis,
}) {
  if (availableProin > 0 && expiresAtMillis > nowMillis) return "active";
  if (reservedProin > 0 && expiresAtMillis <= nowMillis) {
    return "reserved_after_expiry";
  }
  if (reservedProin > 0) return "reserved";
  if (availableProin > 0) return "active";
  if (redeemedProin > 0) return "redeemed";
  if (expiredProin > 0) return "expired";
  return "closed";
}

function proinProgramRecord({
  normalized,
  version,
  adminUid,
  previous,
  Timestamp,
  fieldValue,
}) {
  const {startsAtMillis, endsAtMillis, ...fields} = normalized;
  return {
    ...fields,
    version,
    proinToInrRate: 1,
    regulatoryMode: "promotional_reward_only",
    customerFunded: false,
    cashWithdrawable: false,
    transferable: false,
    purchasable: false,
    startsAt: Timestamp.fromMillis(startsAtMillis),
    endsAt: Timestamp.fromMillis(endsAtMillis),
    createdAt: previous?.createdAt || fieldValue.serverTimestamp(),
    createdByAdminUid: previous?.createdByAdminUid || adminUid,
    updatedAt: fieldValue.serverTimestamp(),
    updatedByAdminUid: adminUid,
  };
}

function proinProgramView(programId, program = {}) {
  return {
    programId,
    name: String(program.name || ""),
    sourceType: String(program.sourceType || ""),
    walletType: String(program.walletType || ""),
    qualificationEvent: String(program.qualificationEvent || ""),
    rewardRecipient: String(program.rewardRecipient || "account"),
    referralTargetRole: String(program.referralTargetRole || ""),
    referralInviterRole: String(program.referralInviterRole || ""),
    active: program.active === true,
    rewardAmountProin: storedProin(program.rewardAmountProin),
    rewardValidityDays: storedProin(program.rewardValidityDays),
    totalBudgetProin: storedProin(program.totalBudgetProin),
    maximumTotalGrants: storedProin(program.maximumTotalGrants),
    maximumGrantsPerAccount: storedProin(program.maximumGrantsPerAccount),
    minimumBookingAmount: storedProin(program.minimumBookingAmount),
    maximumProinPerBooking: storedProin(program.maximumProinPerBooking),
    maximumRedemptionPercent:
      storedProin(program.maximumRedemptionPercent),
    stackableWithDiscount: program.stackableWithDiscount === true,
    eligibleSalonIds: storedStringList(program.eligibleSalonIds),
    eligibleServiceIds: storedStringList(program.eligibleServiceIds),
    termsVersion: String(program.termsVersion || ""),
    startsAtMillis: timestampMillis(program.startsAt),
    endsAtMillis: timestampMillis(program.endsAt),
    version: storedProin(program.version),
    regulatoryMode: String(program.regulatoryMode || ""),
  };
}

function referralCodeView(code, data = {}) {
  return {
    code: String(data.code || code || "").trim().toUpperCase(),
    ownerUid: String(data.ownerUid || "").trim(),
    inviterRole: String(data.inviterRole || "").trim(),
    targetRole: String(data.targetRole || "").trim(),
    active: data.active === true,
    replacedByCode: String(data.replacedByCode || "").trim().toUpperCase(),
    replacedFromCode: String(data.replacedFromCode || "").trim().toUpperCase(),
    createdAtMillis: timestampMillis(data.createdAt),
    updatedAtMillis: timestampMillis(data.updatedAt),
  };
}

function referralRecordView(referralId, data = {}) {
  return {
    referralId,
    referredUid: String(data.referredUid || referralId || "").trim(),
    referredRole: String(data.referredRole || "").trim(),
    referralCode: String(data.referralCode || "").trim().toUpperCase(),
    inviterUid: String(data.inviterUid || "").trim(),
    inviterRole: String(data.inviterRole || "").trim(),
    status: String(data.status || "").trim(),
    qualificationType: String(data.qualificationType || "").trim(),
    qualificationBookingId:
      String(data.qualificationBookingId || "").trim(),
    qualificationSalonId: String(data.qualificationSalonId || "").trim(),
    proinAwardStatus: String(data.proinAwardStatus || "").trim(),
    proinAwardPending: data.proinAwardPending === true,
    createdAtMillis: timestampMillis(data.createdAt),
    qualifiedAtMillis: timestampMillis(data.qualifiedAt),
  };
}

function referralStatsView(userId, data = {}) {
  return {
    userId,
    pendingCustomerCount: storedProin(data.pendingCustomerCount),
    qualifiedCustomerCount: storedProin(data.qualifiedCustomerCount),
    pendingSalonCount: storedProin(data.pendingSalonCount),
    qualifiedSalonCount: storedProin(data.qualifiedSalonCount),
    updatedAtMillis: timestampMillis(data.updatedAt),
  };
}

function proinWalletState(data = {}) {
  const walletType = String(data?.walletType || "");
  const isSalonPromotionWallet = walletType === "salon_promotion_credits";
  const creditLimitProin = isSalonPromotionWallet ?
    (Object.prototype.hasOwnProperty.call(data || {}, "creditLimitProin") ?
      storedProin(data?.creditLimitProin) :
      DEFAULT_SALON_PROMOTION_CREDIT_LIMIT) : 0;
  return {
    walletType,
    accountId: String(data?.accountId || ""),
    availableProin: isSalonPromotionWallet ?
      storedSignedProin(data?.availableProin) : storedProin(data?.availableProin),
    reservedProin: storedProin(data?.reservedProin),
    lifetimeGrantedProin: storedProin(data?.lifetimeGrantedProin),
    lifetimeRedeemedProin: storedProin(data?.lifetimeRedeemedProin),
    lifetimeExpiredProin: storedProin(data?.lifetimeExpiredProin),
    lifetimeRevokedProin: storedProin(data?.lifetimeRevokedProin),
    creditLimitProin,
    nextExpiryAtMillis: timestampMillis(data?.nextExpiryAt) ||
      storedProin(data?.nextExpiryAtMillis),
  };
}

function proinWalletView(wallet = {}) {
  const isSalonPromotionWallet =
    String(wallet.walletType || "") === "salon_promotion_credits";
  const availableProin = isSalonPromotionWallet ?
    storedSignedProin(wallet.availableProin) : storedProin(wallet.availableProin);
  const creditLimitProin = isSalonPromotionWallet ?
    (Object.prototype.hasOwnProperty.call(wallet || {}, "creditLimitProin") ?
      storedProin(wallet.creditLimitProin) :
      DEFAULT_SALON_PROMOTION_CREDIT_LIMIT) : 0;
  return {
    availableProin,
    reservedProin: storedProin(wallet.reservedProin),
    lifetimeGrantedProin: storedProin(wallet.lifetimeGrantedProin),
    lifetimeRedeemedProin: storedProin(wallet.lifetimeRedeemedProin),
    lifetimeExpiredProin: storedProin(wallet.lifetimeExpiredProin),
    lifetimeRevokedProin: storedProin(wallet.lifetimeRevokedProin),
    creditLimitProin,
    spendableProin: isSalonPromotionWallet ?
      Math.max(0, availableProin + creditLimitProin) : availableProin,
    nextExpiryAtMillis: storedProin(wallet.nextExpiryAtMillis),
  };
}

function proinFinanceState(data = {}) {
  return {
    approvedBudgetInr: storedProin(data?.approvedBudgetInr),
    unallocatedBudgetInr: storedProin(data?.unallocatedBudgetInr),
    outstandingLiabilityInr: storedProin(data?.outstandingLiabilityInr),
    reservedLiabilityInr: storedProin(data?.reservedLiabilityInr),
    redeemedPayableInr: storedProin(data?.redeemedPayableInr),
    settledExpenseInr: storedProin(data?.settledExpenseInr),
    lifetimeGrantedProin: storedProin(data?.lifetimeGrantedProin),
    lifetimeRedeemedProin: storedProin(data?.lifetimeRedeemedProin),
    lifetimeExpiredProin: storedProin(data?.lifetimeExpiredProin),
    lifetimeRevokedProin: storedProin(data?.lifetimeRevokedProin),
    budgetVersion: storedProin(data?.budgetVersion),
  };
}

function proinFinanceView(finance = {}) {
  return {...proinFinanceState(finance), proinToInrRate: 1};
}

function proinProgramUsageState(data = {}) {
  return {
    grantCount: storedProin(data?.grantCount),
    grantedProin: storedProin(data?.grantedProin),
    availableProin: storedProin(data?.availableProin),
    reservedProin: storedProin(data?.reservedProin),
    redeemedProin: storedProin(data?.redeemedProin),
    expiredProin: storedProin(data?.expiredProin),
    revokedProin: storedProin(data?.revokedProin),
  };
}

function proinCouponUsageState(data = {}) {
  return {
    reservedClaims: storedProin(data?.reservedClaims),
    claimedCount: storedProin(data?.claimedCount),
  };
}

function proinCouponView(coupon = {}) {
  return {
    maskedCode: String(coupon.maskedCode || ""),
    programId: String(coupon.programId || ""),
    active: coupon.active === true,
    claimStartsAtMillis: timestampMillis(coupon.claimStartsAt),
    claimEndsAtMillis: timestampMillis(coupon.claimEndsAt),
    maximumClaimsTotal: storedProin(coupon.maximumClaimsTotal),
    maximumClaimsPerAccount:
      storedProin(coupon.maximumClaimsPerAccount),
    eligibleCustomerUids: storedStringList(coupon.eligibleCustomerUids),
    eligibleSalonIds: storedStringList(coupon.eligibleSalonIds),
    termsVersion: String(coupon.termsVersion || ""),
    storesPlaintextCode: coupon.storesPlaintextCode === true,
    version: storedProin(coupon.version),
  };
}

function grantUsage(usage, amountProin) {
  return {
    ...usage,
    grantCount: usage.grantCount + 1,
    grantedProin: usage.grantedProin + amountProin,
    availableProin: usage.availableProin + amountProin,
  };
}

function expireUsage(usage, amountProin, timestamp) {
  return {
    ...usage,
    availableProin: usage.availableProin - amountProin,
    expiredProin: usage.expiredProin + amountProin,
    updatedAt: timestamp,
  };
}

function summarizeLots(lots) {
  const totals = {
    originalProin: 0,
    availableProin: 0,
    reservedProin: 0,
    redeemedProin: 0,
    expiredProin: 0,
    revokedProin: 0,
    invalidLotCount: 0,
  };
  for (const lot of lots) {
    const components = [
      "originalProin",
      "availableProin",
      "reservedProin",
      "redeemedProin",
      "expiredProin",
      "revokedProin",
    ];
    for (const field of components) {
      totals[field] += storedProin(lot[field]);
    }
    if (storedProin(lot.originalProin) !==
        storedProin(lot.availableProin) +
        storedProin(lot.reservedProin) +
        storedProin(lot.redeemedProin) +
        storedProin(lot.expiredProin) +
        storedProin(lot.revokedProin)) {
      totals.invalidLotCount += 1;
    }
  }
  return totals;
}

function sameWalletState(left, right) {
  return [
    "availableProin",
    "reservedProin",
    "lifetimeGrantedProin",
    "lifetimeRedeemedProin",
    "lifetimeExpiredProin",
    "lifetimeRevokedProin",
    "nextExpiryAtMillis",
  ].every((field) => {
    const reader = field === "availableProin" ?
      storedSignedProin : storedProin;
    return reader(left[field]) === reader(right[field]);
  });
}

function sameProgramUsage(left, right) {
  return [
    "grantCount",
    "grantedProin",
    "availableProin",
    "reservedProin",
    "redeemedProin",
    "expiredProin",
    "revokedProin",
  ].every((field) => storedProin(left[field]) === storedProin(right[field]));
}

function proinAuditRecord({
  adminUid,
  action,
  targetType,
  targetId,
  reason,
  before,
  after,
  fieldValue,
}) {
  return {
    adminUid,
    action,
    targetType,
    targetId,
    reason,
    before,
    after,
    createdAt: fieldValue.serverTimestamp(),
  };
}

function proinDocumentId(value, label) {
  const id = String(value ?? "").trim();
  if (!/^[A-Za-z0-9_-]{3,80}$/.test(id)) {
    throw new ProinValidationError(
      `${label} must use 3-80 letters, numbers, underscores or hyphens.`,
    );
  }
  return id;
}

function requiredText(value, label, maximumLength) {
  const text = String(value ?? "").trim();
  if (!text || text.length > maximumLength || text.includes("/")) {
    throw new ProinValidationError(`Enter a valid ${label}.`);
  }
  return text;
}

function proinWalletId(walletType, accountId) {
  return sha256(`${walletType}:${accountId}`);
}

function sha256(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex");
}

function timestampMillis(value) {
  if (value && typeof value.toMillis === "function") return value.toMillis();
  if (value instanceof Date) return value.getTime();
  const number = Number(value);
  return Number.isSafeInteger(number) && number > 0 ? number : 0;
}

function storedProin(value) {
  const number = Number(value);
  return Number.isSafeInteger(number) && number >= 0 ? number : 0;
}

function storedSignedProin(value) {
  const number = Number(value);
  return Number.isSafeInteger(number) ? number : 0;
}

function storedPositiveInteger(value, fallback) {
  const number = Number(value);
  return Number.isSafeInteger(number) && number > 0 ? number : fallback;
}

function storedStringList(value) {
  return Array.isArray(value) ? value.map((item) => String(item || "")) : [];
}

module.exports = {createProinBackend};
