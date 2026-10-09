"use strict";

const MAX_AMOUNT = 1_000_000_000;
const SETTLEMENT_PAYMENT_METHODS = new Set([
  "bank_transfer",
  "upi",
  "cash",
]);

class SalonFinanceValidationError extends Error {
  constructor(message) {
    super(message);
    this.name = "SalonFinanceValidationError";
  }
}

function money(value, label = "Amount") {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0 || number > MAX_AMOUNT) {
    throw new SalonFinanceValidationError(`Enter a valid ${label}.`);
  }
  return Math.round(number * 100) / 100;
}

function positiveMoney(value, label = "Amount") {
  const amount = money(value, label);
  if (amount <= 0) {
    throw new SalonFinanceValidationError(`${label} must be greater than zero.`);
  }
  return amount;
}

function salonCreditLimit(value) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0 || number > MAX_AMOUNT) {
    throw new SalonFinanceValidationError(
      "Enter a whole-number promotional credit limit.",
    );
  }
  return number;
}

function settlementPaymentMethod(value) {
  const method = String(value ?? "bank_transfer").trim().toLowerCase();
  if (!SETTLEMENT_PAYMENT_METHODS.has(method)) {
    throw new SalonFinanceValidationError(
      "Choose Bank transfer, UPI, or Cash as the payment method.",
    );
  }
  return method;
}

function settlementPaymentReference(value, paymentMethod) {
  const method = settlementPaymentMethod(paymentMethod);
  const reference = String(value ?? "").trim().slice(0, 120);
  const label = method === "cash" ? "cash receipt or ledger reference" :
    method === "upi" ? "UPI transaction reference" :
      "bank transaction reference";
  if (reference.length < 4) {
    throw new SalonFinanceValidationError(
      `Enter a ${label} of at least 4 characters.`,
    );
  }
  return {paymentMethod: method, paymentReference: reference};
}

function remainingSettlementAmount(settlement = {}) {
  const original = money(settlement.pritzePayoutAmount ?? 0, "Settlement amount");
  const alreadyPaid = money(settlement.paidAmount ?? 0, "Paid amount");
  return Math.max(0, Math.round((original - alreadyPaid) * 100) / 100);
}

function allocateSalonSettlementPayment(settlements, amountInr) {
  const amount = positiveMoney(amountInr, "Settlement amount");
  const open = (Array.isArray(settlements) ? settlements : [])
    .map((settlement) => ({
      ...settlement,
      remainingAmount: remainingSettlementAmount(settlement),
    }))
    .filter((settlement) => settlement.remainingAmount > 0)
    .sort((left, right) => {
      const leftTime = Number(left.createdAtMillis) || 0;
      const rightTime = Number(right.createdAtMillis) || 0;
      return leftTime - rightTime || String(left.bookingId).localeCompare(String(right.bookingId));
    });
  const outstanding = Math.round(open.reduce(
    (total, settlement) => total + settlement.remainingAmount,
    0,
  ) * 100) / 100;
  if (amount > outstanding) {
    throw new SalonFinanceValidationError(
      "Settlement amount cannot exceed this salon's pending balance.",
    );
  }

  let remaining = amount;
  const allocations = [];
  for (const settlement of open) {
    if (remaining <= 0) break;
    const allocatedAmount = Math.min(settlement.remainingAmount, remaining);
    allocations.push({
      bookingId: String(settlement.bookingId),
      allocatedAmount: Math.round(allocatedAmount * 100) / 100,
      paidAmountAfter: Math.round(
        (money(settlement.paidAmount ?? 0, "Paid amount") + allocatedAmount) * 100,
      ) / 100,
      outstandingAmountAfter: Math.round(
        (settlement.remainingAmount - allocatedAmount) * 100,
      ) / 100,
    });
    remaining = Math.round((remaining - allocatedAmount) * 100) / 100;
  }
  if (remaining !== 0) {
    throw new SalonFinanceValidationError(
      "The pending settlement balance changed. Refresh and try again.",
    );
  }
  return {amountInr: amount, outstandingAmount: outstanding, allocations};
}

module.exports = {
  SalonFinanceValidationError,
  allocateSalonSettlementPayment,
  positiveMoney,
  remainingSettlementAmount,
  salonCreditLimit,
  settlementPaymentMethod,
  settlementPaymentReference,
};
