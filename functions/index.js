const crypto = require("node:crypto");
const admin = require("firebase-admin");
// Required lazily at their only call sites. Loading these at module scope
// made every callable pay for them on cold start, including the ones that
// never send mail or talk to the Play Developer API.
const androidRelease = require("./android_release.json");
const {updateBookingExtraServices} = require("./booking_extra_services");
const {linkOwnerPhoneLogin} = require("./owner_phone_login");
const {
  highestPublishedVersionCode,
  resolveAndroidUpdateVersion,
} = require("./android_update_logic");
const {
  inferStoredRole,
  loginRoleConflictMessage,
  normalizeDisplayName,
  normalizeLoginProvider,
  normalizeRole,
  normalizeVerifiedPhone,
  phoneKey,
  resolveClaimName,
  sameRolePhoneConflictMessage,
} = require("./auth_login_logic");
const {
  ADMIN_PASSWORD_LOCKOUT_MS,
  adminCredentialId,
  createAdminPasswordHash,
  nextAdminPasswordFailure,
  normalizeAdminPassword,
  normalizeAdminUserId,
  verifyAdminPassword,
} = require("./admin_password_auth_logic");
const {
  bookingRecipientRoles,
  bookingStatusRecipients,
} = require("./booking_notification_logic");
const {canonicalizeSalonServices} = require("./service_catalog");
const {
  INSTANT_ARRIVAL_MINUTES,
  INSTANT_RESPONSE_TIMEOUT_MS,
  bookingArrivalReminderDue,
  bookingTransitionError,
  canRescheduleBooking,
  instantResponseDeadlineMillis,
  isBlockingBooking,
  isInstantEnabledForSalon,
  isWithinSalonHours,
  serviceAutoCompleteAtMillis,
  shouldAutoCompleteService,
  shouldAlertOwnerForBooking,
  slotSegmentMillis,
  zonedDateParts,
} = require("./booking_workflow_logic");
const {
  normalizeBirthDate,
  normalizeFeedbackNote,
  normalizeProfileGender,
  normalizeVisitRating,
  sanitizePhotoUrls,
  sanitizeShortList,
} = require("./customer_profile_logic");
const {
  generateReferralCode,
  normalizeReferralCode,
  referralRewardSummary,
  referralTargetAllowed,
} = require("./referral_logic");
const {
  calculateDiscountQuote,
  DEFAULT_SALON_DISCOUNT_BURN_MULTIPLIER,
  DEFAULT_SALON_PROMOTION_CREDIT_LIMIT,
  discountBaseAmount,
  discountBudgetAllows,
  discountCampaignEligible,
  discountCampaignForContext,
  discountCampaignSelectableAtCheckout,
  discountFundingSource,
  discountPayoutMultiplier,
  emptyDiscountQuote,
  money,
  signedMoney,
} = require("./discount_logic");
const {
  DiscountAdminValidationError,
  normalizeDiscountCampaignInput,
  normalizeSalonDiscountBurnMultiplier,
  normalizeSalonPromotionCreditLimit,
  normalizeDiscountVaultBudget,
} = require("./discount_admin_logic");
const {
  SalonFinanceValidationError,
  allocateSalonSettlementPayment,
  positiveMoney,
  salonCreditLimit,
  settlementPaymentReference,
} = require("./salon_finance_logic");
const {
  ProinValidationError,
} = require("./proin_logic");
const {
  normalizeProinCouponCode,
  proinCouponHash,
} = require("./proin_coupon_logic");
const {
  buildCompletedBookingUpiPaymentDetails,
} = require("./upi_payment_logic");
const {createProinBackend} = require("./proin_backend");
const {
  DEFAULT_ADMIN_AUTOMATION_RULES,
  evaluateOperationalAlerts,
  normalizedRules,
} = require("./admin_intelligence_logic");
const {
  coordinatesFromSalon,
  distanceMeters,
  estimatedArrivalMinutes,
  sharingExpiresAtMillis,
  validArrivalStatus,
  validCoordinates,
  validLocationUpdate,
} = require("./arrival_tracking_logic");
const {setGlobalOptions} = require("firebase-functions/v2");
const {HttpsError, onCall} = require("firebase-functions/v2/https");
const {
  onDocumentCreated,
  onDocumentUpdated,
} = require("firebase-functions/v2/firestore");
const {defineSecret} = require("firebase-functions/params");
const {onSchedule} = require("firebase-functions/v2/scheduler");

admin.initializeApp();

// Single region, matching the Firestore instance. Functions previously split
// across two regions, which left some defined in both and blocked deploys.
setGlobalOptions({region: "asia-south1"});

const proinBackend = createProinBackend({admin, HttpsError});

const smtpHost = defineSecret("SMTP_HOST");
const smtpPort = defineSecret("SMTP_PORT");
const smtpUser = defineSecret("SMTP_USER");
const smtpPass = defineSecret("SMTP_PASS");
const smtpFrom = defineSecret("SMTP_FROM");
const otpSecret = defineSecret("EMAIL_OTP_SECRET");

const OTP_TTL_MS = 10 * 60 * 1000;
const MAX_ATTEMPTS = 5;
const EMAIL_RESEND_DELAY_MS = 45_000;
// The Android channel carries the alert's sound settings and cannot be
// changed after creation, so each change of them is a new channel id and a
// new token list. A device registers exactly one of these, and the client
// ignores a push naming a channel it does not know.
const OWNER_BOOKING_REQUEST_CHANNEL = "pritze_owner_booking_requests_v4";
const OWNER_BOOKING_REQUEST_CHANNEL_V3 = "pritze_owner_booking_requests_v3";
const LEGACY_OWNER_BOOKING_REQUEST_CHANNEL =
  "pritze_owner_booking_requests_v2";
const OWNER_ALERT_TOKEN_FIELD = "ownerAlertV4Tokens";
const OWNER_ALERT_TOKEN_FIELD_V3 = "ownerAlertV3Tokens";
const OWNER_BOOKING_REQUEST_SOUND = "owner_booking_request";
const IOS_OWNER_BOOKING_REQUEST_CATEGORY = "PRITZE_BOOKING_REQUEST_V2";
const OWNER_ALERT_REPEAT_DELAY_MS = 15_000;
const OWNER_ALERT_ATTEMPTS = 10;
const DISCOUNT_QUOTE_TTL_MS = 10 * 60 * 1000;
const REFERRAL_ATTEMPT_WINDOW_MS = 60 * 60 * 1000;
const REFERRAL_ATTEMPT_LIMIT = 10;
const DISCOUNT_QUOTE_LIMIT = 60;
const PROIN_COUPON_ATTEMPT_LIMIT = 10;
const PROIN_QUOTE_ATTEMPT_LIMIT = 60;
const MOBILE_CALLABLE_REGIONS = ["asia-south1"];

function onMobileCall(options, handler) {
  return onCall({...options, region: MOBILE_CALLABLE_REGIONS}, handler);
}
// This stays at the last version known to be publicly downloadable. Release
// builds update android_release.json automatically, while Google Play remains
// the authority that decides when the candidate can be advertised to users.
const ANDROID_LAST_CONFIRMED_PUBLIC_VERSION_CODE = 31;
const ANDROID_PLAY_STORE_URL =
  "https://play.google.com/store/apps/details?id=com.trimtime.app";
const ANDROID_RELEASES_API_URL =
  "https://androidpublisher.googleapis.com/androidpublisher/v3/" +
  "applications/com.trimtime.app/tracks/production/releases";
const ANDROID_RELEASE_CACHE_MS = 5 * 60 * 1000;
let androidReleaseCache = {expiresAt: 0, versionCode: null};
// Keep this aligned with the newest build that is publicly downloadable.
// Do not advance it merely because a newer build was uploaded for review.
const IOS_CURRENT_BUILD_NUMBER = 28;
const IOS_NEXT_VERSION = "1.0.16";
const IOS_NEXT_BUILD_NUMBER = 29;
const IOS_APP_STORE_LOOKUP_URL =
  "https://itunes.apple.com/lookup?id=6792811282&country=in";
const IOS_APP_STORE_URL =
  "https://apps.apple.com/in/app/pritze/id6792811282";
const PLATFORM_ADMIN_EMAIL_HASHES = new Set([
  "7f3bb1d3b9445a8dafcfa10873b7ffc4221ecc4e3234acad83dddb7f021f2c20",
]);
const ADMIN_PASSWORD_ATTEMPT_LIMIT = 12;
const ADMIN_PASSWORD_ATTEMPT_WINDOW_MS = 15 * 60 * 1000;
const DUMMY_ADMIN_PASSWORD_HASH = createAdminPasswordHash(
  "InvalidPassword1",
  Buffer.alloc(16),
);

exports.getAndroidAppUpdate = onMobileCall(
  {invoker: "public", cpu: "gcf_gen1"},
  async () => {
  const snapshot = await admin.firestore()
    .collection("appConfig")
    .doc("android")
    .get();
  const configured = snapshot.data() || {};
  const configuredVersionCode = positiveInteger(
    configured.latestVersionCode || configured.latestBuildNumber,
    ANDROID_LAST_CONFIRMED_PUBLIC_VERSION_CODE,
  );
  const playPublishedVersionCode = await getPlayPublishedAndroidVersion();
  const latestVersionCode = resolveAndroidUpdateVersion({
    lastConfirmedPublicVersion:
      ANDROID_LAST_CONFIRMED_PUBLIC_VERSION_CODE,
    candidateVersion: androidRelease.candidateVersionCode,
    configuredVersion: configuredVersionCode,
    playPublishedVersion: playPublishedVersionCode,
  });
  const playStoreUrl = String(configured.playStoreUrl || "").trim() ||
    ANDROID_PLAY_STORE_URL;
  return {
    latestVersionCode,
    playStoreUrl,
    playStoreVerified: playPublishedVersionCode !== null,
  };
  },
);

async function getPlayPublishedAndroidVersion() {
  const now = Date.now();
  if (androidReleaseCache.expiresAt > now) {
    return androidReleaseCache.versionCode;
  }
  try {
    const {GoogleAuth} = require("google-auth-library");
    const auth = new GoogleAuth({
      scopes: ["https://www.googleapis.com/auth/androidpublisher"],
    });
    const client = await auth.getClient();
    const response = await client.request({
      url: ANDROID_RELEASES_API_URL,
      method: "GET",
      timeout: 8000,
    });
    const versionCode = highestPublishedVersionCode(response.data);
    androidReleaseCache = {
      expiresAt: now + ANDROID_RELEASE_CACHE_MS,
      versionCode,
    };
    return versionCode;
  } catch (error) {
    console.warn("Google Play release verification failed", {
      message: error?.message || String(error),
    });
    androidReleaseCache = {
      expiresAt: now + 60 * 1000,
      versionCode: null,
    };
    return null;
  }
}

exports.getIosAppUpdate = onMobileCall(
  {invoker: "public", cpu: "gcf_gen1"},
  async () => {
  const snapshot = await admin.firestore()
    .collection("appConfig")
    .doc("ios")
    .get();
  const configured = snapshot.data() || {};
  const configuredBuildNumber = positiveInteger(
    configured.latestBuildNumber || configured.latestVersionCode,
    IOS_CURRENT_BUILD_NUMBER,
  );
  let publicBuildNumber = IOS_CURRENT_BUILD_NUMBER;
  try {
    const response = await fetch(IOS_APP_STORE_LOOKUP_URL, {
      signal: AbortSignal.timeout(8000),
    });
    if (response.ok) {
      const payload = await response.json();
      const publicVersion = String(payload?.results?.[0]?.version || "");
      if (versionAtLeast(publicVersion, IOS_NEXT_VERSION)) {
        publicBuildNumber = IOS_NEXT_BUILD_NUMBER;
      }
    }
  } catch (error) {
    console.warn("App Store version lookup failed", {
      message: error?.message || String(error),
    });
  }
  const latestBuildNumber = publicBuildNumber >= IOS_NEXT_BUILD_NUMBER ?
    Math.max(configuredBuildNumber, publicBuildNumber) :
    Math.min(configuredBuildNumber, IOS_CURRENT_BUILD_NUMBER);
  const appStoreUrl = String(configured.appStoreUrl || "").trim() ||
    IOS_APP_STORE_URL;
  return {latestBuildNumber, appStoreUrl};
  },
);

exports.getCompletedBookingUpiPaymentDetails = onMobileCall(
  // Full vCPU: this opens the completion receipt, where the owner is waiting
  // on the dialog. "gcf_gen1" caps the container at a sixth of a core.
  {invoker: "public", enforceAppCheck: true, cpu: 1},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    const bookingId = requiredId(request.data?.bookingId, "booking id");
    const firestore = admin.firestore();
    const bookingRef = firestore.collection("bookings").doc(bookingId);
    const userRef = firestore.collection("users").doc(uid);
    const [bookingSnapshot, userSnapshot] = await Promise.all([
      bookingRef.get(),
      userRef.get(),
    ]);
    const booking = bookingSnapshot.data();
    requireStoredRole(userSnapshot.data(), "customer");
    if (!booking) {
      throw new HttpsError("not-found", "Booking not found.");
    }
    if (String(booking.customerUid || "").trim() !== uid) {
      throw new HttpsError(
        "permission-denied",
        "Only the customer who made this booking can view payment options.",
      );
    }
    if (booking.status !== "completed") {
      throw new HttpsError(
        "failed-precondition",
        "Payment options are available only after service completion.",
      );
    }
    const salonId = requiredId(booking.salonId, "salon id");
    const [salonSnapshot, paymentProfileSnapshot] = await Promise.all([
      firestore.collection("salons").doc(salonId).get(),
      firestore.collection("salonPaymentProfiles").doc(salonId).get(),
    ]);
    const salon = salonSnapshot.data() || {};
    const paymentProfile = paymentProfileSnapshot.data() || {};
    return buildCompletedBookingUpiPaymentDetails({
      bookingId,
      salonId,
      salonName: salon.name,
      amountInr: money(booking.customerPayableAmount),
      upiId: paymentProfile.upiId,
      qrCodeUrl: paymentProfile.qrCodeUrl,
    });
  },
);

exports.getAdminPhaseOneData = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    const firestore = admin.firestore();
    const platformAdmin = await firestore
      .collection("platformAdmins")
      .doc(uid)
      .get();
    const hasActiveAdminRecord = platformAdmin.exists &&
      platformAdmin.data()?.active !== false;
    const hasAdminClaim = request.auth?.token?.platformAdmin === true &&
      hasActiveAdminRecord;
    const tokenEmail = normalizeEmail(request.auth?.token?.email);
    const tokenEmailHash = tokenEmail ?
      crypto.createHash("sha256").update(tokenEmail).digest("hex") : "";
    const hasInvitedAdminEmail =
      request.auth?.token?.email_verified !== false &&
      PLATFORM_ADMIN_EMAIL_HASHES.has(tokenEmailHash) &&
      (!platformAdmin.exists || hasActiveAdminRecord);
    if (!hasAdminClaim && !hasActiveAdminRecord && !hasInvitedAdminEmail) {
      throw new HttpsError(
        "permission-denied",
        "This account is not a Pritze platform administrator.",
      );
    }
    if (hasInvitedAdminEmail && !platformAdmin.exists) {
      await platformAdmin.ref.set({
        active: true,
        email: tokenEmail,
        provisionedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    const [
      bookingsSnapshot,
      salonsSnapshot,
      salonPaymentProfilesSnapshot,
      barbersSnapshot,
      customersSnapshot,
      salonFeedbackSnapshot,
      customerRatingsSnapshot,
      joinRequestsSnapshot,
      settlementsSnapshot,
      settlementPaymentsSnapshot,
      walletsSnapshot,
      notesSnapshot,
      auditSnapshot,
      automationRulesSnapshot,
      operationalAlertsSnapshot,
      arrivalSessionsSnapshot,
    ] = await Promise.all([
      firestore.collection("bookings")
        .orderBy("start", "desc")
        .limit(1000)
        .get(),
      firestore.collection("salons").limit(500).get(),
      firestore.collection("salonPaymentProfiles").limit(500).get(),
      firestore.collection("barbers").limit(1000).get(),
      firestore.collection("users")
        .where("role", "==", "customer")
        .limit(1000)
        .get(),
      firestore.collection("salonFeedback")
        .orderBy("createdAt", "desc")
        .limit(500)
        .get(),
      firestore.collection("customerRatings")
        .orderBy("createdAt", "desc")
        .limit(500)
        .get(),
      firestore.collection("joinRequests")
        .orderBy("requestedAt", "desc")
        .limit(500)
        .get(),
      firestore.collection("salonSettlements").limit(1000).get(),
      firestore.collection("salonSettlementPayments")
        .orderBy("paidAt", "desc")
        .limit(1000)
        .get(),
      firestore.collection("salonWallets").limit(500).get(),
      firestore.collection("adminNotes")
        .orderBy("createdAt", "desc")
        .limit(500)
        .get(),
      firestore.collection("adminAuditLogs")
        .orderBy("createdAt", "desc")
        .limit(500)
        .get(),
      firestore.collection("adminAutomationRules").limit(50).get(),
      firestore.collection("adminOperationalAlerts").limit(500).get(),
      firestore.collection("bookingArrivalSessions").limit(500).get(),
    ]);

    const paymentProfilesBySalonId = new Map(
      salonPaymentProfilesSnapshot.docs.map((document) => [
        document.id,
        document.data() || {},
      ]),
    );
    return {
      generatedAtMillis: Date.now(),
      bookings: bookingsSnapshot.docs.map(adminBookingRecord),
      salons: salonsSnapshot.docs.map((document) =>
        adminSalonRecord(
          document,
          paymentProfilesBySalonId.get(document.id),
        )),
      barbers: barbersSnapshot.docs.map(adminBarberRecord),
      customers: customersSnapshot.docs.map(adminCustomerRecord),
      reviews: [
        ...salonFeedbackSnapshot.docs.map((document) =>
          adminReviewRecord(document, "salon")),
        ...customerRatingsSnapshot.docs.map((document) =>
          adminReviewRecord(document, "customer")),
      ],
      joinRequests: joinRequestsSnapshot.docs.map(adminJoinRequestRecord),
      settlements: settlementsSnapshot.docs.map(adminSettlementRecord),
      settlementPayments: settlementPaymentsSnapshot.docs
        .map(adminSalonSettlementPaymentRecord),
      wallets: walletsSnapshot.docs.map(adminWalletRecord),
      notes: notesSnapshot.docs.map(adminNoteRecord),
      auditLogs: auditSnapshot.docs.map(adminAuditLogRecord),
      automationRules: adminAutomationRuleRecords(automationRulesSnapshot),
      operationalAlerts: operationalAlertsSnapshot.docs
        .map(adminOperationalAlertRecord)
        .sort((left, right) => right.detectedAtMillis - left.detectedAtMillis),
      arrivalSessions: arrivalSessionsSnapshot.docs
        .map(adminArrivalSessionRecord)
        .filter((session) => session.bookingId && session.sharingActive)
        .sort((left, right) =>
          right.lastLocationAtMillis - left.lastLocationAtMillis),
    };
  },
);

exports.setSalonPromotionCreditLimitAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const salonId = requiredId(request.data?.salonId, "salon id");
    const reason = requiredAdminReason(request.data?.reason);
    let creditLimitProin;
    try {
      creditLimitProin = salonCreditLimit(request.data?.creditLimitProin);
    } catch (error) {
      if (error instanceof SalonFinanceValidationError) {
        throw new HttpsError("invalid-argument", error.message);
      }
      throw error;
    }
    const firestore = admin.firestore();
    const salonRef = firestore.collection("salons").doc(salonId);
    const walletRef = firestore.collection("proinWallets")
      .doc(discountSalonPromotionWalletId(salonId));
    const auditRef = firestore.collection("adminAuditLogs").doc();
    let result = null;
    await firestore.runTransaction(async (transaction) => {
      const [salonSnapshot, walletSnapshot] = await Promise.all([
        transaction.get(salonRef),
        transaction.get(walletRef),
      ]);
      if (!salonSnapshot.exists) {
        throw new HttpsError("not-found", "Salon not found.");
      }
      const wallet = walletSnapshot.data() || {};
      const availableProin = signedMoney(wallet.availableProin);
      if (availableProin + creditLimitProin < 0) {
        throw new HttpsError(
          "failed-precondition",
          "The credit limit cannot be below this salon's current negative balance.",
        );
      }
      const before = {
        availableProin,
        creditLimitProin: money(wallet.creditLimitProin ??
          DEFAULT_SALON_PROMOTION_CREDIT_LIMIT),
      };
      const after = {...before, creditLimitProin};
      const timestamp = admin.firestore.FieldValue.serverTimestamp();
      transaction.set(walletRef, {
        walletId: walletRef.id,
        walletType: "salon_promotion_credits",
        accountId: salonId,
        availableProin,
        reservedProin: money(wallet.reservedProin),
        lifetimeGrantedProin: money(wallet.lifetimeGrantedProin),
        lifetimeRedeemedProin: money(wallet.lifetimeRedeemedProin),
        lifetimeExpiredProin: money(wallet.lifetimeExpiredProin),
        lifetimeRevokedProin: money(wallet.lifetimeRevokedProin),
        creditLimitProin,
        proinToInrRate: 1,
        createdAt: wallet.createdAt || timestamp,
        updatedAt: timestamp,
        updatedByAdminUid: adminUid,
      }, {merge: true});
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: "salon.promotion_credit_limit_changed",
        targetType: "salon",
        targetId: salonId,
        reason,
        before,
        after,
      }));
      result = {salonId, ...after};
    });
    return result;
  },
);

exports.recordSalonSettlementPaymentAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const salonId = requiredId(request.data?.salonId, "salon id");
    const reason = requiredAdminReason(request.data?.reason);
    let payment;
    try {
      payment = settlementPaymentReference(
        request.data?.paymentReference,
        request.data?.paymentMethod,
      );
    } catch (error) {
      if (error instanceof SalonFinanceValidationError) {
        throw new HttpsError("invalid-argument", error.message);
      }
      throw error;
    }
    const {paymentMethod, paymentReference} = payment;
    let amountInr;
    try {
      amountInr = positiveMoney(request.data?.amountInr, "Settlement amount");
    } catch (error) {
      if (error instanceof SalonFinanceValidationError) {
        throw new HttpsError("invalid-argument", error.message);
      }
      throw error;
    }
    const paidAtMillis = Number(request.data?.paidAtMillis) || Date.now();
    if (paidAtMillis <= 0 || paidAtMillis > Date.now() + 5 * 60 * 1000) {
      throw new HttpsError("invalid-argument", "Enter a valid payment date.");
    }
    const firestore = admin.firestore();
    const salonRef = firestore.collection("salons").doc(salonId);
    const walletRef = firestore.collection("salonWallets").doc(salonId);
    const paymentRef = firestore.collection("salonSettlementPayments").doc();
    const referenceRef = firestore.collection("salonSettlementPaymentReferences")
      .doc(crypto.createHash("sha256")
        .update(paymentReference.toUpperCase()).digest("hex"));
    const auditRef = firestore.collection("adminAuditLogs").doc();
    const openSettlementsQuery = firestore.collection("salonSettlements")
      .where("salonId", "==", salonId)
      .limit(1000);
    let result = null;
    await firestore.runTransaction(async (transaction) => {
      const [salonSnapshot, walletSnapshot, referenceSnapshot,
        settlementsSnapshot] = await Promise.all([
        transaction.get(salonRef),
        transaction.get(walletRef),
        transaction.get(referenceRef),
        transaction.get(openSettlementsQuery),
      ]);
      if (!salonSnapshot.exists) {
        throw new HttpsError("not-found", "Salon not found.");
      }
      if (referenceSnapshot.exists) {
        const prior = referenceSnapshot.data() || {};
        throw new HttpsError(
          "already-exists",
          `This payment reference is already recorded for ${
            String(prior.salonId || "another salon")}.`,
        );
      }
      const wallet = walletSnapshot.data() || {};
      const payableBefore = money(wallet.payableBalance);
      if (amountInr > payableBefore) {
        throw new HttpsError(
          "failed-precondition",
          "Settlement amount cannot exceed this salon's pending balance.",
        );
      }
      let allocation;
      try {
        allocation = allocateSalonSettlementPayment(
          settlementsSnapshot.docs
            .map((document) => ({
              bookingId: document.id,
              ...document.data(),
              createdAtMillis: adminMillis(document.data()?.createdAt),
            }))
            .filter((settlement) => settlement.status !== "paid"),
          amountInr,
        );
      } catch (error) {
        if (error instanceof SalonFinanceValidationError) {
          throw new HttpsError("failed-precondition", error.message);
        }
        throw error;
      }
      if (Math.abs(payableBefore - allocation.outstandingAmount) > 0.01) {
        throw new HttpsError(
          "failed-precondition",
          "The salon settlement records do not match its pending balance. Reconcile before recording a payment.",
        );
      }
      const timestamp = admin.firestore.FieldValue.serverTimestamp();
      const paidAt = admin.firestore.Timestamp.fromMillis(paidAtMillis);
      for (const item of allocation.allocations) {
        const settlementRef = firestore.collection("salonSettlements")
          .doc(item.bookingId);
        transaction.update(settlementRef, {
          paidAmount: item.paidAmountAfter,
          outstandingAmount: item.outstandingAmountAfter,
          status: item.outstandingAmountAfter === 0 ? "paid" : "partially_paid",
          paymentReference,
          paymentMethod,
          lastPaymentReference: paymentReference,
          lastPaymentMethod: paymentMethod,
          lastPaidAt: paidAt,
          ...(item.outstandingAmountAfter === 0 ? {
            paidAt,
            paidByAdminUid: adminUid,
          } : {}),
          updatedAt: timestamp,
        });
      }
      const payableAfter = Math.round((payableBefore - amountInr) * 100) / 100;
      transaction.set(walletRef, {
        salonId,
        payableBalance: payableAfter,
        paidAmount: money(wallet.paidAmount) + amountInr,
        lastPaymentReference: paymentReference,
        lastPaymentMethod: paymentMethod,
        lastPaidAt: paidAt,
        updatedAt: timestamp,
      }, {merge: true});
      transaction.create(paymentRef, {
        paymentId: paymentRef.id,
        salonId,
        amountInr,
        paymentReference,
        paymentMethod,
        paidAt,
        paidByAdminUid: adminUid,
        reason,
        allocations: allocation.allocations,
        createdAt: timestamp,
      });
      transaction.create(referenceRef, {
        paymentId: paymentRef.id,
        salonId,
        paymentReference,
        paymentMethod,
        createdAt: timestamp,
      });
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: "salon.settlement_payment_recorded",
        targetType: "salon",
        targetId: salonId,
        reason,
        before: {payableBalance: payableBefore},
        after: {
          payableBalance: payableAfter,
          amountInr,
          paymentMethod,
          paymentReference,
        },
      }));
      result = {
        paymentId: paymentRef.id,
        salonId,
        amountInr,
        paymentMethod,
        payableBalance: payableAfter,
        allocationCount: allocation.allocations.length,
      };
    });
    return result;
  },
);

exports.markSalonSettlementPaid = onCall(
  {invoker: "public", enforceAppCheck: false},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const bookingId = requiredId(request.data?.bookingId, "booking id");
    const reason = requiredAdminReason(request.data?.reason);
    let payment;
    try {
      payment = settlementPaymentReference(
        request.data?.paymentReference,
        request.data?.paymentMethod,
      );
    } catch (error) {
      if (error instanceof SalonFinanceValidationError) {
        throw new HttpsError("invalid-argument", error.message);
      }
      throw error;
    }
    const {paymentMethod, paymentReference} = payment;
    const paidAtMillis = Number(request.data?.paidAtMillis) || Date.now();
    if (paidAtMillis <= 0 || paidAtMillis > Date.now() + 5 * 60 * 1000) {
      throw new HttpsError("invalid-argument", "Enter a valid payment date.");
    }
    const firestore = admin.firestore();
    const settlementRef = firestore.collection("salonSettlements").doc(bookingId);
    const paymentRef = firestore.collection("salonSettlementPayments").doc();
    const auditRef = firestore.collection("adminAuditLogs").doc();
    const paymentReferenceRef = firestore
      .collection("settlementPaymentReferences")
      .doc(crypto.createHash("sha256")
        .update(paymentReference.toUpperCase()).digest("hex"));
    let result = null;
    await firestore.runTransaction(async (transaction) => {
      const [settlementSnapshot, paymentReferenceSnapshot] = await Promise.all([
        transaction.get(settlementRef),
        transaction.get(paymentReferenceRef),
      ]);
      const settlement = settlementSnapshot.data();
      if (!settlement) {
        throw new HttpsError("not-found", "Settlement not found.");
      }
      if (settlement.status === "paid") {
        if (settlement.paymentReference !== paymentReference) {
          throw new HttpsError(
            "already-exists",
            "This settlement was already paid with another reference.",
          );
        }
        if (paymentReferenceSnapshot.exists &&
            paymentReferenceSnapshot.data()?.bookingId !== bookingId) {
          throw new HttpsError(
            "already-exists",
            "This payment reference is already used by another settlement.",
          );
        }
        if (!paymentReferenceSnapshot.exists) {
          transaction.set(paymentReferenceRef, {
            bookingId,
            paymentReference,
            paymentMethod,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }
        result = {bookingId, status: "paid", alreadyPaid: true};
        return;
      }
      if (settlement.status !== "payable") {
        throw new HttpsError(
          "failed-precondition",
          "Only payable settlements can be marked paid.",
        );
      }
      const payoutAmount = money(settlement.pritzePayoutAmount);
      const salonId = requiredId(settlement.salonId, "salon id");
      const walletRef = firestore.collection("salonWallets").doc(salonId);
      const walletSnapshot = await transaction.get(walletRef);
      const payableBalance = money(walletSnapshot.data()?.payableBalance);
      if (payoutAmount <= 0 || payableBalance < payoutAmount) {
        throw new HttpsError(
          "failed-precondition",
          "The salon payable wallet does not match this settlement.",
        );
      }
      if (paymentReferenceSnapshot.exists &&
          paymentReferenceSnapshot.data()?.bookingId !== bookingId) {
        throw new HttpsError(
          "already-exists",
          "This payment reference is already used by another settlement.",
        );
      }
      transaction.update(settlementRef, {
        status: "paid",
        paidAmount: payoutAmount,
        outstandingAmount: 0,
        paymentReference,
        paymentMethod,
        paidAt: admin.firestore.Timestamp.fromMillis(paidAtMillis),
        paidByAdminUid: adminUid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      transaction.set(walletRef, {
        payableBalance: admin.firestore.FieldValue.increment(-payoutAmount),
        paidAmount: admin.firestore.FieldValue.increment(payoutAmount),
        lastPaidBookingId: bookingId,
        lastPaymentReference: paymentReference,
        lastPaymentMethod: paymentMethod,
        lastPaidAt: admin.firestore.Timestamp.fromMillis(paidAtMillis),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.create(paymentRef, {
        paymentId: paymentRef.id,
        salonId,
        amountInr: payoutAmount,
        paymentReference,
        paymentMethod,
        paidAt: admin.firestore.Timestamp.fromMillis(paidAtMillis),
        paidByAdminUid: adminUid,
        reason,
        allocations: [{
          bookingId,
          allocatedAmount: payoutAmount,
          paidAmountAfter: payoutAmount,
          outstandingAmountAfter: 0,
        }],
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      transaction.set(paymentReferenceRef, {
        paymentId: paymentRef.id,
        bookingId,
        salonId,
        paymentReference,
        paymentMethod,
        paidAt: admin.firestore.Timestamp.fromMillis(paidAtMillis),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: "settlement.marked_paid",
        targetType: "booking",
        targetId: bookingId,
        reason,
        before: {status: settlement.status, paymentReference: ""},
        after: {status: "paid", paymentMethod, paymentReference},
      }));
      result = {bookingId, status: "paid", alreadyPaid: false};
    });
    return result;
  },
);

exports.updateSalonControlAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const salonId = requiredId(request.data?.salonId, "salon id");
    const control = String(request.data?.control ?? "").trim();
    const value = request.data?.value;
    const reason = requiredAdminReason(request.data?.reason);
    if (!["isOpen", "instantBookingsEnabled", "adminSuspended",
      "proinReferralApproved"]
      .includes(control) || typeof value !== "boolean") {
      throw new HttpsError("invalid-argument", "Invalid salon control.");
    }
    const firestore = admin.firestore();
    const salonRef = firestore.collection("salons").doc(salonId);
    const auditRef = firestore.collection("adminAuditLogs").doc();
    let after = {};
    await firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(salonRef);
      const salon = snapshot.data();
      if (!salon) throw new HttpsError("not-found", "Salon not found.");
      const before = {
        isOpen: salon.isOpen === true,
        instantBookingsEnabled: salon.instantBookingsEnabled !== false,
        adminSuspended: salon.adminSuspended === true,
        proinReferralApproved: salon.proinReferralApproved === true,
      };
      after = control === "adminSuspended" && value === true ? {
        ...before,
        adminSuspended: true,
        isOpen: false,
        instantBookingsEnabled: false,
      } : {...before, [control]: value};
      transaction.update(salonRef, {
        ...after,
        lastAdminActionAt: admin.firestore.FieldValue.serverTimestamp(),
        lastAdminActionBy: adminUid,
        lastAdminActionReason: reason,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: `salon.${control}`,
        targetType: "salon",
        targetId: salonId,
        reason,
        before,
        after,
      }));
    });
    return {salonId, ...after};
  },
);

exports.reviewSalonOnboardingAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const salonId = requiredId(request.data?.salonId, "salon id");
    const decision = String(request.data?.decision || "").trim();
    const reason = requiredAdminReason(request.data?.reason);
    if (!["approved", "rejected"].includes(decision)) {
      throw new HttpsError(
        "invalid-argument",
        "Choose whether to approve or reject this salon listing.",
      );
    }
    const firestore = admin.firestore();
    const salonRef = firestore.collection("salons").doc(salonId);
    const auditRef = firestore.collection("adminAuditLogs").doc();
    let ownerUid = "";
    let salonName = "Salon";
    await firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(salonRef);
      const salon = snapshot.data();
      if (!salon) throw new HttpsError("not-found", "Salon not found.");
      const beforeStatus = salonApprovalStatus(salon);
      if (beforeStatus === "approved" && decision === "approved") {
        throw new HttpsError(
          "failed-precondition",
          "This salon is already approved and visible to customers.",
        );
      }
      ownerUid = requiredId(salon.ownerUid, "salon owner uid");
      salonName = adminString(salon.name) || "Salon";
      const ownerRef = firestore.collection("users").doc(ownerUid);
      const ownerSnapshot = await transaction.get(ownerRef);
      if (!ownerSnapshot.exists) {
        throw new HttpsError("not-found", "Salon owner account not found.");
      }
      requireStoredRole(ownerSnapshot.data(), "owner");
      const next = {
        approvalStatus: decision,
        approvalReviewedAt: admin.firestore.FieldValue.serverTimestamp(),
        approvalReviewedBy: adminUid,
        approvalReviewReason: reason,
        lastAdminActionAt: admin.firestore.FieldValue.serverTimestamp(),
        lastAdminActionBy: adminUid,
        lastAdminActionReason: reason,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        ...(decision === "rejected" ? {
          isOpen: false,
          instantBookingsEnabled: false,
        } : {}),
      };
      transaction.update(salonRef, next);
      transaction.set(ownerRef, {
        salonApprovalStatus: decision,
        salonApprovalUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: `salon.onboarding_${decision}`,
        targetType: "salon",
        targetId: salonId,
        reason,
        before: {approvalStatus: beforeStatus},
        after: {approvalStatus: decision},
      }));
    });
    await sendToUsers([ownerUid], {
      title: decision === "approved" ?
        "Your salon is approved" : "Your salon listing needs review",
      body: decision === "approved" ?
        `${salonName} is now visible to customers.` :
        "Your salon is not visible to customers. Open Pritze or contact support for details.",
      data: {type: "salon_onboarding_review", salonId, decision},
      requiredActiveRolesByUser: {[ownerUid]: ["owner"]},
    });
    return {salonId, approvalStatus: decision};
  },
);

exports.updateCustomerProfileAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const customerUid = requiredId(request.data?.customerUid, "customer uid");
    const reason = requiredAdminReason(request.data?.reason);
    const name = normalizeDisplayName(request.data?.name);
    const phone = normalizeVerifiedPhone(request.data?.phone);
    const emailValue = adminString(request.data?.email);
    const email = emailValue ? normalizeEmail(emailValue) : "";
    const gender = normalizeProfileGender(request.data?.gender);
    const birthDate = normalizeBirthDate(request.data?.birthDate);
    const preferredStyles = sanitizeShortList(request.data?.preferredStyles);
    const photoUrl = sanitizePhotoUrls([request.data?.photoUrl], 1)[0] || "";
    const stylePhotoUrls = sanitizePhotoUrls(request.data?.stylePhotoUrls);
    if (!name) {
      throw new HttpsError("invalid-argument", "Enter the customer name.");
    }
    if (!/^\+91\d{10}$/.test(phone)) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a valid +91 10-digit customer phone number.",
      );
    }
    if (emailValue && !email) {
      throw new HttpsError("invalid-argument", "Enter a valid email address.");
    }
    if (gender === null || birthDate === null) {
      throw new HttpsError("invalid-argument", "Check the customer details.");
    }

    const firestore = admin.firestore();
    const userRef = firestore.collection("users").doc(customerUid);
    const initialSnapshot = await userRef.get();
    const initial = initialSnapshot.data();
    if (!initial) throw new HttpsError("not-found", "Customer not found.");
    requireStoredRole(initial, "customer");
    const previousPhone = normalizeVerifiedPhone(initial.phone || initial.contact);
    const phoneRef = firestore.collection("loginIdentifiers").doc(phoneKey(phone));

    let phoneAuthUser = null;
    try {
      phoneAuthUser = await admin.auth().getUserByPhoneNumber(phone);
    } catch (error) {
      if (error.code !== "auth/user-not-found") throw error;
    }
    if (phoneAuthUser && phoneAuthUser.uid !== customerUid) {
      throw new HttpsError(
        "already-exists",
        "This phone number already belongs to another account.",
      );
    }

    const before = adminCustomerProfileView(customerUid, initial);
    const after = {
      ...before,
      name,
      phone,
      email,
      gender,
      birthDate,
      preferredStyles,
      photoUrl,
      stylePhotoUrls,
    };
    const auditRef = firestore.collection("adminAuditLogs").doc();
    await firestore.runTransaction(async (transaction) => {
      const latestSnapshot = await transaction.get(userRef);
      const latest = latestSnapshot.data();
      if (!latest) throw new HttpsError("not-found", "Customer not found.");
      requireStoredRole(latest, "customer");
      const claimedPhoneSnapshot = await transaction.get(phoneRef);
      const claimedPhone = claimedPhoneSnapshot.data();
      if (claimedPhoneSnapshot.exists && claimedPhone?.uid !== customerUid) {
        const role = normalizeRole(claimedPhone?.role);
        throw new HttpsError(
          "already-exists",
          role === "owner" ?
            "This phone number is already registered as a salon owner." :
            "This phone number already belongs to another customer.",
        );
      }
      let previousPhoneRef = null;
      let previousPhoneSnapshot = null;
      if (previousPhone && previousPhone !== phone) {
        previousPhoneRef = firestore.collection("loginIdentifiers")
          .doc(phoneKey(previousPhone));
        previousPhoneSnapshot = await transaction.get(previousPhoneRef);
      }
      transaction.set(userRef, {
        name,
        contact: phone,
        phone,
        email: email || null,
        gender,
        birthDate,
        preferredStyles,
        photoUrl,
        stylePhotoUrls,
        lastAdminActionAt: admin.firestore.FieldValue.serverTimestamp(),
        lastAdminActionBy: adminUid,
        lastAdminActionReason: reason,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.set(phoneRef, {
        phone,
        role: "customer",
        uid: customerUid,
        source: "admin_customer_profile",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      if (previousPhoneRef && previousPhoneSnapshot?.data()?.uid === customerUid) {
        transaction.delete(previousPhoneRef);
      }
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: "customer.profile_updated",
        targetType: "customer",
        targetId: customerUid,
        reason,
        before,
        after,
      }));
    });
    await admin.auth().updateUser(customerUid, {
      displayName: name,
      phoneNumber: phone,
    });
    return after;
  },
);

exports.updateCustomerControlAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const customerUid = requiredId(request.data?.customerUid, "customer uid");
    const adminSuspended = request.data?.adminSuspended;
    const reason = requiredAdminReason(request.data?.reason);
    if (typeof adminSuspended !== "boolean") {
      throw new HttpsError("invalid-argument", "Invalid customer access state.");
    }
    const firestore = admin.firestore();
    const userRef = firestore.collection("users").doc(customerUid);
    const snapshot = await userRef.get();
    const user = snapshot.data();
    if (!user) throw new HttpsError("not-found", "Customer not found.");
    requireStoredRole(user, "customer");
    await admin.auth().updateUser(customerUid, {disabled: adminSuspended});
    const auditRef = firestore.collection("adminAuditLogs").doc();
    await firestore.runTransaction(async (transaction) => {
      const latestSnapshot = await transaction.get(userRef);
      const latest = latestSnapshot.data();
      if (!latest) throw new HttpsError("not-found", "Customer not found.");
      requireStoredRole(latest, "customer");
      transaction.set(userRef, {
        adminSuspended,
        lastAdminActionAt: admin.firestore.FieldValue.serverTimestamp(),
        lastAdminActionBy: adminUid,
        lastAdminActionReason: reason,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: adminSuspended ?
          "customer.account_suspended" : "customer.account_restored",
        targetType: "customer",
        targetId: customerUid,
        reason,
        before: {adminSuspended: latest.adminSuspended === true},
        after: {adminSuspended},
      }));
    });
    return {customerUid, adminSuspended};
  },
);

exports.updateSalonProfileAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const salonId = requiredId(request.data?.salonId, "salon id");
    const reason = requiredAdminReason(request.data?.reason);
    const name = normalizeDisplayName(request.data?.name);
    const ownerName = normalizeDisplayName(request.data?.ownerName);
    const address = adminString(request.data?.address).slice(0, 500);
    const directionsUrl = adminHttpsUrl(request.data?.directionsUrl);
    const phone = normalizeVerifiedPhone(request.data?.phone);
    const emailValue = adminString(request.data?.email);
    const email = emailValue ? normalizeEmail(emailValue) : "";
    const logoUrl = adminHttpsUrl(request.data?.logoUrl);
    const photoUrls = sanitizePhotoUrls(request.data?.photoUrls);
    const distanceLabel = adminString(request.data?.distanceLabel).slice(0, 80);
    const openTime = adminSalonTime(request.data?.openTime);
    const closeTime = adminSalonTime(request.data?.closeTime);
    if (!name || !ownerName || !address) {
      throw new HttpsError(
        "invalid-argument",
        "Salon name, owner name and address are required.",
      );
    }
    if (!/^\+91\d{10}$/.test(phone)) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a valid +91 10-digit salon phone number.",
      );
    }
    if (emailValue && !email) {
      throw new HttpsError("invalid-argument", "Enter a valid email address.");
    }
    if (directionsUrl === null || logoUrl === null) {
      throw new HttpsError(
        "invalid-argument",
        "Salon links and images must use secure https links.",
      );
    }
    if (!openTime || !closeTime || adminSalonMinutes(closeTime) <=
        adminSalonMinutes(openTime)) {
      throw new HttpsError(
        "invalid-argument",
        "Enter valid opening and closing times, with closing after opening.",
      );
    }

    const firestore = admin.firestore();
    const salonRef = firestore.collection("salons").doc(salonId);
    const initialSnapshot = await salonRef.get();
    const initial = initialSnapshot.data();
    if (!initial) throw new HttpsError("not-found", "Salon not found.");
    const ownerUid = requiredId(initial.ownerUid, "salon owner uid");
    const ownerRef = firestore.collection("users").doc(ownerUid);
    const ownerSnapshot = await ownerRef.get();
    const owner = ownerSnapshot.data();
    if (!owner) throw new HttpsError("not-found", "Salon owner not found.");
    requireStoredRole(owner, "owner");
    const previousPhone = normalizeVerifiedPhone(
      owner.profilePhone || initial.phone,
    );
    const phoneRef = firestore.collection("loginIdentifiers").doc(phoneKey(phone));
    let phoneAuthUser = null;
    try {
      phoneAuthUser = await admin.auth().getUserByPhoneNumber(phone);
    } catch (error) {
      if (error.code !== "auth/user-not-found") throw error;
    }
    if (phoneAuthUser && phoneAuthUser.uid !== ownerUid) {
      throw new HttpsError(
        "already-exists",
        "This phone number already belongs to another account.",
      );
    }
    const before = adminSalonProfileView(salonId, initial);
    const after = {
      ...before,
      name,
      ownerName,
      address,
      directionsUrl: directionsUrl || "",
      phone,
      email,
      logoUrl: logoUrl || "",
      photoUrls,
      distanceLabel: distanceLabel || "Nearby",
      openTime,
      closeTime,
    };
    const auditRef = firestore.collection("adminAuditLogs").doc();
    await firestore.runTransaction(async (transaction) => {
      const [latestSalonSnapshot, latestOwnerSnapshot, phoneSnapshot] =
        await Promise.all([
          transaction.get(salonRef),
          transaction.get(ownerRef),
          transaction.get(phoneRef),
        ]);
      const latestSalon = latestSalonSnapshot.data();
      const latestOwner = latestOwnerSnapshot.data();
      if (!latestSalon || !latestOwner) {
        throw new HttpsError("not-found", "Salon or owner not found.");
      }
      requireStoredRole(latestOwner, "owner");
      if (phoneSnapshot.exists && phoneSnapshot.data()?.uid !== ownerUid) {
        const role = normalizeRole(phoneSnapshot.data()?.role);
        throw new HttpsError(
          "already-exists",
          role === "customer" ?
            "This phone number is already registered as a customer." :
            "This phone number belongs to another salon owner.",
        );
      }
      let previousPhoneRef = null;
      let previousPhoneSnapshot = null;
      if (previousPhone && previousPhone !== phone) {
        previousPhoneRef = firestore.collection("loginIdentifiers")
          .doc(phoneKey(previousPhone));
        previousPhoneSnapshot = await transaction.get(previousPhoneRef);
      }
      transaction.set(salonRef, {
        name,
        ownerName,
        address,
        directionsUrl: directionsUrl || "",
        phone,
        email: email || null,
        logoUrl: logoUrl || "",
        photoUrls,
        distanceLabel: distanceLabel || "Nearby",
        openTime,
        closeTime,
        lastAdminActionAt: admin.firestore.FieldValue.serverTimestamp(),
        lastAdminActionBy: adminUid,
        lastAdminActionReason: reason,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.set(ownerRef, {
        profilePhone: phone,
        lastAdminActionAt: admin.firestore.FieldValue.serverTimestamp(),
        lastAdminActionBy: adminUid,
        lastAdminActionReason: reason,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.set(phoneRef, {
        phone,
        role: "owner",
        uid: ownerUid,
        source: "admin_salon_profile",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      if (previousPhoneRef && previousPhoneSnapshot?.data()?.uid === ownerUid) {
        transaction.delete(previousPhoneRef);
      }
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: "salon.profile_updated",
        targetType: "salon",
        targetId: salonId,
        reason,
        before,
        after,
      }));
    });
    const ownerAuth = await admin.auth().getUser(ownerUid);
    if (ownerAuth.phoneNumber && ownerAuth.phoneNumber !== phone) {
      await admin.auth().updateUser(ownerUid, {phoneNumber: phone});
    }
    return after;
  },
);

exports.updateSalonServiceAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const salonId = requiredId(request.data?.salonId, "salon id");
    const serviceId = requiredId(request.data?.serviceId, "service id");
    const reason = requiredAdminReason(request.data?.reason);
    const hasName = Object.prototype.hasOwnProperty.call(request.data || {}, "name");
    const hasCategory = Object.prototype.hasOwnProperty.call(
      request.data || {}, "category",
    );
    const hasPrice = Object.prototype.hasOwnProperty.call(request.data || {}, "price");
    const hasDuration = Object.prototype.hasOwnProperty.call(
      request.data || {}, "durationMinutes",
    );
    const hasAvailability = Object.prototype.hasOwnProperty.call(
      request.data || {}, "isAvailable",
    );
    const hasInstant = Object.prototype.hasOwnProperty.call(
      request.data || {}, "instantBookingEnabled",
    );
    const name = normalizeDisplayName(request.data?.name);
    const category = adminString(request.data?.category).slice(0, 80);
    const price = Number(request.data?.price);
    const durationMinutes = Number(request.data?.durationMinutes);
    const isAvailable = request.data?.isAvailable;
    const instantBookingEnabled = request.data?.instantBookingEnabled;
    if (hasName && !name) {
      throw new HttpsError("invalid-argument", "Enter the service name.");
    }
    if (hasCategory && !category) {
      throw new HttpsError("invalid-argument", "Enter the service category.");
    }
    if (hasPrice && (!Number.isFinite(price) || price < 0 || price > 100000)) {
      throw new HttpsError("invalid-argument", "Enter a valid service price.");
    }
    if (hasDuration && (!Number.isInteger(durationMinutes) ||
        durationMinutes < 5 || durationMinutes > 480)) {
      throw new HttpsError(
        "invalid-argument",
        "Service duration must be between 5 and 480 minutes.",
      );
    }
    if (hasAvailability && typeof isAvailable !== "boolean") {
      throw new HttpsError("invalid-argument", "Invalid service availability.");
    }
    if (hasInstant && typeof instantBookingEnabled !== "boolean") {
      throw new HttpsError(
        "invalid-argument", "Invalid instant-booking availability.",
      );
    }
    if (!hasName && !hasCategory && !hasPrice && !hasDuration &&
        !hasAvailability && !hasInstant) {
      throw new HttpsError("invalid-argument", "No service changes supplied.");
    }
    const firestore = admin.firestore();
    const salonRef = firestore.collection("salons").doc(salonId);
    const auditRef = firestore.collection("adminAuditLogs").doc();
    await firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(salonRef);
      const salon = snapshot.data();
      if (!salon) throw new HttpsError("not-found", "Salon not found.");
      const services = Array.isArray(salon.services) ? salon.services : [];
      const serviceIndex = services.findIndex((item) =>
        String(item?.id ?? "").trim() === serviceId);
      if (serviceIndex < 0) {
        throw new HttpsError("not-found", "Salon service not found.");
      }
      const previous = services[serviceIndex] || {};
      const nextService = {
        ...previous,
        ...(hasName ? {name} : {}),
        ...(hasCategory ? {category} : {}),
        ...(hasPrice ? {price: money(price)} : {}),
        ...(hasDuration ? {durationMinutes} : {}),
        ...(hasAvailability ? {isAvailable} : {}),
        ...(hasInstant ? {instantBookingEnabled} : {}),
      };
      const nextServices = services.map((item, index) => index === serviceIndex ?
        nextService : item);
      transaction.update(salonRef, {
        services: nextServices,
        lastAdminActionAt: admin.firestore.FieldValue.serverTimestamp(),
        lastAdminActionBy: adminUid,
        lastAdminActionReason: reason,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: "salon.service_updated",
        targetType: "salon",
        targetId: salonId,
        reason,
        before: {serviceId, ...previous},
        after: {serviceId, ...nextService},
      }));
    });
    return {salonId, serviceId};
  },
);

exports.updateBarberStatusAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const barberId = requiredId(request.data?.barberId, "barber id");
    const isActive = request.data?.isActive;
    const reason = requiredAdminReason(request.data?.reason);
    if (typeof isActive !== "boolean") {
      throw new HttpsError("invalid-argument", "Invalid barber status.");
    }
    const firestore = admin.firestore();
    const barberRef = firestore.collection("barbers").doc(barberId);
    const auditRef = firestore.collection("adminAuditLogs").doc();
    await firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(barberRef);
      const barber = snapshot.data();
      if (!barber) throw new HttpsError("not-found", "Barber not found.");
      transaction.update(barberRef, {
        isActive,
        lastAdminActionAt: admin.firestore.FieldValue.serverTimestamp(),
        lastAdminActionBy: adminUid,
        lastAdminActionReason: reason,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: "barber.active_status",
        targetType: "barber",
        targetId: barberId,
        reason,
        before: {isActive: barber.isActive !== false},
        after: {isActive},
      }));
    });
    return {barberId, isActive};
  },
);

exports.updateBarberProfileAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const barberId = requiredId(request.data?.barberId, "barber id");
    const reason = requiredAdminReason(request.data?.reason);
    const name = normalizeDisplayName(request.data?.name);
    const phone = adminString(request.data?.phone).slice(0, 30);
    const emailValue = adminString(request.data?.email);
    const email = emailValue ? normalizeEmail(emailValue) : "";
    const speciality = adminString(request.data?.speciality).slice(0, 120);
    const experienceYears = Number(request.data?.experienceYears);
    const resumeSummary = adminString(request.data?.resumeSummary).slice(0, 1000);
    const serviceIds = adminStringList(request.data?.serviceIds, 100);
    const isActive = request.data?.isActive;
    if (!name) throw new HttpsError("invalid-argument", "Enter the barber name.");
    if (emailValue && !email) {
      throw new HttpsError("invalid-argument", "Enter a valid barber email.");
    }
    if (!Number.isInteger(experienceYears) || experienceYears < 0 ||
        experienceYears > 80 || typeof isActive !== "boolean") {
      throw new HttpsError("invalid-argument", "Check the barber details.");
    }
    const firestore = admin.firestore();
    const barberRef = firestore.collection("barbers").doc(barberId);
    const auditRef = firestore.collection("adminAuditLogs").doc();
    await firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(barberRef);
      const barber = snapshot.data();
      if (!barber) throw new HttpsError("not-found", "Barber not found.");
      const before = adminBarberRecord(snapshot);
      const after = {
        ...before,
        name,
        phone,
        email,
        speciality,
        experienceYears,
        resumeSummary,
        serviceIds,
        serviceCount: serviceIds.length,
        isActive,
      };
      transaction.set(barberRef, {
        name,
        phone,
        email: email || null,
        speciality,
        experienceYears,
        resumeSummary,
        serviceIds,
        isActive,
        lastAdminActionAt: admin.firestore.FieldValue.serverTimestamp(),
        lastAdminActionBy: adminUid,
        lastAdminActionReason: reason,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: "barber.profile_updated",
        targetType: "barber",
        targetId: barberId,
        reason,
        before,
        after,
      }));
    });
    return {barberId};
  },
);

exports.resolveJoinRequestAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const requestId = requiredId(request.data?.requestId, "request id");
    const status = String(request.data?.status ?? "").trim();
    const reason = requiredAdminReason(request.data?.reason);
    if (!["approved", "rejected"].includes(status)) {
      throw new HttpsError("invalid-argument", "Invalid join request decision.");
    }
    const firestore = admin.firestore();
    const requestRef = firestore.collection("joinRequests").doc(requestId);
    const barberRef = status === "approved" ?
      firestore.collection("barbers").doc() : null;
    const auditRef = firestore.collection("adminAuditLogs").doc();
    let requesterUid = "";
    await firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(requestRef);
      const joinRequest = snapshot.data();
      if (!joinRequest) {
        throw new HttpsError("not-found", "Join request not found.");
      }
      if (joinRequest.status !== "pending") {
        throw new HttpsError(
          "failed-precondition",
          "Only pending join requests can be reviewed.",
        );
      }
      requesterUid = adminString(joinRequest.requesterUid);
      transaction.update(requestRef, {
        status,
        reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
        reviewedByAdminUid: adminUid,
        reviewReason: reason,
        ...(barberRef ? {barberId: barberRef.id} : {}),
      });
      if (barberRef) {
        transaction.create(barberRef, {
          uid: requesterUid || null,
          salonId: adminString(joinRequest.salonId),
          name: adminString(joinRequest.barberName) || "Barber",
          phone: adminString(joinRequest.barberPhone),
          email: adminString(joinRequest.barberEmail),
          speciality: adminString(joinRequest.speciality),
          experienceYears: Math.max(0, Number(joinRequest.experienceYears) || 0),
          resumeSummary: adminString(joinRequest.resumeSummary),
          serviceIds: adminStringList(joinRequest.serviceIds),
          isActive: true,
          createdByAdminUid: adminUid,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: `join_request.${status}`,
        targetType: "joinRequest",
        targetId: requestId,
        reason,
        before: {status: joinRequest.status},
        after: {status, barberId: barberRef?.id || ""},
      }));
    });
    if (requesterUid) {
      await sendToUsers([requesterUid], {
        title: status === "approved" ? "Join request approved" :
          "Join request update",
        body: status === "approved" ?
          "Your salon join request was approved." :
          "Your salon join request was not approved.",
        data: {type: "join_request", requestId, event: status},
      });
    }
    return {requestId, status, barberId: barberRef?.id || ""};
  },
);

exports.addAdminNote = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const targetType = String(request.data?.targetType ?? "").trim();
    const targetId = requiredId(request.data?.targetId, "target id");
    const note = String(request.data?.note ?? "").trim().slice(0, 1000);
    if (!["booking", "customer", "salon", "barber"].includes(targetType)) {
      throw new HttpsError("invalid-argument", "Invalid note target.");
    }
    if (note.length < 3) {
      throw new HttpsError("invalid-argument", "Enter an internal note.");
    }
    const targetCollections = {
      booking: "bookings",
      customer: "users",
      salon: "salons",
      barber: "barbers",
    };
    const firestore = admin.firestore();
    const targetRef = firestore.collection(targetCollections[targetType])
      .doc(targetId);
    const noteRef = firestore.collection("adminNotes").doc();
    const auditRef = firestore.collection("adminAuditLogs").doc();
    await firestore.runTransaction(async (transaction) => {
      const targetSnapshot = await transaction.get(targetRef);
      if (!targetSnapshot.exists) {
        throw new HttpsError("not-found", "Note target not found.");
      }
      transaction.create(noteRef, {
        targetType,
        targetId,
        note,
        adminUid,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: "note.created",
        targetType,
        targetId,
        reason: "Internal operational note",
        before: {},
        after: {noteId: noteRef.id},
      }));
    });
    return {noteId: noteRef.id};
  },
);

exports.updateAdminAutomationRule = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const ruleId = String(request.data?.ruleId ?? "").trim();
    const enabled = request.data?.enabled;
    const threshold = Number(request.data?.threshold);
    const reason = requiredAdminReason(request.data?.reason);
    const thresholdBounds = {
      instant_response: [1, 15],
      overdue_arrival: [5, 60],
      unassigned_booking: [1, 60],
      cancellation_spike: [5, 100],
      low_rating: [1, 5],
    };
    const bounds = thresholdBounds[ruleId];
    if (!bounds || typeof enabled !== "boolean" ||
        !Number.isFinite(threshold) || threshold < bounds[0] ||
        threshold > bounds[1]) {
      throw new HttpsError("invalid-argument", "Invalid automation rule.");
    }
    const firestore = admin.firestore();
    const ruleRef = firestore.collection("adminAutomationRules").doc(ruleId);
    const auditRef = firestore.collection("adminAuditLogs").doc();
    await firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(ruleRef);
      const before = snapshot.exists ? snapshot.data() :
        DEFAULT_ADMIN_AUTOMATION_RULES[ruleId];
      const after = {enabled, threshold};
      transaction.set(ruleRef, {
        ...after,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedByAdminUid: adminUid,
      }, {merge: true});
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: "automation.rule_updated",
        targetType: "automationRule",
        targetId: ruleId,
        reason,
        before: {enabled: before?.enabled, threshold: before?.threshold},
        after,
      }));
    });
    return {ruleId, enabled, threshold};
  },
);

exports.acknowledgeAdminOperationalAlert = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const alertId = requiredId(request.data?.alertId, "alert id");
    const reason = requiredAdminReason(request.data?.reason);
    const firestore = admin.firestore();
    const alertRef = firestore.collection("adminOperationalAlerts").doc(alertId);
    const auditRef = firestore.collection("adminAuditLogs").doc();
    await firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(alertRef);
      const alert = snapshot.data();
      if (!alert) throw new HttpsError("not-found", "Alert not found.");
      if (alert.status !== "active") {
        throw new HttpsError("failed-precondition", "This alert is no longer active.");
      }
      transaction.update(alertRef, {
        status: "acknowledged",
        acknowledgedAt: admin.firestore.FieldValue.serverTimestamp(),
        acknowledgedByAdminUid: adminUid,
        acknowledgementReason: reason,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: "intelligence.alert_acknowledged",
        targetType: alert.targetType || "alert",
        targetId: alert.targetId || alertId,
        reason,
        before: {alertId, status: alert.status},
        after: {alertId, status: "acknowledged"},
      }));
    });
    return {alertId, status: "acknowledged"};
  },
);

exports.runAdminIntelligenceScan = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const reason = requiredAdminReason(request.data?.reason);
    const result = await generateAdminOperationalAlerts();
    await admin.firestore().collection("adminAuditLogs").add(adminAuditRecord({
      adminUid,
      action: "intelligence.scan_requested",
      targetType: "platform",
      targetId: "pritze",
      reason,
      before: {},
      after: result,
    }));
    return result;
  },
);

exports.getDiscountAdministrationDataAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    await requirePlatformAdministrator(request);
    const firestore = admin.firestore();
    const [
      campaigns,
      campaignUsage,
      salonUsage,
      customerUsage,
      customerTotals,
      salonTotals,
      platformTotals,
      vault,
    ] = await Promise.all([
      firestore.collection("discountCampaigns").limit(500).get(),
      firestore.collection("discountCampaignUsage").limit(500).get(),
      firestore.collection("discountSalonUsage").limit(5000).get(),
      firestore.collection("discountCustomerUsage").limit(5000).get(),
      firestore.collection("discountCustomerTotals").limit(2000).get(),
      firestore.collection("discountSalonTotals").limit(1000).get(),
      firestore.collection("discountPlatformTotals").doc("current").get(),
      firestore.collection("platformFinance").doc("discountVault").get(),
    ]);
    return {
      generatedAtMillis: Date.now(),
      campaigns: campaigns.docs.map((document) =>
        discountCampaignAdminView(document.id, document.data())),
      campaignUsage: campaignUsage.docs.map((document) => ({
        campaignId: document.id,
        ...discountUsageAdminView(document.data()),
      })),
      salonUsage: salonUsage.docs.map((document) => ({
        usageId: document.id,
        campaignId: adminString(document.data()?.campaignId),
        salonId: adminString(document.data()?.salonId),
        ...discountUsageAdminView(document.data()),
      })),
      customerUsage: customerUsage.docs.map((document) => ({
        usageId: document.id,
        campaignId: adminString(document.data()?.campaignId),
        customerUid: adminString(document.data()?.customerUid),
        ...discountUsageAdminView(document.data()),
      })),
      customerTotals: customerTotals.docs.map((document) => ({
        customerUid: document.id,
        ...discountTotalsAdminView(document.data()),
      })),
      salonTotals: salonTotals.docs.map((document) => ({
        salonId: document.id,
        ...discountTotalsAdminView(document.data()),
      })),
      platformTotals: discountTotalsAdminView(platformTotals.data()),
      vault: discountVaultAdminView(vault.data()),
    };
  },
);

exports.upsertDiscountCampaignAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const reason = requiredAdminReason(request.data?.reason);
    return runDiscountAdminCallable(async () => {
      const normalized = normalizeDiscountCampaignInput(request.data || {});
      const firestore = admin.firestore();
      const campaignRef = firestore.collection("discountCampaigns")
        .doc(normalized.campaignId);
      const usageRef = firestore.collection("discountCampaignUsage")
        .doc(normalized.campaignId);
      const cashbackProgramRef = firestore.collection("proinPrograms")
        .doc(discountCashbackProgramId(normalized.campaignId));
      const cashbackProgramUsageRef = firestore.collection("proinProgramUsage")
        .doc(discountCashbackProgramId(normalized.campaignId));
      const auditRef = firestore.collection("adminAuditLogs").doc();
      let result = null;
      await firestore.runTransaction(async (transaction) => {
        const [
          campaignSnapshot,
          usageSnapshot,
          cashbackProgramSnapshot,
          cashbackProgramUsageSnapshot,
        ] = await Promise.all([
          transaction.get(campaignRef),
          transaction.get(usageRef),
          transaction.get(cashbackProgramRef),
          transaction.get(cashbackProgramUsageRef),
        ]);
        const before = campaignSnapshot.data() || null;
        const usage = discountUsageAdminView(usageSnapshot.data());
        const committed = usage.reservedPayoutAmount +
          usage.realizedPayoutAmount;
        if (normalized.totalPayoutBudget < committed) {
          throw new HttpsError(
            "failed-precondition",
            "Campaign budget cannot be below its reserved and spent payout.",
          );
        }
        const existingVoucherHash = adminString(before?.voucherCodeHash);
        if (normalized.expectedVoucherCodeHash &&
            normalized.expectedVoucherCodeHash !== existingVoucherHash) {
          throw new HttpsError(
            "failed-precondition",
            "This voucher changed after the page was loaded. Refresh and try again.",
          );
        }
        const voucherCodeHash = normalized.voucherOnly ?
          (normalized.voucherCodeHash || existingVoucherHash) : "";
        const voucherMaskedCode = normalized.voucherOnly ?
          (normalized.voucherMaskedCode ||
            adminString(before?.voucherMaskedCode)) : "";
        if (normalized.voucherOnly && !voucherCodeHash) {
          throw new HttpsError(
            "invalid-argument",
            "Enter the original voucher code.",
          );
        }
        const recordedUses = usage.reservedUses + usage.realizedUses +
          usage.releasedUses;
        const previousCashback = Number(before?.cashbackProinAmount) || 0;
        const journeyChanged = JSON.stringify(before?.journeyMilestones || []) !==
          JSON.stringify(normalized.journeyMilestones || []) ||
          adminString(before?.journeyCountScope || "platform") !==
          normalized.journeyCountScope;
        if (recordedUses > 0 && (previousCashback !==
            normalized.cashbackProinAmount || journeyChanged)) {
          throw new HttpsError(
            "failed-precondition",
            "A journey campaign with booking usage cannot change its reward milestones. Create a new campaign for new milestones.",
          );
        }
        const grantedCashback = Number(
          cashbackProgramUsageSnapshot.data()?.grantedProin,
        ) || 0;
        if (normalized.cashbackProinAmount > 0 &&
            normalized.cashbackTotalBudgetProin < grantedCashback) {
          throw new HttpsError(
            "failed-precondition",
            "Proin cashback budget cannot be below cashback already granted.",
          );
        }
        if (existingVoucherHash !== voucherCodeHash && recordedUses > 0) {
          throw new HttpsError(
            "failed-precondition",
            "A campaign with booking usage cannot change or remove its voucher code.",
          );
        }
        const registryRef = voucherCodeHash ? firestore
          .collection("voucherCodeRegistry").doc(voucherCodeHash) : null;
        const oldRegistryRef = existingVoucherHash &&
          existingVoucherHash !== voucherCodeHash ? firestore
          .collection("voucherCodeRegistry").doc(existingVoucherHash) : null;
        const duplicateDiscountQuery = voucherCodeHash ? firestore
          .collection("discountCampaigns")
          .where("voucherCodeHash", "==", voucherCodeHash)
          .limit(2) : null;
        const registrySnapshot = registryRef ?
          await transaction.get(registryRef) : null;
        const oldRegistrySnapshot = oldRegistryRef ?
          await transaction.get(oldRegistryRef) : null;
        const proinCouponSnapshot = voucherCodeHash ? await transaction.get(
          firestore.collection("proinCoupons").doc(voucherCodeHash),
        ) : null;
        const duplicateDiscounts = duplicateDiscountQuery ?
          await transaction.get(duplicateDiscountQuery) : null;
        const registry = registrySnapshot?.data();
        if (registry && (registry.kind !== "discount" ||
            registry.targetId !== normalized.campaignId)) {
          throw new HttpsError(
            "already-exists",
            "This voucher code is already assigned to another campaign.",
          );
        }
        if (proinCouponSnapshot?.exists) {
          throw new HttpsError(
            "already-exists",
            "This code is already assigned to a Proin coupon.",
          );
        }
        if (duplicateDiscounts?.docs.some((document) =>
          document.id !== normalized.campaignId)) {
          throw new HttpsError(
            "already-exists",
            "This voucher code is already assigned to another discount campaign.",
          );
        }
        const version = Math.max(0, Number(before?.version) || 0) + 1;
        const versionRef = firestore.collection("discountCampaignVersions")
          .doc(`${normalized.campaignId}__v${version}`);
        const versionSnapshot = await transaction.get(versionRef);
        if (versionSnapshot.exists) {
          throw new HttpsError(
            "already-exists",
            "This discount campaign version already exists.",
          );
        }
        const campaignId = normalized.campaignId;
        const startsAtMillis = normalized.startsAtMillis;
        const endsAtMillis = normalized.endsAtMillis;
        const fields = {...normalized};
        delete fields.campaignId;
        delete fields.startsAtMillis;
        delete fields.endsAtMillis;
        delete fields.voucherCode;
        delete fields.expectedVoucherCodeHash;
        delete fields.voucherCodeHash;
        delete fields.voucherMaskedCode;
        fields.cashbackProgramId = normalized.cashbackProinAmount > 0 ?
          discountCashbackProgramId(campaignId) : "";
        const timestamp = admin.firestore.FieldValue.serverTimestamp();
        const record = {
          ...fields,
          voucherCodeHash,
          voucherMaskedCode,
          storesPlaintextVoucherCode: false,
          version,
          startsAt: startsAtMillis > 0 ?
            admin.firestore.Timestamp.fromMillis(startsAtMillis) : null,
          endsAt: endsAtMillis > 0 ?
            admin.firestore.Timestamp.fromMillis(endsAtMillis) : null,
          createdAt: before?.createdAt || timestamp,
          createdByAdminUid: before?.createdByAdminUid || adminUid,
          updatedAt: timestamp,
          updatedByAdminUid: adminUid,
        };
        transaction.set(campaignRef, record);
        if (normalized.cashbackProinAmount > 0) {
          const journeyProinAmounts = normalized.journeyMilestones
            .map((item) => item.cashbackProinAmount)
            .filter((amount) => amount > 0);
          const smallestCashback = journeyProinAmounts.length > 0 ?
            Math.min(...journeyProinAmounts) :
            normalized.cashbackProinAmount;
          const cashbackTimestamp = admin.firestore.FieldValue.serverTimestamp();
          transaction.set(cashbackProgramRef, {
            name: `${normalized.name} cashback`,
            sourceType: "promotion",
            walletType: "customer_rewards",
            qualificationEvent: "campaign_award",
            rewardRecipient: "account",
            referralTargetRole: "",
            referralInviterRole: "",
            active: true,
            rewardAmountProin: normalized.cashbackProinAmount,
            rewardValidityDays: normalized.cashbackValidityDays,
            totalBudgetProin: normalized.cashbackTotalBudgetProin,
            maximumTotalGrants: Math.max(
              1,
              Math.floor(
                normalized.cashbackTotalBudgetProin /
                  smallestCashback,
              ),
            ),
            maximumGrantsPerAccount: normalized.maximumUsesPerCustomer,
            minimumBookingAmount: 0,
            maximumProinPerBooking: normalized.cashbackProinAmount,
            maximumRedemptionPercent: 100,
            stackableWithDiscount: true,
            eligibleSalonIds: [],
            eligibleServiceIds: [],
            termsVersion: normalized.termsVersion,
            version,
            proinToInrRate: 1,
            regulatoryMode: "promotional_reward_only",
            customerFunded: false,
            cashWithdrawable: false,
            transferable: false,
            purchasable: false,
            startsAt: startsAtMillis > 0 ?
              admin.firestore.Timestamp.fromMillis(startsAtMillis) :
              admin.firestore.Timestamp.fromMillis(0),
            endsAt: admin.firestore.Timestamp.fromMillis(endsAtMillis),
            createdAt: cashbackProgramSnapshot.data()?.createdAt ||
              cashbackTimestamp,
            createdByAdminUid: cashbackProgramSnapshot.data()?.createdByAdminUid ||
              adminUid,
            updatedAt: cashbackTimestamp,
            updatedByAdminUid: adminUid,
            linkedDiscountCampaignId: campaignId,
            systemManaged: true,
          }, {merge: true});
        } else if (cashbackProgramSnapshot.exists && recordedUses === 0) {
          transaction.set(cashbackProgramRef, {
            active: false,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedByAdminUid: adminUid,
          }, {merge: true});
        }
        if (registryRef) {
          transaction.set(registryRef, {
            codeHash: voucherCodeHash,
            maskedCode: voucherMaskedCode,
            kind: "discount",
            targetId: campaignId,
            updatedAt: timestamp,
          }, {merge: true});
        }
        if (oldRegistryRef && oldRegistrySnapshot?.data()?.kind === "discount" &&
            oldRegistrySnapshot.data()?.targetId === campaignId) {
          transaction.delete(oldRegistryRef);
        }
        transaction.create(versionRef, {
          ...record,
          campaignId,
          versionCreatedAt: timestamp,
        });
        result = discountCampaignAdminView(campaignId, record);
        transaction.create(auditRef, adminAuditRecord({
          adminUid,
          action: before ?
            "discount.campaign_updated" : "discount.campaign_created",
          targetType: "discountCampaign",
          targetId: campaignId,
          reason,
          before: before ? discountCampaignAdminView(campaignId, before) : {},
          after: result,
        }));
      });
      return result;
    });
  },
);

exports.setDiscountVaultBudgetAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const reason = requiredAdminReason(request.data?.reason);
    return runDiscountAdminCallable(async () => {
      const approvedAmount = normalizeDiscountVaultBudget(
        request.data?.approvedAmount,
      );
      const requestedSalonCreditLimit = request.data &&
        Object.prototype.hasOwnProperty.call(
          request.data,
          "salonCreditLimitAmount",
        ) ?
        normalizeSalonPromotionCreditLimit(request.data.salonCreditLimitAmount) :
        null;
      const requestedSalonDiscountBurnMultiplier = request.data &&
        Object.prototype.hasOwnProperty.call(
          request.data,
          "salonDiscountBurnMultiplier",
        ) ? normalizeSalonDiscountBurnMultiplier(
          request.data.salonDiscountBurnMultiplier,
        ) : null;
      const firestore = admin.firestore();
      const vaultRef = firestore.collection("platformFinance")
        .doc("discountVault");
      const auditRef = firestore.collection("adminAuditLogs").doc();
      let result = null;
      await firestore.runTransaction(async (transaction) => {
        const snapshot = await transaction.get(vaultRef);
        const before = discountVaultAdminView(snapshot.data());
        const committed = before.reservedAmount + before.spentAmount;
        if (approvedAmount < committed) {
          throw new HttpsError(
            "failed-precondition",
            "Approved discount budget cannot be below reserved and spent payout.",
          );
        }
        const salonCreditLimitAmount = requestedSalonCreditLimit ??
          before.salonCreditLimitAmount;
        const salonDiscountBurnMultiplier =
          requestedSalonDiscountBurnMultiplier ??
          before.salonDiscountBurnMultiplier;
        const after = {
          approvedAmount,
          availableAmount: approvedAmount - committed,
          reservedAmount: before.reservedAmount,
          spentAmount: before.spentAmount,
          salonCreditLimitAmount,
          salonDiscountBurnMultiplier,
          budgetVersion: before.budgetVersion + 1,
        };
        const timestamp = admin.firestore.FieldValue.serverTimestamp();
        transaction.set(vaultRef, {
          ...after,
          createdAt: snapshot.data()?.createdAt || timestamp,
          updatedAt: timestamp,
          updatedByAdminUid: adminUid,
        }, {merge: true});
        transaction.create(auditRef, adminAuditRecord({
          adminUid,
          action: "discount.vault_budget_changed",
          targetType: "discountVault",
          targetId: "discountVault",
          reason,
          before,
          after,
        }));
        result = after;
      });
      return result;
    });
  },
);

exports.getProinPhaseOneDataAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    await requirePlatformAdministrator(request);
    return runProinCallable(() => proinBackend.phaseOneSnapshot());
  },
);

exports.upsertProinProgramAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const reason = requiredAdminReason(request.data?.reason);
    return runProinCallable(() => proinBackend.upsertProgram({
      adminUid,
      data: request.data || {},
      reason,
    }));
  },
);

exports.setProinFinanceBudgetAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const reason = requiredAdminReason(request.data?.reason);
    return runProinCallable(() => proinBackend.setFinanceBudget({
      adminUid,
      data: request.data || {},
      reason,
    }));
  },
);

exports.grantProinAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const reason = requiredAdminReason(request.data?.reason);
    return runProinCallable(() => proinBackend.grantAsAdmin({
      adminUid,
      data: request.data || {},
      reason,
    }));
  },
);

exports.upsertProinCouponAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const reason = requiredAdminReason(request.data?.reason);
    return runProinCallable(() => proinBackend.upsertCoupon({
      adminUid,
      data: request.data || {},
      reason,
    }));
  },
);

exports.claimProinCoupon = onMobileCall(
  {invoker: "public", enforceAppCheck: true, cpu: "gcf_gen1"},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    await enforceHourlyAttemptLimit({
      firestore: admin.firestore(),
      collection: "proinCouponAttempts",
      uid,
      limit: PROIN_COUPON_ATTEMPT_LIMIT,
      message: "Too many coupon attempts. Try again later.",
    });
    const result = await runProinCallable(() => proinBackend.claimCoupon({
      uid,
      rawCode: request.data?.couponCode,
    }));
    if (!result.alreadyClaimed && result.amountProin > 0) {
      sendProinRewardNotification({
        recipientUid: uid,
        amountProin: result.amountProin,
        expiresAtMillis: result.expiresAtMillis,
        sourceType: "coupon",
      }).catch((error) => {
        console.error("Proin coupon notification failed", {
          uid,
          error: error.message,
        });
      });
    }
    return result;
  },
);

exports.claimSalonProinCoupon = onMobileCall(
  {invoker: "public", enforceAppCheck: true, cpu: "gcf_gen1"},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    const salonId = requiredId(request.data?.salonId, "salon id");
    await enforceHourlyAttemptLimit({
      firestore: admin.firestore(),
      collection: "salonProinCouponAttempts",
      uid,
      limit: PROIN_COUPON_ATTEMPT_LIMIT,
      message: "Too many coupon attempts. Try again later.",
    });
    const result = await runProinCallable(() => proinBackend.claimCoupon({
      uid,
      salonId,
      rawCode: request.data?.couponCode,
    }));
    if (!result.alreadyClaimed && result.amountProin > 0) {
      await sendProinRewardNotification({
        recipientUid: uid,
        amountProin: result.amountProin,
        expiresAtMillis: result.expiresAtMillis,
        sourceType: "coupon",
      });
    }
    return {
      message: result.alreadyClaimed ?
        "This coupon was already added to this salon." :
        `${result.amountProin} credits added to this salon.`,
      ...result,
    };
  },
);

exports.getCustomerProinWallet = onMobileCall(
  {invoker: "public", enforceAppCheck: true, cpu: "gcf_gen1"},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    return runProinCallable(() => proinBackend.customerWalletData({uid}));
  },
);

exports.getSalonProinWallet = onMobileCall(
  {invoker: "public", enforceAppCheck: true, cpu: "gcf_gen1"},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    const salonId = requiredId(request.data?.salonId, "salon id");
    const salonSnapshot = await admin.firestore()
      .collection("salons").doc(salonId).get();
    if (!salonSnapshot.exists) {
      throw new HttpsError("not-found", "Salon not found.");
    }
    if (String(salonSnapshot.data()?.ownerUid || "").trim() !== uid) {
      throw new HttpsError(
        "permission-denied",
        "Only this salon's owner can view its promotional credits.",
      );
    }
    return runProinCallable(() => proinBackend.salonWalletData({salonId}));
  },
);

exports.getCustomerProinActivity = onMobileCall(
  {invoker: "public", enforceAppCheck: true, cpu: "gcf_gen1"},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    return runProinCallable(() => proinBackend.customerStatementData({
      uid,
      limit: request.data?.limit,
      beforeMillis: request.data?.beforeMillis,
    }));
  },
);

exports.revokeProinAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const reason = requiredAdminReason(request.data?.reason);
    const result = await runProinCallable(() =>
      proinBackend.revokeAvailableLotAsAdmin({
        adminUid,
        data: request.data || {},
        reason,
      }));
    if (!result.duplicate && result.walletType === "customer_rewards" &&
        result.accountId) {
      try {
        await sendToUsers([result.accountId], {
          title: "Proin balance adjusted",
          body: `${result.amountProin} unused Proin was removed from your balance.`,
          data: {
            type: "proin",
            event: "rewardRevoked",
            amountProin: result.amountProin,
            destination: "profile",
          },
          collapseKey: `proin-revoked-${result.lotId}`,
        });
      } catch (error) {
        console.error("Could not send Proin revocation notification", error);
      }
    }
    return result;
  },
);

exports.markProinReimbursementSettledAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const reason = requiredAdminReason(request.data?.reason);
    const result = await runProinCallable(() =>
      proinBackend.settleSalonReimbursementAsAdmin({
        adminUid,
        data: request.data || {},
        reason,
      }));
    if (!result.alreadySettled && result.salonId) {
      try {
        const salonSnapshot = await admin.firestore().collection("salons")
          .doc(result.salonId).get();
        const ownerUid = String(salonSnapshot.data()?.ownerUid || "").trim();
        await sendToUsers([ownerUid].filter(Boolean), {
          title: "Proin reimbursement recorded",
          body: `₹${result.amountInr} has been marked as paid by Pritze.`,
          data: {
            type: "proin",
            event: "reimbursementSettled",
            bookingId: result.bookingId,
            amountInr: result.amountInr,
            destination: "salonOverview",
          },
          collapseKey: `proin-reimbursement-${result.bookingId}`,
        });
      } catch (error) {
        console.error("Could not send Proin settlement notification", error);
      }
    }
    return result;
  },
);

exports.getProinBookingQuote = onMobileCall(
  {invoker: "public", enforceAppCheck: true, cpu: 1},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    const firestore = admin.firestore();
    await enforceHourlyAttemptLimit({
      firestore,
      collection: "proinQuoteAttempts",
      uid,
      limit: PROIN_QUOTE_ATTEMPT_LIMIT,
      message: "Too many Proin price refreshes. Try again later.",
    });
    const salonId = requiredId(request.data?.salonId, "salon id");
    const serviceIds = [...new Set(
      (Array.isArray(request.data?.serviceIds) ? request.data.serviceIds : [])
        .map((value) => String(value ?? "").trim())
        .filter(Boolean),
    )];
    if (serviceIds.length === 0 || serviceIds.length > 6) {
      throw new HttpsError("invalid-argument", "Choose between 1 and 6 services.");
    }
    const [userSnapshot, salonSnapshot] = await Promise.all([
      firestore.collection("users").doc(uid).get(),
      firestore.collection("salons").doc(salonId).get(),
    ]);
    requireStoredRole(userSnapshot.data(), "customer");
    const salon = salonSnapshot.data();
    if (!salon) throw new HttpsError("not-found", "Salon not found.");
    const services = serviceIds.map((id) => findSalonService(salon, id));
    if (services.some((service) => !service || service.isAvailable === false)) {
      throw new HttpsError("failed-precondition", "A service is unavailable.");
    }
    const originalAmount = services.reduce(
      (total, service) => total + money(service.price),
      0,
    );
    const quoteId = String(request.data?.quoteId || "").trim();
    let discountAmount = 0;
    if (quoteId) {
      const quoteSnapshot = await firestore.collection("discountQuotes")
        .doc(quoteId).get();
      const error = lockedDiscountQuoteError({
        quote: quoteSnapshot.data(),
        customerUid: uid,
        salonId,
        serviceIds,
        originalAmount,
        nowMillis: Date.now(),
      });
      if (error) throw new HttpsError("failed-precondition", error);
      discountAmount = money(quoteSnapshot.data()?.discountAmount);
    }
    return runProinCallable(() => proinBackend.quoteBookingRedemption({
      uid,
      salonId,
      serviceIds,
      originalAmount,
      discountAmount,
    }));
  },
);

exports.runProinReconciliationAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const reason = requiredAdminReason(request.data?.reason);
    const result = await runProinCallable(() => proinBackend.reconcile());
    await admin.firestore().collection("adminAuditLogs").add(adminAuditRecord({
      adminUid,
      action: "proin.reconciliation_requested",
      targetType: "platform",
      targetId: "proin",
      reason,
      before: {},
      after: result,
    }));
    return result;
  },
);

exports.runProinReferralAwardBackfillAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const reason = requiredAdminReason(request.data?.reason);
    const result = await scanQualifiedReferralRewards({
      includePreviouslyProcessed: true,
      limit: 500,
    });
    await admin.firestore().collection("adminAuditLogs").add(adminAuditRecord({
      adminUid,
      action: "proin.referral_backfill_requested",
      targetType: "platform",
      targetId: "proin",
      reason,
      before: {},
      after: result,
    }));
    return result;
  },
);

exports.expireProinLots = onSchedule(
  {schedule: "every 15 minutes", timeZone: "Asia/Kolkata", cpu: "gcf_gen1"},
  async () => proinBackend.expireLots(),
);

exports.reconcileProinFinancialState = onSchedule(
  {schedule: "every day 03:15", timeZone: "Asia/Kolkata", cpu: "gcf_gen1"},
  async () => proinBackend.reconcile(),
);

exports.retryPendingProinReferralAwards = onSchedule(
  {schedule: "every 30 minutes", timeZone: "Asia/Kolkata", cpu: "gcf_gen1"},
  async () => scanQualifiedReferralRewards({limit: 100}),
);

exports.sendProinExpiryReminders = onSchedule(
  {
    schedule: "every day 10:00",
    timeZone: "Asia/Kolkata",
    cpu: "gcf_gen1",
  },
  async () => sendProinExpiryReminders(),
);

exports.generateAdminOperationalAlerts = onSchedule(
  {schedule: "every 5 minutes", timeZone: "Asia/Kolkata", cpu: "gcf_gen1"},
  async () => generateAdminOperationalAlerts(),
);

async function generateAdminOperationalAlerts() {
  const firestore = admin.firestore();
  const [bookingsSnapshot, salonsSnapshot, rulesSnapshot, alertsSnapshot] =
    await Promise.all([
      firestore.collection("bookings").limit(2000).get(),
      firestore.collection("salons").limit(500).get(),
      firestore.collection("adminAutomationRules").limit(50).get(),
      firestore.collection("adminOperationalAlerts").limit(500).get(),
    ]);
  const storedRules = Object.fromEntries(rulesSnapshot.docs.map((document) =>
    [document.id, document.data()]));
  const nowMillis = Date.now();
  const alerts = evaluateOperationalAlerts({
    bookings: bookingsSnapshot.docs.map((document) => ({
      id: document.id,
      ...document.data(),
    })),
    salons: salonsSnapshot.docs.map((document) => ({
      id: document.id,
      ...document.data(),
    })),
    storedRules,
    nowMillis,
  });
  const activeIds = new Set();
  const existingAlerts = new Map(alertsSnapshot.docs.map((document) =>
    [document.id, document.data()]));
  const writer = firestore.bulkWriter();
  for (const alert of alerts) {
    const alertId = crypto.createHash("sha256").update(alert.key).digest("hex");
    activeIds.add(alertId);
    const persistedStatus = existingAlerts.get(alertId)?.status ===
      "acknowledged" ? "acknowledged" : "active";
    writer.set(firestore.collection("adminOperationalAlerts").doc(alertId), {
      ...alert,
      status: persistedStatus,
      detectedAt: admin.firestore.Timestamp.fromMillis(alert.detectedAtMillis),
      lastDetectedAt: admin.firestore.FieldValue.serverTimestamp(),
      occurrenceCount: admin.firestore.FieldValue.increment(1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
  }
  let resolvedCount = 0;
  for (const document of alertsSnapshot.docs) {
    if (!activeIds.has(document.id) &&
        ["active", "acknowledged"].includes(document.data()?.status)) {
      resolvedCount += 1;
      writer.update(document.ref, {
        status: "resolved",
        resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
  await writer.close();
  return {activeCount: alerts.length, resolvedCount, scannedAtMillis: nowMillis};
}

async function scanQualifiedReferralRewards({
  includePreviouslyProcessed = false,
  limit = 100,
} = {}) {
  const firestore = admin.firestore();
  let query = firestore.collection("referrals")
    .where("status", "==", "qualified");
  if (!includePreviouslyProcessed) {
    query = query.where("proinAwardPending", "==", true);
  }
  const snapshot = await query.limit(Math.max(1, Math.min(500, limit))).get();
  let processedCount = 0;
  let awardedCount = 0;
  const failures = [];
  for (const document of snapshot.docs) {
    try {
      const result = await processQualifiedReferralRewards(
        document.id,
        document.data(),
      );
      processedCount += 1;
      awardedCount += result.newAwardCount;
    } catch (error) {
      failures.push({
        referralId: document.id,
        message: String(error.message || error).slice(0, 300),
      });
    }
  }
  return {
    scannedCount: snapshot.size,
    processedCount,
    awardedCount,
    failureCount: failures.length,
    failures: failures.slice(0, 20),
  };
}

async function processQualifiedReferralRewards(referralId, suppliedReferral) {
  const firestore = admin.firestore();
  const referralSnapshot = await firestore.collection("referrals")
    .doc(referralId).get();
  const referral = referralSnapshot.data() || suppliedReferral;
  if (!referral || referral.status !== "qualified") {
    return {newAwardCount: 0, pending: false};
  }
  const qualification = await proinReferralQualification(referral);
  if (!qualification.ready) {
    await referralSnapshot.ref.set({
      proinAwardPending: true,
      proinAwardStatus: qualification.status,
      proinAwardLastScannedAt:
        admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    return {newAwardCount: 0, pending: true};
  }
  const programsSnapshot = await firestore.collection("proinPrograms")
    .where("sourceType", "==", qualification.sourceType)
    .where("active", "==", true)
    .limit(50)
    .get();
  const programs = programsSnapshot.docs
    .map((document) => ({id: document.id, ...document.data()}))
    .filter((program) =>
      program.referralTargetRole === referral.referredRole &&
      program.referralInviterRole === referral.inviterRole &&
      program.qualificationEvent === qualification.qualificationEvent &&
      adminMillis(program.startsAt) <= qualification.eligibilityAtMillis &&
      adminMillis(program.endsAt) > qualification.eligibilityAtMillis);

  const existingAwards = Array.isArray(referral.proinAwards) ?
    referral.proinAwards : [];
  const awardsByProgram = new Map(existingAwards.map((award) =>
    [String(award?.programId || ""), award]));
  const failures = [];
  let newAwardCount = 0;
  for (const program of programs) {
    try {
      const recipient = await proinReferralRecipient({
        program,
        referral,
        qualification,
      });
      if (!recipient.ready) {
        failures.push({programId: program.id, message: recipient.status});
        continue;
      }
      const result = await runProinCallable(() =>
        proinBackend.grantQualifiedEvent({
          data: {
            programId: program.id,
            walletType: recipient.walletType,
            accountId: recipient.accountId,
            sourceId: referralId,
            idempotencyKey:
              `referral:${referralId}:${program.id}:${program.rewardRecipient}`,
            expectedSourceType: qualification.sourceType,
            expectedQualificationEvent: qualification.qualificationEvent,
            eligibilityAtMillis: qualification.eligibilityAtMillis,
          },
        }));
      awardsByProgram.set(program.id, {
        programId: program.id,
        recipient: String(program.rewardRecipient || ""),
        walletType: recipient.walletType,
        lotId: result.lotId,
        amountProin: result.amountProin,
        expiresAtMillis: result.expiresAtMillis,
      });
      if (!result.duplicate) {
        newAwardCount += 1;
        await sendProinRewardNotification({
          recipientUid: recipient.recipientUserUid,
          amountProin: result.amountProin,
          expiresAtMillis: result.expiresAtMillis,
          sourceType: qualification.sourceType,
        });
      }
    } catch (error) {
      failures.push({
        programId: program.id,
        message: String(error.message || error).slice(0, 300),
      });
    }
  }
  const hasConfiguredPrograms = programs.length > 0;
  const pending = !hasConfiguredPrograms || failures.length > 0;
  await referralSnapshot.ref.set({
    proinAwardPending: pending,
    proinAwardStatus: pending ?
      (hasConfiguredPrograms ? "partial_or_retry" : "waiting_for_program") :
      "awarded",
    proinAwards: [...awardsByProgram.values()].slice(0, 20),
    proinAwardFailureCount: failures.length,
    proinAwardFailures: failures.slice(0, 10),
    proinAwardLastScannedAt: admin.firestore.FieldValue.serverTimestamp(),
    ...(pending ? {} : {
      proinAwardProcessedAt: admin.firestore.FieldValue.serverTimestamp(),
    }),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});
  return {newAwardCount, pending, failureCount: failures.length};
}

async function awardDiscountCashbackForCompletedBooking(
  bookingId,
  suppliedBooking = null,
) {
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const snapshot = suppliedBooking ? null : await bookingRef.get();
  const booking = suppliedBooking || snapshot?.data();
  if (!booking || booking.status !== "completed" ||
      booking.discountCashbackStatus !== "pending") {
    return {awarded: false, duplicate: false};
  }
  const amountProin = money(booking.cashbackProinAmount);
  const programId = adminString(booking.cashbackProgramId);
  const customerUid = adminString(booking.customerUid);
  if (amountProin <= 0 || !programId || !customerUid) {
    await bookingRef.set({
      discountCashbackStatus: "none",
      discountCashbackLastError: "Invalid cashback booking fields.",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    return {awarded: false, duplicate: false};
  }
  try {
    const result = await runProinCallable(() =>
      proinBackend.grantQualifiedEvent({
        data: {
          programId,
          walletType: "customer_rewards",
          accountId: customerUid,
          sourceId: bookingId,
          idempotencyKey: `discount-cashback:${bookingId}:${programId}`,
          expectedSourceType: "promotion",
          expectedQualificationEvent: "campaign_award",
          rewardAmountProin: amountProin,
          rewardValidityDays: money(booking.cashbackValidityDays),
          // A scheduled booking can complete after the campaign window. The
          // locked booking was created while eligible, so qualify by creation.
          eligibilityAtMillis: adminMillis(booking.createdAt) || Date.now(),
        },
      }),
    );
    await bookingRef.set({
      discountCashbackStatus: "awarded",
      discountCashbackAwardLotId: result.lotId,
      discountCashbackAwardedProin: result.amountProin,
      discountCashbackExpiresAtMillis: result.expiresAtMillis,
      discountCashbackLastError: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    if (!result.duplicate) {
      await sendProinRewardNotification({
        recipientUid: customerUid,
        amountProin: result.amountProin,
        expiresAtMillis: result.expiresAtMillis,
        sourceType: "promotion",
      });
    }
    return {awarded: true, duplicate: result.duplicate === true};
  } catch (error) {
    await bookingRef.set({
      discountCashbackStatus: "pending",
      discountCashbackLastError: String(error.message || error).slice(0, 500),
      discountCashbackLastAttemptAt:
        admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    throw error;
  }
}

async function proinReferralQualification(referral) {
  const firestore = admin.firestore();
  if (referral.referredRole === "customer") {
    const bookingId = String(referral.qualificationBookingId || "").trim();
    if (!bookingId) {
      return {ready: false, status: "waiting_for_completed_booking"};
    }
    const bookingSnapshot = await firestore.collection("bookings")
      .doc(bookingId).get();
    const booking = bookingSnapshot.data();
    if (!booking || booking.status !== "completed" ||
        booking.customerUid !== referral.referredUid) {
      return {ready: false, status: "qualification_booking_not_valid"};
    }
    return {
      ready: true,
      sourceType: "referral_customer",
      qualificationEvent: "first_completed_booking",
      eligibilityAtMillis: adminMillis(booking.completedAt) ||
        adminMillis(referral.qualifiedAt) || Date.now(),
      qualificationSalon: null,
    };
  }
  if (referral.referredRole !== "owner") {
    return {ready: false, status: "unsupported_referral_role"};
  }
  let salonId = String(referral.qualificationSalonId || "").trim();
  if (!salonId) {
    const salonSnapshot = await firestore.collection("salons")
      .where("ownerUid", "==", referral.referredUid).limit(1).get();
    salonId = salonSnapshot.docs[0]?.id || "";
  }
  if (!salonId) {
    return {ready: false, status: "waiting_for_referred_salon"};
  }
  const salonSnapshot = await firestore.collection("salons").doc(salonId).get();
  const salon = salonSnapshot.data();
  if (!salon || salon.ownerUid !== referral.referredUid ||
      salon.proinReferralApproved !== true || salon.adminSuspended === true) {
    return {ready: false, status: "waiting_for_admin_approval"};
  }
  const completedSnapshot = await firestore.collection("bookings")
    .where("salonId", "==", salonId)
    .where("status", "==", "completed")
    .orderBy("completedAt", "asc")
    .limit(1)
    .get();
  const completedBooking = completedSnapshot.docs[0]?.data();
  if (!completedBooking) {
    return {ready: false, status: "waiting_for_first_completed_booking"};
  }
  return {
    ready: true,
    sourceType: "referral_salon",
    qualificationEvent: "salon_approved_and_first_completed_booking",
    eligibilityAtMillis: adminMillis(completedBooking.completedAt) ||
      adminMillis(completedBooking.updatedAt) || Date.now(),
    qualificationSalon: {id: salonId, ...salon},
  };
}

async function proinReferralRecipient({program, referral, qualification}) {
  const rewardRecipient = String(program.rewardRecipient || "");
  const role = rewardRecipient === "inviter" ?
    referral.inviterRole : referral.referredRole;
  const userUid = rewardRecipient === "inviter" ?
    referral.inviterUid : referral.referredUid;
  if (!userUid || !["customer", "owner"].includes(role)) {
    return {ready: false, status: "reward_recipient_not_valid"};
  }
  if (role === "customer") {
    if (program.walletType !== "customer_rewards") {
      return {ready: false, status: "customer_wallet_type_mismatch"};
    }
    const userSnapshot = await admin.firestore().collection("users")
      .doc(userUid).get();
    if (userSnapshot.data()?.role !== "customer") {
      return {ready: false, status: "customer_account_not_found"};
    }
    return {
      ready: true,
      walletType: "customer_rewards",
      accountId: userUid,
      recipientUserUid: userUid,
    };
  }
  if (program.walletType !== "salon_promotion_credits") {
    return {ready: false, status: "salon_wallet_type_mismatch"};
  }
  let salon = rewardRecipient === "referred" ?
    qualification.qualificationSalon : null;
  if (!salon) {
    const salonSnapshot = await admin.firestore().collection("salons")
      .where("ownerUid", "==", userUid).limit(10).get();
    const document = salonSnapshot.docs.find((candidate) =>
      candidate.data()?.proinReferralApproved === true &&
      candidate.data()?.adminSuspended !== true);
    salon = document ? {id: document.id, ...document.data()} : null;
  }
  if (!salon?.id) {
    return {ready: false, status: "approved_salon_account_not_found"};
  }
  return {
    ready: true,
    walletType: "salon_promotion_credits",
    accountId: salon.id,
    recipientUserUid: userUid,
  };
}

async function sendProinRewardNotification({
  recipientUid,
  amountProin,
  expiresAtMillis,
  sourceType,
}) {
  if (!recipientUid || amountProin <= 0) return;
  const expiry = new Intl.DateTimeFormat("en-IN", {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "Asia/Kolkata",
  }).format(new Date(expiresAtMillis));
  await sendToUsers([recipientUid], {
    title: `You earned ${amountProin} Proin`,
    body: `Your reward is available until ${expiry}.`,
    data: {
      type: "proin",
      event: "rewardGranted",
      sourceType,
      amountProin,
      expiresAtMillis,
      destination: "profile",
    },
    collapseKey: `proin-reward-${sourceType}-${recipientUid}`,
  });
}

async function sendProinExpiryReminders() {
  const firestore = admin.firestore();
  const nowMillis = Date.now();
  const horizonMillis = nowMillis + 30 * 24 * 60 * 60 * 1000;
  const snapshot = await firestore.collection("proinLots")
    .where("status", "==", "active")
    .where("expiresAt", ">", admin.firestore.Timestamp.fromMillis(nowMillis))
    .where(
      "expiresAt",
      "<=",
      admin.firestore.Timestamp.fromMillis(horizonMillis),
    )
    .orderBy("expiresAt", "asc")
    .limit(2000)
    .get();
  let sentCount = 0;
  const failures = [];
  for (const document of snapshot.docs) {
    try {
      if (await sendClaimedProinExpiryReminder(document.ref, nowMillis)) {
        sentCount += 1;
      }
    } catch (error) {
      failures.push({lotId: document.id, message: String(error.message)});
    }
  }
  return {
    scannedCount: snapshot.size,
    sentCount,
    failureCount: failures.length,
    failures: failures.slice(0, 20),
  };
}

async function sendClaimedProinExpiryReminder(lotRef, nowMillis) {
  const firestore = admin.firestore();
  let claimedLot = null;
  let reminderTier = 0;
  let sentField = "";
  let claimField = "";
  const claimed = await firestore.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(lotRef);
    const lot = snapshot.data();
    const remainingMillis = adminMillis(lot?.expiresAt) - nowMillis;
    if (!lot || lot.status !== "active" || lot.availableProin <= 0 ||
        remainingMillis <= 0) {
      return false;
    }
    reminderTier = remainingMillis <= 24 * 60 * 60 * 1000 ? 1 :
      remainingMillis <= 7 * 24 * 60 * 60 * 1000 ? 7 : 30;
    sentField = `expiryReminder${reminderTier}dSentAt`;
    claimField = `expiryReminder${reminderTier}dClaimedAt`;
    if (lot[sentField]) return false;
    const previousClaimMillis = adminMillis(lot[claimField]);
    if (previousClaimMillis > nowMillis - 6 * 60 * 60 * 1000) return false;
    claimedLot = {id: snapshot.id, ...lot};
    transaction.update(lotRef, {
      [claimField]: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });
  if (!claimed || !claimedLot) return false;
  try {
    let recipientUid = claimedLot.accountId;
    if (claimedLot.walletType === "salon_promotion_credits") {
      const salonSnapshot = await firestore.collection("salons")
        .doc(claimedLot.accountId).get();
      recipientUid = String(salonSnapshot.data()?.ownerUid || "").trim();
    }
    if (!recipientUid) throw new Error("Proin reminder recipient not found.");
    const remainingDays = Math.max(1, Math.ceil(
      (adminMillis(claimedLot.expiresAt) - nowMillis) /
        (24 * 60 * 60 * 1000),
    ));
    await sendToUsers([recipientUid], {
      title: `${claimedLot.availableProin} Proin expiring soon`,
      body: `Use your Proin within ${remainingDays} day${
        remainingDays === 1 ? "" : "s"}.`,
      data: {
        type: "proin",
        event: "expiryReminder",
        lotId: claimedLot.id,
        amountProin: claimedLot.availableProin,
        reminderTier,
        expiresAtMillis: adminMillis(claimedLot.expiresAt),
        destination: "profile",
      },
      collapseKey: `proin-expiry-${claimedLot.id}-${reminderTier}`,
    });
    await lotRef.update({
      [sentField]: admin.firestore.FieldValue.serverTimestamp(),
      [claimField]: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  } catch (error) {
    await lotRef.update({
      [claimField]: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    throw error;
  }
}

exports.sendAdminEmailOtp = onCall(
  {
    invoker: "public",
    enforceAppCheck: false,
    cpu: "gcf_gen1",
    secrets: [smtpHost, smtpPort, smtpUser, smtpPass, smtpFrom, otpSecret],
  },
  async (request) => {
    const email = normalizeEmail(request.data?.email);
    if (!isPlatformAdminEmail(email)) {
      throw new HttpsError(
        "permission-denied",
        "This email is not authorized for the Pritze Control Center.",
      );
    }

    const docRef = admin.firestore()
      .collection("adminEmailOtps")
      .doc(emailKey(email));
    const now = Date.now();
    const code = crypto.randomInt(100000, 1000000).toString();
    await admin.firestore().runTransaction(async (transaction) => {
      const snapshot = await transaction.get(docRef);
      const previous = snapshot.data();
      if (
        previous?.sentAt?.toMillis &&
        now - previous.sentAt.toMillis() < EMAIL_RESEND_DELAY_MS
      ) {
        throw new HttpsError(
          "resource-exhausted",
          "Please wait before requesting another code.",
        );
      }
      transaction.set(docRef, {
        email,
        codeHash: hashCode(email, code),
        attempts: 0,
        sentAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt: admin.firestore.Timestamp.fromMillis(now + OTP_TTL_MS),
      });
    });

    try {
      await sendOtpMail(email, code);
    } catch (error) {
      await docRef.delete();
      console.error("sendAdminEmailOtp delivery failed", {
        emailDomain: email.split("@").pop(),
        error: error.message,
      });
      throw new HttpsError(
        "unavailable",
        "The sign-in code could not be sent. Please try again.",
      );
    }
    return {ok: true};
  },
);

exports.verifyAdminEmailOtp = onCall(
  {
    invoker: "public",
    enforceAppCheck: false,
    cpu: "gcf_gen1",
    secrets: [otpSecret],
  },
  async (request) => {
    const email = normalizeEmail(request.data?.email);
    const code = String(request.data?.code ?? "").trim();
    if (!isPlatformAdminEmail(email)) {
      throw new HttpsError(
        "permission-denied",
        "This email is not authorized for the Pritze Control Center.",
      );
    }
    if (!/^\d{6}$/.test(code)) {
      throw new HttpsError("invalid-argument", "Enter the 6-digit code.");
    }

    const docRef = admin.firestore()
      .collection("adminEmailOtps")
      .doc(emailKey(email));
    const verification = await admin.firestore().runTransaction(async (
      transaction,
    ) => {
      const snapshot = await transaction.get(docRef);
      const data = snapshot.data();
      if (!data) {
        return {code: "not-found", message: "Request a new sign-in code."};
      }
      if (!data.expiresAt?.toMillis || data.expiresAt.toMillis() < Date.now()) {
        transaction.delete(docRef);
        return {code: "deadline-exceeded", message: "This code expired."};
      }
      if ((data.attempts ?? 0) >= MAX_ATTEMPTS) {
        transaction.delete(docRef);
        return {
          code: "resource-exhausted",
          message: "Too many attempts. Request a new code.",
        };
      }
      if (data.codeHash !== hashCode(email, code)) {
        transaction.update(docRef, {
          attempts: admin.firestore.FieldValue.increment(1),
        });
        return {code: "permission-denied", message: "Incorrect code."};
      }
      transaction.delete(docRef);
      return {code: "ok", message: ""};
    });
    if (verification.code !== "ok") {
      throw new HttpsError(verification.code, verification.message);
    }

    const user = await getOrCreateEmailUser(email);
    await admin.firestore().collection("platformAdmins").doc(user.uid).set({
      active: true,
      email,
      provisionedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    const customToken = await admin.auth().createCustomToken(user.uid, {
      platformAdmin: true,
      provider: "admin_email_otp",
    });
    return {customToken};
  },
);

exports.signInAdminWithPassword = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const normalizedUserId = normalizeAdminUserId(request.data?.userId);
    const password = normalizeAdminPassword(request.data?.password);
    if (!normalizedUserId || !password) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a valid User ID and password.",
      );
    }

    const firestore = admin.firestore();
    const credentialId = adminCredentialId(normalizedUserId);
    await enforceAdminPasswordAttemptLimit({
      firestore,
      request,
      credentialId,
    });
    const credentialRef = firestore
      .collection("platformAdminCredentials")
      .doc(credentialId);
    const credentialSnapshot = await credentialRef.get();
    const credential = credentialSnapshot.data() || {};
    const lockedUntilMillis = credential.lockedUntil?.toMillis?.() || 0;
    const suppliedPasswordMatches = verifyAdminPassword(
      password,
      credentialSnapshot.exists ?
        credential.passwordHash : DUMMY_ADMIN_PASSWORD_HASH,
    );

    if (credentialSnapshot.exists && lockedUntilMillis > Date.now()) {
      await recordAdminAuthenticationEvent({
        firestore,
        request,
        credentialId,
        outcome: "locked",
      });
      throw new HttpsError(
        "resource-exhausted",
        "Too many attempts. Try again in 15 minutes.",
      );
    }
    if (
      !credentialSnapshot.exists ||
      credential.active !== true ||
      !suppliedPasswordMatches
    ) {
      let accountLocked = false;
      if (credentialSnapshot.exists && credential.active === true) {
        await firestore.runTransaction(async (transaction) => {
          const latestSnapshot = await transaction.get(credentialRef);
          const latest = latestSnapshot.data() || {};
          if (!latestSnapshot.exists || latest.active !== true) return;
          const failure = nextAdminPasswordFailure(latest);
          accountLocked = failure.shouldLock;
          transaction.update(credentialRef, {
            failedAttempts: failure.failedAttempts,
            failureWindowStartedAt: admin.firestore.Timestamp.fromMillis(
              failure.failureWindowStartedAtMillis,
            ),
            lockedUntil: failure.lockedUntilMillis ?
              admin.firestore.Timestamp.fromMillis(
                failure.lockedUntilMillis,
              ) : admin.firestore.FieldValue.delete(),
            lastFailedAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        });
      }
      await recordAdminAuthenticationEvent({
        firestore,
        request,
        credentialId,
        outcome: accountLocked ? "locked" : "denied",
      });
      throw new HttpsError(
        accountLocked ? "resource-exhausted" : "permission-denied",
        accountLocked ?
          "Too many attempts. Try again in 15 minutes." :
          "The User ID or password is incorrect.",
      );
    }

    const authUid = adminString(credential.authUid);
    const displayName = adminString(credential.displayName) || "Pritze Admin";
    if (!authUid) {
      console.error("Administrator credential is missing an Auth UID", {
        credentialId,
      });
      throw new HttpsError(
        "failed-precondition",
        "This administrator account is not ready. Contact the account owner.",
      );
    }
    const platformAdminRef = firestore.collection("platformAdmins").doc(authUid);
    const auditRef = firestore.collection("adminAuditLogs").doc();
    await firestore.runTransaction(async (transaction) => {
      const latestCredential = await transaction.get(credentialRef);
      const platformAdmin = await transaction.get(platformAdminRef);
      if (
        latestCredential.data()?.active !== true ||
        latestCredential.data()?.authUid !== authUid ||
        !platformAdmin.exists ||
        platformAdmin.data()?.active === false
      ) {
        throw new HttpsError(
          "permission-denied",
          "This administrator account is no longer active.",
        );
      }
      transaction.update(credentialRef, {
        failedAttempts: 0,
        failureWindowStartedAt: admin.firestore.FieldValue.delete(),
        lockedUntil: admin.firestore.FieldValue.delete(),
        lastAuthenticatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      transaction.create(auditRef, adminAuditRecord({
        adminUid: authUid,
        action: "administrator.signed_in",
        targetType: "platformAdmin",
        targetId: authUid,
        reason: "Pritze team credential authentication",
        before: {},
        after: {provider: "admin_password"},
      }));
    });

    try {
      await admin.auth().getUser(authUid);
    } catch (error) {
      console.error("Administrator Auth user is unavailable", {
        authUid,
        error: error.message,
      });
      throw new HttpsError(
        "failed-precondition",
        "This administrator account is not ready. Contact the account owner.",
      );
    }
    const customToken = await admin.auth().createCustomToken(authUid, {
      platformAdmin: true,
      provider: "admin_password",
    });
    await recordAdminAuthenticationEvent({
      firestore,
      request,
      credentialId,
      outcome: "success",
      authUid,
    });
    return {customToken, displayName};
  },
);

exports.getDiscountQuote = onMobileCall({
  invoker: "public",
  enforceAppCheck: true,
  cpu: 1,
}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const firestore = admin.firestore();
  if (request.data?.previewOnly !== true) {
    await enforceHourlyAttemptLimit({
      firestore,
      collection: "discountQuoteAttempts",
      uid,
      limit: DISCOUNT_QUOTE_LIMIT,
      message: "Too many price refreshes. Try again later.",
    });
  }
  const checkout = await loadCheckoutDiscountContext(
    firestore,
    uid,
    request.data || {},
  );
  if (request.data?.previewOnly === true) {
    return findBestActiveDiscountQuote(firestore, checkout.context);
  }
  return emptyDiscountQuote(checkout.originalAmount);
});

exports.listCheckoutDiscountOffers = onMobileCall({
  invoker: "public",
  enforceAppCheck: true,
  cpu: 1,
}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const firestore = admin.firestore();
  if (request.data?.prefetchOnly !== true) {
    await enforceHourlyAttemptLimit({
      firestore,
      collection: "discountOfferAttempts",
      uid,
      limit: DISCOUNT_QUOTE_LIMIT,
      message: "Too many offer refreshes. Try again later.",
    });
  }
  const checkout = await loadCheckoutDiscountContext(
    firestore,
    uid,
    request.data || {},
  );
  return {
    offers: await findVisibleCheckoutDiscountOffers(
      firestore,
      checkout.context,
    ),
  };
});

exports.applyVisibleCheckoutDiscount = onMobileCall({
  invoker: "public",
  enforceAppCheck: true,
  cpu: 1,
}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const firestore = admin.firestore();
  const campaignId = requiredId(
    request.data?.campaignId,
    "discount campaign id",
  );
  await enforceHourlyAttemptLimit({
    firestore,
    collection: "checkoutCouponAttempts",
    uid,
    limit: PROIN_COUPON_ATTEMPT_LIMIT,
    message: "Too many offer attempts. Try again later.",
  });
  const checkout = await loadCheckoutDiscountContext(
    firestore,
    uid,
    request.data || {},
  );
  const quote = await findVisibleCheckoutDiscountQuote(
    firestore,
    checkout.context,
    campaignId,
  );
  if (!quote.campaignId) {
    throw new HttpsError(
      "failed-precondition",
      "This offer is no longer available for this booking.",
    );
  }
  const lockedQuote = await persistDiscountQuote(firestore, {
    uid,
    salonId: checkout.salonId,
    serviceIds: checkout.serviceIds,
    originalAmount: checkout.originalAmount,
    quote,
  });
  return {
    benefitType: "discount",
    message: discountBenefitMessage(quote),
    quote: lockedQuote,
  };
});

exports.applyCheckoutCoupon = onMobileCall({
  invoker: "public",
  enforceAppCheck: true,
  cpu: 1,
}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const firestore = admin.firestore();
  const rawCode = String(request.data?.couponCode ?? "").trim();
  const code = normalizeProinCouponCode(rawCode);
  if (!code) {
    throw new HttpsError(
      "invalid-argument",
      "Enter a 4-20 character coupon code with at least one letter.",
    );
  }
  const codeHash = proinCouponHash(code);
  const [proinCouponSnapshot, registrySnapshot] = await Promise.all([
    firestore.collection("proinCoupons").doc(codeHash).get(),
    firestore.collection("voucherCodeRegistry").doc(codeHash).get(),
    enforceHourlyAttemptLimit({
      firestore,
      collection: "checkoutCouponAttempts",
      uid,
      limit: PROIN_COUPON_ATTEMPT_LIMIT,
      message: "Too many coupon attempts. Try again later.",
    }),
  ]);
  if (proinCouponSnapshot.exists) {
    const result = await runProinCallable(() => proinBackend.claimCoupon({
      uid,
      rawCode: code,
    }));
    if (!result.alreadyClaimed && result.amountProin > 0) {
      await sendProinRewardNotification({
        recipientUid: uid,
        amountProin: result.amountProin,
        expiresAtMillis: result.expiresAtMillis,
        sourceType: "coupon",
      });
    }
    return {
      benefitType: "proin",
      message: result.alreadyClaimed ?
        "This Proin coupon was already added to your account." :
        `${result.amountProin} Proin added to your account.`,
      ...result,
    };
  }

  const salonId = requiredId(request.data?.salonId, "salon id");
  const serviceIds = [...new Set(
    (Array.isArray(request.data?.serviceIds) ? request.data.serviceIds : [])
      .map((value) => String(value ?? "").trim())
      .filter(Boolean),
  )];
  if (serviceIds.length === 0 || serviceIds.length > 6) {
    throw new HttpsError("invalid-argument", "Choose between 1 and 6 services.");
  }
  const registry = registrySnapshot.data() || {};
  const registeredCampaignId = registry.kind === "discount" ?
    String(registry.targetId || "").trim() : "";
  const checkoutPromise = loadCheckoutDiscountContext(firestore, uid, {
    salonId,
    serviceIds,
  });
  const fundingPromise = registeredCampaignId ?
    loadVoucherDiscountFunding(
      firestore,
      registeredCampaignId,
      salonId,
      uid,
    ) : null;
  const [checkout, registeredFunding] = await Promise.all([
    checkoutPromise,
    fundingPromise,
  ]);
  const quote = registeredFunding ?
    voucherDiscountQuoteFromFunding(
      checkout.context,
      codeHash,
      registeredFunding,
    ) : await findVoucherDiscountQuote(
      firestore,
      checkout.context,
      codeHash,
    );
  if (!quote.campaignId) {
    throw new HttpsError(
      "failed-precondition",
      "This voucher is invalid, expired, fully used, or not eligible for this booking.",
    );
  }
  const lockedQuote = await persistDiscountQuote(firestore, {
    uid,
    salonId: checkout.salonId,
    serviceIds: checkout.serviceIds,
    originalAmount: checkout.originalAmount,
    quote,
  });
  return {
    benefitType: "discount",
    message: discountBenefitMessage(quote, "Voucher"),
    quote: lockedQuote,
  };
});

exports.createBooking = onMobileCall({
  invoker: "public",
  enforceAppCheck: true,
  cpu: 1,
}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const firestore = admin.firestore();
  const salonId = requiredId(request.data?.salonId, "salon id");
  const isInstant = request.data?.isInstant === true;
  const suppliedServiceIds = Array.isArray(request.data?.serviceIds) ?
    request.data.serviceIds : [];
  const serviceIds = [...new Set([
    ...suppliedServiceIds,
    request.data?.serviceId,
  ].map((value) => String(value ?? "").trim()).filter(Boolean))];
  if (serviceIds.length === 0 || serviceIds.length > 6) {
    throw new HttpsError(
      "invalid-argument",
      "Choose between 1 and 6 services.",
    );
  }
  if (!isInstant && serviceIds.length !== 1) {
    throw new HttpsError(
      "invalid-argument",
      "Scheduled appointments support one service at a time.",
    );
  }
  const serviceId = serviceIds[0];
  const quoteId = String(request.data?.quoteId ?? "").trim();
  const requestedProin = Number(request.data?.requestedProin ?? 0);
  const arrivalMinutes = isInstant ? Number(request.data?.arrivalMinutes) : 0;
  const requestedStartMillis = Number(request.data?.startMillis);
  const requestedBarberId = String(request.data?.barberId ?? "").trim();
  if (isInstant && !INSTANT_ARRIVAL_MINUTES.has(arrivalMinutes)) {
    throw new HttpsError(
      "invalid-argument",
      "Choose an arrival time of 15, 20, or 25 minutes.",
    );
  }
  if (!isInstant && (!requestedBarberId || !Number.isFinite(requestedStartMillis))) {
    throw new HttpsError(
      "invalid-argument",
      "Choose an available barber and appointment time.",
    );
  }

  const userRef = firestore.collection("users").doc(uid);
  const salonRef = firestore.collection("salons").doc(salonId);
  const [userSnapshot, salonSnapshot] = await Promise.all([
    userRef.get(),
    salonRef.get(),
  ]);
  const user = userSnapshot.data();
  const salon = salonSnapshot.data();
  requireStoredRole(user, "customer");
  if (!salon || !isSalonApproved(salon) || salon.isOpen !== true) {
    throw new HttpsError("failed-precondition", "This salon is not bookable.");
  }
  const ownerUid = String(salon.ownerUid ?? "").trim();
  if (!ownerUid) {
    throw new HttpsError(
      "failed-precondition",
      "This salon cannot receive bookings right now.",
    );
  }
  const services = serviceIds.map((id) => findSalonService(salon, id));
  if (services.some((service) => !service || service.isAvailable === false)) {
    throw new HttpsError(
      "failed-precondition",
      "One or more selected services are no longer available.",
    );
  }
  const barbersPromise = firestore.collection("barbers")
    .where("salonId", "==", salonId)
    .get();
  const visitCountsPromise = loadDiscountVisitCounts(
    firestore,
    uid,
    salonId,
    user,
  );
  const journeyCampaignsPromise = quoteId ? null :
    firestore.collection("discountCampaigns")
      .where("active", "==", true)
      .limit(50)
      .get();
  const durationMinutes = services.reduce(
    (total, service) => total + positiveInteger(service.durationMinutes, 30),
    0,
  );
  const nowMillis = Date.now();
  if (isInstant && !isWithinSalonHours({
    startMillis: nowMillis,
    durationMinutes: 1,
    openTime: salon.openTime,
    closeTime: salon.closeTime,
  })) {
    throw new HttpsError(
      "failed-precondition",
      "This salon is currently closed.",
    );
  }
  const startMillis = isInstant ?
    nowMillis + arrivalMinutes * 60 * 1000 : requestedStartMillis;
  if (!isInstant && startMillis <= nowMillis) {
    throw new HttpsError(
      "failed-precondition",
      "Choose a future appointment time.",
    );
  }
  if (!isWithinSalonHours({
    startMillis,
    durationMinutes,
    openTime: salon.openTime,
    closeTime: salon.closeTime,
  })) {
    throw new HttpsError(
      "failed-precondition",
      "This appointment does not fit within salon hours.",
    );
  }

  const barbersSnapshot = await barbersPromise;
  const eligibleBarbers = barbersSnapshot.docs
    .filter((doc) => serviceIds.every((id) => barberCanServe(doc.data(), id)))
    .sort((a, b) => a.id.localeCompare(b.id));
  if (eligibleBarbers.length === 0) {
    throw new HttpsError(
      "failed-precondition",
      "No barber is available for this service.",
    );
  }
  let scheduledBarber = null;
  if (isInstant) {
    if (services.some((service) => service.instantBookingEnabled === false) ||
        !isInstantEnabledForSalon(salon)) {
      throw new HttpsError(
        "failed-precondition",
        "This service is not available for instant booking.",
      );
    }
  } else {
    scheduledBarber = eligibleBarbers.find((doc) => doc.id === requestedBarberId);
    if (!scheduledBarber) {
      throw new HttpsError(
        "failed-precondition",
        "The selected barber is no longer available for this service.",
      );
    }
  }

  const bookingRef = firestore.collection("bookings").doc();
  const activeCustomerRef = firestore
    .collection("activeCustomerBookings")
    .doc(uid);
  const activeInstantRef = firestore
    .collection("activeInstantBookings")
    .doc(uid);
  const lockMillis = isInstant ? [] :
    slotSegmentMillis(startMillis, durationMinutes);
  const lockRefs = lockMillis.map((segmentMillis) => firestore
    .collection("slotLocks")
    .doc(slotLockId(requestedBarberId, segmentMillis)));
  const createdAt = admin.firestore.Timestamp.fromMillis(nowMillis);
  const start = admin.firestore.Timestamp.fromMillis(startMillis);
  const customerName = String(user.name ?? request.auth?.token?.name ?? "Customer")
    .trim() || "Customer";
  const customerPhone = normalizeVerifiedPhone(
    user.phone || user.contact || request.auth?.token?.phone_number,
  );
  if (!customerPhone) {
    throw new HttpsError(
      "failed-precondition",
      "A verified customer phone number is required to book.",
    );
  }
  const servicePrice = services.reduce(
    (total, service) => total + Math.max(0, Number(service.price) || 0),
    0,
  );
  const visitCounts = await visitCountsPromise;
  const discountContext = buildDiscountContext({
    customerUid: uid,
    salonId,
    serviceIds,
    serviceAmounts: Object.fromEntries(
      services.map((service, index) => [
        serviceIds[index],
        Math.max(0, Number(service.price) || 0),
      ]),
    ),
    originalAmount: servicePrice,
    ...visitCounts,
    nowMillis,
  });
  let discountQuote = emptyDiscountQuote(servicePrice);
  if (!quoteId) {
    const campaignsSnapshot = await journeyCampaignsPromise;
    discountQuote = await findBestActiveDiscountQuote(
      firestore,
      discountContext,
      {journeyOnly: true, campaignsSnapshot},
    );
  }
  const quoteRef = quoteId ?
    firestore.collection("discountQuotes").doc(quoteId) : null;
  const booking = {
    salonId,
    serviceId,
    serviceIds,
    barberId: isInstant ? "" : scheduledBarber.id,
    customerUid: uid,
    ownerUid,
    barberUid: isInstant ? null : normalizedOptionalString(scheduledBarber.data().uid),
    customerName,
    customerPhone,
    start,
    durationMinutes,
    serviceName: services
      .map((service) => String(service.name ?? "Service").trim() || "Service")
      .join(", "),
    servicePrice,
    serviceNameBreakdown: Object.fromEntries(services.map((service) => [service.id, service.name])),
    servicePriceBreakdown: Object.fromEntries(
      services.map((service, index) => [
        serviceIds[index],
        money(service.price),
      ]),
    ),
    bookingFee: 0,
    paymentRequired: false,
    paymentStatus: "not_required",
    ...discountBookingFields(discountQuote),
    status: isInstant ? "pending" : "confirmed",
    createdAt,
    isInstant,
    acceptedAt: null,
    arrivalMinutes,
    salonArrivalMinutes: isInstant ? arrivalMinutes + 5 : 0,
    cancellationReason: "",
    cancelledBy: "",
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  await firestore.runTransaction(async (transaction) => {
    const [currentSalonSnapshot, activeCustomer, activeInstant, ...lockSnapshots] =
      await Promise.all([
        transaction.get(salonRef),
        transaction.get(activeCustomerRef),
        transaction.get(activeInstantRef),
        ...lockRefs.map((lockRef) => transaction.get(lockRef)),
      ]);
    // Re-read availability inside the transaction: an owner can switch off
    // while the customer is viewing checkout or while this callable loads.
    const currentSalon = currentSalonSnapshot.data();
    if (!currentSalon || !isSalonApproved(currentSalon) ||
        currentSalon.isOpen !== true) {
      throw new HttpsError("failed-precondition", "This salon is not bookable.");
    }
    if (isInstant && (!isInstantEnabledForSalon(currentSalon) ||
        serviceIds.some((id) => {
          const service = findSalonService(currentSalon, id);
          return !service || service.isAvailable === false ||
            service.instantBookingEnabled === false;
        }))) {
      throw new HttpsError(
        "failed-precondition",
        "This salon is not accepting instant bookings right now.",
      );
    }
    await assertNoBlockingMarker(
      transaction,
      [activeCustomer, activeInstant],
      nowMillis,
    );
    if (lockSnapshots.some((snapshot) =>
      snapshot.exists && snapshot.data()?.active !== false)) {
      throw new HttpsError(
        "already-exists",
        "This slot was just booked. Please choose another time.",
      );
    }

    let lockedQuote = false;
    if (quoteRef) {
      const quoteSnapshot = await transaction.get(quoteRef);
      const quoteData = quoteSnapshot.data();
      const quoteError = lockedDiscountQuoteError({
        quote: quoteData,
        customerUid: uid,
        salonId,
        serviceIds,
        originalAmount: servicePrice,
        nowMillis,
      });
      if (quoteError) {
        throw new HttpsError("failed-precondition", quoteError);
      }
      discountQuote = discountQuoteFromStored(quoteData);
      lockedQuote = true;
    }

    let discountReservation = null;
    let discountFundingState = null;
    if (discountQuote.campaignId) {
      discountReservation = discountReferences(
        firestore,
        discountQuote.campaignId,
        salonId,
        uid,
      );
      const [
        campaignSnapshot,
        campaignUsageSnapshot,
        salonUsageSnapshot,
        customerUsageSnapshot,
        vaultSnapshot,
        salonPromotionWalletSnapshot,
        salonPromotionLotsSnapshot,
      ] = await Promise.all([
        transaction.get(discountReservation.campaignRef),
        transaction.get(discountReservation.campaignUsageRef),
        transaction.get(discountReservation.salonUsageRef),
        transaction.get(discountReservation.customerUsageRef),
        transaction.get(discountReservation.vaultRef),
        transaction.get(discountReservation.salonPromotionWalletRef),
        transaction.get(discountReservation.salonPromotionLotsQuery),
      ]);
      const campaign = campaignSnapshot.data();
      const recalculated = campaign && discountCampaignEligible(
        campaign,
        discountContext,
      ) ? quoteForDiscountCampaign(
        campaignSnapshot.id,
        campaign,
        discountContext,
        vaultSnapshot.data(),
      ) : emptyDiscountQuote(servicePrice);
      const usage = {
        campaign: campaignUsageSnapshot.data(),
        salon: salonUsageSnapshot.data(),
        customer: customerUsageSnapshot.data(),
        vault: vaultSnapshot.data(),
        salonCreditWallet: salonPromotionWalletSnapshot.data(),
      };
      const quoteToReserve = lockedQuote ? discountQuote : recalculated;
      if (!campaign || campaign.active !== true ||
          !discountBudgetAllows(campaign, quoteToReserve, usage)) {
        if (lockedQuote) {
          throw new HttpsError(
            "failed-precondition",
            "This discount is no longer available. Refresh the price before booking.",
          );
        }
        discountQuote = emptyDiscountQuote(servicePrice);
        discountReservation = null;
      } else {
        discountQuote = quoteToReserve;
        discountFundingState = {
          vault: vaultSnapshot.data(),
          salonCreditWallet: salonPromotionWalletSnapshot.data(),
          salonCreditLots: salonPromotionLotsSnapshot.docs.map((document) => ({
            id: document.id,
            ref: document.ref,
            ...document.data(),
          })),
        };
      }
      Object.assign(booking, discountBookingFields(discountQuote));
    }

    booking.discountGlobalTotalsTracked = Boolean(discountReservation);

    const proinFields = await runProinCallable(() =>
      proinBackend.reserveBookingRedemptionInTransaction({
        transaction,
        bookingId: bookingRef.id,
        uid,
        salonId,
        serviceIds,
        originalAmount: servicePrice,
        discountAmount: discountQuote.discountAmount,
        requestedProin,
      }));
    Object.assign(booking, proinFields);

    transaction.create(bookingRef, booking);
    if (quoteRef) {
      transaction.update(quoteRef, {
        consumedAt: admin.firestore.FieldValue.serverTimestamp(),
        consumedByBookingId: bookingRef.id,
      });
    }
    if (discountReservation) {
      reserveDiscountInTransaction(
        transaction,
        discountReservation,
        discountQuote,
        {
          bookingId: bookingRef.id,
          salonId,
          customerUid: uid,
          fundingState: discountFundingState,
        },
      );
    }
    transaction.set(activeCustomerRef, activeBookingMarker({
      bookingId: bookingRef.id,
      salonId,
      customerUid: uid,
      isInstant,
      createdAt,
    }));
    transaction.set(activeInstantRef, isInstant ? activeBookingMarker({
      bookingId: bookingRef.id,
      salonId,
      customerUid: uid,
      isInstant: true,
      createdAt,
    }) : {
      active: false,
      customerUid: uid,
      resolvedStatus: "not_instant",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    for (let index = 0; index < lockRefs.length; index += 1) {
      transaction.set(lockRefs[index], slotLockData({
        bookingId: bookingRef.id,
        salonId,
        serviceId,
        barberId: requestedBarberId,
        segmentMillis: lockMillis[index],
        bookingStartMillis: startMillis,
        createdAt,
      }));
    }
  });

  // Return the committed booking so the mobile app does not need a second
  // cross-region Firestore read immediately after this callable completes.
  // Firestore Timestamp/FieldValue objects are converted or removed to keep
  // the callable payload deterministic on every client SDK.
  const callableBooking = {...booking};
  callableBooking.start = startMillis;
  callableBooking.createdAt = nowMillis;
  delete callableBooking.updatedAt;
  return {bookingId: bookingRef.id, booking: callableBooking};
});

// Full vCPU: this carries accept, reject, start service and end service, so
// a person is waiting on it every time it runs. "gcf_gen1" caps the
// container at a sixth of a core, which dominated the wait on a cold start.
exports.updateBookingStatus = onMobileCall({
  invoker: "public",
  enforceAppCheck: true,
  cpu: 1,
}, (request) => updateBookingStatusHandler(request));

exports.updateBookingStatusAsAdmin = onCall({
  invoker: "public",
  enforceAppCheck: false,
  cpu: "gcf_gen1",
}, (request) => updateBookingStatusHandler(request, {platformAdmin: true}));

// Full vCPU: the customer taps this on the way to the salon and watches for
// the owner's acknowledgement.
exports.updateCustomerArrivalStatus = onMobileCall({
  invoker: "public",
  enforceAppCheck: true,
  cpu: 1,
}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const bookingId = requiredId(request.data?.bookingId, "booking id");
  const arrivalStatus = String(request.data?.arrivalStatus ?? "").trim();
  if (!validArrivalStatus(arrivalStatus)) {
    throw new HttpsError("invalid-argument", "Invalid arrival status.");
  }
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const sessionRef = firestore.collection("bookingArrivalSessions").doc(bookingId);
  let bookingForNotification = null;
  await firestore.runTransaction(async (transaction) => {
    const bookingSnapshot = await transaction.get(bookingRef);
    const booking = bookingSnapshot.data();
    requireCustomerArrivalBooking(booking, uid);
    const stopSharing = arrivalStatus === "arrived" ||
      arrivalStatus === "notStarted";
    transaction.update(bookingRef, {
      arrivalStatus,
      arrivalStatusUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(stopSharing ? {
        arrivalSharingActive: false,
        arrivalSharingExpiresAt: admin.firestore.FieldValue.delete(),
      } : {}),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (stopSharing) {
      transaction.set(sessionRef, {
        bookingId,
        customerUid: uid,
        sharingActive: false,
        stoppedReason: arrivalStatus,
        stoppedAt: admin.firestore.FieldValue.serverTimestamp(),
        ...customerArrivalLocationDeletes(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
    }
    bookingForNotification = {...booking, arrivalStatus};
  });
  const hydrated = await hydrateBookingRecipients(bookingForNotification);
  await sendToUsers(
    [hydrated?.ownerUid, hydrated?.barberUid].filter(Boolean),
    {
      title: "Customer arrival update",
      body: `${hydrated?.customerName || "Customer"}: ` +
        customerArrivalStatusLabel(arrivalStatus),
      data: {
        type: "customerArrival",
        bookingId,
        salonId: hydrated?.salonId || "",
        arrivalStatus,
        destination: "bookings",
      },
      collapseKey: `arrival-${bookingId}`,
    },
  );
  return {bookingId, arrivalStatus};
});

exports.startCustomerArrivalSharing = onMobileCall({
  invoker: "public",
  enforceAppCheck: true,
  cpu: "gcf_gen1",
}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const bookingId = requiredId(request.data?.bookingId, "booking id");
  const location = customerLocationPayload(request.data);
  const nowMillis = Date.now();
  if (!validLocationUpdate({...location, nowMillis})) {
    throw new HttpsError("invalid-argument", "Location is invalid or too old.");
  }
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const sessionRef = firestore.collection("bookingArrivalSessions").doc(bookingId);
  let result = null;
  await firestore.runTransaction(async (transaction) => {
    const bookingSnapshot = await transaction.get(bookingRef);
    const booking = bookingSnapshot.data();
    requireCustomerArrivalBooking(booking, uid);
    const startMillis = booking.start?.toMillis?.() || 0;
    if (startMillis <= 0 || nowMillis < startMillis - 2 * 60 * 60 * 1000) {
      throw new HttpsError(
        "failed-precondition",
        "Live arrival sharing opens two hours before the booking.",
      );
    }
    const expiresAtMillis = sharingExpiresAtMillis({
      nowMillis,
      bookingStartMillis: startMillis,
      durationMinutes: booking.durationMinutes,
    });
    if (expiresAtMillis <= nowMillis) {
      throw new HttpsError("failed-precondition", "This booking has ended.");
    }
    const salonSnapshot = await transaction.get(
      firestore.collection("salons").doc(String(booking.salonId || "")),
    );
    const salon = salonSnapshot.data() || {};
    const metrics = customerArrivalMetrics(location, salon);
    const expiresAt = admin.firestore.Timestamp.fromMillis(expiresAtMillis);
    transaction.set(sessionRef, {
      bookingId,
      customerUid: uid,
      salonId: String(booking.salonId || ""),
      sharingActive: true,
      startedAt: admin.firestore.FieldValue.serverTimestamp(),
      expiresAt,
      latestLatitude: location.latitude,
      latestLongitude: location.longitude,
      accuracyMeters: location.accuracyMeters,
      speedMetersPerSecond: location.speedMetersPerSecond,
      lastLocationAt: admin.firestore.Timestamp.fromMillis(
        location.capturedAtMillis,
      ),
      ...metrics,
      stoppedReason: "",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    transaction.update(bookingRef, {
      arrivalStatus: booking.arrivalStatus === "runningLate" ?
        "runningLate" : "onTheWay",
      arrivalStatusUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
      arrivalSharingActive: true,
      arrivalSharingExpiresAt: expiresAt,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    result = {bookingId, expiresAtMillis, ...metrics};
  });
  return result;
});

exports.updateCustomerArrivalLocation = onMobileCall({
  invoker: "public",
  enforceAppCheck: true,
  cpu: "gcf_gen1",
}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const bookingId = requiredId(request.data?.bookingId, "booking id");
  const location = customerLocationPayload(request.data);
  const nowMillis = Date.now();
  if (!validLocationUpdate({...location, nowMillis})) {
    throw new HttpsError("invalid-argument", "Location is invalid or too old.");
  }
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const sessionRef = firestore.collection("bookingArrivalSessions").doc(bookingId);
  let result = null;
  await firestore.runTransaction(async (transaction) => {
    const [bookingSnapshot, sessionSnapshot] = await Promise.all([
      transaction.get(bookingRef),
      transaction.get(sessionRef),
    ]);
    const booking = bookingSnapshot.data();
    const session = sessionSnapshot.data();
    requireCustomerArrivalBooking(booking, uid);
    if (!session || session.customerUid !== uid ||
        session.sharingActive !== true ||
        (session.expiresAt?.toMillis?.() || 0) <= nowMillis) {
      throw new HttpsError("failed-precondition", "Location sharing is not active.");
    }
    const salonSnapshot = await transaction.get(
      firestore.collection("salons").doc(String(booking.salonId || "")),
    );
    const metrics = customerArrivalMetrics(
      location,
      salonSnapshot.data() || {},
    );
    transaction.update(sessionRef, {
      latestLatitude: location.latitude,
      latestLongitude: location.longitude,
      accuracyMeters: location.accuracyMeters,
      speedMetersPerSecond: location.speedMetersPerSecond,
      lastLocationAt: admin.firestore.Timestamp.fromMillis(
        location.capturedAtMillis,
      ),
      ...metrics,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    result = {bookingId, ...metrics};
  });
  return result;
});

exports.stopCustomerArrivalSharing = onMobileCall({
  invoker: "public",
  enforceAppCheck: true,
  cpu: "gcf_gen1",
}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const bookingId = requiredId(request.data?.bookingId, "booking id");
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const sessionRef = firestore.collection("bookingArrivalSessions").doc(bookingId);
  await firestore.runTransaction(async (transaction) => {
    const bookingSnapshot = await transaction.get(bookingRef);
    const booking = bookingSnapshot.data();
    if (!booking) throw new HttpsError("not-found", "Booking not found.");
    if (booking.customerUid !== uid) {
      throw new HttpsError("permission-denied", "Not allowed.");
    }
    transaction.update(bookingRef, {
      arrivalSharingActive: false,
      arrivalSharingExpiresAt: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    transaction.set(sessionRef, {
      bookingId,
      customerUid: uid,
      sharingActive: false,
      stoppedReason: "customer",
      stoppedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...customerArrivalLocationDeletes(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
  });
  return {bookingId, sharingActive: false};
});

exports.updateBookingExtraServices = onMobileCall({enforceAppCheck: true, invoker: "public", cpu: 1}, (request) =>
  updateBookingExtraServices({uid: requireAuthenticatedUid(request), data: request.data,
    firestore: admin.firestore(), Timestamp: admin.firestore.Timestamp}));

async function updateBookingStatusHandler(
  request,
  {platformAdmin = false, systemActor = false} = {},
) {
  const uid = systemActor ? "system" : platformAdmin ?
    await requirePlatformAdministrator(request) :
    requireAuthenticatedUid(request);
  const bookingId = requiredId(request.data?.bookingId, "booking id");
  const nextStatus = String(request.data?.status ?? "").trim();
  const adminReason = platformAdmin ?
    requiredAdminReason(request.data?.reason) : "";
  const allowedStatuses = new Set([
    "confirmed",
    "inProgress",
    "completed",
    "cancelled",
    "rejected",
  ]);
  if (!allowedStatuses.has(nextStatus)) {
    throw new HttpsError("invalid-argument", "Invalid booking status.");
  }
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const auditRef = platformAdmin ?
    firestore.collection("adminAuditLogs").doc() : null;
  const initialBookingSnapshot = await bookingRef.get();
  const initialBooking = initialBookingSnapshot.data();
  if (!initialBooking) {
    throw new HttpsError("not-found", "Booking not found.");
  }
  let instantCandidates = [];
  if (
    initialBooking.isInstant === true &&
    initialBooking.status === "pending" &&
    nextStatus === "confirmed"
  ) {
    const barbers = await firestore.collection("barbers")
      .where("salonId", "==", initialBooking.salonId)
      .get();
    instantCandidates = barbers.docs
      .filter((doc) => bookingServiceIds(initialBooking)
        .every((serviceId) => barberCanServe(doc.data(), serviceId)))
      .sort((a, b) => a.id.localeCompare(b.id));
  }

  const nowMillis = Date.now();
  const acceptedStartMillis =
    initialBooking.isInstant === true &&
    initialBooking.status === "pending" &&
    nextStatus === "confirmed" ?
      nowMillis + positiveInteger(initialBooking.arrivalMinutes, 15) * 60 * 1000 :
      initialBooking.start?.toMillis?.();
  const cancellationReason = String(request.data?.cancellationReason ?? "")
    .trim();
  let actorRole = "";
  let updatedBooking = null;
  let statusChanged = false;
  let proinWalletToRefresh = "";
  await firestore.runTransaction(async (transaction) => {
    statusChanged = false;
    proinWalletToRefresh = "";
    const actorRef = platformAdmin || systemActor ? null :
      firestore.collection("users").doc(uid);
    const initialReads = await Promise.all([
      transaction.get(bookingRef),
      ...(actorRef ? [transaction.get(actorRef)] : []),
    ]);
    const bookingSnapshot = initialReads[0];
    const actorSnapshot = actorRef ? initialReads[1] : null;
    const booking = bookingSnapshot.data();
    if (!booking) {
      throw new HttpsError("not-found", "Booking not found.");
    }
    if (booking.status === nextStatus) {
      updatedBooking = booking;
      return;
    }
    actorRole = systemActor ? "admin" : platformAdmin ?
      "admin" : normalizeRole(actorSnapshot.data()?.role) || "";
    if (
      (actorRole === "customer" && booking.customerUid !== uid) ||
      (actorRole === "owner" && booking.ownerUid !== uid) ||
      !["customer", "owner", "admin"].includes(actorRole)
    ) {
      throw new HttpsError("permission-denied", "Not allowed.");
    }
    const transitionError = bookingTransitionError({
      booking,
      actorRole,
      nextStatus,
      nowMillis,
    });
    if (transitionError) {
      throw new HttpsError("failed-precondition", transitionError);
    }
    // A service addition can extend the deadline after the scheduler's query.
    if (systemActor && nextStatus === "completed" && !shouldAutoCompleteService(booking, nowMillis)) {
      updatedBooking = booking;
      return;
    }
    statusChanged = true;

    let assignedBarber = null;
    const lockReads = new Map();
    if (
      booking.isInstant === true &&
      booking.status === "pending" &&
      nextStatus === "confirmed"
    ) {
      const candidateLockRefs = instantCandidates.flatMap((barber) =>
        slotSegmentMillis(
          acceptedStartMillis,
          positiveInteger(booking.durationMinutes, 30),
        ).map((segmentMillis) => firestore.collection("slotLocks")
          .doc(slotLockId(barber.id, segmentMillis))),
      );
      const uniqueLockRefs = [...new Map(candidateLockRefs.map((ref) =>
        [ref.path, ref])).values()];
      const candidateLockSnapshots = await Promise.all(
        uniqueLockRefs.map((ref) => transaction.get(ref)),
      );
      for (const snapshot of candidateLockSnapshots) {
        lockReads.set(snapshot.ref.path, snapshot);
      }
      for (const barber of instantCandidates) {
        const candidateLocks = slotSegmentMillis(
          acceptedStartMillis,
          positiveInteger(booking.durationMinutes, 30),
        ).map((segmentMillis) => lockReads.get(
          firestore.collection("slotLocks")
            .doc(slotLockId(barber.id, segmentMillis)).path,
        ));
        if (candidateLocks.every((snapshot) =>
          !snapshot?.exists || snapshot.data()?.active === false ||
          snapshot.data()?.bookingId === bookingId)) {
          assignedBarber = barber;
          break;
        }
      }
      if (!assignedBarber) {
        throw new HttpsError(
          "resource-exhausted",
          "No barber is free for this instant booking. Reject the request.",
        );
      }
    }

    const shouldReleaseLocks = ["cancelled", "rejected", "completed"]
      .includes(nextStatus);
    const previousLockRefs = [];
    const previousLockSnapshots = [];
    if (shouldReleaseLocks && String(booking.barberId ?? "").trim()) {
      for (const segmentMillis of slotSegmentMillis(
        booking.start.toMillis(),
        positiveInteger(booking.durationMinutes, 30),
      )) {
        const lockRef = firestore.collection("slotLocks")
          .doc(slotLockId(booking.barberId, segmentMillis));
        previousLockRefs.push(lockRef);
        const cached = lockReads.get(lockRef.path);
        previousLockSnapshots.push(cached || await transaction.get(lockRef));
      }
    }
    if (shouldReleaseLocks) {
      for (const lockId of booking.extraSlotLockIds || []) {
        const lockRef = firestore.collection("slotLocks").doc(lockId);
        if (!previousLockRefs.some((ref) => ref.path === lockRef.path)) {
          previousLockRefs.push(lockRef);
          previousLockSnapshots.push(await transaction.get(lockRef));
        }
      }
    }
    const activeCustomerRef = firestore.collection("activeCustomerBookings")
      .doc(booking.customerUid);
    const activeInstantRef = firestore.collection("activeInstantBookings")
      .doc(booking.customerUid);
    const isTerminal = ["cancelled", "rejected", "completed"]
      .includes(nextStatus);
    const shouldStopArrivalSharing = isTerminal || nextStatus === "inProgress";
    const activeCustomerSnapshot = isTerminal ?
      await transaction.get(activeCustomerRef) : null;
    const activeInstantSnapshot = isTerminal && booking.isInstant === true ?
      await transaction.get(activeInstantRef) : null;
    let discountResolution = null;
    if (isTerminal &&
        booking.discountStatus === "reserved" &&
        String(booking.discountCampaignId ?? "").trim()) {
      const refs = discountReferences(
        firestore,
        booking.discountCampaignId,
        booking.salonId,
        booking.customerUid,
      );
      await transaction.get(refs.campaignUsageRef);
      await transaction.get(refs.salonUsageRef);
      await transaction.get(refs.customerUsageRef);
      const fundingState = await readDiscountResolutionFundingState({
        transaction,
        firestore,
        refs,
        booking,
        bookingId,
      });
      discountResolution = {
        refs,
        outcome: nextStatus === "completed" ? "redeemed" : "released",
        fundingState,
      };
    }
    let qualifyingCustomerReferral = null;
    if (nextStatus === "completed") {
      const referralRef = firestore.collection("referrals")
        .doc(booking.customerUid);
      const referralSnapshot = await transaction.get(referralRef);
      const referral = referralSnapshot.data();
      if (referral?.status === "pending" &&
          referral.referredRole === "customer") {
        qualifyingCustomerReferral = {ref: referralRef, data: referral};
      }
    }

    let proinResolutionFields = null;
    if (isTerminal && booking.proinStatus === "reserved") {
      const resolution = await runProinCallable(() =>
        proinBackend.resolveBookingRedemptionInTransaction({
          transaction,
          bookingId,
          booking,
          outcome: nextStatus === "completed" ? "redeemed" : "released",
          nowMillis,
        }));
      if (resolution) {
        const {walletId, ...bookingFields} = resolution;
        proinWalletToRefresh = walletId;
        proinResolutionFields = bookingFields;
      }
    }

    const update = {
      status: nextStatus,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(proinResolutionFields || {}),
      ...(shouldStopArrivalSharing ? {
        arrivalSharingActive: false,
        arrivalSharingExpiresAt: admin.firestore.FieldValue.delete(),
      } : {}),
    };
    if (nextStatus === "confirmed" && booking.status === "pending") {
      update.acceptedAt = admin.firestore.FieldValue.serverTimestamp();
      update.start = admin.firestore.Timestamp.fromMillis(acceptedStartMillis);
      update.customerArrivalReminderSentAt = null;
      update.ownerArrivalReminderSentAt = null;
      update.barberId = assignedBarber.id;
      update.barberUid = normalizedOptionalString(assignedBarber.data().uid);
    }
    if (nextStatus === "inProgress") {
      update.startedAt = admin.firestore.FieldValue.serverTimestamp();
      update.autoCompleteAt = admin.firestore.Timestamp.fromMillis(
        serviceAutoCompleteAtMillis({...booking, startedAt: nowMillis}),
      );
    }
    if (isTerminal) update.extraServiceRequest = null;
    if (nextStatus === "completed") {
      update.completedAt = admin.firestore.FieldValue.serverTimestamp();
      update.completionSource = systemActor ?
        "automatic_timeout" : platformAdmin ? "admin" : "salon";
      update.autoCompleted = systemActor;
    }
    if (nextStatus === "cancelled") {
      update.cancelledBy = actorRole;
      update.cancellationReason = cancellationReason ||
        (actorRole === "admin" ? adminReason :
          actorRole === "owner" ? "Cancelled by salon" :
            "Cancelled by customer");
      update.cancelledAt = admin.firestore.FieldValue.serverTimestamp();
    }
    if (nextStatus === "rejected") {
      update.cancelledBy = actorRole === "admin" ? "admin" : "owner";
      update.cancellationReason = cancellationReason ||
        (actorRole === "admin" ? adminReason : "Rejected by salon");
      update.rejectedAt = admin.firestore.FieldValue.serverTimestamp();
    }
    if (platformAdmin) {
      update.lastAdminActionAt = admin.firestore.FieldValue.serverTimestamp();
      update.lastAdminActionBy = uid;
      update.lastAdminActionReason = adminReason;
    }
    if (discountResolution) {
      update.discountStatus = discountResolution.outcome;
    }
    if (nextStatus === "cancelled" || nextStatus === "rejected") {
      if (booking.discountCashbackStatus === "pending") {
        update.discountCashbackStatus = "cancelled";
      }
    }
    transaction.update(bookingRef, update);
    if (shouldStopArrivalSharing) {
      transaction.set(
        firestore.collection("bookingArrivalSessions").doc(bookingId),
        {
          bookingId,
          customerUid: booking.customerUid,
          sharingActive: false,
          stoppedReason: nextStatus,
          stoppedAt: admin.firestore.FieldValue.serverTimestamp(),
          ...customerArrivalLocationDeletes(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        {merge: true},
      );
    }
    if (nextStatus === "completed") {
      transaction.set(firestore.collection("users").doc(booking.customerUid), {
        completedBookingCount: admin.firestore.FieldValue.increment(1),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.set(
        firestore.collection("customerSalonStats")
          .doc(`${booking.customerUid}__${booking.salonId}`),
        {
          customerUid: booking.customerUid,
          salonId: booking.salonId,
          completedBookingCount: admin.firestore.FieldValue.increment(1),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        {merge: true},
      );
    }
    if (qualifyingCustomerReferral) {
      transaction.update(qualifyingCustomerReferral.ref, {
        status: "qualified",
        qualifiedAt: admin.firestore.FieldValue.serverTimestamp(),
        qualificationBookingId: bookingId,
        proinAwardPending: true,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      transaction.set(
        firestore.collection("referralStats")
          .doc(qualifyingCustomerReferral.data.inviterUid),
        {
          pendingCustomerCount: admin.firestore.FieldValue.increment(-1),
          qualifiedCustomerCount: admin.firestore.FieldValue.increment(1),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        {merge: true},
      );
    }
    if (discountResolution) {
      resolveReservedDiscountInTransaction({
        transaction,
        firestore,
        refs: discountResolution.refs,
        booking,
        bookingId,
        outcome: discountResolution.outcome,
        fundingState: discountResolution.fundingState,
      });
    }

    if (assignedBarber) {
      const createdAt = booking.createdAt ||
        admin.firestore.Timestamp.fromMillis(nowMillis);
      for (const segmentMillis of slotSegmentMillis(
        acceptedStartMillis,
        positiveInteger(booking.durationMinutes, 30),
      )) {
        const lockRef = firestore.collection("slotLocks")
          .doc(slotLockId(assignedBarber.id, segmentMillis));
        transaction.set(lockRef, slotLockData({
          bookingId,
          salonId: booking.salonId,
          serviceId: booking.serviceId,
          barberId: assignedBarber.id,
          segmentMillis,
          bookingStartMillis: acceptedStartMillis,
          createdAt,
        }));
      }
    }
    for (let index = 0; index < previousLockRefs.length; index += 1) {
      if (previousLockSnapshots[index].data()?.bookingId === bookingId) {
        transaction.set(previousLockRefs[index], {
          active: false,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, {merge: true});
      }
    }
    if (activeCustomerSnapshot?.data()?.bookingId === bookingId) {
      transaction.set(activeCustomerRef, {
        active: false,
        resolvedStatus: nextStatus,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
    }
    if (activeInstantSnapshot?.data()?.bookingId === bookingId) {
      transaction.set(activeInstantRef, {
        active: false,
        resolvedStatus: nextStatus,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
    }
    if (auditRef) {
      transaction.create(auditRef, adminAuditRecord({
        adminUid: uid,
        action: "booking.status_changed",
        targetType: "booking",
        targetId: bookingId,
        reason: adminReason,
        before: {status: booking.status},
        after: {status: nextStatus},
      }));
    }
    updatedBooking = {...booking, ...update};
    if (assignedBarber) {
      updatedBooking.barberId = assignedBarber.id;
      updatedBooking.barberUid = normalizedOptionalString(assignedBarber.data().uid);
    }
  });

  if (!statusChanged) {
    return {bookingId, status: nextStatus, unchanged: true};
  }

  // The booking has committed. A push or wallet-maintenance failure must not
  // tell the owner that Start/Complete failed and roll the phone back.
  const followUp = async (stage, operation) => {
    try {
      await operation();
    } catch (error) {
      console.error("booking status follow-up failed", {
        bookingId, status: nextStatus, stage,
        code: error?.code || "unknown", message: error?.message || String(error),
      });
    }
  };

  // Completion is the customer's payment trigger. Deliver it immediately
  // after the authoritative transaction commits instead of making the
  // customer wait for wallet expiry maintenance and recipient hydration.
  if (nextStatus === "completed") {
    const completionMessage = bookingStatusMessage(updatedBooking);
    await followUp("customer_notification", () => sendToUsers([updatedBooking.customerUid].filter(Boolean), {
      title: completionMessage.title,
      body: completionMessage.body,
      data: bookingNotificationData(bookingId, updatedBooking),
      requiredActiveRolesByUser: bookingRecipientRoles(updatedBooking),
    }));
  }

  if (proinWalletToRefresh) {
    await followUp("wallet_expiry", () =>
      proinBackend.refreshWalletExpiry(proinWalletToRefresh));
  }

  await followUp("status_notifications", async () => {
    const hydrated = await hydrateBookingRecipients(updatedBooking);
    const message = bookingStatusMessage(hydrated);
    const recipients = bookingStatusRecipients({}, hydrated).filter(
      (recipientUid) => nextStatus !== "completed" ||
        recipientUid !== updatedBooking.customerUid,
    );
    await sendToUsers(recipients, {
      title: message.title,
      body: message.body,
      data: bookingNotificationData(bookingId, hydrated),
      requiredActiveRolesByUser: bookingRecipientRoles(hydrated),
    });
  });
  return {bookingId, status: nextStatus};
}

function discountBenefitMessage(quote, labelOverride = "") {
  const cashback = money(quote.cashbackProinAmount);
  const label = labelOverride || quote.campaignName;
  return cashback > 0 ?
    `${label} applied. You save ₹${quote.discountAmount} now and earn ${cashback} Proin after the service.` :
    `${label} applied. You save ₹${quote.discountAmount}.`;
}

exports.rescheduleBooking = onMobileCall(
  // Full vCPU: a customer-facing booking change, waited on in the UI.
  {invoker: "public", cpu: 1},
  (request) => rescheduleBookingHandler(request),
);

exports.rescheduleBookingAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  (request) => rescheduleBookingHandler(request, {platformAdmin: true}),
);

async function rescheduleBookingHandler(
  request,
  {platformAdmin = false} = {},
) {
  const uid = platformAdmin ?
    await requirePlatformAdministrator(request) :
    requireAuthenticatedUid(request);
  const bookingId = requiredId(request.data?.bookingId, "booking id");
  const barberId = requiredId(request.data?.barberId, "barber id");
  const startMillis = Number(request.data?.startMillis);
  const adminReason = platformAdmin ?
    requiredAdminReason(request.data?.reason) : "";
  if (!Number.isFinite(startMillis)) {
    throw new HttpsError("invalid-argument", "Choose a new appointment time.");
  }
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const initial = (await bookingRef.get()).data();
  if (!initial) {
    throw new HttpsError("not-found", "Booking not found.");
  }
  const salonRef = firestore.collection("salons").doc(initial.salonId);
  const barberRef = firestore.collection("barbers").doc(barberId);
  const auditRef = platformAdmin ?
    firestore.collection("adminAuditLogs").doc() : null;
  const nowMillis = Date.now();
  let updatedBooking = null;
  await firestore.runTransaction(async (transaction) => {
    const bookingSnapshot = await transaction.get(bookingRef);
    const actorSnapshot = platformAdmin ? null : await transaction.get(
      firestore.collection("users").doc(uid),
    );
    const salonSnapshot = await transaction.get(salonRef);
    const barberSnapshot = await transaction.get(barberRef);
    const booking = bookingSnapshot.data();
    const salon = salonSnapshot.data();
    const barber = barberSnapshot.data();
    if (!platformAdmin) requireStoredRole(actorSnapshot.data(), "customer");
    if (!booking || (!platformAdmin && booking.customerUid !== uid)) {
      throw new HttpsError("permission-denied", "Not allowed.");
    }
    if (!canRescheduleBooking(booking, nowMillis)) {
      throw new HttpsError(
        "failed-precondition",
        "Rescheduling closes two hours before the appointment.",
      );
    }
    if (startMillis <= nowMillis) {
      throw new HttpsError("failed-precondition", "Choose a future time.");
    }
    if (!salon || !barberCanServe(barber, booking.serviceId) ||
        barber.salonId !== booking.salonId) {
      throw new HttpsError(
        "failed-precondition",
        "The selected barber is no longer available for this service.",
      );
    }
    const service = findSalonService(salon, booking.serviceId);
    const durationMinutes = positiveInteger(
      booking.durationMinutes || service?.durationMinutes,
      30,
    );
    if (!service || service.isAvailable === false || !isWithinSalonHours({
      startMillis,
      durationMinutes,
      openTime: salon.openTime,
      closeTime: salon.closeTime,
    })) {
      throw new HttpsError(
        "failed-precondition",
        "The selected appointment is no longer available.",
      );
    }

    const oldSegments = slotSegmentMillis(
      booking.start.toMillis(),
      durationMinutes,
    );
    const newSegments = slotSegmentMillis(startMillis, durationMinutes);
    const oldRefs = oldSegments.map((segmentMillis) => firestore
      .collection("slotLocks")
      .doc(slotLockId(booking.barberId, segmentMillis)));
    const newRefs = newSegments.map((segmentMillis) => firestore
      .collection("slotLocks")
      .doc(slotLockId(barberId, segmentMillis)));
    const oldSnapshots = [];
    const newSnapshots = [];
    for (const ref of oldRefs) {
      oldSnapshots.push(await transaction.get(ref));
    }
    for (const ref of newRefs) {
      newSnapshots.push(await transaction.get(ref));
    }
    if (newSnapshots.some((snapshot) =>
      snapshot.exists && snapshot.data()?.active !== false &&
      snapshot.data()?.bookingId !== bookingId)) {
      throw new HttpsError(
        "already-exists",
        "This slot was just booked. Please choose another time.",
      );
    }

    transaction.update(bookingRef, {
      barberId,
      barberUid: normalizedOptionalString(barber.uid),
      start: admin.firestore.Timestamp.fromMillis(startMillis),
      rescheduledAt: admin.firestore.FieldValue.serverTimestamp(),
      rescheduledFrom: booking.start,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(platformAdmin ? {
        lastAdminActionAt: admin.firestore.FieldValue.serverTimestamp(),
        lastAdminActionBy: uid,
        lastAdminActionReason: adminReason,
      } : {}),
    });
    for (let index = 0; index < oldRefs.length; index += 1) {
      if (oldSnapshots[index].data()?.bookingId === bookingId) {
        transaction.set(oldRefs[index], {
          active: false,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, {merge: true});
      }
    }
    const createdAt = booking.createdAt ||
      admin.firestore.Timestamp.fromMillis(nowMillis);
    for (let index = 0; index < newRefs.length; index += 1) {
      transaction.set(newRefs[index], slotLockData({
        bookingId,
        salonId: booking.salonId,
        serviceId: booking.serviceId,
        barberId,
        segmentMillis: newSegments[index],
        bookingStartMillis: startMillis,
        createdAt,
      }));
    }
    if (auditRef) {
      transaction.create(auditRef, adminAuditRecord({
        adminUid: uid,
        action: "booking.rescheduled",
        targetType: "booking",
        targetId: bookingId,
        reason: adminReason,
        before: {
          barberId: adminString(booking.barberId),
          startMillis: adminMillis(booking.start),
        },
        after: {barberId, startMillis},
      }));
    }
    updatedBooking = {
      ...booking,
      barberId,
      barberUid: normalizedOptionalString(barber.uid),
      start: admin.firestore.Timestamp.fromMillis(startMillis),
    };
  });

  const hydrated = await hydrateBookingRecipients(updatedBooking);
  await sendToUsers([hydrated.ownerUid].filter(Boolean), {
    title: "Booking rescheduled",
    body: `${hydrated.customerName || "A customer"} rescheduled ${hydrated.serviceName || "a service"}.`,
    data: bookingNotificationData(bookingId, hydrated),
    requiredActiveRolesByUser: bookingRecipientRoles(hydrated),
  });
  return {bookingId};
}

exports.sendBookingPush = onMobileCall(
  {invoker: "public", cpu: "gcf_gen1"},
  async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }

  const bookingId = String(request.data?.bookingId ?? "").trim();
  const event = String(request.data?.event ?? "").trim();
  if (!bookingId) {
    throw new HttpsError("invalid-argument", "Missing booking id.");
  }

  const snapshot = await admin.firestore()
    .collection("bookings")
    .doc(bookingId)
    .get();
  const booking = await hydrateBookingRecipients(snapshot.data());
  if (!booking) {
    throw new HttpsError("not-found", "Booking not found.");
  }

  const participants = [
    booking.customerUid,
    booking.ownerUid,
    booking.barberUid,
  ].filter(Boolean);
  if (!participants.includes(uid)) {
    throw new HttpsError("permission-denied", "Not allowed.");
  }

  return {
    ok: true,
    event,
    handledBy: "authoritativeBookingWorkflow",
  };
  },
);

exports.qualifySalonReferralOnSalonCreated = onDocumentCreated(
  "salons/{salonId}",
  async (event) => {
    const salon = event.data?.data();
    const ownerUid = String(salon?.ownerUid ?? "").trim();
    if (!ownerUid) return;
    const firestore = admin.firestore();
    const referralRef = firestore.collection("referrals").doc(ownerUid);
    await firestore.runTransaction(async (transaction) => {
      const referralSnapshot = await transaction.get(referralRef);
      const referral = referralSnapshot.data();
      if (referral?.status !== "pending" ||
          referral.referredRole !== "owner") {
        return;
      }
      transaction.update(referralRef, {
        status: "qualified",
        qualifiedAt: admin.firestore.FieldValue.serverTimestamp(),
        qualificationSalonId: event.params.salonId,
        proinAwardPending: true,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      transaction.set(
        firestore.collection("referralStats").doc(referral.inviterUid),
        {
          pendingSalonCount: admin.firestore.FieldValue.increment(-1),
          qualifiedSalonCount: admin.firestore.FieldValue.increment(1),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        {merge: true},
      );
    });
  },
);

exports.awardProinOnReferralQualified = onDocumentUpdated(
  "referrals/{referredUserId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (before?.status === "qualified" || after?.status !== "qualified") {
      return;
    }
    await processQualifiedReferralRewards(
      event.params.referredUserId,
      after,
    );
  },
);

exports.awardSalonReferralAfterFirstCompletedBooking = onDocumentUpdated(
  "bookings/{bookingId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (before?.status === "completed" || after?.status !== "completed") {
      return;
    }
    const salonId = String(after.salonId || "").trim();
    if (!salonId) return;
    const salonSnapshot = await admin.firestore()
      .collection("salons").doc(salonId).get();
    const ownerUid = String(salonSnapshot.data()?.ownerUid || "").trim();
    if (!ownerUid) return;
    const referralSnapshot = await admin.firestore()
      .collection("referrals").doc(ownerUid).get();
    if (referralSnapshot.data()?.status !== "qualified" ||
        referralSnapshot.data()?.referredRole !== "owner") {
      return;
    }
    await processQualifiedReferralRewards(ownerUid, {
      ...referralSnapshot.data(),
      qualificationSalonId:
        referralSnapshot.data()?.qualificationSalonId || salonId,
    });
  },
);

exports.awardDiscountCashbackOnBookingCompleted = onDocumentUpdated(
  {
    document: "bookings/{bookingId}",
    timeoutSeconds: 120,
    memory: "256MiB",
  },
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (before?.status === "completed" || after?.status !== "completed") {
      return;
    }
    await awardDiscountCashbackForCompletedBooking(
      event.params.bookingId,
      after,
    );
  },
);

exports.retryPendingDiscountCashback = onSchedule(
  "every 5 minutes",
  async () => {
    const snapshot = await admin.firestore().collection("bookings")
      .where("discountCashbackStatus", "==", "pending")
      .limit(100)
      .get();
    for (const document of snapshot.docs) {
      const booking = document.data();
      if (booking.status !== "completed") continue;
      try {
        await awardDiscountCashbackForCompletedBooking(document.id, booking);
      } catch (error) {
        console.error("discount cashback retry failed", {
          bookingId: document.id,
          error: String(error.message || error),
        });
      }
    }
  },
);

exports.awardSalonReferralAfterAdminApproval = onDocumentUpdated(
  "salons/{salonId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (before?.proinReferralApproved === true ||
        after?.proinReferralApproved !== true) {
      return;
    }
    const ownerUid = String(after.ownerUid || "").trim();
    if (!ownerUid) return;
    const referralSnapshot = await admin.firestore()
      .collection("referrals").doc(ownerUid).get();
    if (referralSnapshot.data()?.status !== "qualified" ||
        referralSnapshot.data()?.referredRole !== "owner") {
      return;
    }
    await processQualifiedReferralRewards(ownerUid, {
      ...referralSnapshot.data(),
      qualificationSalonId: event.params.salonId,
    });
  },
);

exports.alertOwnerOnBookingCreated = onDocumentCreated(
  {
    document: "bookings/{bookingId}",
    timeoutSeconds: 240,
    memory: "256MiB",
  },
  async (event) => {
    const bookingId = event.params.bookingId;
    const bookingRef = event.data?.ref;
    if (!bookingRef) {
      return;
    }
    const createdBooking = event.data?.data();
    const hydratedCreatedBooking = await hydrateBookingRecipients(
      createdBooking,
    );
    const customerDeliveryPromise = sendToUsers(
      [hydratedCreatedBooking?.customerUid].filter(Boolean),
      {
        title: createdBooking?.isInstant === true ?
          "Instant booking request sent" : "Booking confirmed",
        body: createdBooking?.isInstant === true ?
          `${createdBooking.serviceName || "Your service"} was sent to the salon. Your reach-by time will appear after the salon accepts.` :
          `${createdBooking?.serviceName || "Your service"} is booked for your selected appointment time.`,
        data: {
          ...bookingNotificationData(bookingId, createdBooking || {}),
          event: "created",
        },
        requiredActiveRolesByUser: bookingRecipientRoles(
          hydratedCreatedBooking || {},
        ),
      },
    );
    if (
      createdBooking?.isInstant !== true &&
      createdBooking?.status === "confirmed"
    ) {
      const booking = hydratedCreatedBooking;
      const [delivery] = await Promise.all([
        sendToUsers([booking.ownerUid].filter(Boolean), {
        title: "New scheduled booking",
        body: `${booking.customerName || "A customer"} booked ${booking.serviceName || "a service"}.`,
        data: bookingNotificationData(bookingId, booking),
        requiredActiveRolesByUser: bookingRecipientRoles(booking),
        }),
        customerDeliveryPromise,
      ]);
      console.log("scheduled booking delivered", {bookingId, delivery});
      return;
    }
    if (
      createdBooking?.isInstant !== true ||
      createdBooking?.status !== "pending"
    ) {
      return;
    }
    const claimed = await claimOwnerBookingAlert(bookingRef, event.id);
    if (!claimed) {
      await customerDeliveryPromise;
      return;
    }

    const createdAtMillis = createdBooking.createdAt?.toMillis?.() ||
      Date.now();
    const expiresAtMillis = createdAtMillis + INSTANT_RESPONSE_TIMEOUT_MS;
    for (let attempt = 0; attempt < OWNER_ALERT_ATTEMPTS; attempt += 1) {
      if (attempt > 0) {
        const waitMillis = Math.min(
          OWNER_ALERT_REPEAT_DELAY_MS,
          Math.max(0, expiresAtMillis - Date.now()),
        );
        if (waitMillis > 0) {
          await delay(waitMillis);
        }
      }
      if (Date.now() >= expiresAtMillis) {
        break;
      }
      const snapshot = await bookingRef.get();
      const current = snapshot.data();
      if (
        !current ||
        current.isInstant !== true ||
        current.status !== "pending"
      ) {
        console.log("owner booking alert stopped", {
          bookingId,
          status: current?.status || "deleted",
          attempt,
        });
        await customerDeliveryPromise;
        return;
      }
      const booking = await hydrateBookingRecipients(current);
      const ownerDelivery = await sendOwnerBookingRequest(
        bookingId,
        booking,
        attempt,
      );
      if (attempt === 0) {
        const customerArrivalMinutes = booking.arrivalMinutes || 15;
        const salonArrivalMinutes =
          booking.salonArrivalMinutes || customerArrivalMinutes + 5;
        await sendToUsers([booking.barberUid].filter(Boolean), {
          title: "Instant booking assigned",
          body: `${booking.serviceName || "A service"} is assigned. Customer ETA ${customerArrivalMinutes} min; salon window ${salonArrivalMinutes} min.`,
          data: bookingNotificationData(bookingId, booking),
          requiredActiveRolesByUser: bookingRecipientRoles(booking),
        });
      }
      console.log("owner booking alert delivered", {
        bookingId,
        attempt: attempt + 1,
        delivery: ownerDelivery,
      });
    }
    const remainingMillis = expiresAtMillis - Date.now();
    if (remainingMillis > 0) {
      await delay(remainingMillis);
    }
    const expiredBooking = await expirePendingInstantBooking(
      bookingRef,
      bookingId,
    );
    if (expiredBooking) {
      console.log("instant booking auto-cancelled", {bookingId});
    }
    await customerDeliveryPromise;
  },
);

exports.notifyBookingExtraServices = onDocumentUpdated(
  {document: "bookings/{bookingId}", region: "asia-south1", cpu: "gcf_gen1"},
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after || after.status !== "inProgress") return;
    const proposed = after.extraServiceRequest;
    const resolved = before.extraServiceRequest;
    const isNew = proposed && proposed.id !== resolved?.id;
    const isResolved = resolved && !proposed;
    if (!isNew && !isResolved) return;
    const current = (await admin.firestore().collection("bookings").doc(event.params.bookingId).get()).data();
    if (current?.status !== "inProgress" ||
        (isNew && current.extraServiceRequest?.id !== proposed.id) ||
        (isResolved && current.extraServiceRequest)) return;
    const proposal = isNew ? proposed : resolved;
    const recipient = isNew ? (proposal.proposedByUid === after.ownerUid ? after.customerUid : after.ownerUid) : proposal.proposedByUid;
    const approved = after.extraServiceDecisions?.[proposal.id] === "approve";
    await sendToUsers([recipient].filter(Boolean), {
      title: isNew ? "Review extra services" : approved ? "Extra services approved" : "Extra service request closed",
      body: isNew ? `${Object.values(proposal.names || {}).join(", ")}: +₹${proposal.amount}. Open the booking to approve or decline.` :
        approved ? `Your updated total is ₹${money(after.customerPayableAmount)}.` : "The additional services were not charged.",
      data: bookingNotificationData(event.params.bookingId, after),
      requiredActiveRolesByUser: bookingRecipientRoles(after),
    });
  },
);

exports.stopOwnerAlertOnBookingResolved = onDocumentUpdated(
  {
    document: "bookings/{bookingId}",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (
      !before ||
      !after ||
      before.status !== "pending" ||
      after.status === "pending" ||
      after.isInstant !== true
    ) {
      return;
    }
    const booking = await hydrateBookingRecipients(after);
    // The stop must reach every alert generation: a device that rang and was
    // not told to stop keeps ringing until its own deadline.
    const stopRecipients = [booking.ownerUid].filter(Boolean);
    const stopMessage = {
      title: "",
      body: "",
      data: {
        type: "bookingAlertControl",
        action: "stop_owner_booking_alarm",
        bookingId: event.params.bookingId,
        status: after.status || "",
      },
      androidDataOnly: true,
      controlOnly: true,
      collapseKey: `booking-${event.params.bookingId}`,
    };
    const delivery = mergeDelivery(
      await sendToUsers(stopRecipients, {
        ...stopMessage,
        tokenField: OWNER_ALERT_TOKEN_FIELD,
      }),
      await sendToUsers(stopRecipients, {
        ...stopMessage,
        tokenField: OWNER_ALERT_TOKEN_FIELD_V3,
        excludeTokenField: OWNER_ALERT_TOKEN_FIELD,
      }),
    );
    console.log("owner booking alert stop delivered", {
      bookingId: event.params.bookingId,
      status: after.status,
      delivery,
    });
    const ownerUid = String(booking.ownerUid ?? "").trim();
    if (ownerUid) {
      const ownerBookings = await admin.firestore()
        .collection("bookings")
        .where("ownerUid", "==", ownerUid)
        .get();
      const remainingRequests = ownerBookings.docs
        .filter((doc) => doc.id !== event.params.bookingId)
        .filter((doc) => {
          const data = doc.data();
          return shouldAlertOwnerForBooking(data);
        })
        .sort((left, right) => {
          const leftMillis = left.data().createdAt?.toMillis?.() || 0;
          const rightMillis = right.data().createdAt?.toMillis?.() || 0;
          return leftMillis - rightMillis;
        });
      if (remainingRequests.length > 0) {
        const next = remainingRequests[0];
        const nextBooking = await hydrateBookingRecipients(next.data());
        const delivery = await sendOwnerBookingRequest(
          next.id,
          nextBooking,
          0,
        );
        console.log("owner booking alert continued", {
          resolvedBookingId: event.params.bookingId,
          nextBookingId: next.id,
          delivery,
        });
        return;
      }
    }
  },
);

// A booking-created trigger normally expires unanswered instant requests.
// This scheduled recovery covers process crashes, deployment interruptions,
// and older records whose long-running alert trigger never reached cleanup.
exports.expireStaleInstantBookings = onSchedule(
  {
    schedule: "every 1 minutes",
    timeZone: "Asia/Kolkata",
    region: "asia-south1",
    timeoutSeconds: 240,
    memory: "256MiB",
  },
  async () => {
    const nowMillis = Date.now();
    const snapshot = await admin.firestore().collection("bookings")
      .where("status", "==", "pending")
      .limit(100)
      .get();
    let expiredCount = 0;
    let failureCount = 0;
    for (const document of snapshot.docs) {
      const booking = document.data();
      const deadline = instantResponseDeadlineMillis(booking);
      if (booking.isInstant !== true ||
          !Number.isFinite(deadline) ||
          nowMillis < deadline) {
        continue;
      }
      try {
        const expired = await expirePendingInstantBooking(
          document.ref,
          document.id,
        );
        if (expired) expiredCount += 1;
      } catch (error) {
        failureCount += 1;
        console.error("stale instant booking expiry failed", {
          bookingId: document.id,
          error: String(error?.message || error),
        });
      }
    }
    console.log("stale instant bookings checked", {
      candidateCount: snapshot.size,
      expiredCount,
      failureCount,
    });
  },
);

exports.completeOverdueServices = onSchedule(
  {
    schedule: "every 1 minutes",
    timeZone: "Asia/Kolkata",
    timeoutSeconds: 120,
    memory: "256MiB",
    cpu: "gcf_gen1",
  },
  async () => {
    const firestore = admin.firestore();
    const nowMillis = Date.now();
    const snapshot = await firestore.collection("bookings")
      .where("status", "==", "inProgress")
      .limit(500)
      .get();
    const overdue = snapshot.docs.filter((document) =>
      shouldAutoCompleteService(document.data(), nowMillis));
    const results = await Promise.allSettled(overdue.map((document) =>
      updateBookingStatusHandler(
        {data: {bookingId: document.id, status: "completed"}},
        {systemActor: true},
      )));
    for (const result of results) {
      if (result.status === "rejected") {
        console.error("automatic service completion failed", result.reason);
      }
    }
    console.log("overdue services checked", {
      activeServiceCount: snapshot.size,
      completedServiceCount: results.filter(
        (result) => result.status === "fulfilled",
      ).length,
    });
  },
);

exports.sendBookingArrivalReminders = onSchedule(
  {
    schedule: "every 1 minutes",
    timeZone: "Asia/Kolkata",
    timeoutSeconds: 120,
    memory: "256MiB",
    cpu: "gcf_gen1",
  },
  async () => {
    const firestore = admin.firestore();
    const nowMillis = Date.now();
    const lowerBound = admin.firestore.Timestamp.fromMillis(
      nowMillis - 60 * 1000,
    );
    const upperBound = admin.firestore.Timestamp.fromMillis(
      nowMillis + 31 * 60 * 1000,
    );
    const snapshot = await firestore.collection("bookings")
      .where("start", ">=", lowerBound)
      .where("start", "<=", upperBound)
      .get();

    const tasks = [];
    for (const document of snapshot.docs) {
      const booking = document.data();
      for (const audience of ["customer", "owner"]) {
        if (!bookingArrivalReminderDue({booking, audience, nowMillis})) {
          continue;
        }
        tasks.push(sendClaimedArrivalReminder({
          bookingRef: document.ref,
          bookingId: document.id,
          audience,
          nowMillis,
        }));
      }
    }
    const results = await Promise.allSettled(tasks);
    for (const result of results) {
      if (result.status === "rejected") {
        console.error("booking arrival reminder failed", result.reason);
      }
    }
    console.log("booking arrival reminders checked", {
      candidateCount: snapshot.size,
      reminderCount: tasks.length,
    });
  },
);

exports.expireCustomerArrivalSharing = onSchedule(
  {
    schedule: "every 10 minutes",
    timeZone: "Asia/Kolkata",
    timeoutSeconds: 120,
    memory: "256MiB",
    cpu: "gcf_gen1",
  },
  async () => {
    const firestore = admin.firestore();
    const now = admin.firestore.Timestamp.now();
    const snapshot = await firestore.collection("bookingArrivalSessions")
      .where("sharingActive", "==", true)
      .limit(500)
      .get();
    const writer = firestore.bulkWriter();
    let expiredCount = 0;
    for (const document of snapshot.docs) {
      if ((document.data().expiresAt?.toMillis?.() || 0) > now.toMillis()) {
        continue;
      }
      expiredCount += 1;
      writer.update(document.ref, {
        sharingActive: false,
        stoppedReason: "expired",
        stoppedAt: now,
        ...customerArrivalLocationDeletes(),
        updatedAt: now,
      });
      writer.set(firestore.collection("bookings").doc(document.id), {
        arrivalSharingActive: false,
        arrivalSharingExpiresAt: admin.firestore.FieldValue.delete(),
        updatedAt: now,
      }, {merge: true});
    }
    await writer.close();
    console.log("customer arrival sharing expiry checked", {
      expiredCount,
    });
  },
);

exports.sendJoinRequestPush = onMobileCall(
  {invoker: "public", cpu: "gcf_gen1"},
  async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }

  const requestId = String(request.data?.requestId ?? "").trim();
  const event = String(request.data?.event ?? "").trim();
  if (!requestId) {
    throw new HttpsError("invalid-argument", "Missing request id.");
  }

  const snapshot = await admin.firestore()
    .collection("joinRequests")
    .doc(requestId)
    .get();
  const joinRequest = snapshot.data();
  if (!joinRequest) {
    throw new HttpsError("not-found", "Request not found.");
  }

  const participants = [
    joinRequest.requesterUid,
    joinRequest.ownerUid,
  ].filter(Boolean);
  if (!participants.includes(uid)) {
    throw new HttpsError("permission-denied", "Not allowed.");
  }

  let recipients;
  let title;
  let body;
  if (event === "created") {
    recipients = [joinRequest.ownerUid];
    title = "New barber request";
    body = `${joinRequest.barberName || "A barber"} wants to join your salon.`;
  } else if (event === "withdrawn" || joinRequest.status === "withdrawn") {
    recipients = [joinRequest.ownerUid];
    title = "Barber request withdrawn";
    body = `${joinRequest.barberName || "A barber"} withdrew the join request.`;
  } else {
    recipients = [joinRequest.requesterUid];
    title = joinRequest.status === "approved"
      ? "Salon request accepted"
      : "Salon request rejected";
    body = joinRequest.status === "approved"
      ? "Your barber request was accepted. You can now see assigned bookings."
      : "Your barber request was rejected by the salon.";
  }

  const delivery = await sendToUsers(recipients.filter((id) => id && id !== uid), {
    title,
    body,
    data: {
      type: "joinRequest",
      requestId,
      salonId: joinRequest.salonId || "",
      status: joinRequest.status || "",
      destination: "team",
    },
  });
  console.log("sendJoinRequestPush", {
    requestId,
    recipients: recipients.filter((id) => id && id !== uid),
    delivery,
  });
  return {ok: true, delivery};
  },
);

exports.sendEmailOtp = onMobileCall(
  {
    enforceAppCheck: true,
    invoker: "public",
    cpu: "gcf_gen1",
    secrets: [smtpHost, smtpPort, smtpUser, smtpPass, smtpFrom, otpSecret],
  },
  async (request) => {
    const email = normalizeEmail(request.data?.email);
    if (!email) {
      throw new HttpsError("invalid-argument", "Enter a valid email address.");
    }

    const docRef = admin.firestore().collection("emailOtps").doc(emailKey(email));
    const now = Date.now();
    const code = crypto.randomInt(100000, 1000000).toString();
    const expiresAt = admin.firestore.Timestamp.fromMillis(now + OTP_TTL_MS);
    const codeHash = hashCode(email, code);
    await admin.firestore().runTransaction(async (transaction) => {
      const snapshot = await transaction.get(docRef);
      const previous = snapshot.data();
      if (
        previous?.sentAt?.toMillis &&
        now - previous.sentAt.toMillis() < EMAIL_RESEND_DELAY_MS
      ) {
        throw new HttpsError(
          "resource-exhausted",
          "Please wait before requesting another email OTP.",
        );
      }
      transaction.set(docRef, {
        email,
        codeHash,
        attempts: 0,
        sentAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt,
      });
    });

    try {
      await sendOtpMail(email, code);
    } catch (error) {
      await docRef.delete();
      console.error("sendEmailOtp delivery failed", {
        emailDomain: email.split("@").pop(),
        error: error.message,
      });
      throw new HttpsError(
        "unavailable",
        "The email could not be sent. Please try again.",
      );
    }
    console.log("sendEmailOtp delivered", {
      emailDomain: email.split("@").pop(),
    });
    return {ok: true};
  },
);

exports.verifyEmailOtp = onMobileCall(
  {
    enforceAppCheck: true,
    invoker: "public",
    cpu: "gcf_gen1",
    secrets: [otpSecret],
  },
  async (request) => {
    const email = normalizeEmail(request.data?.email);
    const code = String(request.data?.code ?? "").trim();
    if (!email || !/^\d{6}$/.test(code)) {
      throw new HttpsError("invalid-argument", "Enter the 6-digit email OTP.");
    }

    const docRef = admin.firestore().collection("emailOtps").doc(emailKey(email));
    const verification = await admin.firestore().runTransaction(async (
      transaction,
    ) => {
      const snapshot = await transaction.get(docRef);
      const data = snapshot.data();
      if (!data) {
        return {code: "not-found", message: "Request a new email OTP."};
      }
      if (!data.expiresAt?.toMillis || data.expiresAt.toMillis() < Date.now()) {
        transaction.delete(docRef);
        return {
          code: "deadline-exceeded",
          message: "This email OTP expired.",
        };
      }
      if ((data.attempts ?? 0) >= MAX_ATTEMPTS) {
        transaction.delete(docRef);
        return {
          code: "resource-exhausted",
          message: "Too many OTP attempts.",
        };
      }
      if (data.codeHash !== hashCode(email, code)) {
        transaction.update(docRef, {
          attempts: admin.firestore.FieldValue.increment(1),
        });
        return {
          code: "permission-denied",
          message: "Incorrect email OTP.",
        };
      }
      transaction.delete(docRef);
      return {code: "ok", message: ""};
    });
    if (verification.code !== "ok") {
      throw new HttpsError(verification.code, verification.message);
    }

    try {
      const user = await getOrCreateEmailUser(email);
      const customToken = await admin.auth().createCustomToken(user.uid, {
        provider: "email_otp",
      });
      console.log("verifyEmailOtp succeeded", {
        uid: user.uid,
        emailDomain: email.split("@").pop(),
      });
      return {customToken};
    } catch (error) {
      if (error.code === "auth/insufficient-permission") {
        throw new HttpsError(
          "failed-precondition",
          "Email OTP sign-in needs the Cloud Function service account to have Service Account Token Creator permission.",
        );
      }
      throw error;
    }
  },
);

exports.claimLoginRole = onMobileCall(
  {enforceAppCheck: false, invoker: "public", cpu: "gcf_gen1"},
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in first.");
    }

    const requestedRole = String(request.data?.role ?? "").trim();
    if (requestedRole !== "customer" && requestedRole !== "owner") {
      throw new HttpsError(
        "invalid-argument",
        "Login role must be customer or owner.",
      );
    }

    const token = request.auth.token ?? {};
    const authPhone = normalizeVerifiedPhone(token.phone_number);
    const normalizedSuppliedPhone = normalizeVerifiedPhone(
      request.data?.phone,
    );
    const suppliedPhone = /^\+91\d{10}$/.test(normalizedSuppliedPhone) ?
      normalizedSuppliedPhone : "";
    const signInProvider = String(
      token.firebase?.sign_in_provider ?? "",
    ).trim();
    const googleIdentities = token.firebase?.identities?.["google.com"];
    const hasGoogleIdentity = Array.isArray(googleIdentities) &&
      googleIdentities.length > 0;
    const canSupplyCustomerPhone =
      requestedRole === "customer" &&
      (signInProvider === "google.com" || hasGoogleIdentity);
    const phone = authPhone || (canSupplyCustomerPhone ? suppliedPhone : "");
    const email = normalizeEmail(token.email);
    const name = normalizeDisplayName(request.data?.name);
    const provider = normalizeLoginProvider(request.data?.provider, phone);
    if (requestedRole === "customer" && !phone) {
      throw new HttpsError(
        "failed-precondition",
        signInProvider === "google.com" ?
          "Enter a valid 10-digit Indian mobile number." :
          "Customers must sign in with a verified phone number.",
      );
    }
    const firestore = admin.firestore();
    const userRef = firestore.collection("users").doc(uid);
    const phoneRef = phone ?
      firestore.collection("loginIdentifiers").doc(phoneKey(phone)) :
      null;
    const ownerSalons = await firestore
      .collection("salons")
      .where("ownerUid", "==", uid)
      .limit(1)
      .get();

    const claim = await firestore.runTransaction(async (transaction) => {
      const userSnapshot = await transaction.get(userRef);
      const phoneSnapshot = phoneRef ? await transaction.get(phoneRef) : null;
      const storedRole = inferStoredRole(
        userSnapshot.data(),
        !ownerSalons.empty,
      );
      const isNewRegistration = !storedRole;
      const referralOnboardingPending =
        userSnapshot.data()?.referralOnboardingCompleted === false;
      const claimedPhoneRole = normalizeRole(phoneSnapshot?.data()?.role);

      if (storedRole && storedRole !== requestedRole) {
        throw loginRoleConflict(requestedRole, storedRole, Boolean(phone));
      }
      if (claimedPhoneRole && claimedPhoneRole !== requestedRole) {
        throw loginRoleConflict(requestedRole, claimedPhoneRole, true);
      }
      if (phoneSnapshot?.exists && phoneSnapshot.data()?.uid !== uid) {
        throw new HttpsError(
          "already-exists",
          sameRolePhoneConflictMessage(requestedRole),
        );
      }

      const storedName = normalizeDisplayName(userSnapshot.data()?.name);
      const resolvedName = resolveClaimName({
        requestedRole,
        requestedName: name,
        storedRole,
        storedName,
        email,
      });
      if (requestedRole === "customer" && !resolvedName) {
        return {
          role: requestedRole,
          name: "",
          requiresName: true,
          requiresReferralOnboarding: false,
        };
      }

      const contact = phone || email;
      transaction.set(userRef, {
        role: requestedRole,
        roles: [requestedRole],
        activeRole: requestedRole,
        name: resolvedName,
        contact,
        email: email || null,
        phone: phone || null,
        provider,
        ...(isNewRegistration ? {
          referralOnboardingCompleted: false,
          registeredAt: admin.firestore.FieldValue.serverTimestamp(),
        } : {}),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});

      if (phoneRef) {
        transaction.set(phoneRef, {
          phone,
          role: requestedRole,
          uid,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      return {
        role: requestedRole,
        name: resolvedName,
        requiresName: false,
        requiresReferralOnboarding:
          isNewRegistration || referralOnboardingPending,
      };
    });

    return claim;
  },
);

exports.getReferralCodes = onMobileCall(
  {enforceAppCheck: true, invoker: "public", cpu: 1},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    const firestore = admin.firestore();
    const userRef = firestore.collection("users").doc(uid);

    for (let attempt = 0; attempt < 12; attempt += 1) {
      const proposedCustomerCode = generateReferralCode();
      let proposedSalonCode = generateReferralCode();
      while (proposedSalonCode === proposedCustomerCode) {
        proposedSalonCode = generateReferralCode();
      }
      try {
        return await firestore.runTransaction(async (transaction) => {
          const userSnapshot = await transaction.get(userRef);
          const user = userSnapshot.data() ?? {};
          const role = inferStoredRole(user, false);
          if (role !== "customer" && role !== "owner") {
            throw new HttpsError(
              "permission-denied",
              "Only customers and salon owners can create referral codes.",
            );
          }

          const customerField = role === "customer" ?
            "customerReferralCode" : "ownerCustomerReferralCode";
          const existingCustomerCode = normalizeReferralCode(
            user[customerField],
          );
          const existingSalonCode = role === "owner" ?
            normalizeReferralCode(user.ownerSalonReferralCode) : "";
          const customerCode = existingCustomerCode || proposedCustomerCode;
          const salonCode = role === "owner" ?
            (existingSalonCode || proposedSalonCode) : "";
          const reservations = [
            {
              code: customerCode,
              targetRole: "customer",
              wasStored: Boolean(existingCustomerCode),
            },
            ...(role === "owner" ? [{
              code: salonCode,
              targetRole: "owner",
              wasStored: Boolean(existingSalonCode),
            }] : []),
          ];
          const reservationSnapshots = [];
          for (const reservation of reservations) {
            reservationSnapshots.push(await transaction.get(
              firestore.collection("referralCodes").doc(reservation.code),
            ));
          }
          for (let index = 0; index < reservations.length; index += 1) {
            const reservation = reservations[index];
            const reserved = reservationSnapshots[index].data();
            if (!reserved) continue;
            const matchesOwner = reserved.ownerUid === uid &&
              reserved.targetRole === reservation.targetRole;
            if (matchesOwner) continue;
            if (reservation.wasStored) {
              throw new HttpsError(
                "data-loss",
                "A stored referral code has an ownership conflict. Contact support.",
              );
            }
            const collision = new Error("referral-code-collision");
            collision.isReferralCodeCollision = true;
            throw collision;
          }

          reservations.forEach((reservation, index) => {
            if (reservationSnapshots[index].exists) return;
            transaction.set(reservationSnapshots[index].ref, {
              code: reservation.code,
              ownerUid: uid,
              inviterRole: role,
              targetRole: reservation.targetRole,
              active: true,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
          });
          transaction.set(userRef, {
            [customerField]: customerCode,
            ...(role === "owner" ? {ownerSalonReferralCode: salonCode} : {}),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, {merge: true});
          return {customerInviteCode: customerCode, salonInviteCode: salonCode};
        });
      } catch (error) {
        if (error?.isReferralCodeCollision === true) {
          continue;
        }
        throw error;
      }
    }
    throw new HttpsError(
      "resource-exhausted",
      "Could not reserve a referral code. Please try again.",
    );
  },
);

exports.updateReferralCodeAsAdmin = onCall(
  {invoker: "public", enforceAppCheck: false, cpu: "gcf_gen1"},
  async (request) => {
    const adminUid = await requirePlatformAdministrator(request);
    const reason = requiredAdminReason(request.data?.reason);
    const currentCode = normalizeReferralCode(request.data?.currentCode);
    const newCode = normalizeReferralCode(request.data?.newCode);
    if (!currentCode || !newCode) {
      throw new HttpsError(
        "invalid-argument",
        "Referral codes must be 6 characters with letters and numbers.",
      );
    }
    const firestore = admin.firestore();
    const currentRef = firestore.collection("referralCodes").doc(currentCode);
    const newRef = firestore.collection("referralCodes").doc(newCode);
    const auditRef = firestore.collection("adminAuditLogs").doc();
    let response = null;

    await firestore.runTransaction(async (transaction) => {
      const [currentSnapshot, newSnapshot] = await Promise.all([
        transaction.get(currentRef),
        currentCode === newCode ? transaction.get(currentRef) :
          transaction.get(newRef),
      ]);
      const before = currentSnapshot.data();
      if (!before) {
        throw new HttpsError("not-found", "This referral code was not found.");
      }
      if (currentCode !== newCode && newSnapshot.exists) {
        throw new HttpsError(
          "already-exists",
          "This referral code is already assigned to another account.",
        );
      }
      const ownerUid = adminString(before.ownerUid);
      const inviterRole = adminString(before.inviterRole);
      const targetRole = adminString(before.targetRole);
      const userCodeField = referralCodeUserField(inviterRole, targetRole);
      if (!ownerUid || !userCodeField) {
        throw new HttpsError(
          "data-loss",
          "This referral code record is missing its owner or role.",
        );
      }
      const userRef = firestore.collection("users").doc(ownerUid);
      const userSnapshot = await transaction.get(userRef);
      if (!userSnapshot.exists) {
        throw new HttpsError(
          "failed-precondition",
          "The referral code owner account no longer exists.",
        );
      }
      const active = request.data?.active === true;
      const nowField = admin.firestore.FieldValue.serverTimestamp();
      const after = {
        code: newCode,
        ownerUid,
        inviterRole,
        targetRole,
        active,
        createdAt: before.createdAt || nowField,
        replacedFromCode: currentCode === newCode ?
          adminString(before.replacedFromCode) : currentCode,
        updatedAt: nowField,
        updatedByAdminUid: adminUid,
      };

      if (currentCode === newCode) {
        transaction.set(currentRef, after, {merge: true});
      } else {
        transaction.set(currentRef, {
          active: false,
          replacedByCode: newCode,
          updatedAt: nowField,
          updatedByAdminUid: adminUid,
        }, {merge: true});
        transaction.create(newRef, after);
        transaction.set(userRef, {
          [userCodeField]: newCode,
          updatedAt: nowField,
        }, {merge: true});
      }

      const beforeView = referralCodeAdminView(currentCode, before);
      const afterView = referralCodeAdminView(newCode, after);
      transaction.create(auditRef, adminAuditRecord({
        adminUid,
        action: currentCode === newCode ?
          "referral.code_updated" : "referral.code_replaced",
        targetType: "referralCode",
        targetId: currentCode,
        reason,
        before: beforeView,
        after: afterView,
      }));
      response = afterView;
    });
    return response;
  },
);

exports.completeReferralOnboarding = onMobileCall(
  {enforceAppCheck: true, invoker: "public", cpu: "gcf_gen1"},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    const rawCode = String(request.data?.referralCode ?? "").trim();
    const code = rawCode ? normalizeReferralCode(rawCode) : "";
    if (rawCode && !code) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a valid 6-character referral code.",
      );
    }
    const firestore = admin.firestore();
    if (code) {
      await enforceReferralAttemptLimit(firestore, uid);
    }
    const userRef = firestore.collection("users").doc(uid);
    const codeRef = code ? firestore.collection("referralCodes").doc(code) : null;
    const referralRef = firestore.collection("referrals").doc(uid);

    return firestore.runTransaction(async (transaction) => {
      const userSnapshot = await transaction.get(userRef);
      const codeSnapshot = codeRef ? await transaction.get(codeRef) : null;
      const referralSnapshot = await transaction.get(referralRef);
      const user = userSnapshot.data() ?? {};
      const role = inferStoredRole(user, false);
      if (role !== "customer" && role !== "owner") {
        throw new HttpsError("permission-denied", "Complete registration first.");
      }
      if (user.referralOnboardingCompleted === true) {
        return {completed: true, alreadyCompleted: true};
      }
      if (user.referralOnboardingCompleted !== false) {
        throw new HttpsError(
          "failed-precondition",
          "Referral codes can only be entered during first registration.",
        );
      }
      if (code) {
        const referralCode = codeSnapshot?.data();
        if (!referralCode || referralCode.active !== true) {
          throw new HttpsError("not-found", "This referral code is not valid.");
        }
        if (!referralTargetAllowed(referralCode.targetRole, role)) {
          throw new HttpsError(
            "failed-precondition",
            role === "customer" ?
              "This code cannot be used for a customer account." :
              "This code cannot be used for a salon account.",
          );
        }
        if (referralCode.ownerUid === uid) {
          throw new HttpsError(
            "failed-precondition",
            "You cannot use your own referral code.",
          );
        }
        if (referralSnapshot.exists) {
          throw new HttpsError(
            "already-exists",
            "A referral has already been recorded for this account.",
          );
        }
        const inviteLimit = await referralInviteLimit({
          transaction,
          firestore,
          inviterUid: referralCode.ownerUid,
          inviterRole: referralCode.inviterRole,
          targetRole: role,
        });
        if (inviteLimit.hasLimit) {
          const statsRef = firestore.collection("referralStats")
            .doc(referralCode.ownerUid);
          const statsSnapshot = await transaction.get(statsRef);
          const stats = statsSnapshot.data() || {};
          const pendingField = role === "owner" ?
            "pendingSalonCount" : "pendingCustomerCount";
          const qualifiedField = role === "owner" ?
            "qualifiedSalonCount" : "qualifiedCustomerCount";
          const currentInviteCount = money(stats[pendingField]) +
            money(stats[qualifiedField]);
          if (currentInviteCount >= inviteLimit.maximumInvitesPerAccount) {
            throw new HttpsError(
              "resource-exhausted",
              role === "owner" ?
                "This salon referral code has reached its invite limit." :
                "This customer referral code has reached its invite limit.",
            );
          }
        }
        transaction.set(referralRef, {
          referredUid: uid,
          referredRole: role,
          referralCode: code,
          inviterUid: referralCode.ownerUid,
          inviterRole: referralCode.inviterRole,
          status: "pending",
          qualificationType: role === "owner" ?
            "salon_registered" : "first_completed_booking",
          qualifiedAt: null,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        transaction.set(
          firestore.collection("referralStats").doc(referralCode.ownerUid),
          {
            inviterUid: referralCode.ownerUid,
            [role === "owner" ? "pendingSalonCount" :
              "pendingCustomerCount"]:
                admin.firestore.FieldValue.increment(1),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          {merge: true},
        );
      }
      transaction.set(userRef, {
        referralOnboardingCompleted: true,
        referralCodeEntered: code || null,
        referralCompletedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      return {completed: true, alreadyCompleted: false};
    });
  },
);

async function referralInviteLimit({
  transaction,
  firestore,
  inviterUid,
  inviterRole,
  targetRole,
}) {
  const normalizedInviterRole = String(inviterRole || "").trim();
  const normalizedTargetRole = String(targetRole || "").trim();
  if (!inviterUid || !["customer", "owner"].includes(normalizedInviterRole) ||
      !["customer", "owner"].includes(normalizedTargetRole)) {
    return {hasLimit: false, maximumInvitesPerAccount: 0};
  }
  const sourceType = normalizedTargetRole === "owner" ?
    "referral_salon" : "referral_customer";
  const qualificationEvent = normalizedTargetRole === "owner" ?
    "salon_approved_and_first_completed_booking" :
    "first_completed_booking";
  const nowMillis = Date.now();
  const snapshot = await transaction.get(
    firestore.collection("proinPrograms")
      .where("sourceType", "==", sourceType)
      .where("active", "==", true)
      .limit(50),
  );
  const limits = snapshot.docs
    .map((document) => document.data())
    .filter((program) =>
      String(program.rewardRecipient || "") === "inviter" &&
      String(program.referralInviterRole || "") === normalizedInviterRole &&
      String(program.referralTargetRole || "") === normalizedTargetRole &&
      String(program.qualificationEvent || "") === qualificationEvent &&
      adminMillis(program.startsAt) <= nowMillis &&
      adminMillis(program.endsAt) > nowMillis)
    .map((program) => money(program.maximumGrantsPerAccount))
    .filter((value) => value > 0);
  if (!limits.length) {
    return {hasLimit: false, maximumInvitesPerAccount: 0};
  }
  return {
    hasLimit: true,
    maximumInvitesPerAccount: Math.min(...limits),
  };
}

exports.getReferralSummary = onMobileCall(
  {enforceAppCheck: true, invoker: "public", cpu: 1},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    const firestore = admin.firestore();
    const userSnapshot = await firestore.collection("users").doc(uid).get();
    const role = inferStoredRole(userSnapshot.data(), false);
    if (role !== "customer" && role !== "owner") {
      throw new HttpsError("permission-denied", "Referral summary unavailable.");
    }
    const [statsSnapshot, programsSnapshot, outgoingSnapshot,
      incomingSnapshot] = await Promise.all([
      firestore.collection("referralStats").doc(uid).get(),
      firestore.collection("proinPrograms")
        .where("active", "==", true).limit(100).get(),
      firestore.collection("referrals")
        .where("inviterUid", "==", uid).limit(100).get(),
      firestore.collection("referrals").doc(uid).get(),
    ]);
    const data = statsSnapshot.data() ?? {};
    const referrals = outgoingSnapshot.docs.map((document) => ({
      referralId: document.id,
      ...document.data(),
    }));
    if (incomingSnapshot.exists) {
      referrals.push({
        referralId: incomingSnapshot.id,
        ...incomingSnapshot.data(),
      });
    }
    const rewards = referralRewardSummary({
      inviterUid: uid,
      inviterRole: role,
      nowMillis: Date.now(),
      programs: programsSnapshot.docs.map((document) => ({
        ...document.data(),
        startsAtMillis: adminMillis(document.data()?.startsAt),
        endsAtMillis: adminMillis(document.data()?.endsAt),
      })),
      referrals,
    });
    return {
      pendingCustomerCount: money(data.pendingCustomerCount),
      qualifiedCustomerCount: money(data.qualifiedCustomerCount),
      pendingSalonCount: role === "owner" ? money(data.pendingSalonCount) : 0,
      qualifiedSalonCount: role === "owner" ?
        money(data.qualifiedSalonCount) : 0,
      ...rewards,
    };
  },
);

exports.linkOwnerPhoneLogin = onMobileCall(
  {enforceAppCheck: true, invoker: "public", cpu: 1},
  (request) => linkOwnerPhoneLogin({
    uid: requireAuthenticatedUid(request),
    phoneIdToken: request.data?.phoneIdToken,
    firestore: admin.firestore(),
    auth: admin.auth(),
  }),
);

exports.claimOwnerProfilePhone = onMobileCall(
  {enforceAppCheck: false, invoker: "public", cpu: "gcf_gen1"},
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in first.");
    }

    const phone = normalizeVerifiedPhone(request.data?.phone);
    if (!phone) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a valid salon phone number.",
      );
    }

    const firestore = admin.firestore();
    const userRef = firestore.collection("users").doc(uid);
    const phoneRef = firestore
      .collection("loginIdentifiers")
      .doc(phoneKey(phone));
    const ownerSalons = await firestore
      .collection("salons")
      .where("ownerUid", "==", uid)
      .limit(1)
      .get();
    const salonsUsingPhone = await firestore
      .collection("salons")
      .where("phone", "==", phone)
      .limit(2)
      .get();
    if (salonsUsingPhone.docs.some((doc) => doc.data().ownerUid !== uid)) {
      throw new HttpsError(
        "already-exists",
        "Unable to save this salon because this phone number is already " +
          "registered to another salon owner account.",
      );
    }

    let phoneAuthUser = null;
    try {
      phoneAuthUser = await admin.auth().getUserByPhoneNumber(phone);
    } catch (error) {
      if (error.code !== "auth/user-not-found") {
        throw error;
      }
    }
    const otherUserRef = phoneAuthUser && phoneAuthUser.uid !== uid ?
      firestore.collection("users").doc(phoneAuthUser.uid) :
      null;

    await firestore.runTransaction(async (transaction) => {
      const userSnapshot = await transaction.get(userRef);
      const phoneSnapshot = await transaction.get(phoneRef);
      const otherUserSnapshot = otherUserRef ?
        await transaction.get(otherUserRef) :
        null;
      const userData = userSnapshot.data() ?? {};
      const storedRole = inferStoredRole(userData, !ownerSalons.empty);
      if (storedRole !== "owner") {
        throw new HttpsError(
          "permission-denied",
          "Only a signed-in salon owner can save a salon phone number.",
        );
      }

      const claimedPhoneRole = normalizeRole(phoneSnapshot.data()?.role);
      if (claimedPhoneRole === "customer") {
        throw new HttpsError(
          "already-exists",
          "Unable to save this salon because this phone number is already " +
            "registered as a customer.",
        );
      }
      if (phoneSnapshot.exists && phoneSnapshot.data()?.uid !== uid) {
        throw new HttpsError(
          "already-exists",
          "Unable to save this salon because this phone number is already " +
            "registered to another salon owner account.",
        );
      }

      const phoneAlreadyClaimedByThisOwner =
        phoneSnapshot.exists &&
        claimedPhoneRole === "owner" &&
        phoneSnapshot.data()?.uid === uid;
      if (otherUserSnapshot && !phoneAlreadyClaimedByThisOwner) {
        const otherRole = inferStoredRole(otherUserSnapshot.data(), false);
        if (otherRole === "customer") {
          throw new HttpsError(
            "already-exists",
            "Unable to save this salon because this phone number is already " +
              "registered as a customer.",
          );
        }
        throw new HttpsError(
          "already-exists",
          "Unable to save this salon because this phone number belongs to " +
            "another account.",
        );
      }

      const previousProfilePhone = normalizeVerifiedPhone(
        userData.profilePhone,
      );
      let previousPhoneRef = null;
      let previousPhoneSnapshot = null;
      if (previousProfilePhone && previousProfilePhone !== phone) {
        previousPhoneRef = firestore
          .collection("loginIdentifiers")
          .doc(phoneKey(previousProfilePhone));
        previousPhoneSnapshot = await transaction.get(previousPhoneRef);
      }

      transaction.set(userRef, {
        profilePhone: phone,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.set(phoneRef, {
        phone,
        role: "owner",
        uid,
        source: "salon_profile",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      const authPhone = normalizeVerifiedPhone(userData.phone);
      if (
        previousPhoneRef &&
        previousProfilePhone !== authPhone &&
        previousPhoneSnapshot?.data()?.uid === uid
      ) {
        transaction.delete(previousPhoneRef);
      }
    });

    return {phone, role: "owner"};
  },
);

// Salon-owner edits used to write the complete public salon document from the
// phone. A harmless toggle or price change could therefore be rejected by an
// unrelated legacy profile field, while an offline Firestore write left the
// button waiting indefinitely. These focused, idempotent callables validate
// ownership once and update only the requested resource.
exports.saveOwnerSalonProfile = onMobileCall(
  {enforceAppCheck: false, invoker: "public", cpu: 1},
  async (request) => {
    const startedAt = Date.now();
    const uid = requireAuthenticatedUid(request);
    const salonId = validOwnerResourceId(
      request.data?.salonId,
      "salon id",
    );
    const name = normalizeDisplayName(request.data?.name);
    const ownerName = normalizeDisplayName(request.data?.ownerName);
    const address = adminString(request.data?.address).slice(0, 500);
    const directionsUrl = adminHttpsUrl(request.data?.directionsUrl);
    const phone = normalizeVerifiedPhone(request.data?.phone);
    const email = normalizeEmail(request.data?.email);
    const logoUrl = adminHttpsUrl(request.data?.logoUrl);
    const photoUrls = sanitizePhotoUrls(request.data?.photoUrls);
    const openTime = adminSalonTime(request.data?.openTime);
    const closeTime = adminSalonTime(request.data?.closeTime);
    if (!name || !ownerName || !address) {
      throw new HttpsError(
        "invalid-argument",
        "Salon name, owner name and address are required.",
      );
    }
    if (!phone) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a valid salon phone number.",
      );
    }
    if (!email) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a valid salon email address.",
      );
    }
    if (directionsUrl === null || logoUrl === null) {
      throw new HttpsError(
        "invalid-argument",
        "Salon links and images must use secure https links.",
      );
    }
    if (!openTime || !closeTime ||
        adminSalonMinutes(closeTime) <= adminSalonMinutes(openTime)) {
      throw new HttpsError(
        "invalid-argument",
        "Enter valid opening and closing times, with closing after opening.",
      );
    }

    const firestore = admin.firestore();
    const salonRef = firestore.collection("salons").doc(salonId);
    const [salonSnapshot, ownerSnapshot] = await Promise.all([
      salonRef.get(),
      firestore.collection("users").doc(uid).get(),
    ]);
    requireStoredRole(ownerSnapshot.data(), "owner");
    const previous = salonSnapshot.data();
    if (previous && previous.ownerUid !== uid) {
      throw new HttpsError(
        "permission-denied",
        "Only this salon's owner can edit its details.",
      );
    }
    if (previous?.adminSuspended === true) {
      throw new HttpsError(
        "failed-precondition",
        "This salon is suspended. Contact Pritze support.",
      );
    }
    const previousPhone = normalizeVerifiedPhone(previous?.phone);
    const storedProfilePhone = normalizeVerifiedPhone(
      ownerSnapshot.data()?.profilePhone,
    );
    if (previousPhone !== phone || storedProfilePhone !== phone) {
      await claimOwnerProfilePhoneForUid({uid, phone});
    }
    const services = canonicalizeSalonServices(
      previous?.services || request.data?.services,
    );
    await salonRef.set({
      ownerUid: uid,
      name,
      ownerName,
      address,
      directionsUrl,
      phone,
      email,
      logoUrl,
      photoUrls,
      distanceLabel: adminString(previous?.distanceLabel) || "Nearby",
      openTime,
      closeTime,
      isOpen: previous ? previous.isOpen === true : true,
      instantBookingsEnabled:
        previous ? previous.instantBookingsEnabled !== false : true,
      instantBookingsPausedDate: "",
      approvalStatus: previous ? salonApprovalStatus(previous) : "pending",
      services,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    console.log("owner salon profile saved", {
      uid,
      salonId,
      durationMs: Date.now() - startedAt,
    });
    return {salonId, name, phone, email};
  },
);

exports.setOwnerInstantBookingEnabled = onMobileCall(
  {enforceAppCheck: false, invoker: "public", cpu: 1},
  async (request) => {
    const startedAt = Date.now();
    const uid = requireAuthenticatedUid(request);
    const salonId = validOwnerResourceId(
      request.data?.salonId,
      "salon id",
    );
    const enabled = request.data?.enabled;
    if (typeof enabled !== "boolean") {
      throw new HttpsError(
        "invalid-argument",
        "Choose whether instant bookings are on or off.",
      );
    }
    const {salonRef} = await requireOwnedSalon({uid, salonId});
    await salonRef.update({
      instantBookingsEnabled: enabled,
      // Kept only for compatibility with installed builds. Off is now
      // persistent instead of silently resetting on the next calendar day.
      instantBookingsPausedDate: "",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log("owner instant booking availability saved", {
      uid,
      salonId,
      enabled,
      durationMs: Date.now() - startedAt,
    });
    return {salonId, enabled};
  },
);

exports.saveOwnerSalonServices = onMobileCall(
  {enforceAppCheck: false, invoker: "public", cpu: 1},
  async (request) => {
    const startedAt = Date.now();
    const uid = requireAuthenticatedUid(request);
    const salonId = validOwnerResourceId(
      request.data?.salonId,
      "salon id",
    );
    const {salonRef} = await requireOwnedSalon({uid, salonId});
    const submitted = Array.isArray(request.data?.services) ?
      request.data.services : [];
    const services = canonicalizeSalonServices(submitted);
    await salonRef.update({
      services,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log("owner salon services saved", {
      uid,
      salonId,
      serviceCount: services.length,
      durationMs: Date.now() - startedAt,
    });
    return {salonId, serviceCount: services.length};
  },
);

exports.saveOwnerBarber = onMobileCall(
  {enforceAppCheck: false, invoker: "public", cpu: 1},
  async (request) => {
    const startedAt = Date.now();
    const uid = requireAuthenticatedUid(request);
    const salonId = validOwnerResourceId(
      request.data?.salonId,
      "salon id",
    );
    const barberId = validOwnerResourceId(
      request.data?.barberId,
      "barber id",
    );
    const name = normalizeDisplayName(request.data?.name);
    const rawPhone = adminString(request.data?.phone);
    const phone = rawPhone ? normalizeVerifiedPhone(rawPhone) : "";
    const speciality = adminString(request.data?.speciality).slice(0, 120);
    const experienceYears = Number(request.data?.experienceYears);
    const resumeSummary = adminString(request.data?.resumeSummary)
      .slice(0, 1000);
    const isActive = request.data?.isActive !== false;
    if (!name) {
      throw new HttpsError("invalid-argument", "Enter the barber's name.");
    }
    if (rawPhone && !phone) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a valid barber phone number.",
      );
    }
    if (!Number.isInteger(experienceYears) ||
        experienceYears < 0 || experienceYears > 80) {
      throw new HttpsError(
        "invalid-argument",
        "Enter valid years of experience.",
      );
    }
    const {firestore, salon} = await requireOwnedSalon({uid, salonId});
    const validServiceIds = new Set(
      canonicalizeSalonServices(salon.services).map((service) => service.id),
    );
    // Match against the salon catalogue BEFORE capping. Capping first threw
    // away every valid id for barbers whose stored list still carries the
    // legacy catalogue, so saving them failed with "assign at least one
    // service" even though the owner did have services selected.
    const serviceIds = [
      ...new Set(
          adminStringList(request.data?.serviceIds, 1000)
              .filter((serviceId) => validServiceIds.has(serviceId)),
      ),
    ].slice(0, 100);
    if (isActive && serviceIds.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "Assign at least one service to this barber.",
      );
    }
    const barberRef = firestore.collection("barbers").doc(barberId);
    await firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(barberRef);
      if (snapshot.exists &&
          (snapshot.data()?.ownerUid !== uid ||
            snapshot.data()?.salonId !== salonId)) {
        throw new HttpsError(
          "permission-denied",
          "Only this salon's owner can edit this barber.",
        );
      }
      transaction.set(barberRef, {
        ownerUid: uid,
        salonId,
        name,
        phone,
        email: "",
        speciality: speciality || "Grooming expert",
        experienceYears,
        resumeSummary: resumeSummary ||
          "Customer-first grooming professional.",
        serviceIds,
        isActive,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        ...(snapshot.exists ? {} : {
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }),
      }, {merge: true});
    });
    console.log("owner barber saved", {
      uid,
      salonId,
      barberId,
      isActive,
      durationMs: Date.now() - startedAt,
    });
    return {salonId, barberId, isActive};
  },
);

exports.updateCustomerProfile = onMobileCall(
  {enforceAppCheck: false, invoker: "public", cpu: "gcf_gen1"},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    const name = normalizeDisplayName(request.data?.name);
    const phone = normalizeVerifiedPhone(request.data?.phone);
    const gender = normalizeProfileGender(request.data?.gender);
    const birthDate = normalizeBirthDate(request.data?.birthDate);
    const preferredStyles = sanitizeShortList(request.data?.preferredStyles);
    const stylePhotoUrls = sanitizePhotoUrls(request.data?.stylePhotoUrls);
    const photoUrl = sanitizePhotoUrls([request.data?.photoUrl], 1)[0] || "";
    if (!name) {
      throw new HttpsError("invalid-argument", "Enter your name.");
    }
    if (!/^\+91\d{10}$/.test(phone)) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a valid 10-digit Indian mobile number.",
      );
    }
    if (gender === null || birthDate === null) {
      throw new HttpsError("invalid-argument", "Check your profile details.");
    }

    const firestore = admin.firestore();
    const userRef = firestore.collection("users").doc(uid);
    const userSnapshot = await userRef.get();
    const userData = userSnapshot.data();
    requireStoredRole(userData, "customer");
    const oldPhone = normalizeVerifiedPhone(userData?.phone || userData?.contact);
    const newPhoneRef = firestore.collection("loginIdentifiers").doc(phoneKey(phone));

    let phoneAuthUser = null;
    try {
      phoneAuthUser = await admin.auth().getUserByPhoneNumber(phone);
    } catch (error) {
      if (error.code !== "auth/user-not-found") throw error;
    }
    if (phoneAuthUser && phoneAuthUser.uid !== uid) {
      throw new HttpsError(
        "already-exists",
        "This phone number already belongs to another account.",
      );
    }

    await firestore.runTransaction(async (transaction) => {
      const latestUser = await transaction.get(userRef);
      const phoneSnapshot = await transaction.get(newPhoneRef);
      requireStoredRole(latestUser.data(), "customer");
      const claimedRole = normalizeRole(phoneSnapshot.data()?.role);
      if (claimedRole === "owner") {
        throw new HttpsError(
          "already-exists",
          "Unable to save this number because it is already registered as a salon owner.",
        );
      }
      if (phoneSnapshot.exists && phoneSnapshot.data()?.uid !== uid) {
        throw new HttpsError(
          "already-exists",
          "This phone number already belongs to another customer.",
        );
      }

      let oldPhoneRef = null;
      let oldPhoneSnapshot = null;
      if (oldPhone && oldPhone !== phone) {
        oldPhoneRef = firestore.collection("loginIdentifiers")
          .doc(phoneKey(oldPhone));
        oldPhoneSnapshot = await transaction.get(oldPhoneRef);
      }

      transaction.set(userRef, {
        name,
        contact: phone,
        phone,
        gender,
        birthDate,
        preferredStyles,
        photoUrl,
        stylePhotoUrls,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.set(newPhoneRef, {
        phone,
        role: "customer",
        uid,
        source: "customer_profile",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      if (oldPhoneRef && oldPhoneSnapshot?.data()?.uid === uid) {
          transaction.delete(oldPhoneRef);
      }
    });

    await admin.auth().updateUser(uid, {displayName: name, phoneNumber: phone});
    return {name, phone};
  },
);

exports.submitSalonFeedback = onMobileCall(
  {invoker: "public", cpu: "gcf_gen1"},
  async (request) => {
  const uid = requireAuthenticatedUid(request);
  const bookingId = requiredId(request.data?.bookingId, "booking id");
  const rating = normalizeVisitRating(request.data?.rating);
  const note = normalizeFeedbackNote(request.data?.note);
  if (rating === null) {
    throw new HttpsError("invalid-argument", "Choose a rating from 1 to 5.");
  }
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const feedbackRef = firestore.collection("salonFeedback").doc(bookingId);
  await firestore.runTransaction(async (transaction) => {
    const bookingSnapshot = await transaction.get(bookingRef);
    const userSnapshot = await transaction.get(
      firestore.collection("users").doc(uid),
    );
    const booking = bookingSnapshot.data();
    requireStoredRole(userSnapshot.data(), "customer");
    if (!booking || booking.customerUid !== uid || booking.status !== "completed") {
      throw new HttpsError(
        "failed-precondition",
        "Feedback is available after a completed appointment.",
      );
    }
    const salonRef = firestore.collection("salons").doc(booking.salonId);
    const salonSnapshot = await transaction.get(salonRef);
    const existing = await transaction.get(feedbackRef);
    const salon = salonSnapshot.data() || {};
    const oldRating = Number(existing.data()?.rating || 0);
    const currentCount = Number(salon.reviewCount || 0);
    const nextCount = existing.exists ? Math.max(1, currentCount) : currentCount + 1;
    const nextTotal = Number(salon.rating || 0) * currentCount - oldRating + rating;
    transaction.set(feedbackRef, {
      bookingId,
      customerUid: uid,
      ownerUid: booking.ownerUid,
      salonId: booking.salonId,
      salonName: String(salon.name || "Salon"),
      rating,
      note,
      createdAt: existing.data()?.createdAt ||
        admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    transaction.set(salonRef, {
      rating: nextTotal / nextCount,
      reviewCount: nextCount,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
  });
  return {bookingId, rating};
  },
);

exports.submitCustomerRating = onMobileCall(
  {invoker: "public", cpu: "gcf_gen1"},
  async (request) => {
  const uid = requireAuthenticatedUid(request);
  const bookingId = requiredId(request.data?.bookingId, "booking id");
  const rating = normalizeVisitRating(request.data?.rating);
  const note = normalizeFeedbackNote(request.data?.note);
  if (rating === null) {
    throw new HttpsError("invalid-argument", "Choose a rating from 1 to 5.");
  }
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const ratingRef = firestore.collection("customerRatings").doc(bookingId);
  await firestore.runTransaction(async (transaction) => {
    const bookingSnapshot = await transaction.get(bookingRef);
    const ownerSnapshot = await transaction.get(
      firestore.collection("users").doc(uid),
    );
    const booking = bookingSnapshot.data();
    requireStoredRole(ownerSnapshot.data(), "owner");
    if (!booking || booking.ownerUid !== uid || booking.status !== "completed") {
      throw new HttpsError(
        "failed-precondition",
        "Customer ratings are available after completed visits.",
      );
    }
    const customerUid = String(booking.customerUid || "").trim();
    if (!customerUid) {
      throw new HttpsError("failed-precondition", "Customer account not found.");
    }
    const customerRef = firestore.collection("users").doc(customerUid);
    const salonRef = firestore.collection("salons").doc(booking.salonId);
    const customerSnapshot = await transaction.get(customerRef);
    const salonSnapshot = await transaction.get(salonRef);
    const existing = await transaction.get(ratingRef);
    requireStoredRole(customerSnapshot.data(), "customer");
    const customer = customerSnapshot.data() || {};
    const oldRating = Number(existing.data()?.rating || 0);
    const currentCount = Number(customer.salonRatingCount || 0);
    const nextCount = existing.exists ? Math.max(1, currentCount) : currentCount + 1;
    const nextTotal = Number(customer.salonRating || 0) * currentCount - oldRating + rating;
    transaction.set(ratingRef, {
      bookingId,
      customerUid,
      ownerUid: uid,
      salonId: booking.salonId,
      salonName: String(salonSnapshot.data()?.name || "Salon"),
      rating,
      note,
      createdAt: existing.data()?.createdAt ||
        admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    transaction.set(customerRef, {
      salonRating: nextTotal / nextCount,
      salonRatingCount: nextCount,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
  });
  return {bookingId, rating};
  },
);

function buildDiscountContext({
  customerUid,
  salonId,
  serviceIds,
  serviceAmounts = {},
  originalAmount,
  bookings = [],
  completedBookingCount,
  salonCompletedCount,
  nowMillis,
}) {
  const completed = bookings.filter((booking) => booking.status === "completed");
  return {
    customerUid,
    salonId,
    serviceIds,
    serviceAmounts,
    originalAmount: money(originalAmount),
    completedBookingCount: Number.isInteger(completedBookingCount) ?
      completedBookingCount : completed.length,
    salonCompletedCount: Number.isInteger(salonCompletedCount) ?
      salonCompletedCount : completed.filter(
        (booking) => booking.salonId === salonId,
      ).length,
    nowMillis,
  };
}

async function loadDiscountVisitCounts(
  firestore,
  uid,
  salonId,
  user = {},
  preloadedStatSnapshot = null,
) {
  const statRef = firestore.collection("customerSalonStats")
    .doc(`${uid}__${salonId}`);
  const statSnapshot = preloadedStatSnapshot || await statRef.get();
  const storedTotal = Number(user.completedBookingCount);
  const storedSalonTotal = Number(statSnapshot.data()?.completedBookingCount);
  if (Number.isInteger(storedTotal) && storedTotal >= 0 &&
      Number.isInteger(storedSalonTotal) && storedSalonTotal >= 0) {
    return {
      completedBookingCount: storedTotal,
      salonCompletedCount: storedSalonTotal,
    };
  }

  const bookingsSnapshot = await firestore.collection("bookings")
    .where("customerUid", "==", uid)
    .get();
  const completed = bookingsSnapshot.docs
    .map((doc) => doc.data())
    .filter((booking) => booking.status === "completed");
  const completedBookingCount = completed.length;
  const salonCompletedCount = completed.filter(
    (booking) => booking.salonId === salonId,
  ).length;
  const userRef = firestore.collection("users").doc(uid);
  let resolvedTotal = completedBookingCount;
  let resolvedSalonTotal = salonCompletedCount;
  await firestore.runTransaction(async (transaction) => {
    const [currentUserSnapshot, currentStatSnapshot] = await Promise.all([
      transaction.get(userRef),
      transaction.get(statRef),
    ]);
    const currentTotal = Number(currentUserSnapshot.data()?.completedBookingCount);
    const currentSalonTotal = Number(
      currentStatSnapshot.data()?.completedBookingCount,
    );
    if (Number.isInteger(currentTotal) && currentTotal >= 0) {
      resolvedTotal = currentTotal;
    } else {
      transaction.set(userRef, {
        completedBookingCount,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
    }
    if (Number.isInteger(currentSalonTotal) && currentSalonTotal >= 0) {
      resolvedSalonTotal = currentSalonTotal;
    } else {
      transaction.set(statRef, {
        customerUid: uid,
        salonId,
        completedBookingCount: salonCompletedCount,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
    }
  });
  return {
    completedBookingCount: resolvedTotal,
    salonCompletedCount: resolvedSalonTotal,
  };
}

function discountQuoteFromStored(data = {}) {
  return {
    campaignId: String(data.discountCampaignId ?? "").trim(),
    campaignName: String(data.discountCampaignName ?? "").trim(),
    fundingSource: data.discountFundingSource ?
      discountFundingSource(data.discountFundingSource) : "platform_vault",
    discountType: data.discountType === "fixed" ? "fixed" : "percent",
    discountPercent: Number(data.discountPercent) || 0,
    fixedDiscountAmount: money(data.fixedDiscountAmount),
    voucherOnly: data.discountSource === "voucher",
    voucherMaskedCode: String(data.voucherMaskedCode ?? "").trim(),
    originalAmount: money(data.originalAmount),
    discountBaseAmount: money(data.discountBaseAmount),
    discountAmount: money(data.discountAmount),
    customerPayableAmount: money(data.customerPayableAmount),
    pritzePayoutAmount: money(data.pritzePayoutAmount),
    salonTotalEarning: money(data.salonTotalEarning),
    payoutMultiplierApplied: Number(data.payoutMultiplierApplied) || 0,
    salonPayoutPercentApplied: Number(data.salonPayoutPercentApplied) || 0,
    cashbackProinAmount: money(data.cashbackProinAmount),
    cashbackValidityDays: money(data.cashbackValidityDays),
    cashbackProgramId: adminString(data.cashbackProgramId),
    journeyMilestoneBookingNumber:
      money(data.journeyMilestoneBookingNumber),
    journeyCountScope: data.journeyCountScope === "salon" ?
      "salon" : "platform",
  };
}

function lockedDiscountQuoteError({
  quote,
  customerUid,
  salonId,
  serviceIds,
  originalAmount,
  nowMillis,
}) {
  if (!quote) return "This discount quote was not found. Refresh the price.";
  if (quote.customerUid !== customerUid) return "This discount quote is not yours.";
  if (quote.salonId !== salonId) return "This discount quote is for another salon.";
  if (quote.consumedAt) return "This discount quote has already been used.";
  if (!quote.expiresAt?.toMillis || quote.expiresAt.toMillis() <= nowMillis) {
    return "This discount quote expired. Refresh the price before booking.";
  }
  const expectedServices = [...serviceIds].sort().join("|");
  const quotedServices = (Array.isArray(quote.serviceIds) ? quote.serviceIds : [])
    .map((value) => String(value ?? "").trim())
    .filter(Boolean)
    .sort()
    .join("|");
  if (expectedServices !== quotedServices ||
      money(quote.originalAmount) !== money(originalAmount)) {
    return "The selected services changed. Refresh the price before booking.";
  }
  return "";
}

function discountReferences(firestore, campaignId, salonId, customerUid) {
  return {
    campaignRef: firestore.collection("discountCampaigns").doc(campaignId),
    campaignUsageRef: firestore.collection("discountCampaignUsage")
      .doc(campaignId),
    salonUsageRef: firestore.collection("discountSalonUsage")
      .doc(`${campaignId}__${salonId}`),
    customerUsageRef: firestore.collection("discountCustomerUsage")
      .doc(`${campaignId}__${customerUid}`),
    customerTotalRef: firestore.collection("discountCustomerTotals")
      .doc(customerUid),
    salonTotalRef: firestore.collection("discountSalonTotals").doc(salonId),
    platformTotalRef: firestore.collection("discountPlatformTotals")
      .doc("current"),
    vaultRef: firestore.collection("platformFinance").doc("discountVault"),
    salonPromotionWalletRef: firestore.collection("proinWallets")
      .doc(discountSalonPromotionWalletId(salonId)),
    salonPromotionUsageRef: firestore.collection("salonPromotionCreditUsage")
      .doc(discountSalonPromotionWalletId(salonId)),
    salonPromotionReservationRef: firestore
      .collection("discountSalonPromotionCreditReservations"),
    salonPromotionLotsQuery: firestore.collection("proinLots")
      .where("walletId", "==", discountSalonPromotionWalletId(salonId))
      .limit(500),
  };
}

function discountSalonPromotionWalletId(salonId) {
  return crypto.createHash("sha256")
    .update(`salon_promotion_credits:${salonId}`)
    .digest("hex");
}

async function loadCheckoutDiscountContext(firestore, uid, data = {}) {
  const salonId = requiredId(data.salonId, "salon id");
  const serviceIds = [...new Set(
    (Array.isArray(data.serviceIds) ? data.serviceIds : [])
      .map((value) => String(value ?? "").trim())
      .filter(Boolean),
  )];
  if (serviceIds.length === 0 || serviceIds.length > 6) {
    throw new HttpsError("invalid-argument", "Choose between 1 and 6 services.");
  }
  const statRef = firestore.collection("customerSalonStats")
    .doc(`${uid}__${salonId}`);
  const [userSnapshot, salonSnapshot, statSnapshot] = await Promise.all([
    firestore.collection("users").doc(uid).get(),
    firestore.collection("salons").doc(salonId).get(),
    statRef.get(),
  ]);
  requireStoredRole(userSnapshot.data(), "customer");
  const salon = salonSnapshot.data();
  if (!salon) {
    throw new HttpsError("not-found", "Salon not found.");
  }
  const services = serviceIds.map((id) => findSalonService(salon, id));
  if (services.some((service) => !service || service.isAvailable === false)) {
    throw new HttpsError("failed-precondition", "A service is unavailable.");
  }
  const originalAmount = services.reduce(
    (total, service) => total + Math.max(0, Number(service.price) || 0),
    0,
  );
  const visitCounts = await loadDiscountVisitCounts(
    firestore,
    uid,
    salonId,
    userSnapshot.data(),
    statSnapshot,
  );
  const context = buildDiscountContext({
    customerUid: uid,
    salonId,
    serviceIds,
    serviceAmounts: Object.fromEntries(
      services.map((service, index) => [
        serviceIds[index],
        Math.max(0, Number(service.price) || 0),
      ]),
    ),
    originalAmount,
    ...visitCounts,
    nowMillis: Date.now(),
  });
  return {salonId, serviceIds, originalAmount, context};
}

async function persistDiscountQuote(firestore, {
  uid,
  salonId,
  serviceIds,
  originalAmount,
  quote,
}) {
  const quoteRef = firestore.collection("discountQuotes").doc();
  const expiresAtMillis = Date.now() + DISCOUNT_QUOTE_TTL_MS;
  await quoteRef.set({
    quoteId: quoteRef.id,
    customerUid: uid,
    salonId,
    serviceIds: [...serviceIds].sort(),
    originalAmount,
    ...discountBookingFields(quote),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    expiresAt: admin.firestore.Timestamp.fromMillis(expiresAtMillis),
    consumedAt: null,
  });
  return {
    ...quote,
    quoteId: quoteRef.id,
    expiresAtMillis,
  };
}

function quoteForDiscountCampaign(campaignId, campaign, context, vault = {}) {
  const effectiveCampaign = discountCampaignForContext(campaign, context);
  if (!effectiveCampaign) return emptyDiscountQuote(context.originalAmount);
  const customerFacingCampaign = effectiveCampaign
    .journeyMilestoneBookingNumber ? {
      ...effectiveCampaign,
      name: "Pritze offer",
    } : effectiveCampaign;
  return calculateDiscountQuote(
    campaignId,
    customerFacingCampaign,
    context.originalAmount,
    discountBaseAmount(campaign, context),
    discountPayoutMultiplier(
      effectiveCampaign,
      vault,
      effectiveCampaign.journeyMilestoneBookingNumber ||
        context.completedBookingCount + 1,
    ),
  );
}

async function loadDiscountCandidateFunding(firestore, candidates, context) {
  if (candidates.length === 0) return [];
  const sharedRefs = discountReferences(
    firestore,
    "checkout-shared",
    context.salonId,
    context.customerUid,
  );
  const entries = candidates.map((candidate) => ({
    candidate,
    refs: discountReferences(
      firestore,
      candidate.doc.id,
      context.salonId,
      context.customerUid,
    ),
  }));
  const references = [
    sharedRefs.vaultRef,
    sharedRefs.salonPromotionWalletRef,
    ...entries.flatMap(({refs}) => [
      refs.campaignUsageRef,
      refs.salonUsageRef,
      refs.customerUsageRef,
    ]),
  ];
  const snapshotBatches = await Promise.all(
    Array.from(
      {length: Math.ceil(references.length / 100)},
      (_, index) => references.slice(index * 100, (index + 1) * 100),
    ).map((batch) => firestore.getAll(...batch)),
  );
  const snapshots = snapshotBatches.flat();
  const snapshotsByPath = new Map(
    snapshots.map((snapshot) => [snapshot.ref.path, snapshot]),
  );
  const dataFor = (reference) =>
    snapshotsByPath.get(reference.path)?.data();
  const vault = dataFor(sharedRefs.vaultRef);
  const salonCreditWallet = dataFor(sharedRefs.salonPromotionWalletRef);
  return entries.map(({candidate, refs}) => ({
    candidate,
    usage: {
      campaign: dataFor(refs.campaignUsageRef),
      salon: dataFor(refs.salonUsageRef),
      customer: dataFor(refs.customerUsageRef),
      vault,
      salonCreditWallet,
    },
  }));
}

async function findBestActiveDiscountQuote(
  firestore,
  context,
  {journeyOnly = false, campaignsSnapshot: preloadedCampaignsSnapshot} = {},
) {
  const campaignsSnapshot = preloadedCampaignsSnapshot ||
    await firestore.collection("discountCampaigns")
      .where("active", "==", true)
      .limit(50)
      .get();
  const candidates = campaignsSnapshot.docs
    .filter((doc) => doc.data()?.voucherOnly !== true)
    .filter((doc) => discountCampaignEligible(doc.data(), context))
    .map((doc) => ({
      doc,
      campaign: doc.data(),
      quote: quoteForDiscountCampaign(doc.id, doc.data(), context),
    }))
    .filter((candidate) => journeyOnly ?
      Array.isArray(candidate.campaign.journeyMilestones) &&
        candidate.campaign.journeyMilestones.length > 0 &&
        (candidate.quote.discountAmount > 0 ||
          candidate.quote.cashbackProinAmount > 0) :
      candidate.quote.discountAmount > 0)
    .sort((left, right) =>
      right.quote.discountAmount - left.quote.discountAmount ||
      Number(right.campaign.priority ?? 0) -
        Number(left.campaign.priority ?? 0) ||
      left.doc.id.localeCompare(right.doc.id),
    );
  const funding = await loadDiscountCandidateFunding(
    firestore,
    candidates,
    context,
  );
  const evaluatedCandidates = funding.map(({candidate, usage}) => {
    const quote = quoteForDiscountCampaign(
      candidate.doc.id,
      candidate.campaign,
      context,
      usage.vault,
    );
    if (discountBudgetAllows(candidate.campaign, quote, usage)) {
      return {
        ...quote,
        campaignEndsAtMillis: adminMillis(candidate.campaign.endsAt),
      };
    }
    return null;
  });
  const availableQuote = evaluatedCandidates.find(Boolean);
  if (availableQuote) return availableQuote;
  return emptyDiscountQuote(context.originalAmount);
}

async function findVisibleCheckoutDiscountOffers(firestore, context) {
  const campaignsSnapshot = await firestore.collection("discountCampaigns")
    .where("active", "==", true)
    .limit(50)
    .get();
  const candidates = campaignsSnapshot.docs
    .filter((doc) =>
      discountCampaignSelectableAtCheckout(doc.data(), context))
    .map((doc) => {
      const campaign = doc.data();
      return {
        doc,
        campaign,
        quote: quoteForDiscountCampaign(doc.id, campaign, context),
      };
    })
    .filter((candidate) => candidate.quote.discountAmount > 0)
    .sort((left, right) =>
      right.quote.discountAmount - left.quote.discountAmount ||
      Number(right.campaign.priority ?? 0) -
        Number(left.campaign.priority ?? 0) ||
      left.doc.id.localeCompare(right.doc.id),
    );
  const funding = await loadDiscountCandidateFunding(
    firestore,
    candidates,
    context,
  );
  const evaluatedCandidates = funding.map(({candidate, usage}) => {
    const quote = quoteForDiscountCampaign(
      candidate.doc.id,
      candidate.campaign,
      context,
      usage.vault,
    );
    if (discountBudgetAllows(candidate.campaign, quote, usage)) {
      return {
        ...quote,
        campaignEndsAtMillis: adminMillis(candidate.campaign.endsAt),
      };
    }
    return null;
  });
  return evaluatedCandidates.filter(Boolean).slice(0, 10);
}

async function findVisibleCheckoutDiscountQuote(firestore, context, campaignId) {
  const snapshot = await firestore.collection("discountCampaigns")
    .doc(campaignId)
    .get();
  const campaign = snapshot.data();
  if (!campaign ||
      !discountCampaignSelectableAtCheckout(campaign, context)) {
    return emptyDiscountQuote(context.originalAmount);
  }
  const refs = discountReferences(
    firestore,
    snapshot.id,
    context.salonId,
    context.customerUid,
  );
  const [
    campaignUsage,
    salonUsage,
    customerUsage,
    vault,
    salonCreditWallet,
  ] = await Promise.all([
    refs.campaignUsageRef.get(),
    refs.salonUsageRef.get(),
    refs.customerUsageRef.get(),
    refs.vaultRef.get(),
    refs.salonPromotionWalletRef.get(),
  ]);
  const quote = quoteForDiscountCampaign(
    snapshot.id,
    campaign,
    context,
    vault.data(),
  );
  if (!discountBudgetAllows(campaign, quote, {
    campaign: campaignUsage.data(),
    salon: salonUsage.data(),
    customer: customerUsage.data(),
    vault: vault.data(),
    salonCreditWallet: salonCreditWallet.data(),
  })) {
    return emptyDiscountQuote(context.originalAmount);
  }
  return {
    ...quote,
    campaignEndsAtMillis: adminMillis(campaign.endsAt),
  };
}

async function findVoucherDiscountQuote(firestore, context, codeHash) {
  const campaignsSnapshot = await firestore.collection("discountCampaigns")
    .where("voucherCodeHash", "==", codeHash)
    .limit(2)
    .get();
  if (campaignsSnapshot.size !== 1) {
    return emptyDiscountQuote(context.originalAmount);
  }
  const funding = await loadVoucherDiscountFunding(
    firestore,
    campaignsSnapshot.docs[0].id,
    context.salonId,
    context.customerUid,
    campaignsSnapshot.docs[0],
  );
  return voucherDiscountQuoteFromFunding(context, codeHash, funding);
}

async function loadVoucherDiscountFunding(
  firestore,
  campaignId,
  salonId,
  customerUid,
  campaignDocument = null,
) {
  const refs = discountReferences(
    firestore,
    campaignId,
    salonId,
    customerUid,
  );
  const [
    document,
    campaignUsage,
    salonUsage,
    customerUsage,
    vault,
    salonCreditWallet,
  ] = await Promise.all([
    campaignDocument || firestore.collection("discountCampaigns")
      .doc(campaignId).get(),
    refs.campaignUsageRef.get(),
    refs.salonUsageRef.get(),
    refs.customerUsageRef.get(),
    refs.vaultRef.get(),
    refs.salonPromotionWalletRef.get(),
  ]);
  return {
    document,
    campaignUsage,
    salonUsage,
    customerUsage,
    vault,
    salonCreditWallet,
  };
}

function voucherDiscountQuoteFromFunding(context, codeHash, funding) {
  const campaign = funding.document.data();
  if (!campaign ||
      campaign.voucherOnly !== true ||
      String(campaign.voucherCodeHash || "") !== codeHash ||
      !discountCampaignEligible(campaign, context)) {
    return emptyDiscountQuote(context.originalAmount);
  }
  const quote = quoteForDiscountCampaign(
    funding.document.id,
    campaign,
    context,
    funding.vault.data(),
  );
  if (!discountBudgetAllows(campaign, quote, {
    campaign: funding.campaignUsage.data(),
    salon: funding.salonUsage.data(),
    customer: funding.customerUsage.data(),
    vault: funding.vault.data(),
    salonCreditWallet: funding.salonCreditWallet.data(),
  })) {
    return emptyDiscountQuote(context.originalAmount);
  }
  return {
    ...quote,
    campaignEndsAtMillis: adminMillis(campaign.endsAt),
  };
}

function discountBookingFields(quote) {
  return {
    discountCampaignId: quote.campaignId,
    discountCampaignName: quote.campaignName,
    discountType: quote.discountType === "fixed" ? "fixed" : "percent",
    discountPercent: quote.discountPercent,
    fixedDiscountAmount: money(quote.fixedDiscountAmount),
    discountFundingSource: quote.campaignId ?
      discountFundingSource(quote) : "none",
    discountSource: quote.voucherOnly === true ? "voucher" :
      (quote.campaignId ? "automatic" : "none"),
    voucherMaskedCode: String(quote.voucherMaskedCode ?? "").trim(),
    discountBaseAmount: quote.discountBaseAmount,
    discountAmount: quote.discountAmount,
    customerPayableAmount: quote.customerPayableAmount,
    pritzePayoutAmount: quote.pritzePayoutAmount,
    salonTotalEarning: quote.salonTotalEarning,
    payoutMultiplierApplied: Number(quote.payoutMultiplierApplied) || 0,
    salonPayoutPercentApplied:
      Number(quote.salonPayoutPercentApplied) || 0,
    cashbackProinAmount: money(quote.cashbackProinAmount),
    cashbackValidityDays: money(quote.cashbackValidityDays),
    cashbackProgramId: adminString(quote.cashbackProgramId),
    journeyMilestoneBookingNumber:
      money(quote.journeyMilestoneBookingNumber),
    journeyCountScope: quote.journeyMilestoneBookingNumber ?
      (quote.journeyCountScope === "salon" ? "salon" : "platform") : "",
    discountCashbackStatus: quote.cashbackProinAmount > 0 ? "pending" : "none",
    discountStatus: quote.campaignId ? "reserved" : "none",
  };
}

function usageReservationUpdate(quote, metadata) {
  return {
    ...metadata,
    reservedDiscountAmount: admin.firestore.FieldValue.increment(
      quote.discountAmount,
    ),
    reservedPayoutAmount: admin.firestore.FieldValue.increment(
      quote.pritzePayoutAmount,
    ),
    reservedUses: admin.firestore.FieldValue.increment(1),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

function reserveDiscountInTransaction(
  transaction,
  refs,
  quote,
  {bookingId, salonId, customerUid, fundingState = null},
) {
  transaction.set(refs.campaignUsageRef, usageReservationUpdate(quote, {
    campaignId: quote.campaignId,
  }), {merge: true});
  transaction.set(refs.salonUsageRef, usageReservationUpdate(quote, {
    campaignId: quote.campaignId,
    salonId,
  }), {merge: true});
  transaction.set(refs.customerUsageRef, usageReservationUpdate(quote, {
    campaignId: quote.campaignId,
    customerUid,
  }), {merge: true});
  transaction.set(refs.customerTotalRef, usageReservationUpdate(quote, {
    customerUid,
  }), {merge: true});
  transaction.set(refs.salonTotalRef, usageReservationUpdate(quote, {
    salonId,
  }), {merge: true});
  transaction.set(refs.platformTotalRef, usageReservationUpdate(quote, {
    scope: "platform",
  }), {merge: true});
  transaction.set(refs.vaultRef, {
    availableAmount: admin.firestore.FieldValue.increment(
      -quote.pritzePayoutAmount,
    ),
    reservedAmount: admin.firestore.FieldValue.increment(
      quote.pritzePayoutAmount,
    ),
    lastReservedBookingId: bookingId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});
  if (discountFundingSource(quote) !== "salon_promotion_credits") return;
  reserveSalonPromotionCreditInTransaction({
    transaction,
    refs,
    quote,
    bookingId,
    salonId,
    fundingState,
  });
}

function resolveReservedDiscountInTransaction({
  transaction,
  firestore,
  refs,
  booking,
  bookingId,
  outcome,
  fundingState = null,
}) {
  const discountAmount = money(booking.discountAmount);
  const payoutAmount = money(booking.pritzePayoutAmount);
  const isRedeemed = outcome === "redeemed";
  const metricPrefix = isRedeemed ? "realized" : "released";
  const resolution = {
    reservedDiscountAmount: admin.firestore.FieldValue.increment(
      -discountAmount,
    ),
    reservedPayoutAmount: admin.firestore.FieldValue.increment(-payoutAmount),
    reservedUses: admin.firestore.FieldValue.increment(-1),
    [`${metricPrefix}DiscountAmount`]: admin.firestore.FieldValue.increment(
      discountAmount,
    ),
    [`${metricPrefix}PayoutAmount`]: admin.firestore.FieldValue.increment(
      payoutAmount,
    ),
    [`${metricPrefix}Uses`]: admin.firestore.FieldValue.increment(1),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  transaction.set(refs.campaignUsageRef, resolution, {merge: true});
  transaction.set(refs.salonUsageRef, resolution, {merge: true});
  transaction.set(refs.customerUsageRef, resolution, {merge: true});
  if (booking.discountGlobalTotalsTracked === true) {
    transaction.set(refs.customerTotalRef, resolution, {merge: true});
    transaction.set(refs.salonTotalRef, resolution, {merge: true});
    transaction.set(refs.platformTotalRef, resolution, {merge: true});
  }
  transaction.set(refs.vaultRef, isRedeemed ? {
    reservedAmount: admin.firestore.FieldValue.increment(-payoutAmount),
    spentAmount: admin.firestore.FieldValue.increment(payoutAmount),
    lastRedeemedBookingId: bookingId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  } : {
    reservedAmount: admin.firestore.FieldValue.increment(-payoutAmount),
    availableAmount: admin.firestore.FieldValue.increment(payoutAmount),
    lastReleasedBookingId: bookingId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});
  if (isSalonPromotionCreditFundedDiscount(booking)) {
    resolveSalonPromotionCreditInTransaction({
      transaction,
      firestore,
      refs,
      booking,
      bookingId,
      outcome,
      fundingState,
    });
  }

  if (!isRedeemed || payoutAmount <= 0) return;
  const salonId = String(booking.salonId ?? "").trim();
  transaction.set(firestore.collection("salonWallets").doc(salonId), {
    salonId,
    payableBalance: admin.firestore.FieldValue.increment(payoutAmount),
    lifetimePritzeEarnings: admin.firestore.FieldValue.increment(payoutAmount),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});
  transaction.set(firestore.collection("salonSettlements").doc(bookingId), {
    bookingId,
    salonId,
    customerUid: booking.customerUid,
    campaignId: booking.discountCampaignId,
    originalAmount: money(booking.servicePrice),
    discountAmount,
    customerCounterAmount: money(booking.customerPayableAmount),
    pritzePayoutAmount: payoutAmount,
    salonTotalEarning: money(booking.salonTotalEarning),
    status: "payable",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: false});
}

function reserveSalonPromotionCreditInTransaction({
  transaction,
  refs,
  quote,
  bookingId,
  salonId,
  fundingState,
}) {
  const payoutAmount = money(quote.pritzePayoutAmount);
  if (payoutAmount <= 0) return;
  const wallet = fundingState?.salonCreditWallet || {};
  const vault = fundingState?.vault || {};
  const creditLimitProin = discountSalonPromotionCreditLimit(vault, wallet);
  const availableBefore = signedMoney(wallet.availableProin);
  const reservedBefore = money(wallet.reservedProin);
  if (availableBefore + creditLimitProin < payoutAmount) {
    throw new HttpsError(
      "resource-exhausted",
      "This salon has reached its promotional credit limit.",
    );
  }
  const timestamp = admin.firestore.FieldValue.serverTimestamp();
  const nowMillis = Date.now();
  const targetLotBackedAmount = Math.min(
    payoutAmount,
    Math.max(0, availableBefore),
  );
  const lotAllocations = [];
  let remainingLotBackedAmount = targetLotBackedAmount;
  const lots = Array.isArray(fundingState?.salonCreditLots) ?
    [...fundingState.salonCreditLots] : [];
  for (const lot of lots.sort((left, right) =>
    adminMillis(left.expiresAt) - adminMillis(right.expiresAt) ||
    adminMillis(left.earnedAt) - adminMillis(right.earnedAt) ||
    String(left.id || "").localeCompare(String(right.id || "")),
  )) {
    if (remainingLotBackedAmount <= 0) break;
    const available = money(lot.availableProin);
    if (!lot.ref || lot.status !== "active" || available <= 0 ||
        adminMillis(lot.expiresAt) <= nowMillis) {
      continue;
    }
    const amountProin = Math.min(remainingLotBackedAmount, available);
    const availableAfter = available - amountProin;
    const reservedAfter = money(lot.reservedProin) + amountProin;
    lotAllocations.push({lotId: lot.id, amountProin});
    remainingLotBackedAmount -= amountProin;
    transaction.update(lot.ref, {
      availableProin: availableAfter,
      reservedProin: reservedAfter,
      status: discountPromotionLotStatus({
        availableProin: availableAfter,
        reservedProin: reservedAfter,
        redeemedProin: money(lot.redeemedProin),
        expiredProin: money(lot.expiredProin),
        revokedProin: money(lot.revokedProin),
      }),
      updatedAt: timestamp,
    });
  }
  const lotBackedProin = lotAllocations.reduce(
    (total, allocation) => total + allocation.amountProin,
    0,
  );
  const creditLineProin = payoutAmount - lotBackedProin;
  const availableAfter = availableBefore - payoutAmount;
  const reservedAfter = reservedBefore + payoutAmount;
  if (availableAfter < -creditLimitProin) {
    throw new HttpsError(
      "resource-exhausted",
      "This salon has reached its promotional credit limit.",
    );
  }
  transaction.set(refs.salonPromotionWalletRef, {
    walletId: refs.salonPromotionWalletRef.id,
    walletType: "salon_promotion_credits",
    accountId: salonId,
    availableProin: availableAfter,
    reservedProin: reservedAfter,
    lifetimeGrantedProin: money(wallet.lifetimeGrantedProin),
    lifetimeRedeemedProin: money(wallet.lifetimeRedeemedProin),
    lifetimeExpiredProin: money(wallet.lifetimeExpiredProin),
    lifetimeRevokedProin: money(wallet.lifetimeRevokedProin),
    creditLimitProin,
    proinToInrRate: 1,
    negativeBalanceAllowed: true,
    createdAt: wallet.createdAt || timestamp,
    updatedAt: timestamp,
  }, {merge: true});
  if (creditLineProin > 0) {
    transaction.set(refs.salonPromotionUsageRef, {
      walletId: refs.salonPromotionWalletRef.id,
      walletType: "salon_promotion_credits",
      salonId,
      reservedProin: admin.firestore.FieldValue.increment(creditLineProin),
      reservedUses: admin.firestore.FieldValue.increment(1),
      creditLimitProin,
      updatedAt: timestamp,
    }, {merge: true});
  }
  transaction.create(refs.salonPromotionReservationRef.doc(bookingId), {
    bookingId,
    walletId: refs.salonPromotionWalletRef.id,
    walletType: "salon_promotion_credits",
    salonId,
    campaignId: quote.campaignId,
    status: "reserved",
    amountProin: payoutAmount,
    lotBackedProin,
    creditLineProin,
    lotAllocations,
    availableProinBefore: availableBefore,
    availableProinAfter: availableAfter,
    reservedProinBefore: reservedBefore,
    reservedProinAfter: reservedAfter,
    creditLimitProin,
    createdAt: timestamp,
    updatedAt: timestamp,
  });
  transaction.create(
    admin.firestore().collection("proinLedger")
      .doc(`discount_salon_credit_reserve_${bookingId}`),
    {
      transactionId: `discount_salon_credit_reserve_${bookingId}`,
      walletId: refs.salonPromotionWalletRef.id,
      walletType: "salon_promotion_credits",
      accountId: salonId,
      type: "discount_reserve",
      direction: "hold",
      amountProin: payoutAmount,
      creditLineProin,
      lotBackedProin,
      bookingId,
      salonId,
      campaignId: quote.campaignId,
      lotAllocations,
      createdByType: "system",
      createdByUid: "",
      balanceAfter: {
        availableProin: availableAfter,
        reservedProin: reservedAfter,
        creditLimitProin,
      },
      createdAt: timestamp,
    },
  );
}

function resolveSalonPromotionCreditInTransaction({
  transaction,
  firestore,
  refs,
  booking,
  bookingId,
  outcome,
  fundingState,
}) {
  const payoutAmount = money(booking.pritzePayoutAmount);
  if (payoutAmount <= 0) return;
  const isRedeemed = outcome === "redeemed";
  const reservation = fundingState?.salonCreditReservation;
  if (!reservation || reservation.status !== "reserved" ||
      money(reservation.amountProin) !== payoutAmount) {
    throw new HttpsError(
      "data-loss",
      "Salon promotional credit reservation is not balanced.",
    );
  }
  const lotAllocations = Array.isArray(reservation.lotAllocations) ?
    reservation.lotAllocations.map((allocation) => ({
      lotId: String(allocation?.lotId || "").trim(),
      amountProin: money(allocation?.amountProin),
    })).filter((allocation) => allocation.lotId && allocation.amountProin > 0) :
    [];
  const lotBackedProin = lotAllocations.reduce(
    (total, allocation) => total + allocation.amountProin,
    0,
  );
  const creditLineProin = money(reservation.creditLineProin);
  if (lotBackedProin + creditLineProin !== payoutAmount) {
    throw new HttpsError(
      "data-loss",
      "Salon promotional credit allocation is not balanced.",
    );
  }
  const lotsById = new Map((fundingState?.salonCreditLots || [])
    .map((lot) => [String(lot.id || ""), lot]));
  const timestamp = admin.firestore.FieldValue.serverTimestamp();
  for (const allocation of lotAllocations) {
    const lot = lotsById.get(allocation.lotId);
    if (!lot?.ref || money(lot.reservedProin) < allocation.amountProin) {
      throw new HttpsError(
        "data-loss",
        "A salon promotional credit lot is not balanced.",
      );
    }
    const reservedAfter = money(lot.reservedProin) - allocation.amountProin;
    const availableAfter = isRedeemed ?
      money(lot.availableProin) :
      money(lot.availableProin) + allocation.amountProin;
    const redeemedAfter = money(lot.redeemedProin) +
      (isRedeemed ? allocation.amountProin : 0);
    transaction.update(lot.ref, {
      availableProin: availableAfter,
      reservedProin: reservedAfter,
      redeemedProin: redeemedAfter,
      status: discountPromotionLotStatus({
        availableProin: availableAfter,
        reservedProin: reservedAfter,
        redeemedProin: redeemedAfter,
        expiredProin: money(lot.expiredProin),
        revokedProin: money(lot.revokedProin),
      }),
      updatedAt: timestamp,
    });
  }
  const wallet = fundingState?.salonCreditWallet || {};
  const creditLimitProin = discountSalonPromotionCreditLimit(
    fundingState?.vault,
    wallet,
  );
  const availableBefore = signedMoney(wallet.availableProin);
  const reservedBefore = money(wallet.reservedProin);
  if (reservedBefore < payoutAmount) {
    throw new HttpsError(
      "data-loss",
      "Salon promotional credit reservation exceeds the wallet hold.",
    );
  }
  const availableAfter = isRedeemed ?
    availableBefore : availableBefore + payoutAmount;
  const reservedAfter = reservedBefore - payoutAmount;
  if (availableAfter < -creditLimitProin || reservedAfter < 0) {
    throw new HttpsError(
      "data-loss",
      "Salon promotional credit resolution would exceed its limit.",
    );
  }
  transaction.set(refs.salonPromotionWalletRef, {
    walletId: refs.salonPromotionWalletRef.id,
    walletType: "salon_promotion_credits",
    accountId: String(booking.salonId || ""),
    availableProin: availableAfter,
    reservedProin: reservedAfter,
    lifetimeGrantedProin: money(wallet.lifetimeGrantedProin),
    lifetimeRedeemedProin:
      money(wallet.lifetimeRedeemedProin) + (isRedeemed ? payoutAmount : 0),
    lifetimeExpiredProin: money(wallet.lifetimeExpiredProin),
    lifetimeRevokedProin: money(wallet.lifetimeRevokedProin),
    creditLimitProin,
    negativeBalanceAllowed: true,
    updatedAt: timestamp,
  }, {merge: true});
  if (creditLineProin > 0) {
    transaction.set(refs.salonPromotionUsageRef, {
      walletId: refs.salonPromotionWalletRef.id,
      walletType: "salon_promotion_credits",
      salonId: String(booking.salonId || ""),
      reservedProin: admin.firestore.FieldValue.increment(-creditLineProin),
      reservedUses: admin.firestore.FieldValue.increment(-1),
      [isRedeemed ? "redeemedProin" : "releasedProin"]:
        admin.firestore.FieldValue.increment(creditLineProin),
      [isRedeemed ? "redeemedUses" : "releasedUses"]:
        admin.firestore.FieldValue.increment(1),
      creditLimitProin,
      updatedAt: timestamp,
    }, {merge: true});
  }
  transaction.update(reservation.ref, {
    status: isRedeemed ? "redeemed" : "released",
    resolvedAt: timestamp,
    availableProinAfter: availableAfter,
    reservedProinAfter: reservedAfter,
    updatedAt: timestamp,
  });
  transaction.create(
    firestore.collection("proinLedger")
      .doc(`discount_salon_credit_${isRedeemed ? "redeem" : "release"}_${bookingId}`),
    {
      transactionId:
        `discount_salon_credit_${isRedeemed ? "redeem" : "release"}_${bookingId}`,
      walletId: refs.salonPromotionWalletRef.id,
      walletType: "salon_promotion_credits",
      accountId: String(booking.salonId || ""),
      type: isRedeemed ? "discount_redeem" : "discount_release",
      direction: isRedeemed ? "debit" : "credit",
      amountProin: payoutAmount,
      creditLineProin,
      lotBackedProin,
      bookingId,
      salonId: String(booking.salonId || ""),
      campaignId: String(booking.discountCampaignId || ""),
      lotAllocations,
      createdByType: "system",
      createdByUid: "",
      balanceAfter: {
        availableProin: availableAfter,
        reservedProin: reservedAfter,
        creditLimitProin,
      },
      createdAt: timestamp,
    },
  );
}

async function readDiscountResolutionFundingState({
  transaction,
  firestore,
  refs,
  booking,
  bookingId,
}) {
  const vaultSnapshot = await transaction.get(refs.vaultRef);
  const fundingState = {vault: vaultSnapshot.data()};
  if (!isSalonPromotionCreditFundedDiscount(booking)) {
    return fundingState;
  }
  const [walletSnapshot, reservationSnapshot] = await Promise.all([
    transaction.get(refs.salonPromotionWalletRef),
    transaction.get(refs.salonPromotionReservationRef.doc(bookingId)),
  ]);
  const reservation = reservationSnapshot.data();
  const lotRefs = (Array.isArray(reservation?.lotAllocations) ?
    reservation.lotAllocations : [])
    .map((allocation) => String(allocation?.lotId || "").trim())
    .filter(Boolean)
    .map((lotId) => firestore.collection("proinLots").doc(lotId));
  const lotSnapshots = await Promise.all(
    lotRefs.map((lotRef) => transaction.get(lotRef)),
  );
  return {
    ...fundingState,
    salonCreditWallet: walletSnapshot.data(),
    salonCreditReservation: reservationSnapshot.exists ?
      {id: reservationSnapshot.id, ref: reservationSnapshot.ref, ...reservation} :
      null,
    salonCreditLots: lotSnapshots.map((snapshot) => ({
      id: snapshot.id,
      ref: snapshot.ref,
      ...snapshot.data(),
    })),
  };
}

function isSalonPromotionCreditFundedDiscount(booking = {}) {
  return String(booking.discountFundingSource || "").trim() ===
    "salon_promotion_credits";
}

function discountSalonPromotionCreditLimit(vault = {}, wallet = {}) {
  if (Object.prototype.hasOwnProperty.call(wallet || {}, "creditLimitProin")) {
    return money(wallet?.creditLimitProin);
  }
  if (Object.prototype.hasOwnProperty.call(vault || {}, "salonCreditLimitAmount")) {
    return money(vault?.salonCreditLimitAmount);
  }
  return DEFAULT_SALON_PROMOTION_CREDIT_LIMIT;
}

function discountPromotionLotStatus({
  availableProin,
  reservedProin,
  redeemedProin,
  expiredProin,
  revokedProin,
}) {
  if (money(availableProin) > 0) return "active";
  if (money(reservedProin) > 0) return "reserved";
  if (money(expiredProin) > 0) return "expired";
  if (money(revokedProin) > 0) return "revoked";
  if (money(redeemedProin) > 0) return "redeemed";
  return "spent";
}

function requireAuthenticatedUid(request) {
  const uid = String(request.auth?.uid ?? "").trim();
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }
  return uid;
}

function validOwnerResourceId(value, label) {
  const id = requiredId(value, label);
  if (!/^[A-Za-z0-9_-]{1,180}$/.test(id)) {
    throw new HttpsError("invalid-argument", `Invalid ${label}.`);
  }
  return id;
}

async function requireOwnedSalon({uid, salonId}) {
  const firestore = admin.firestore();
  const salonRef = firestore.collection("salons").doc(salonId);
  const [ownerSnapshot, salonSnapshot] = await Promise.all([
    firestore.collection("users").doc(uid).get(),
    salonRef.get(),
  ]);
  requireStoredRole(ownerSnapshot.data(), "owner");
  const salon = salonSnapshot.data();
  if (!salon) {
    throw new HttpsError("not-found", "Salon not found.");
  }
  if (salon.ownerUid !== uid) {
    throw new HttpsError(
      "permission-denied",
      "Only this salon's owner can change it.",
    );
  }
  if (salon.adminSuspended === true) {
    throw new HttpsError(
      "failed-precondition",
      "This salon is suspended. Contact Pritze support.",
    );
  }
  return {firestore, salonRef, salon};
}

async function claimOwnerProfilePhoneForUid({uid, phone}) {
  const firestore = admin.firestore();
  const userRef = firestore.collection("users").doc(uid);
  const phoneRef = firestore.collection("loginIdentifiers")
    .doc(phoneKey(phone));
  const [ownerSalons, salonsUsingPhone] = await Promise.all([
    firestore.collection("salons")
      .where("ownerUid", "==", uid)
      .limit(1)
      .get(),
    firestore.collection("salons")
      .where("phone", "==", phone)
      .limit(2)
      .get(),
  ]);
  if (salonsUsingPhone.docs.some((doc) => doc.data().ownerUid !== uid)) {
    throw new HttpsError(
      "already-exists",
      "This phone number belongs to another salon owner account.",
    );
  }

  let phoneAuthUser = null;
  try {
    phoneAuthUser = await admin.auth().getUserByPhoneNumber(phone);
  } catch (error) {
    if (error.code !== "auth/user-not-found") throw error;
  }
  const otherUserRef = phoneAuthUser && phoneAuthUser.uid !== uid ?
    firestore.collection("users").doc(phoneAuthUser.uid) : null;

  await firestore.runTransaction(async (transaction) => {
    const userSnapshot = await transaction.get(userRef);
    const phoneSnapshot = await transaction.get(phoneRef);
    const otherUserSnapshot = otherUserRef ?
      await transaction.get(otherUserRef) : null;
    const userData = userSnapshot.data() || {};
    const storedRole = inferStoredRole(userData, !ownerSalons.empty);
    if (storedRole !== "owner") {
      throw new HttpsError(
        "permission-denied",
        "Only a signed-in salon owner can save salon details.",
      );
    }
    const claimedPhoneRole = normalizeRole(phoneSnapshot.data()?.role);
    if (claimedPhoneRole === "customer") {
      throw new HttpsError(
        "already-exists",
        "This phone number is already registered as a customer.",
      );
    }
    if (phoneSnapshot.exists && phoneSnapshot.data()?.uid !== uid) {
      throw new HttpsError(
        "already-exists",
        "This phone number belongs to another salon owner account.",
      );
    }
    const alreadyClaimedByOwner = phoneSnapshot.exists &&
      claimedPhoneRole === "owner" && phoneSnapshot.data()?.uid === uid;
    if (otherUserSnapshot && !alreadyClaimedByOwner) {
      const otherRole = inferStoredRole(otherUserSnapshot.data(), false);
      throw new HttpsError(
        "already-exists",
        otherRole === "customer" ?
          "This phone number is already registered as a customer." :
          "This phone number belongs to another account.",
      );
    }

    const previousProfilePhone = normalizeVerifiedPhone(userData.profilePhone);
    let previousPhoneRef = null;
    let previousPhoneSnapshot = null;
    if (previousProfilePhone && previousProfilePhone !== phone) {
      previousPhoneRef = firestore.collection("loginIdentifiers")
        .doc(phoneKey(previousProfilePhone));
      previousPhoneSnapshot = await transaction.get(previousPhoneRef);
    }
    transaction.set(userRef, {
      profilePhone: phone,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    transaction.set(phoneRef, {
      phone,
      role: "owner",
      uid,
      source: "salon_profile",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const authPhone = normalizeVerifiedPhone(userData.phone);
    if (previousPhoneRef && previousProfilePhone !== authPhone &&
        previousPhoneSnapshot?.data()?.uid === uid) {
      transaction.delete(previousPhoneRef);
    }
  });
}

function requireCustomerArrivalBooking(booking, uid) {
  if (!booking) throw new HttpsError("not-found", "Booking not found.");
  if (booking.customerUid !== uid) {
    throw new HttpsError("permission-denied", "Not allowed.");
  }
  if (!["confirmed", "inProgress"].includes(booking.status)) {
    throw new HttpsError(
      "failed-precondition",
      "Arrival updates are only available for active confirmed bookings.",
    );
  }
}

function customerLocationPayload(data) {
  return {
    latitude: Number(data?.latitude),
    longitude: Number(data?.longitude),
    accuracyMeters: Number(data?.accuracyMeters),
    speedMetersPerSecond: Math.max(0, Number(data?.speedMetersPerSecond) || 0),
    capturedAtMillis: Number(data?.capturedAtMillis),
  };
}

function customerArrivalMetrics(location, salon) {
  const salonCoordinates = coordinatesFromSalon(salon);
  if (!salonCoordinates) {
    return {distanceMeters: 0, estimatedArrivalMinutes: 0, hasSalonPin: false};
  }
  const distance = distanceMeters(location, salonCoordinates);
  return {
    distanceMeters: Math.round(distance || 0),
    estimatedArrivalMinutes: estimatedArrivalMinutes(
      distance,
      location.speedMetersPerSecond,
    ),
    hasSalonPin: true,
  };
}

function customerArrivalLocationDeletes() {
  const remove = admin.firestore.FieldValue.delete();
  return {
    latestLatitude: remove,
    latestLongitude: remove,
    accuracyMeters: remove,
    speedMetersPerSecond: remove,
    lastLocationAt: remove,
    distanceMeters: remove,
    estimatedArrivalMinutes: remove,
    hasSalonPin: remove,
  };
}

function customerArrivalStatusLabel(status) {
  return ({
    notStarted: "Not started",
    leavingNow: "Leaving now",
    onTheWay: "On the way",
    runningLate: "Running late",
    arrived: "Arrived",
  })[status] || "Arrival updated";
}

async function enforceReferralAttemptLimit(firestore, uid) {
  const attemptRef = firestore.collection("referralAttempts").doc(uid);
  const nowMillis = Date.now();
  await firestore.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(attemptRef);
    const data = snapshot.data() ?? {};
    const windowStartMillis = data.windowStartedAt?.toMillis?.() ?? 0;
    const insideWindow = nowMillis - windowStartMillis <
      REFERRAL_ATTEMPT_WINDOW_MS;
    const attemptCount = insideWindow ? money(data.attemptCount) : 0;
    if (attemptCount >= REFERRAL_ATTEMPT_LIMIT) {
      throw new HttpsError(
        "resource-exhausted",
        "Too many referral attempts. Try again later.",
      );
    }
    transaction.set(attemptRef, {
      attemptCount: attemptCount + 1,
      windowStartedAt: insideWindow && data.windowStartedAt ?
        data.windowStartedAt : admin.firestore.Timestamp.fromMillis(nowMillis),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
}

async function enforceHourlyAttemptLimit({
  firestore,
  collection,
  uid,
  limit,
  message,
}) {
  const attemptRef = firestore.collection(collection).doc(uid);
  const nowMillis = Date.now();
  await firestore.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(attemptRef);
    const data = snapshot.data() ?? {};
    const windowStartMillis = data.windowStartedAt?.toMillis?.() ?? 0;
    const insideWindow = nowMillis - windowStartMillis <
      REFERRAL_ATTEMPT_WINDOW_MS;
    const attemptCount = insideWindow ? money(data.attemptCount) : 0;
    if (attemptCount >= limit) {
      throw new HttpsError("resource-exhausted", message);
    }
    transaction.set(attemptRef, {
      attemptCount: attemptCount + 1,
      windowStartedAt: insideWindow && data.windowStartedAt ?
        data.windowStartedAt : admin.firestore.Timestamp.fromMillis(nowMillis),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
}

async function enforceAdminPasswordAttemptLimit({
  firestore,
  request,
  credentialId,
}) {
  const fingerprint = adminAuthenticationFingerprint(request);
  const attemptId = crypto.createHash("sha256")
    .update(`${credentialId}:${fingerprint.networkHash}`)
    .digest("hex");
  const attemptRef = firestore
    .collection("adminPasswordAttemptBuckets")
    .doc(attemptId);
  const nowMillis = Date.now();
  await firestore.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(attemptRef);
    const data = snapshot.data() || {};
    const windowStartedAtMillis = data.windowStartedAt?.toMillis?.() || 0;
    const insideWindow = nowMillis - windowStartedAtMillis <
      ADMIN_PASSWORD_ATTEMPT_WINDOW_MS;
    const attemptCount = insideWindow ?
      Math.max(0, Number(data.attemptCount) || 0) : 0;
    if (attemptCount >= ADMIN_PASSWORD_ATTEMPT_LIMIT) {
      throw new HttpsError(
        "resource-exhausted",
        "Too many attempts. Try again in 15 minutes.",
      );
    }
    transaction.set(attemptRef, {
      attemptCount: attemptCount + 1,
      windowStartedAt: insideWindow && data.windowStartedAt ?
        data.windowStartedAt :
        admin.firestore.Timestamp.fromMillis(nowMillis),
      expiresAt: admin.firestore.Timestamp.fromMillis(
        nowMillis + ADMIN_PASSWORD_LOCKOUT_MS,
      ),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
}

function adminAuthenticationFingerprint(request) {
  const forwarded = String(
    request.rawRequest?.headers?.["x-forwarded-for"] || "",
  ).split(",")[0].trim();
  const network = String(request.rawRequest?.ip || forwarded || "unknown");
  const userAgent = String(
    request.rawRequest?.headers?.["user-agent"] || "unknown",
  ).slice(0, 500);
  return {
    networkHash: crypto.createHash("sha256").update(network).digest("hex"),
    userAgentHash: crypto
      .createHash("sha256")
      .update(userAgent)
      .digest("hex"),
  };
}

async function recordAdminAuthenticationEvent({
  firestore,
  request,
  credentialId,
  outcome,
  authUid = "",
}) {
  const fingerprint = adminAuthenticationFingerprint(request);
  try {
    await firestore.collection("adminAuthenticationEvents").add({
      credentialId,
      outcome,
      authUid,
      networkHash: fingerprint.networkHash,
      userAgentHash: fingerprint.userAgentHash,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (error) {
    console.error("Administrator authentication audit failed", {
      credentialId,
      outcome,
      error: error.message,
    });
  }
}

async function requirePlatformAdministrator(request) {
  const uid = requireAuthenticatedUid(request);
  const snapshot = await admin.firestore()
    .collection("platformAdmins").doc(uid).get();
  if (
    request.auth?.token?.platformAdmin === true &&
    snapshot.exists &&
    snapshot.data()?.active !== false
  ) {
    return uid;
  }
  if (snapshot.exists && snapshot.data()?.active === false) {
    throw new HttpsError(
      "permission-denied",
      "This account is not a Pritze platform administrator.",
    );
  }
  const email = normalizeEmail(request.auth?.token?.email);
  const emailHash = email ?
    crypto.createHash("sha256").update(email).digest("hex") : "";
  if (snapshot.data()?.active !== false && snapshot.exists) return uid;
  if (request.auth?.token?.email_verified !== false &&
      PLATFORM_ADMIN_EMAIL_HASHES.has(emailHash)) {
    return uid;
  }
  throw new HttpsError(
    "permission-denied",
    "This account is not a Pritze platform administrator.",
  );
}

async function runProinCallable(operation) {
  try {
    return await operation();
  } catch (error) {
    if (error instanceof ProinValidationError) {
      throw new HttpsError("invalid-argument", error.message);
    }
    throw error;
  }
}

async function runDiscountAdminCallable(operation) {
  try {
    return await operation();
  } catch (error) {
    if (error instanceof DiscountAdminValidationError) {
      throw new HttpsError("invalid-argument", error.message);
    }
    throw error;
  }
}

function discountCampaignAdminView(campaignId, data = {}) {
  return {
    campaignId,
    name: adminString(data.name),
    active: data.active === true,
    priority: money(data.priority),
    discountType: data.discountType === "fixed" ? "fixed" : "percent",
    discountPercent: Number(data.discountPercent) || 0,
    fixedDiscountAmount: money(data.fixedDiscountAmount),
    voucherOnly: data.voucherOnly === true,
    visibleAtCheckout: data.visibleAtCheckout === true,
    fundingSource: discountFundingSource(data),
    voucherCodeHash: adminString(data.voucherCodeHash),
    voucherMaskedCode: adminString(data.voucherMaskedCode),
    payoutMultiplier: Number(data.payoutMultiplier) || 2,
    salonPayoutPercent: Number.isFinite(Number(data.salonPayoutPercent)) ?
      Number(data.salonPayoutPercent) :
      (Number(data.payoutMultiplier) || 2) * 100,
    salonPayoutPercentByBookingNumber:
      adminBookingPayoutPercentRules(data.salonPayoutPercentByBookingNumber),
    cashbackProinAmount: money(data.cashbackProinAmount),
    cashbackValidityDays: money(data.cashbackValidityDays),
    cashbackTotalBudgetProin: money(data.cashbackTotalBudgetProin),
    cashbackProgramId: adminString(data.cashbackProgramId),
    journeyCountScope: data.journeyCountScope === "salon" ?
      "salon" : "platform",
    journeyMilestones: adminJourneyMilestones(data.journeyMilestones),
    totalPayoutBudget: money(data.totalPayoutBudget),
    maximumUsesPerCustomer: money(data.maximumUsesPerCustomer),
    maximumDiscountAmount: money(data.maximumDiscountAmount),
    minimumServiceAmount: money(data.minimumServiceAmount),
    perSalonPayoutBudget: money(data.perSalonPayoutBudget),
    perCustomerPayoutBudget: money(data.perCustomerPayoutBudget),
    startsAtMillis: adminMillis(data.startsAt),
    endsAtMillis: adminMillis(data.endsAt),
    salonIds: adminStringList(data.salonIds, 200),
    excludedSalonIds: adminStringList(data.excludedSalonIds, 200),
    customerUids: adminStringList(data.customerUids, 500),
    serviceIds: adminStringList(data.serviceIds, 200),
    eligibleBookingNumbers: Array.isArray(data.eligibleBookingNumbers) ?
      data.eligibleBookingNumbers.map(Number).filter(Number.isSafeInteger) : [],
    minimumBookingNumber: Math.max(1, money(data.minimumBookingNumber) || 1),
    maximumBookingNumber: money(data.maximumBookingNumber),
    newToSalonOnly: data.newToSalonOnly === true,
    returningToSalonOnly: data.returningToSalonOnly === true,
    termsVersion: adminString(data.termsVersion),
    version: money(data.version),
  };
}

function adminJourneyMilestones(value) {
  if (!Array.isArray(value)) return [];
  return value.map((item) => ({
    bookingNumber: money(item?.bookingNumber),
    rewardType: ["discount", "discount_proin", "proin"]
      .includes(item?.rewardType) ? item.rewardType : "discount",
    discountType: item?.discountType === "fixed" ? "fixed" :
      item?.discountType === "none" ? "none" : "percent",
    discountPercent: Number(item?.discountPercent) || 0,
    fixedDiscountAmount: money(item?.fixedDiscountAmount),
    maximumDiscountAmount: money(item?.maximumDiscountAmount),
    cashbackProinAmount: money(item?.cashbackProinAmount),
    cashbackValidityDays: money(item?.cashbackValidityDays),
  })).filter((item) => item.bookingNumber > 0)
    .sort((left, right) => left.bookingNumber - right.bookingNumber);
}

function adminBookingPayoutPercentRules(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const entries = Object.entries(value)
    .map(([bookingNumber, percent]) => [
      Number(bookingNumber),
      Number(percent),
    ])
    .filter(([bookingNumber, percent]) =>
      Number.isSafeInteger(bookingNumber) && bookingNumber >= 1 &&
      Number.isFinite(percent) && percent >= 0 && percent <= 1000,
    )
    .sort((left, right) => left[0] - right[0]);
  return Object.fromEntries(entries.map(([bookingNumber, percent]) => [
    String(bookingNumber),
    Math.round(percent * 100) / 100,
  ]));
}

function discountCashbackProgramId(campaignId) {
  return `discount_cashback__${String(campaignId || "").trim()}`;
}

function discountUsageAdminView(data = {}) {
  return {
    reservedPayoutAmount: money(data?.reservedPayoutAmount),
    realizedPayoutAmount: money(data?.realizedPayoutAmount),
    releasedPayoutAmount: money(data?.releasedPayoutAmount),
    reservedDiscountAmount: money(data?.reservedDiscountAmount),
    realizedDiscountAmount: money(data?.realizedDiscountAmount),
    releasedDiscountAmount: money(data?.releasedDiscountAmount),
    reservedUses: money(data?.reservedUses),
    realizedUses: money(data?.realizedUses),
    releasedUses: money(data?.releasedUses),
  };
}

function discountTotalsAdminView(data = {}) {
  return {
    reservedPayoutAmount: money(data?.reservedPayoutAmount),
    realizedPayoutAmount: money(data?.realizedPayoutAmount),
    releasedPayoutAmount: money(data?.releasedPayoutAmount),
    reservedDiscountAmount: money(data?.reservedDiscountAmount),
    realizedDiscountAmount: money(data?.realizedDiscountAmount),
    releasedDiscountAmount: money(data?.releasedDiscountAmount),
    reservedUses: money(data?.reservedUses),
    realizedUses: money(data?.realizedUses),
    releasedUses: money(data?.releasedUses),
  };
}

function discountVaultAdminView(data = {}) {
  const availableAmount = money(data?.availableAmount);
  const reservedAmount = money(data?.reservedAmount);
  const spentAmount = money(data?.spentAmount);
  const salonCreditLimitAmount = data &&
    Object.prototype.hasOwnProperty.call(data, "salonCreditLimitAmount") ?
    money(data?.salonCreditLimitAmount) :
    DEFAULT_SALON_PROMOTION_CREDIT_LIMIT;
  return {
    approvedAmount: money(data?.approvedAmount) ||
      availableAmount + reservedAmount + spentAmount,
    availableAmount,
    reservedAmount,
    spentAmount,
    salonCreditLimitAmount,
    salonDiscountBurnMultiplier: Number.isFinite(
      Number(data?.salonDiscountBurnMultiplier),
    ) ? Number(data.salonDiscountBurnMultiplier) :
      DEFAULT_SALON_DISCOUNT_BURN_MULTIPLIER,
    budgetVersion: money(data?.budgetVersion),
  };
}

function adminMillis(value) {
  if (value && typeof value.toMillis === "function") {
    return value.toMillis();
  }
  if (value instanceof Date) {
    return value.getTime();
  }
  const numericValue = Number(value);
  return Number.isFinite(numericValue) ? numericValue : 0;
}

function adminString(value) {
  return String(value ?? "").trim();
}

function adminStringList(value, limit = 12) {
  if (!Array.isArray(value)) return [];
  return value
    .map(adminString)
    .filter(Boolean)
    .slice(0, limit);
}

function adminHttpsUrl(value) {
  const url = adminString(value);
  if (!url) return "";
  if (url.length > 2048 || !/^https:\/\//i.test(url)) return null;
  try {
    return new URL(url).toString();
  } catch (_) {
    return null;
  }
}

function adminSalonTime(value) {
  const time = adminString(value).toUpperCase().replace(/\./g, "");
  const match = /^(\d{1,2})(?::(\d{2}))?\s*([AP]M)?$/.exec(time);
  if (!match) return "";
  let hours = Number(match[1]);
  const minutes = Number(match[2] || 0);
  const period = match[3] || "";
  if (!Number.isInteger(hours) || !Number.isInteger(minutes) || minutes > 59) {
    return "";
  }
  if (period) {
    if (hours < 1 || hours > 12) return "";
    if (period === "AM") hours = hours === 12 ? 0 : hours;
    if (period === "PM" && hours !== 12) hours += 12;
  } else if (hours > 23) {
    return "";
  }
  const suffix = hours >= 12 ? "PM" : "AM";
  const displayHours = hours % 12 || 12;
  return `${displayHours}:${String(minutes).padStart(2, "0")} ${suffix}`;
}

function adminSalonMinutes(value) {
  const time = adminSalonTime(value);
  const match = /^(\d{1,2}):(\d{2})\s([AP]M)$/.exec(time);
  if (!match) return -1;
  let hours = Number(match[1]);
  const minutes = Number(match[2]);
  if (match[3] === "AM") hours = hours === 12 ? 0 : hours;
  if (match[3] === "PM" && hours !== 12) hours += 12;
  return hours * 60 + minutes;
}

function adminCustomerProfileView(customerUid, data = {}) {
  return {
    id: customerUid,
    name: adminString(data.name) || "Customer",
    phone: adminString(data.phone || data.contact),
    email: adminString(data.email),
    gender: adminString(data.gender),
    birthDate: adminString(data.birthDate),
    preferredStyles: adminStringList(data.preferredStyles),
    photoUrl: adminString(data.photoUrl),
    stylePhotoUrls: adminStringList(data.stylePhotoUrls, 8),
    provider: adminString(data.provider),
    adminSuspended: data.adminSuspended === true,
    referralOnboardingCompleted: data.referralOnboardingCompleted === true,
    registeredAtMillis: adminMillis(data.registeredAt),
    updatedAtMillis: adminMillis(data.updatedAt),
  };
}

function adminSalonProfileView(salonId, data = {}) {
  return {
    id: salonId,
    name: adminString(data.name) || "Salon",
    ownerUid: adminString(data.ownerUid),
    ownerName: adminString(data.ownerName),
    address: adminString(data.address),
    directionsUrl: adminString(data.directionsUrl),
    phone: adminString(data.phone),
    email: adminString(data.email),
    logoUrl: adminString(data.logoUrl),
    photoUrls: adminStringList(data.photoUrls, 8),
    distanceLabel: adminString(data.distanceLabel) || "Nearby",
    openTime: adminString(data.openTime),
    closeTime: adminString(data.closeTime),
    isOpen: data.isOpen === true,
    instantBookingsEnabled: data.instantBookingsEnabled !== false,
    instantBookingsPausedDate: adminString(data.instantBookingsPausedDate),
    adminSuspended: data.adminSuspended === true,
    approvalStatus: salonApprovalStatus(data),
    approvalRequestedAtMillis: adminMillis(data.approvalRequestedAt),
    approvalReviewedAtMillis: adminMillis(data.approvalReviewedAt),
    approvalReviewReason: adminString(data.approvalReviewReason),
    proinReferralApproved: data.proinReferralApproved === true,
    updatedAtMillis: adminMillis(data.updatedAt),
  };
}

function adminAuditRecord({
  adminUid,
  action,
  targetType,
  targetId,
  reason,
  before,
  after,
}) {
  return {
    adminUid,
    action,
    targetType,
    targetId,
    reason,
    before,
    after,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

function referralCodeUserField(inviterRole, targetRole) {
  if (inviterRole === "customer" && targetRole === "customer") {
    return "customerReferralCode";
  }
  if (inviterRole === "owner" && targetRole === "customer") {
    return "ownerCustomerReferralCode";
  }
  if (inviterRole === "owner" && targetRole === "owner") {
    return "ownerSalonReferralCode";
  }
  return "";
}

function referralCodeAdminView(code, data = {}) {
  return {
    code: adminString(data.code) || code,
    ownerUid: adminString(data.ownerUid),
    inviterRole: adminString(data.inviterRole),
    targetRole: adminString(data.targetRole),
    active: data.active === true,
    replacedByCode: adminString(data.replacedByCode),
    replacedFromCode: adminString(data.replacedFromCode),
    createdAtMillis: adminMillis(data.createdAt),
    updatedAtMillis: adminMillis(data.updatedAt),
  };
}

function isPlatformAdminEmail(email) {
  if (!email) return false;
  const emailHash = crypto.createHash("sha256").update(email).digest("hex");
  return PLATFORM_ADMIN_EMAIL_HASHES.has(emailHash);
}

function adminBookingRecord(document) {
  const data = document.data() || {};
  return {
    id: document.id,
    customerUid: adminString(data.customerUid),
    salonId: adminString(data.salonId),
    barberId: adminString(data.barberId),
    customerName: adminString(data.customerName) || "Customer",
    customerPhone: adminString(data.customerPhone),
    serviceName: adminString(data.serviceName) || "Service",
    servicePrice: Math.max(0, Number(data.servicePrice) || 0),
    durationMinutes: positiveInteger(data.durationMinutes, 30),
    status: adminString(data.status) || "pending",
    isInstant: data.isInstant === true,
    startMillis: adminMillis(data.start),
    createdAtMillis: adminMillis(data.createdAt),
    acceptedAtMillis: adminMillis(data.acceptedAt),
    startedAtMillis: adminMillis(data.startedAt),
    completedAtMillis: adminMillis(data.completedAt),
    cancelledAtMillis: adminMillis(data.cancelledAt),
    rejectedAtMillis: adminMillis(data.rejectedAt),
    arrivalMinutes: Math.max(0, Number(data.arrivalMinutes) || 0),
    cancellationReason: adminString(data.cancellationReason),
    cancelledBy: adminString(data.cancelledBy),
    arrivalStatus: validArrivalStatus(data.arrivalStatus) ?
      data.arrivalStatus : "notStarted",
    arrivalStatusUpdatedAtMillis: adminMillis(data.arrivalStatusUpdatedAt),
    arrivalSharingActive: data.arrivalSharingActive === true,
    arrivalSharingExpiresAtMillis: adminMillis(data.arrivalSharingExpiresAt),
  };
}

function adminArrivalSessionRecord(document) {
  const data = document.data() || {};
  const latitude = Number(data.latestLatitude);
  const longitude = Number(data.latestLongitude);
  const hasLocation = validCoordinates(latitude, longitude);
  const lastLocationAtMillis = adminMillis(data.lastLocationAt);
  const expiresAtMillis = adminMillis(data.expiresAt);
  return {
    bookingId: adminString(data.bookingId) || document.id,
    salonId: adminString(data.salonId),
    sharingActive: data.sharingActive === true && expiresAtMillis > Date.now(),
    latitude: hasLocation ? latitude : 0,
    longitude: hasLocation ? longitude : 0,
    hasLocation,
    accuracyMeters: Math.max(0, Number(data.accuracyMeters) || 0),
    distanceMeters: Math.max(0, Number(data.distanceMeters) || 0),
    estimatedArrivalMinutes:
      Math.max(0, Number(data.estimatedArrivalMinutes) || 0),
    hasSalonPin: data.hasSalonPin === true,
    lastLocationAtMillis,
    expiresAtMillis,
  };
}

function adminSalonRecord(document, paymentProfile = {}) {
  const data = document.data() || {};
  return {
    ...adminSalonProfileView(document.id, data),
    rating: Math.max(0, Number(data.rating) || 0),
    reviewCount: Math.max(0, Number(data.reviewCount) || 0),
    serviceCount: Array.isArray(data.services) ? data.services.length : 0,
    paymentUpiId: adminString(paymentProfile.upiId),
    paymentQrCodeUrl: adminString(paymentProfile.qrCodeUrl),
    services: (Array.isArray(data.services) ? data.services : [])
      .slice(0, 100)
      .map((service) => ({
        id: adminString(service?.id),
        name: adminString(service?.name) || "Service",
        category: adminString(service?.category),
        price: Math.max(0, Number(service?.price) || 0),
        durationMinutes: positiveInteger(service?.durationMinutes, 30),
        isAvailable: service?.isAvailable !== false,
        instantBookingEnabled: service?.instantBookingEnabled !== false,
      })),
  };
}

function adminBarberRecord(document) {
  const data = document.data() || {};
  return {
    id: document.id,
    uid: adminString(data.uid),
    salonId: adminString(data.salonId),
    name: adminString(data.name) || "Barber",
    phone: adminString(data.phone),
    email: adminString(data.email),
    speciality: adminString(data.speciality),
    experienceYears: Math.max(0, Number(data.experienceYears) || 0),
    resumeSummary: adminString(data.resumeSummary).slice(0, 1000),
    serviceIds: adminStringList(data.serviceIds, 100),
    serviceCount: Array.isArray(data.serviceIds) ? data.serviceIds.length : 0,
    isActive: data.isActive !== false,
  };
}

function adminCustomerRecord(document) {
  const data = document.data() || {};
  return {
    ...adminCustomerProfileView(document.id, data),
    salonRating: Math.max(0, Number(data.salonRating) || 0),
    salonRatingCount: Math.max(0, Number(data.salonRatingCount) || 0),
  };
}

function adminReviewRecord(document, direction) {
  const data = document.data() || {};
  return {
    id: document.id,
    bookingId: adminString(data.bookingId) || document.id,
    customerUid: adminString(data.customerUid),
    salonId: adminString(data.salonId),
    salonName: adminString(data.salonName) || "Salon",
    rating: Math.max(0, Math.min(5, Number(data.rating) || 0)),
    note: adminString(data.note).slice(0, 500),
    createdAtMillis: adminMillis(data.updatedAt || data.createdAt),
    direction,
  };
}

function adminJoinRequestRecord(document) {
  const data = document.data() || {};
  return {
    id: document.id,
    salonId: adminString(data.salonId),
    barberName: adminString(data.barberName) || "Barber",
    barberPhone: adminString(data.barberPhone),
    barberEmail: adminString(data.barberEmail),
    speciality: adminString(data.speciality),
    experienceYears: Math.max(0, Number(data.experienceYears) || 0),
    status: adminString(data.status) || "pending",
    requestedAtMillis: adminMillis(data.requestedAt),
  };
}

function adminSettlementRecord(document) {
  const data = document.data() || {};
  const pritzePayoutAmount = money(data.pritzePayoutAmount);
  const paidAmount = money(data.paidAmount);
  return {
    bookingId: adminString(data.bookingId) || document.id,
    salonId: adminString(data.salonId),
    customerUid: adminString(data.customerUid),
    campaignId: adminString(data.campaignId),
    originalAmount: money(data.originalAmount),
    discountAmount: money(data.discountAmount),
    customerCounterAmount: money(data.customerCounterAmount),
    pritzePayoutAmount,
    salonTotalEarning: money(data.salonTotalEarning),
    status: adminString(data.status) || "payable",
    paymentReference: adminString(data.paymentReference),
    paymentMethod: adminString(data.paymentMethod),
    paidAmount,
    outstandingAmount: Object.prototype.hasOwnProperty.call(
      data, "outstandingAmount",
    ) ? money(data.outstandingAmount) : Math.max(0, pritzePayoutAmount - paidAmount),
    createdAtMillis: adminMillis(data.createdAt),
    paidAtMillis: adminMillis(data.paidAt),
  };
}

function adminSalonSettlementPaymentRecord(document) {
  const data = document.data() || {};
  return {
    paymentId: adminString(data.paymentId) || document.id,
    salonId: adminString(data.salonId),
    amountInr: money(data.amountInr),
    paymentReference: adminString(data.paymentReference),
    paymentMethod: adminString(data.paymentMethod),
    paidAtMillis: adminMillis(data.paidAt),
    createdAtMillis: adminMillis(data.createdAt),
    allocationCount: Array.isArray(data.allocations) ? data.allocations.length : 0,
  };
}

function adminWalletRecord(document) {
  const data = document.data() || {};
  return {
    salonId: adminString(data.salonId) || document.id,
    payableBalance: money(data.payableBalance),
    paidAmount: money(data.paidAmount),
    lifetimePritzeEarnings: money(data.lifetimePritzeEarnings),
  };
}

function adminNoteRecord(document) {
  const data = document.data() || {};
  return {
    id: document.id,
    targetType: adminString(data.targetType),
    targetId: adminString(data.targetId),
    note: adminString(data.note).slice(0, 1000),
    adminUid: adminString(data.adminUid),
    createdAtMillis: adminMillis(data.createdAt),
  };
}

function adminAuditLogRecord(document) {
  const data = document.data() || {};
  return {
    id: document.id,
    action: adminString(data.action),
    targetType: adminString(data.targetType),
    targetId: adminString(data.targetId),
    reason: adminString(data.reason).slice(0, 500),
    adminUid: adminString(data.adminUid),
    before: data.before && typeof data.before === "object" ? data.before : {},
    after: data.after && typeof data.after === "object" ? data.after : {},
    createdAtMillis: adminMillis(data.createdAt),
  };
}

function adminAutomationRuleRecords(snapshot) {
  const stored = Object.fromEntries(snapshot.docs.map((document) =>
    [document.id, document.data()]));
  const rules = normalizedRules(stored);
  return Object.entries(rules).map(([id, rule]) => ({
    id,
    enabled: rule.enabled,
    threshold: rule.threshold,
    updatedAtMillis: adminMillis(stored[id]?.updatedAt),
  }));
}

function adminOperationalAlertRecord(document) {
  const data = document.data() || {};
  return {
    id: document.id,
    type: adminString(data.type),
    severity: adminString(data.severity) || "info",
    status: adminString(data.status) || "active",
    targetType: adminString(data.targetType),
    targetId: adminString(data.targetId),
    salonId: adminString(data.salonId),
    title: adminString(data.title).slice(0, 200),
    detail: adminString(data.detail).slice(0, 500),
    recommendedAction: adminString(data.recommendedAction).slice(0, 500),
    detectedAtMillis: adminMillis(data.detectedAt),
    acknowledgedAtMillis: adminMillis(data.acknowledgedAt),
    occurrenceCount: Math.max(0, Number(data.occurrenceCount) || 0),
  };
}

function requiredId(value, label) {
  const id = String(value ?? "").trim();
  if (!id) {
    throw new HttpsError("invalid-argument", `Missing ${label}.`);
  }
  return id;
}

function requiredAdminReason(value) {
  const reason = String(value ?? "").trim().slice(0, 500);
  if (reason.length < 5) {
    throw new HttpsError(
      "invalid-argument",
      "Enter a reason of at least 5 characters.",
    );
  }
  return reason;
}

function requireStoredRole(user, expectedRole) {
  if (normalizeRole(user?.role) !== expectedRole) {
    throw new HttpsError(
      "permission-denied",
      `Only a signed-in ${expectedRole} can perform this action.`,
    );
  }
}

function positiveInteger(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : fallback;
}

function versionAtLeast(value, minimum) {
  const parts = (version) => String(version || "")
    .split(/[+-]/, 1)[0]
    .split(".")
    .map((part) => Number.parseInt(part, 10) || 0);
  const actual = parts(value);
  const required = parts(minimum);
  const length = Math.max(actual.length, required.length);
  for (let index = 0; index < length; index++) {
    const actualPart = actual[index] || 0;
    const requiredPart = required[index] || 0;
    if (actualPart !== requiredPart) {
      return actualPart > requiredPart;
    }
  }
  return true;
}

function normalizedOptionalString(value) {
  const text = String(value ?? "").trim();
  return text || null;
}

function findSalonService(salon, serviceId) {
  const services = Array.isArray(salon?.services) ? salon.services : [];
  return services.find((service) => String(service?.id ?? "") === serviceId) ||
    null;
}

function barberCanServe(barber, serviceId) {
  return Boolean(
    barber &&
    barber.isActive !== false &&
    Array.isArray(barber.serviceIds) &&
    barber.serviceIds.includes(serviceId)
  );
}

function bookingServiceIds(booking) {
  const supplied = Array.isArray(booking?.serviceIds) ? booking.serviceIds : [];
  return [...new Set([
    ...supplied,
    booking?.serviceId,
  ].map((value) => String(value ?? "").trim()).filter(Boolean))];
}

function salonApprovalStatus(salon) {
  const status = String(salon?.approvalStatus || "").trim();
  // Existing salons registered before approval was introduced remain live.
  return ["pending", "rejected", "approved"].includes(status) ?
    status : "approved";
}

function isSalonApproved(salon) {
  return salonApprovalStatus(salon) === "approved";
}

function slotLockId(barberId, segmentMillis) {
  return `${barberId}_${segmentMillis}`;
}

function activeBookingMarker({
  bookingId,
  salonId,
  customerUid,
  isInstant,
  createdAt,
}) {
  return {
    active: true,
    bookingId,
    salonId,
    customerUid,
    isInstant,
    createdAt,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

function slotLockData({
  bookingId,
  salonId,
  serviceId,
  barberId,
  segmentMillis,
  bookingStartMillis,
  createdAt,
}) {
  return {
    bookingId,
    salonId,
    serviceId,
    barberId,
    start: admin.firestore.Timestamp.fromMillis(segmentMillis),
    bookingStart: admin.firestore.Timestamp.fromMillis(bookingStartMillis),
    active: true,
    createdAt,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

async function assertNoBlockingMarker(transaction, markerSnapshots, nowMillis) {
  const bookingIds = [...new Set(markerSnapshots
    .filter((snapshot) => snapshot.data()?.active === true)
    .map((snapshot) => String(snapshot.data()?.bookingId ?? "").trim())
    .filter(Boolean))];
  for (const bookingId of bookingIds) {
    const snapshot = await transaction.get(
      admin.firestore().collection("bookings").doc(bookingId),
    );
    if (isBlockingBooking(snapshot.data(), nowMillis)) {
      throw new HttpsError(
        "already-exists",
        "You already have an active booking.",
      );
    }
  }
}

function normalizeEmail(value) {
  const email = String(value ?? "").trim().toLowerCase();
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) ? email : "";
}

function loginRoleConflict(requestedRole, existingRole, hasPhone) {
  return new HttpsError(
    "already-exists",
    loginRoleConflictMessage(requestedRole, existingRole, hasPhone),
  );
}

function emailKey(email) {
  return Buffer.from(email).toString("base64url");
}

function hashCode(email, code) {
  return crypto
    .createHmac("sha256", otpSecret.value())
    .update(`${email}:${code}`)
    .digest("hex");
}

async function getOrCreateEmailUser(email) {
  try {
    return await admin.auth().getUserByEmail(email);
  } catch (error) {
    if (error.code !== "auth/user-not-found") {
      throw error;
    }
    return admin.auth().createUser({email, emailVerified: true});
  }
}

// Built once per instance and reused. A fresh transport reopened the TCP,
// TLS and SMTP AUTH handshake on every OTP, which dominated the send time.
let otpMailTransporter = null;

function otpMailTransport() {
  if (!otpMailTransporter) {
    const nodemailer = require("nodemailer");
    otpMailTransporter = nodemailer.createTransport({
      host: smtpHost.value(),
      port: Number(smtpPort.value() || 587),
      secure: Number(smtpPort.value()) === 465,
      auth: {
        user: smtpUser.value(),
        pass: smtpPass.value(),
      },
      pool: true,
      maxConnections: 3,
      maxMessages: 100,
    });
  }
  return otpMailTransporter;
}

async function sendOtpMail(email, code) {
  await otpMailTransport().sendMail({
    from: smtpFrom.value(),
    to: email,
    subject: "Your Pritze login OTP",
    text: `Your Pritze login OTP is ${code}. It expires in 10 minutes.`,
    html: `
      <div style="font-family:Arial,sans-serif;line-height:1.5">
        <h2>Your Pritze login OTP</h2>
        <p>Use this code to sign in:</p>
        <p style="font-size:28px;font-weight:700;letter-spacing:4px">${code}</p>
        <p>This code expires in 10 minutes.</p>
      </div>
    `,
  });
}

function bookingStatusMessage(booking) {
  const service = booking.serviceName || "your booking";
  switch (booking.status) {
    case "confirmed":
      return booking.isInstant
        ? {
            title: "Instant booking accepted",
            body: `${booking.customerName || "The customer"}'s ${service} request was accepted by the salon. Arrival time: ${booking.arrivalMinutes || 15} minutes.`,
          }
        : {
            title: "Booking confirmed",
            body: `${booking.customerName || "The customer"}'s ${service} appointment is confirmed.`,
          };
    case "rejected":
      return {
        title: "Booking rejected",
        body: `${booking.customerName || "The customer"}'s ${service} booking was rejected by the salon.`,
      };
    case "inProgress":
      return {
        title: "Service started",
        body: `${service} is now in progress. The final payable amount will appear after the salon ends the service.`,
      };
    case "completed":
      return {
        title: booking.completionSource === "automatic_timeout" ?
          "Service completed automatically" : "Service completed",
        body: `${service} is completed. Final amount ₹${money(booking.customerPayableAmount)} is ready. Open Pritze to view payment options.`,
      };
    case "cancelled":
      if (booking.cancelledBy === "system") {
        return {
            title: "Oops, looks like the salon is busy",
            body: "Please try again or see other nearby salons.",
        };
      }
      if (booking.cancelledBy === "customer") {
        return {
          title: "Customer cancelled booking",
          body: `${booking.customerName || "The customer"} cancelled ${service}.${booking.cancellationReason ? ` Reason: ${booking.cancellationReason}.` : ""}`,
        };
      }
      return {
        title: "Salon cancelled booking",
        body: `The salon cancelled ${booking.customerName || "the customer"}'s ${service} booking.${booking.cancellationReason ? ` Reason: ${booking.cancellationReason}.` : ""}`,
      };
    default:
      return {
        title: "Booking updated",
        body: `${service} status changed to ${booking.status || "updated"}.`,
      };
  }
}

async function hydrateBookingRecipients(booking) {
  if (!booking) {
    return null;
  }
  const hydrated = {...booking};
  if (!hydrated.ownerUid && hydrated.salonId) {
    const salonSnapshot = await admin.firestore()
      .collection("salons")
      .doc(hydrated.salonId)
      .get();
    const salon = salonSnapshot.data() || {};
    if (typeof salon.ownerUid === "string" && salon.ownerUid.trim()) {
      hydrated.ownerUid = salon.ownerUid.trim();
    }
  }
  if (!hydrated.barberUid && hydrated.barberId) {
    const barberSnapshot = await admin.firestore()
      .collection("barbers")
      .doc(hydrated.barberId)
      .get();
    const barber = barberSnapshot.data() || {};
    if (typeof barber.uid === "string" && barber.uid.trim()) {
      hydrated.barberUid = barber.uid.trim();
    }
  }
  return hydrated;
}

function bookingNotificationData(bookingId, booking) {
  const customerArrivalMinutes = booking.arrivalMinutes || 0;
  const salonArrivalMinutes = booking.salonArrivalMinutes ||
    (customerArrivalMinutes > 0 ? customerArrivalMinutes + 5 : 0);
  return {
    type: "booking",
    bookingId,
    salonId: booking.salonId || "",
    status: booking.status || "",
    isInstant: booking.isInstant ? "true" : "false",
    arrivalMinutes: customerArrivalMinutes,
    salonArrivalMinutes,
    bookingFee: booking.bookingFee ?? 0,
    paymentRequired: booking.paymentRequired ? "true" : "false",
    paymentStatus: booking.paymentStatus || "not_required",
    customerPayableAmount: money(booking.customerPayableAmount),
    createdAtMillis: adminMillis(booking.createdAt),
    responseDeadlineMillis: booking.isInstant === true ?
      instantResponseDeadlineMillis(booking) : 0,
    startMillis: adminMillis(booking.start),
    acceptedAtMillis: adminMillis(booking.acceptedAt),
    cancelledAtMillis: adminMillis(booking.cancelledAt),
    rejectedAtMillis: adminMillis(booking.rejectedAt),
    completedAtMillis: adminMillis(booking.completedAt) ||
      (booking.status === "completed" ? Date.now() : 0),
    statusOccurredAtMillis: booking.status === "confirmed" ?
      adminMillis(booking.acceptedAt) || Date.now() :
      booking.status === "rejected" ?
        adminMillis(booking.rejectedAt) || Date.now() :
        booking.status === "cancelled" ?
          adminMillis(booking.cancelledAt) || Date.now() :
          booking.status === "completed" ?
            adminMillis(booking.completedAt) || Date.now() : Date.now(),
    cancelledBy: booking.cancelledBy || "",
    cancellationReason: booking.cancellationReason || "",
    destination: "bookings",
  };
}

async function sendClaimedArrivalReminder({
  bookingRef,
  bookingId,
  audience,
  nowMillis,
}) {
  const firestore = admin.firestore();
  const sentField = audience === "owner" ?
    "ownerArrivalReminderSentAt" : "customerArrivalReminderSentAt";
  const claimField = audience === "owner" ?
    "ownerArrivalReminderClaimedAt" : "customerArrivalReminderClaimedAt";
  const claimExpiryMillis = nowMillis - 3 * 60 * 1000;
  let claimedBooking = null;
  const claimed = await firestore.runTransaction(async (transaction) => {
    const currentSnapshot = await transaction.get(bookingRef);
    const current = currentSnapshot.data();
    if (
      !current ||
      current[sentField] ||
      !bookingArrivalReminderDue({booking: current, audience, nowMillis})
    ) {
      return false;
    }
    const previousClaimMillis = current[claimField]?.toMillis?.() || 0;
    if (previousClaimMillis > claimExpiryMillis) {
      return false;
    }
    claimedBooking = current;
    transaction.update(bookingRef, {
      [claimField]: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });
  if (!claimed || !claimedBooking) {
    return false;
  }

  try {
    const booking = await hydrateBookingRecipients(claimedBooking);
    const recipientUid = audience === "owner" ?
      booking.ownerUid : booking.customerUid;
    const service = booking.serviceName || "your service";
    const title = audience === "owner" ?
      "Customer arriving within 5 minutes" :
      booking.isInstant === true ?
        "Your appointment starts in 5 minutes" :
        "Your appointment starts soon";
    const body = audience === "owner" ?
      `${booking.customerName || "A customer"} is expected within 5 minutes for ${service}.` :
      booking.isInstant === true ?
      `Your ${service} appointment is scheduled to start in about 5 minutes.` :
      `Your ${service} appointment starts in about 30 minutes.`;
    const delivery = await sendToUsers([recipientUid].filter(Boolean), {
      title,
      body,
      data: {
        ...bookingNotificationData(bookingId, booking),
        event: "arrivalReminder",
        audience,
      },
      requiredActiveRolesByUser: bookingRecipientRoles(booking),
    });
    await bookingRef.update({
      [sentField]: admin.firestore.FieldValue.serverTimestamp(),
      [claimField]: admin.firestore.FieldValue.delete(),
    });
    console.log("booking arrival reminder delivered", {
      bookingId,
      audience,
      delivery,
    });
    return true;
  } catch (error) {
    await bookingRef.update({
      [claimField]: admin.firestore.FieldValue.delete(),
    });
    throw error;
  }
}

async function claimOwnerBookingAlert(bookingRef, eventId) {
  return admin.firestore().runTransaction(async (transaction) => {
    const snapshot = await transaction.get(bookingRef);
    const booking = snapshot.data();
    if (
      !booking ||
      booking.isInstant !== true ||
      booking.status !== "pending" ||
      booking.ownerAlertEventId
    ) {
      return false;
    }
    transaction.update(bookingRef, {
      ownerAlertEventId: eventId,
      ownerAlertStartedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });
}

async function expirePendingInstantBooking(bookingRef, bookingId) {
  let expiredBooking = null;
  let proinWalletToRefresh = "";
  const firestore = admin.firestore();
  await firestore.runTransaction(async (transaction) => {
    expiredBooking = null;
    proinWalletToRefresh = "";
    const snapshot = await transaction.get(bookingRef);
    const booking = snapshot.data();
    if (
      !booking ||
      booking.isInstant !== true ||
      booking.status !== "pending" ||
      !Number.isFinite(instantResponseDeadlineMillis(booking)) ||
      Date.now() < instantResponseDeadlineMillis(booking)
    ) {
      return;
    }
    const customerUid = String(booking.customerUid ?? "").trim();
    const activeCustomerRef = customerUid ? admin.firestore()
      .collection("activeCustomerBookings").doc(customerUid) : null;
    const activeInstantRef = customerUid ? admin.firestore()
      .collection("activeInstantBookings").doc(customerUid) : null;
    const activeCustomer = activeCustomerRef ?
      await transaction.get(activeCustomerRef) : null;
    const activeInstant = activeInstantRef ?
      await transaction.get(activeInstantRef) : null;
    let discountResolution = null;
    if (booking.discountStatus === "reserved" &&
        String(booking.discountCampaignId ?? "").trim()) {
      const refs = discountReferences(
        firestore,
        booking.discountCampaignId,
        booking.salonId,
        booking.customerUid,
      );
      await transaction.get(refs.campaignUsageRef);
      await transaction.get(refs.salonUsageRef);
      await transaction.get(refs.customerUsageRef);
      const fundingState = await readDiscountResolutionFundingState({
        transaction,
        firestore,
        refs,
        booking,
        bookingId,
      });
      discountResolution = {refs, fundingState};
    }
    let proinResolutionFields = null;
    if (booking.proinStatus === "reserved") {
      const resolution = await runProinCallable(() =>
        proinBackend.resolveBookingRedemptionInTransaction({
          transaction,
          bookingId,
          booking,
          outcome: "released",
          nowMillis: Date.now(),
        }));
      if (resolution) {
        const {walletId, ...bookingFields} = resolution;
        proinWalletToRefresh = walletId;
        proinResolutionFields = bookingFields;
      }
    }
    const update = {
      status: "cancelled",
      cancelledBy: "system",
      cancellationReason: "No response from salon within 120 seconds",
      cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
      responseTimedOutAt: admin.firestore.FieldValue.serverTimestamp(),
      discountStatus: discountResolution ? "released" :
        (booking.discountStatus || "none"),
      ...(proinResolutionFields || {}),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    transaction.update(bookingRef, update);
    if (discountResolution) {
      resolveReservedDiscountInTransaction({
        transaction,
        firestore,
        refs: discountResolution.refs,
        booking,
        bookingId,
        outcome: "released",
        fundingState: discountResolution.fundingState,
      });
    }
    if (activeCustomerRef && activeCustomer?.data()?.bookingId === bookingId) {
      transaction.set(activeCustomerRef, {
        active: false,
        resolvedStatus: "cancelled",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
    }
    if (activeInstantRef && activeInstant?.data()?.bookingId === bookingId) {
      transaction.set(activeInstantRef, {
        active: false,
        resolvedStatus: "cancelled",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
    }
    expiredBooking = {...booking, ...update};
  });
  if (proinWalletToRefresh) {
    await proinBackend.refreshWalletExpiry(proinWalletToRefresh);
  }
  if (expiredBooking) {
    const booking = await hydrateBookingRecipients(expiredBooking);
    await sendToUsers([booking.customerUid].filter(Boolean), {
      title: "Oops, looks like the salon is busy",
      body: "Please try again or see other nearby salons.",
      data: {
        ...bookingNotificationData(bookingId, booking),
        event: "response_timeout",
      },
      requiredActiveRolesByUser: bookingRecipientRoles(booking),
    });
  }
  return expiredBooking;
}

async function sendOwnerBookingRequest(bookingId, booking, attempt) {
  if (!shouldAlertOwnerForBooking(booking)) return mergeDelivery();
  const expiresAtMillis = instantResponseDeadlineMillis(booking);
  const title = booking.isInstant
    ? "Instant booking request"
    : "New booking request";
  const customerArrivalMinutes = booking.arrivalMinutes || 15;
  const salonArrivalMinutes =
    booking.salonArrivalMinutes || customerArrivalMinutes + 5;
  const body = booking.isInstant
    ? `${booking.customerName || "A customer"} requested ${booking.serviceName || "a service"}. Customer ETA ${customerArrivalMinutes} min; salon window ${salonArrivalMinutes} min.`
    : `${booking.customerName || "A customer"} booked ${booking.serviceName || "a service"}.`;
  const recipients = [booking.ownerUid].filter(Boolean);
  const modernDelivery = await sendToUsers(recipients, {
    title,
    body,
    data: {
      ...bookingNotificationData(bookingId, booking),
      channel: OWNER_BOOKING_REQUEST_CHANNEL,
      alertAttempt: attempt + 1,
    },
    androidChannelId: OWNER_BOOKING_REQUEST_CHANNEL,
    androidSound: OWNER_BOOKING_REQUEST_SOUND,
    androidDataOnly: true,
    apnsSound: "owner_booking_request.wav",
    apnsCategory: IOS_OWNER_BOOKING_REQUEST_CATEGORY,
    collapseKey: `booking-${bookingId}`,
    tokenField: OWNER_ALERT_TOKEN_FIELD,
    requireActiveOwnerSession: true,
    expiresAtMillis,
  });
  // Devices still on the previous build only react to their own channel id.
  const previousDelivery = await sendToUsers(recipients, {
    title,
    body,
    data: {
      ...bookingNotificationData(bookingId, booking),
      channel: OWNER_BOOKING_REQUEST_CHANNEL_V3,
      alertAttempt: attempt + 1,
    },
    androidChannelId: OWNER_BOOKING_REQUEST_CHANNEL_V3,
    androidSound: OWNER_BOOKING_REQUEST_SOUND,
    androidDataOnly: true,
    apnsSound: "owner_booking_request.wav",
    apnsCategory: IOS_OWNER_BOOKING_REQUEST_CATEGORY,
    collapseKey: `booking-${bookingId}`,
    tokenField: OWNER_ALERT_TOKEN_FIELD_V3,
    excludeTokenField: OWNER_ALERT_TOKEN_FIELD,
    requireActiveOwnerSession: true,
    expiresAtMillis,
  });
  const legacyDelivery = await sendToUsers(recipients, {
    title,
    body,
    data: {
      ...bookingNotificationData(bookingId, booking),
      channel: LEGACY_OWNER_BOOKING_REQUEST_CHANNEL,
      alertAttempt: attempt + 1,
    },
    androidChannelId: LEGACY_OWNER_BOOKING_REQUEST_CHANNEL,
    androidSound: OWNER_BOOKING_REQUEST_SOUND,
    apnsSound: "owner_booking_request.wav",
    apnsCategory: IOS_OWNER_BOOKING_REQUEST_CATEGORY,
    collapseKey: `booking-${bookingId}`,
    tokenField: "fcmTokens",
    excludeTokenFields: [
      OWNER_ALERT_TOKEN_FIELD,
      OWNER_ALERT_TOKEN_FIELD_V3,
    ],
    requireActiveOwnerSession: true,
    expiresAtMillis,
  });
  return mergeDelivery(modernDelivery, previousDelivery, legacyDelivery);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function mergeDelivery(...deliveries) {
  return deliveries.reduce((total, delivery) => {
    return {
      userCount: total.userCount + (delivery?.userCount || 0),
      tokenCount: total.tokenCount + (delivery?.tokenCount || 0),
      successCount: total.successCount + (delivery?.successCount || 0),
      failureCount: total.failureCount + (delivery?.failureCount || 0),
    };
  }, {userCount: 0, tokenCount: 0, successCount: 0, failureCount: 0});
}

async function sendToUsers(userIds, message) {
  const uniqueUserIds = [...new Set((userIds || []).filter(Boolean))];
  if (uniqueUserIds.length === 0) {
    return {userCount: 0, tokenCount: 0, successCount: 0, failureCount: 0};
  }
  const tokenEntries = [];
  await Promise.all(uniqueUserIds.map(async (uid) => {
    const snapshot = await admin.firestore().collection("users").doc(uid).get();
    const data = snapshot.data() || {};
    // Sign-out sets this false. It is the authoritative stop, because
    // `fcmTokens` cannot be trusted to be clean on its own: FCM rotates
    // tokens, so a device's older tokens stay in the list and removing the
    // current one does not de-register the phone. Compared against false so
    // accounts that predate the flag keep receiving notifications.
    if (data.notificationsEnabled === false) {
      return;
    }
    if (
      message.requireActiveOwnerSession &&
      (data.activeRole !== "owner" || data.ownerNotificationsEnabled !== true)
    ) {
      return;
    }
    const requiredRoles = message.requiredActiveRolesByUser?.[uid];
    if (
      Array.isArray(requiredRoles) &&
      requiredRoles.length > 0 &&
      !requiredRoles.includes(data.activeRole)
    ) {
      return;
    }
    const tokenField = message.tokenField || "fcmTokens";
    const tokens = Array.isArray(data[tokenField]) ? data[tokenField] : [];
    const excludeFields = [
      ...(message.excludeTokenField ? [message.excludeTokenField] : []),
      ...(Array.isArray(message.excludeTokenFields) ?
        message.excludeTokenFields : []),
    ];
    const excludedTokens = new Set(
      excludeFields.flatMap((field) =>
        Array.isArray(data[field]) ? data[field] : [],
      ),
    );
    for (const token of tokens) {
      if (
        typeof token === "string" &&
        token.trim() &&
        !excludedTokens.has(token)
      ) {
        tokenEntries.push({uid, token});
      }
    }
  }));
  const tokens = [...new Set(tokenEntries.map((entry) => entry.token))];
  if (tokens.length === 0) {
    console.log("sendToUsers no tokens", {userIds: uniqueUserIds});
    return {
      userCount: uniqueUserIds.length,
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
    };
  }
  const data = stringifyData({
    ...message.data,
    notificationTitle: message.title,
    notificationBody: message.body,
  });
  const ttlMillis = message.expiresAtMillis ?
    Math.max(0, message.expiresAtMillis - Date.now()) : 2 * 60 * 1000;
  if (ttlMillis === 0) return mergeDelivery();
  const multicastMessage = {
    tokens: tokens.slice(0, 500),
    data,
    android: {
      priority: "high",
      ttl: ttlMillis,
      ...(message.collapseKey ? {collapseKey: message.collapseKey} : {}),
    },
    apns: {
      headers: {
        "apns-priority": message.controlOnly ? "5" : "10",
        "apns-push-type": message.controlOnly ? "background" : "alert",
        "apns-expiration": String(Math.floor((Date.now() + ttlMillis) / 1000)),
        ...(message.collapseKey
          ? {"apns-collapse-id": message.collapseKey}
          : {}),
      },
      payload: {
        aps: {
          ...(message.controlOnly
            ? {"content-available": 1}
            : {alert: {title: message.title, body: message.body}}),
          ...(!message.controlOnly
            ? {
                sound: message.apnsSound || "default",
                category: message.apnsCategory || "PRITZE_BOOKING_UPDATE",
                "interruption-level": "active",
              }
            : {}),
        },
      },
    },
  };
  if (!message.androidDataOnly) {
    multicastMessage.notification = {
      title: message.title,
      body: message.body,
    };
    multicastMessage.android.notification = {
      channelId: message.androidChannelId || "pritze_booking_updates",
      sound: message.androidSound || "default",
    };
  }
  const response = await admin.messaging().sendEachForMulticast(
    multicastMessage,
  );
  logPushDeliveryFailures(
    tokens,
    tokenEntries,
    response.responses,
    message.tokenField || "fcmTokens",
  );
  await cleanupInvalidTokens(
    tokens,
    tokenEntries,
    response.responses,
    message.tokenField || "fcmTokens",
  );
  return {
    userCount: uniqueUserIds.length,
    tokenCount: tokens.length,
    successCount: response.successCount,
    failureCount: response.failureCount,
  };
}

function logPushDeliveryFailures(
  sentTokens,
  tokenEntries,
  responses,
  tokenField,
) {
  responses.forEach((result, index) => {
    if (result.success) {
      return;
    }
    const failedToken = sentTokens[index];
    const owners = tokenEntries
      .filter((entry) => entry.token === failedToken)
      .map((entry) => entry.uid);
    console.error("push delivery failed", {
      code: result.error?.code || "unknown",
      message: result.error?.message || "Unknown messaging error",
      tokenField,
      userIds: [...new Set(owners)],
      tokenSuffix: String(failedToken || "").slice(-8),
    });
  });
}

function stringifyData(data) {
  return Object.fromEntries(
    Object.entries(data).map(([key, value]) => [key, String(value ?? "")]),
  );
}

async function cleanupInvalidTokens(
  sentTokens,
  tokenEntries,
  responses,
  tokenField,
) {
  const invalidByUser = new Map();
  responses.forEach((result, index) => {
    if (result.success) {
      return;
    }
    const code = result.error?.code || "";
    if (
      code !== "messaging/registration-token-not-registered" &&
      code !== "messaging/invalid-registration-token"
    ) {
      return;
    }
    const failedToken = sentTokens[index];
    for (const entry of tokenEntries) {
      if (entry.token !== failedToken) {
        continue;
      }
      const tokens = invalidByUser.get(entry.uid) || [];
      tokens.push(entry.token);
      invalidByUser.set(entry.uid, tokens);
    }
  });
  await Promise.all([...invalidByUser.entries()].map(([uid, tokens]) => {
    const updates = {
      [tokenField]: admin.firestore.FieldValue.arrayRemove(...tokens),
    };
    if (tokenField !== "fcmTokens") {
      updates.fcmTokens = admin.firestore.FieldValue.arrayRemove(...tokens);
    }
    return admin.firestore().collection("users").doc(uid).set(
      updates,
      {merge: true},
    );
  }));
}
