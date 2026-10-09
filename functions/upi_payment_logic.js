const crypto = require("node:crypto");

const UPI_ID_PATTERN = /^[a-z0-9._-]{2,64}@[a-z][a-z0-9.-]{1,32}$/;

function normalizedMoney(value) {
  const amount = Number(value);
  if (!Number.isFinite(amount) || amount <= 0) return 0;
  return Math.round(amount);
}

function normalizeUpiId(value) {
  const upiId = String(value ?? "").trim().toLowerCase().slice(0, 100);
  return UPI_ID_PATTERN.test(upiId) ? upiId : "";
}

function normalizeQrCodeUrl(value) {
  const text = String(value ?? "").trim();
  if (!text) return "";
  try {
    const url = new URL(text);
    return url.protocol === "https:" ? url.toString() : "";
  } catch (_) {
    return "";
  }
}

function paymentReferenceForBooking(bookingId) {
  const digest = crypto
    .createHash("sha256")
    .update(String(bookingId ?? "").trim())
    .digest("hex")
    .slice(0, 24)
    .toUpperCase();
  return `PRITZE${digest}`;
}

function buildCompletedBookingUpiPaymentDetails({
  bookingId,
  salonId,
  salonName,
  amountInr,
  upiId,
  qrCodeUrl,
}) {
  const normalizedBookingId = String(bookingId ?? "").trim();
  const normalizedSalonId = String(salonId ?? "").trim();
  const normalizedSalonName = String(salonName ?? "").trim() || "Salon";
  const amount = normalizedMoney(amountInr);
  const paymentUpiId = normalizeUpiId(upiId);
  const paymentQrCodeUrl = normalizeQrCodeUrl(qrCodeUrl);
  const transactionReference = paymentReferenceForBooking(normalizedBookingId);
  const paymentAvailable = amount > 0 && paymentUpiId.length > 0;
  let upiUri = "";
  if (paymentAvailable) {
    const query = new URLSearchParams({
      pa: paymentUpiId,
      pn: normalizedSalonName,
      tr: transactionReference,
      tn: `Pritze booking ${normalizedBookingId}`,
      am: amount.toFixed(2),
      cu: "INR",
    });
    upiUri = `upi://pay?${query.toString()}`;
  }
  return {
    bookingId: normalizedBookingId,
    salonId: normalizedSalonId,
    salonName: normalizedSalonName,
    amountInr: amount,
    currency: "INR",
    upiId: paymentUpiId,
    upiUri,
    qrCodeUrl: paymentQrCodeUrl,
    transactionReference,
    paymentAvailable,
  };
}

module.exports = {
  buildCompletedBookingUpiPaymentDetails,
  normalizeQrCodeUrl,
  normalizeUpiId,
  paymentReferenceForBooking,
};
