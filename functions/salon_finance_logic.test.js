const assert = require("node:assert/strict");
const test = require("node:test");

const {
  SalonFinanceValidationError,
  allocateSalonSettlementPayment,
  remainingSettlementAmount,
  salonCreditLimit,
  settlementPaymentReference,
} = require("./salon_finance_logic");

test("allocates a partial salon payment to the oldest unpaid bookings first", () => {
  const result = allocateSalonSettlementPayment([
    {bookingId: "newer", pritzePayoutAmount: 100, paidAmount: 0, createdAtMillis: 20},
    {bookingId: "older", pritzePayoutAmount: 60, paidAmount: 10, createdAtMillis: 10},
  ], 80);
  assert.equal(result.outstandingAmount, 150);
  assert.deepEqual(result.allocations, [
    {bookingId: "older", allocatedAmount: 50, paidAmountAfter: 60, outstandingAmountAfter: 0},
    {bookingId: "newer", allocatedAmount: 30, paidAmountAfter: 30, outstandingAmountAfter: 70},
  ]);
});

test("refuses to settle more than the remaining salon balance", () => {
  assert.throws(
    () => allocateSalonSettlementPayment([
      {bookingId: "booking", pritzePayoutAmount: 50, paidAmount: 10},
    ], 41),
    SalonFinanceValidationError,
  );
});

test("preserves the remaining amount and only accepts whole Proin credit limits", () => {
  assert.equal(remainingSettlementAmount({pritzePayoutAmount: 80, paidAmount: 23.25}), 56.75);
  assert.equal(salonCreditLimit(2000), 2000);
  assert.throws(() => salonCreditLimit(2.5), SalonFinanceValidationError);
});

test("requires auditable references for bank, UPI and cash settlements", () => {
  assert.deepEqual(
    settlementPaymentReference("BANK-1001", "bank_transfer"),
    {paymentMethod: "bank_transfer", paymentReference: "BANK-1001"},
  );
  assert.deepEqual(
    settlementPaymentReference("UPI-1001", "upi"),
    {paymentMethod: "upi", paymentReference: "UPI-1001"},
  );
  assert.deepEqual(
    settlementPaymentReference("CASH-1001", "cash"),
    {paymentMethod: "cash", paymentReference: "CASH-1001"},
  );
  assert.throws(
    () => settlementPaymentReference("", "cash"),
    /cash receipt or ledger reference/,
  );
  assert.throws(
    () => settlementPaymentReference("UPI-1001", "card"),
    /Choose Bank transfer, UPI, or Cash/,
  );
});
