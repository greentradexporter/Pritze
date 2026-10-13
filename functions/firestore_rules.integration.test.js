const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const {
  deleteField,
  doc,
  getDoc,
  setDoc,
  updateDoc,
} = require("firebase/firestore");
const {SERVICE_CATALOG} = require("./service_catalog");

test("Firestore rules isolate referral, discount and Proin financial state", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async () => {
  const rules = fs.readFileSync(
    path.join(__dirname, "..", "firestore.rules"),
    "utf8",
  );
  const environment = await initializeTestEnvironment({
    projectId: "demo-pritze-rules",
    firestore: {rules},
  });
  try {
    await environment.withSecurityRulesDisabled(async (context) => {
      const firestore = context.firestore();
      await setDoc(doc(firestore, "users", "customer-1"), {
        role: "customer",
        name: "Customer",
      });
      await setDoc(doc(firestore, "users", "owner-1"), {
        role: "owner",
        name: "Owner",
        profilePhone: "+919000000001",
      });
      await setDoc(doc(firestore, "salons", "salon-1"), {
        ownerUid: "owner-1",
        name: "Public salon",
      });
      await setDoc(doc(firestore, "discountQuotes", "quote-1"), {
        customerUid: "customer-1",
        discountAmount: 10,
      });
      await setDoc(doc(firestore, "referralStats", "customer-1"), {
        qualifiedCustomerCount: 1,
      });
      await setDoc(doc(firestore, "proinWallets", "wallet-1"), {
        accountId: "customer-1",
        availableProin: 100,
      });
      await setDoc(doc(firestore, "proinLots", "lot-1"), {
        walletId: "wallet-1",
        availableProin: 100,
      });
      await setDoc(doc(firestore, "proinCoupons", "coupon-hash"), {
        maskedCode: "SA••50",
        active: true,
      });
    });

    const customer = environment.authenticatedContext("customer-1")
      .firestore();
    const stranger = environment.authenticatedContext("customer-2")
      .firestore();
    const owner = environment.authenticatedContext("owner-1").firestore();
    const publicClient = environment.unauthenticatedContext().firestore();

    const salonProfile = {
      ownerUid: "owner-1",
      name: "Canonical salon",
      ownerName: "Owner",
      address: "Main Road",
      phone: "+919000000001",
      email: "owner@example.com",
      openTime: "9:00 AM",
      closeTime: "8:00 PM",
      isOpen: true,
      // A new salon starts pending review, exactly as the app writes it.
      approvalStatus: "pending",
      services: SERVICE_CATALOG.map((service, index) => ({
        ...service,
        id: `catalog-${index}`,
        isAvailable: true,
        instantBookingEnabled: true,
        isCustom: false,
      })),
    };

    await assertSucceeds(
        setDoc(doc(owner, "salons", "canonical-salon"), salonProfile),
    );
    const privatePaymentProfile = {
      salonId: "canonical-salon",
      ownerUid: "owner-1",
      upiId: "canonical@bank",
      qrCodeUrl: "https://example.com/private-qr.png",
    };
    await assertSucceeds(setDoc(
        doc(owner, "salonPaymentProfiles", "canonical-salon"),
        privatePaymentProfile,
    ));
    await assertSucceeds(getDoc(
        doc(owner, "salonPaymentProfiles", "canonical-salon"),
    ));
    await assertFails(getDoc(
        doc(customer, "salonPaymentProfiles", "canonical-salon"),
    ));
    await assertFails(getDoc(
        doc(publicClient, "salonPaymentProfiles", "canonical-salon"),
    ));
    await assertFails(
        setDoc(doc(owner, "salons", "custom-salon"), {
          ...salonProfile,
          services: [
            ...salonProfile.services,
            {
              id: "custom",
              name: "Random custom service",
              category: "Hair",
              price: 100,
              durationMinutes: 15,
            },
          ],
        }),
    );

    await assertSucceeds(getDoc(doc(publicClient, "salons", "salon-1")));
    await assertSucceeds(getDoc(doc(customer, "users", "customer-1")));
    await assertFails(getDoc(doc(stranger, "users", "customer-1")));

    for (const target of [
      "discountQuotes/quote-1",
      "discountCampaigns/campaign-1",
      "discountCampaignVersions/campaign-1__v1",
      "discountCustomerTotals/customer-1",
      "discountSalonTotals/salon-1",
      "discountPlatformTotals/current",
      "salonWallets/salon-1",
      "salonSettlements/booking-1",
      "settlementPaymentReferences/reference-1",
      "referralCodes/AB12CD",
      "referrals/customer-1",
      "referralStats/customer-1",
      "referralAttempts/customer-1",
      "proinPrograms/program-1",
      "proinProgramVersions/program-1__v1",
      "proinWallets/wallet-1",
      "proinLots/lot-1",
      "proinLedger/transaction-1",
      "proinReservations/booking-1",
      "discountSalonPromotionCreditReservations/booking-1",
      "proinProgramUsage/program-1",
      "proinProgramAccountUsage/usage-1",
      "salonPromotionCreditUsage/wallet-1",
      "proinFinance/current",
      "proinIdempotencyKeys/key-1",
      "proinReconciliationReports/report-1",
      "proinJobState/referralAwardRetry",
      "proinCoupons/coupon-hash",
      "proinCouponVersions/coupon-hash__v1",
      "proinCouponUsage/coupon-hash",
      "proinCouponClaims/claim-1",
      "proinCouponAttempts/customer-1",
      "checkoutCouponAttempts/customer-1",
      "voucherCodeRegistry/coupon-hash",
      "discountQuoteAttempts/customer-1",
      "proinQuoteAttempts/customer-1",
      "discountOfferAttempts/customer-1",
      "proinSalonReimbursements/booking-1",
      "proinSettlementPaymentReferences/reference-hash-1",
    ]) {
      await assertFails(getDoc(doc(customer, target)));
      await assertFails(setDoc(doc(customer, target), {tampered: true}));
    }
    assert.ok(true);
  } finally {
    await environment.cleanup();
  }
});

