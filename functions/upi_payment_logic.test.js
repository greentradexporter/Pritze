const assert = require("node:assert/strict");
const test = require("node:test");

const {
  buildCompletedBookingUpiPaymentDetails,
  normalizeQrCodeUrl,
  normalizeUpiId,
  paymentReferenceForBooking,
} = require("./upi_payment_logic");

test("builds a stable encoded UPI URI from server-authoritative details", () => {
  const details = buildCompletedBookingUpiPaymentDetails({
    bookingId: "booking / 42",
    salonId: "salon-1",
    salonName: "A & B Salon",
    amountInr: 349,
    upiId: "Owner.Name@okaxis",
    qrCodeUrl: "https://example.com/private-qr.png",
  });
  const uri = new URL(details.upiUri);

  assert.equal(details.paymentAvailable, true);
  assert.equal(details.amountInr, 349);
  assert.equal(details.currency, "INR");
  assert.equal(details.upiId, "owner.name@okaxis");
  assert.equal(uri.protocol, "upi:");
  assert.equal(uri.hostname, "pay");
  assert.equal(uri.searchParams.get("pa"), "owner.name@okaxis");
  assert.equal(uri.searchParams.get("pn"), "A & B Salon");
  assert.equal(uri.searchParams.get("am"), "349.00");
  assert.equal(uri.searchParams.get("cu"), "INR");
  assert.equal(uri.searchParams.get("tn"), "Pritze booking booking / 42");
  assert.equal(uri.searchParams.get("tr"), details.transactionReference);
  assert.equal(
    details.transactionReference,
    paymentReferenceForBooking("booking / 42"),
  );
});

test("invalid or absent UPI details leave direct payment unavailable", () => {
  for (const upiId of ["", "not-an-id", "owner@", "upi://pay"]) {
    const details = buildCompletedBookingUpiPaymentDetails({
      bookingId: "booking-1",
      salonId: "salon-1",
      salonName: "Salon",
      amountInr: 100,
      upiId,
    });
    assert.equal(details.paymentAvailable, false);
    assert.equal(details.upiUri, "");
  }
});

test("zero payable amount omits all payment actions", () => {
  const details = buildCompletedBookingUpiPaymentDetails({
    bookingId: "booking-free",
    salonId: "salon-1",
    salonName: "Salon",
    amountInr: 0,
    upiId: "owner@okaxis",
  });
  assert.equal(details.amountInr, 0);
  assert.equal(details.paymentAvailable, false);
  assert.equal(details.upiUri, "");
});

test("accepts only valid UPI IDs and HTTPS QR URLs", () => {
  assert.equal(normalizeUpiId("Owner@OKSBI"), "owner@oksbi");
  assert.equal(normalizeUpiId("owner @oksbi"), "");
  assert.equal(
    normalizeQrCodeUrl("https://example.com/qr.png"),
    "https://example.com/qr.png",
  );
  assert.equal(normalizeQrCodeUrl("http://example.com/qr.png"), "");
  assert.equal(normalizeQrCodeUrl("not a URL"), "");
});
