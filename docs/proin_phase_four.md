# Proin Phase 4: operational controls

Phase 4 adds the operational layer needed to correct unused promotional
rewards, record externally completed salon reimbursements, and give customers
a readable account statement. It does not add a payment rail, customer-funded
wallet, transfer, withdrawal, or cash-out capability.

## Customer activity statement

`getCustomerProinActivity` is an authenticated, App Check-protected callable.
It derives the customer's wallet ID on the server and returns only that wallet's
immutable ledger entries in newest-first order. The app labels grants,
reservations, releases, redemptions, expiries, and administrative adjustments
in plain language.

Clients still have no direct read or write access to the Proin ledger. This
prevents a caller from requesting another customer's wallet statement.

## Revoking unused Proin

`revokeProinAsAdmin` requires a platform administrator, an audit reason, a
unique request ID, and a target lot. A revocation may affect only Proin that is:

- still available;
- not expired;
- not reserved for a booking; and
- not already redeemed, expired, or revoked.

The transaction updates the lot, customer wallet, program and account usage,
and platform finance totals together. It creates an immutable `revoke` ledger
entry, idempotency record, and administrator audit record. Retrying the same
request ID returns the original result instead of subtracting twice.

Revoking Proin releases the matching outstanding liability back to the
unallocated promotional budget. It never takes money from a customer.

## Recording an offline salon reimbursement

`markProinReimbursementSettledAsAdmin` records that an already-payable Proin
reimbursement was paid outside the application. It does not initiate or route a
payment. The administrator must supply the booking ID, external payment
reference, payment date, and audit reason.

The transaction:

1. verifies that the booking reimbursement is still payable and balanced;
2. prevents reuse of an external payment reference;
3. changes the reimbursement from `payable` to `settled`;
4. moves the platform total from `redeemedPayableInr` to
   `settledExpenseInr`;
5. updates the salon's payable and paid reporting totals; and
6. creates immutable settlement evidence, a ledger record, and an audit log.

A retry with the same booking and reference is idempotent. A conflicting
reference fails clearly and does not alter financial state.

## Reconciliation

Reconciliation now verifies both payable and settled reimbursements against
the platform finance document. Every settled reimbursement must have exactly
matching external-reference evidence, and every reference must point back to a
settled reimbursement with the same salon and amount. Missing, orphaned, or
mismatched evidence moves the report to `review_required` and activates the
existing operational alert.

## Security boundary

Firestore rules deny all client reads and writes to
`proinSettlementPaymentReferences`, as they already do for wallets, lots,
ledger entries, finance totals, reimbursements, and idempotency records.
Administrator access remains callable-only and server-validated.

## Control Center and app visibility

The authenticated Control Center now manages versioned reward programs,
coupon claim windows, reward validity, approved budget, manual support grants,
unused-lot revocations, reimbursements, and reconciliation through privileged
callables. Customers can see exact upcoming reward expiries; salon owners can
see their separate promotional-credit wallet and exact expiries.

## Deferred work

Phase 4 intentionally does not include a bank or UPI integration, automatic
payout execution, customer purchase of Proin, peer-to-peer transfer,
withdrawal, or conversion to cash.
