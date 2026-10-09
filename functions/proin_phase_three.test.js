const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

function source(relativePath) {
  return fs.readFileSync(path.join(__dirname, "..", relativePath), "utf8");
}

test("Phase 3 Proin redemption is server-authoritative", () => {
  const indexSource = source("functions/index.js");
  const backendSource = source("functions/proin_backend.js");
  const rulesSource = source("firestore.rules");

  for (const callable of [
    "getCustomerProinWallet",
    "getProinBookingQuote",
    "claimProinCoupon",
    "applyCheckoutCoupon",
  ]) {
    assert.match(
      indexSource,
      new RegExp(`exports\\.${callable} = onMobileCall`),
    );
  }
  assert.match(indexSource, /enforceAppCheck: true/);
  assert.match(indexSource, /requestedProin/);
  assert.match(indexSource, /reserveBookingRedemptionInTransaction/);
  assert.match(indexSource, /resolveBookingRedemptionInTransaction/);
  assert.match(backendSource, /transaction\.create\(reservationRef/);
  assert.match(backendSource, /`reserve_\$\{bookingId\}`/);
  assert.match(backendSource, /`\$\{outcome === "redeemed" \? "redeem" : "release"\}_\$\{bookingId\}`/);
  assert.match(rulesSource, /match \/proinQuoteAttempts\/\{userId\}/);
  assert.match(rulesSource, /match \/proinSalonReimbursements\/\{bookingId\}/);
});

test("Phase 3 customer surfaces explain and apply promotional Proin", () => {
  const profileSource = source(
    "lib/screens/customer/customer_profile_screen.dart",
  );
  const bookingSource = source(
    "lib/screens/customer/salon_booking_screen.dart",
  );
  const receiptSource = source(
    "lib/screens/customer/customer_completion_receipt_screen.dart",
  );

  assert.match(profileSource, /customer-proin-wallet/);
  assert.match(profileSource, /Put your coupon/);
  assert.match(profileSource, /cannot be purchased, transferred, withdrawn/);
  assert.match(bookingSource, /booking-use-proin-switch/);
  assert.match(bookingSource, /checkout-visible-discount-offers/);
  assert.match(bookingSource, /applyVisibleCheckoutDiscount/);
  assert.match(bookingSource, /checkout-coupon-input/);
  assert.match(bookingSource, /applyCheckoutCoupon/);
  assert.match(bookingSource, /requestedProin:/);
  assert.match(bookingSource, /Pay at salon counter/);
  assert.match(receiptSource, /Proin used/);
});
