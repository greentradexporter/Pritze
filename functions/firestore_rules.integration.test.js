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
  doc,
  getDoc,
  setDoc,
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