// The profile allowlist decides whether a phone can register for push and,
// more importantly, de-register itself at sign-out. A field missing from it
// rejects the entire write, so a signed-out phone keeps receiving booking
// alerts. Nothing else exercises this: the app's own tests mock Firestore.
test("a device can register and de-register its own push profile", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async () => {
  const rules = fs.readFileSync(
    path.join(__dirname, "..", "firestore.rules"),
    "utf8",
  );
  const environment = await initializeTestEnvironment({
    projectId: "demo-pritze-rules",
    firestore: {rules},
  });
  try {
    await environment.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), "users", "owner-1"), {
        role: "owner",
        activeRole: "owner",
        name: "Owner",
        fcmTokens: ["token-1"],
        ownerAlertV4Tokens: ["token-1"],
        notificationsEnabled: true,
        ownerNotificationsEnabled: true,
      });
    });
    const owner = environment.authenticatedContext("owner-1").firestore();
    const profile = doc(owner, "users", "owner-1");

    // Exactly what _saveMessagingToken writes.
    await assertSucceeds(setDoc(profile, {
      fcmTokens: ["token-1", "token-2"],
      ownerAlertV4Tokens: ["token-2"],
      ownerAlertV3Tokens: [],
      lastFcmToken: "token-2",
      notificationsEnabled: true,
      ownerNotificationsEnabled: true,
      fcmUpdatedAt: new Date(),
    }, {merge: true}));

    // Exactly what sign-out writes. activeRole is the field that used to be
    // missing from the allowlist and silently failed the whole request.
    await assertSucceeds(updateDoc(profile, {
      fcmTokens: [],
      ownerAlertV4Tokens: [],
      ownerAlertV3Tokens: [],
      lastFcmToken: deleteField(),
      notificationsEnabled: false,
      ownerNotificationsEnabled: false,
      activeRole: deleteField(),
      fcmUpdatedAt: new Date(),
    }));
    let after;
    await environment.withSecurityRulesDisabled(async (context) => {
      after = (
        await getDoc(doc(context.firestore(), "users", "owner-1"))
      ).data();
    });
    assert.equal(after.notificationsEnabled, false);
    assert.equal(after.ownerNotificationsEnabled, false);
    assert.equal(after.activeRole, undefined);

    // The allowlist must still refuse anything that grants authority. Rules
    // read the immutable 'role' field, never activeRole.
    await assertFails(updateDoc(profile, {role: "admin"}));
    await assertFails(updateDoc(profile, {roles: ["owner", "admin"]}));
    await assertFails(updateDoc(profile, {profilePhone: "+919000000002"}));
    await assertFails(updateDoc(profile, {referralOnboardingCompleted: true}));
    // Another signed-in user may not touch this profile at all.
    const other = environment.authenticatedContext("customer-1").firestore();
    await assertFails(getDoc(doc(other, "users", "owner-1")));
    await assertFails(updateDoc(doc(other, "users", "owner-1"), {
      notificationsEnabled: true,
    }));
  } finally {
    await environment.cleanup();
  }
});

