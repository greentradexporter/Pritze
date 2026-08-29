# Proin Phase 1 financial foundation

Phase 1 establishes the protected accounting foundation for Pritze promotional
reward points. It does not expose a customer wallet, award referral or coupon
rewards, apply Proin to bookings, change the administration website, or settle
money with salons.

Proin is deliberately represented as a free promotional reward:

- one Proin has an internal reimbursement rate of one Indian rupee;
- users cannot purchase, reload, transfer, withdraw, or cash out Proin;
- salons never receive or accept Proin;
- future booking redemption will create an INR promotional reimbursement only
  after the service is completed;
- customer rewards and salon promotion credits are separate wallet types.

Do not enable production reward issuance until the payment-regulatory
classification, salon contract, GST invoice treatment, customer terms, and
privacy notice have been approved.

## Protected collections

All collections below are denied to Firestore mobile and browser clients. A
trusted callable or scheduled Cloud Function is required.

### `proinPrograms/{programId}`

Current administrator-controlled program configuration. Every mutation creates
an immutable snapshot in `proinProgramVersions` and an `adminAuditLogs` record.

The server always records these restrictions:

```text
regulatoryMode: promotional_reward_only
proinToInrRate: 1
customerFunded: false
purchasable: false
transferable: false
cashWithdrawable: false
```

### `proinProgramVersions/{programId}__v{version}`

Immutable historical program configurations. A program with issued rewards
cannot change wallet type or reduce its budget or grant limit below amounts
already used.

### `proinWallets/{walletId}`

Materialized account summary. The document ID is a hash of wallet type and
account ID. It is not the accounting source of truth.

```text
walletType: customer_rewards | salon_promotion_credits
accountId
availableProin
reservedProin
lifetimeGrantedProin
lifetimeRedeemedProin
lifetimeExpiredProin
lifetimeRevokedProin
nextExpiryAt
```

### `proinLots/{lotId}`

Each grant is a separately expiring lot.

```text
walletId
walletType
accountId
programId
sourceType
sourceId
originalProin
availableProin
reservedProin
redeemedProin
expiredProin
revokedProin
earnedAt
expiresAt
status
idempotencyKeyHash
```

The required lot invariant is:

```text
original = available + reserved + redeemed + expired + revoked
```

### `proinLedger/{transactionId}`

Immutable grant and expiry evidence in Phase 1. Future phases add reserve,
release, redeem, revoke, and settlement entries. Existing entries must never be
edited or deleted.

### `proinReservations/{reservationId}`

Reserved for the booking integration phase. It will hold booking-level lot
allocations so cancellation, rejection, timeout, and completion can be handled
without trusting the application.

### Usage and finance

- `proinProgramUsage/{programId}` tracks program totals.
- `proinProgramAccountUsage/{programId}__{walletId}` enforces account limits.
- `proinFinance/current` tracks the approved promotional budget and liability.
- `proinIdempotencyKeys/{hash}` prevents repeated backend delivery from
  granting a reward twice.
- `proinReconciliationReports/{reportId}` records read-only reconciliation
  results.

The finance invariant is:

```text
approved budget = unallocated budget
                + outstanding liability
                + redeemed payable
                + settled expense
```

`reservedLiabilityInr` is a subset of outstanding liability and therefore is
not added again.

## Phase 1 callable functions

All callables require an authenticated Pritze platform administrator.

### `setProinFinanceBudgetAsAdmin`

Creates or changes the maximum approved promotional budget. The budget cannot
be reduced below live liability, payable reimbursement, and settled expense.

```json
{
  "approvedBudgetInr": 100000,
  "reason": "Approved pilot promotional budget"
}
```

### `upsertProinProgramAsAdmin`

Creates a versioned program. Dates are epoch milliseconds and amounts are whole
integers. Program IDs may contain only letters, numbers, underscores, and
hyphens.

```json
{
  "programId": "manual_pilot_2026",
  "name": "Manual pilot corrections",
  "sourceType": "manual",
  "walletType": "customer_rewards",
  "qualificationEvent": "manual_approval",
  "active": true,
  "rewardAmountProin": 100,
  "rewardValidityDays": 90,
  "totalBudgetProin": 10000,
  "maximumTotalGrants": 100,
  "maximumGrantsPerAccount": 1,
  "minimumBookingAmount": 0,
  "maximumProinPerBooking": 100,
  "maximumRedemptionPercent": 25,
  "stackableWithDiscount": false,
  "startsAtMillis": 1785542400000,
  "endsAtMillis": 1798761599000,
  "eligibleSalonIds": [],
  "eligibleServiceIds": [],
  "termsVersion": "proin-pilot-v1",
  "reason": "Create controlled manual pilot"
}
```

### `grantProinAsAdmin`

Provides a controlled manual grant for pilot and support verification. It only
accepts programs with `sourceType: manual` and
`qualificationEvent: manual_approval`; it cannot bypass future referral or
coupon qualification.

Every business event must supply a stable, unique idempotency key. Repeating
the same key returns the existing lot instead of granting again.

```json
{
  "programId": "manual_pilot_2026",
  "walletType": "customer_rewards",
  "accountId": "firebase-user-uid",
  "sourceId": "support-case-123",
  "idempotencyKey": "manual-pilot:support-case-123:customer-uid",
  "reason": "Approved pilot correction for support case 123"
}
```

### Inspection and reconciliation

- `getProinPhaseOneDataAsAdmin` returns protected configuration and summary
  data for a future administration interface.
- `runProinReconciliationAsAdmin` runs a read-only reconciliation and records
  the administrator request.
- `reconcileProinFinancialState` runs daily at 03:15 Asia/Kolkata.
- `expireProinLots` processes available expired lots every 15 minutes.

Reconciliation never silently repairs financial state. It creates a report and
a critical operational alert when wallet, lot, program-usage, or finance totals
do not match.

## Safe activation order

1. Obtain the required legal, contract, GST, terms, and privacy approvals.
2. Deploy Firestore rules and indexes.
3. Deploy the Phase 1 functions.
4. Set a small approved pilot budget.
5. Create one inactive manual pilot program.
6. Run reconciliation and require a `balanced` result.
7. Activate the pilot program.
8. Make one manual test grant with a unique idempotency key.
9. Repeat the same request and confirm that no second grant is created.
10. Run reconciliation again before any wider rollout.

Referral and coupon earning are described in `proin_phase_two.md`. Booking
redemption, cancellation restoration, customer wallet UI, salon reimbursement,
and the administration website remain later phases.
