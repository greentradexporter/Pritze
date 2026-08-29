# Proin Phase 3 — booking redemption

Phase 3 connects the promotional Proin ledger to customer bookings. It does not
add purchasing, transfers, cash withdrawal, external settlement execution, or
website controls.

## Customer flow

- The customer profile shows available and reserved Proin, the next expiry, and
  a coupon-entry action.
- Checkout requests an authoritative quote for the selected salon, services and
  locked discount quote.
- The customer may apply the maximum eligible Proin for that booking. One Proin
  reduces the counter price by one rupee.
- The server recalculates the service price, discount and Proin eligibility when
  the booking is created. Client-supplied prices are never trusted.
- Proin is promotional only. It cannot be purchased, transferred, withdrawn or
  exchanged for cash.

## Eligibility and expiry

Every newly granted reward lot contains an immutable redemption-policy snapshot:

- minimum booking amount;
- maximum Proin per booking;
- maximum redemption percentage;
- whether it can be combined with a discount;
- eligible salons and services; and
- the applicable terms version.

Eligible lots are allocated by earliest expiry first. Expired lots and rewards
that do not match every selected service are excluded.

## Booking lifecycle

Booking creation and Proin reservation occur in the same Firestore transaction.
The transaction moves value from `availableProin` to `reservedProin` in the lot,
wallet, program usage and finance records, then creates:

- `proinReservations/{bookingId}`; and
- `proinLedger/reserve_{bookingId}`.

Terminal outcomes are also atomic:

- cancellation, rejection, or the 150-second instant-booking timeout releases
  the reservation;
- completion redeems it; and
- accepting or starting a booking does not redeem it.

If a reserved lot expires before a cancelled booking releases it, the amount is
expired rather than restored. On completion, the salon receives a server-managed
payable reimbursement record and salon-wallet credit equal to redeemed Proin.
No external payment is sent in this phase.

## Protected collections

All Proin financial state remains server-only under Firestore rules, including
wallets, lots, ledger entries, reservations, quote rate limits, finance totals,
coupon claims, and salon reimbursement records. Mobile clients use App Check and
authenticated callable functions for wallet, quote, claim and booking actions.

## Reconciliation

The scheduled reconciliation checks:

- wallet totals against reward lots;
- program and coupon usage against their source records;
- active reservations against reserved finance liability;
- payable salon reimbursements against redeemed payable liability; and
- the overall budget/liability double-entry invariant.

Any mismatch creates or updates the existing critical Proin operational alert.

## Operations before release

1. Deploy Firestore indexes and rules.
2. Deploy functions.
3. Create or verify active Proin programs and approved budget.
4. Run the Proin reconciliation and require `balanced` status.
5. Test reserve, cancel, timeout, reject and complete against the Firebase
   emulator before testing with production accounts.