// Half the live salons predate the approval gate and have no approvalStatus.
// Rules raise on a missing property, so reading it directly denied every edit
// by exactly the owners the legacy branch is meant to admit.
test("an owner can still edit a salon that predates the approval gate", {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async () => {
  const rules = fs.readFileSync(
    path.join(__dirname, "..", "firestore.rules"),
    "utf8",
  );
  const environment = await initializeTestEnvironment({
    projectId: "demo-pritze-rules",
    firestore: {rules},
  });
  const salon = (overrides = {}) => ({
    ownerUid: "owner-1",
    name: "Legacy salon",
    ownerName: "Owner",
    address: "Nashik",
    openTime: "9:00 AM",
    closeTime: "9:00 PM",
    isOpen: true,
    phone: "+919000000001",
    email: "owner@example.com",
    services: SERVICE_CATALOG.map((service, index) => ({
      ...service,
      id: `catalog-${index}`,
      isAvailable: true,
      instantBookingEnabled: true,
      isCustom: false,
    })),
    ...overrides,
  });
  try {
    await environment.withSecurityRulesDisabled(async (context) => {
      const firestore = context.firestore();
      await setDoc(doc(firestore, "users", "owner-1"), {
        role: "owner",
        name: "Owner",
        profilePhone: "+919000000001",
      });
      // No approvalStatus: registered before the gate existed.
      await setDoc(doc(firestore, "salons", "legacy-1"), salon());
      await setDoc(doc(firestore, "salons", "approved-1"),
        salon({approvalStatus: "approved"}));
    });
    const owner = environment.authenticatedContext("owner-1").firestore();

    // Editing a legacy salon, leaving the field unset.
    await assertSucceeds(setDoc(doc(owner, "salons", "legacy-1"),
      salon({closeTime: "10:00 PM"})));
    // Or adopting 'approved' on that first post-upgrade edit.
    await assertSucceeds(setDoc(doc(owner, "salons", "legacy-1"),
      salon({approvalStatus: "approved"})));
    // An approved salon keeps its state.
    await assertSucceeds(setDoc(doc(owner, "salons", "approved-1"),
      salon({approvalStatus: "approved", isOpen: false})));

    // Nobody self-approves out of pending, or self-rejects into visibility.
    await environment.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), "salons", "pending-1"),
        salon({approvalStatus: "pending"}));
    });
    await assertFails(setDoc(doc(owner, "salons", "pending-1"),
      salon({approvalStatus: "approved"})));
    await assertFails(setDoc(doc(owner, "salons", "pending-1"), salon()));
    // A new salon must start pending.
    await assertFails(setDoc(doc(owner, "salons", "new-1"),
      salon({approvalStatus: "approved"})));
    await assertFails(setDoc(doc(owner, "salons", "new-2"), salon()));
    await assertSucceeds(setDoc(doc(owner, "salons", "new-3"),
      salon({approvalStatus: "pending"})));
  } finally {
    await environment.cleanup();
  }
});
