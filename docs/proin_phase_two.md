# Proin Phase 2 earning programs

Phase 2 connects the protected Proin ledger to qualified referrals and coupon
claims. It also adds one-time reward and expiry notifications. It does not add
Proin redemption to bookings, a customer wallet UI, payment collection, cash
withdrawal, transfers, salon settlement, or website controls.

The Phase 1 financial and regulatory restrictions still apply. Proin remains a
free, non-purchasable, non-transferable promotional reward with an internal
reimbursement rate of one Proin to one Indian rupee.

## Referral qualification

Referral codes remain unique, role-specific, and usable only during first
registration. A customer invite code can register a customer. A salon invite
code can register an owner. A user cannot use their own code.

Creating a referral does not award Proin. The server waits for the relevant
qualification event:

- a referred customer must complete their first booking;
- a referred salon must be explicitly approved for Proin referral rewards by a
  platform administrator and must complete its first booking;
- a suspended salon cannot qualify;
- the qualification event must occur inside the selected program's start and
  end dates.

An active referral program can reward either the inviter or the referred
account. Use separate programs when both parties should earn. Wallet roles are
strictly separated:

| Rewarded role | Required wallet |
| --- | --- |
| Customer | `customer_rewards` |
| Salon owner | `salon_promotion_credits` for an approved salon |

The valid program combinations are:

| Referral target | Inviter | Recipient | Source type | Wallet |
| --- | --- | --- | --- | --- |
| Customer | Customer | Inviter | `referral_customer` | `customer_rewards` |
| Customer | Owner | Inviter | `referral_customer` | `salon_promotion_credits` |
| Customer | Customer/owner | Referred | `referral_customer` | `customer_rewards` |
| Owner | Customer | Inviter | `referral_salon` | `customer_rewards` |
| Owner | Owner | Inviter | `referral_salon` | `salon_promotion_credits` |
| Owner | Customer/owner | Referred | `referral_salon` | `salon_promotion_credits` |

Every award uses a deterministic idempotency key containing the referral,
program, and recipient. Trigger retries and the scheduled 30-minute retry scan
therefore cannot create a second reward lot.

The administrator field `proinReferralApproved` is intentionally separate from
ordinary salon listing or onboarding approval. This prevents a listed salon
from automatically creating a financial reward obligation.

### Referral program example

This example rewards a customer who invited another customer. A second program
with `rewardRecipient: referred` is required to reward the new customer too.

```json
{
  "programId": "customer_referrer_aug_2026",
  "name": "Customer referral inviter reward",
  "sourceType": "referral_customer",
  "walletType": "customer_rewards",
  "qualificationEvent": "first_completed_booking",
  "rewardRecipient": "inviter",
  "referralInviterRole": "customer",
  "active": false,
  "rewardAmountProin": 100,
  "rewardValidityDays": 60,
  "totalBudgetProin": 10000,
  "maximumTotalGrants": 100,
  "maximumGrantsPerAccount": 10,
  "minimumBookingAmount": 0,
  "maximumProinPerBooking": 100,
  "maximumRedemptionPercent": 25,
  "stackableWithDiscount": false,
  "startsAtMillis": 1785542400000,
  "endsAtMillis": 1798761599000,
  "eligibleSalonIds": [],
  "eligibleServiceIds": [],
  "termsVersion": "referral-2026-v1",
  "reason": "Create inactive referral pilot"
}
```

## Coupons

Coupons and Proin programs are separate records:

- the coupon controls its code, audience, claim dates, and total claim cap;
- the linked program controls reward amount, reward-lot validity, program
  budget, per-account grant cap, and future redemption restrictions;
- the coupon's claim expiry does not change the expiry date of Proin already
  earned;
- a customer can claim a particular coupon only once.

Coupon codes contain 6-20 letters and numbers. Codes are normalized to
uppercase. Firestore stores a SHA-256 code hash and a masked label, never the
plain code. Operations must retain the plain code in the approved campaign
record used to communicate it to customers.

Create the linked `coupon` program first, then use
`upsertProinCouponAsAdmin`:

```json
{
  "code": "WELCOME50",
  "programId": "welcome_coupon_aug_2026",
  "active": false,
  "claimStartsAtMillis": 1785542400000,
  "claimEndsAtMillis": 1788134399000,
  "maximumClaimsTotal": 500,
  "eligibleCustomerUids": [],
  "termsVersion": "coupon-2026-v1",
  "reason": "Create inactive welcome coupon"
}
```

`eligibleCustomerUids: []` means every registered customer is eligible.
Supplying UIDs creates a limited audience. An authenticated customer uses
`claimProinCoupon` with `couponCode`. App Check is enforced and each user is
limited to ten attempts per hour.

Claims use a transactionally reserved counter followed by an idempotent ledger
grant. Failed grants release the reservation. Repeated or concurrent calls for
the same customer and coupon return the original lot instead of issuing again.

## Expiry communication

Earned Proin remains in separately expiring lots. A daily server job identifies
available lots approaching expiry and sends reminders at 30, 7, and 1 day.
Each reminder tier is claimed transactionally before sending, so scheduler
retries do not intentionally duplicate it. The normal 15-minute expiry job
removes expired value from the wallet and financial liability.

## Protected data and reconciliation

The following Phase 2 collections are server-only under Firestore rules:

- `proinCoupons`
- `proinCouponVersions`
- `proinCouponUsage`
- `proinCouponClaims`
- `proinCouponAttempts`

Coupon creation and updates are versioned and audited. Reconciliation now also
compares pending and awarded coupon-claim records with the coupon usage
counters. Counter drift, invalid claim status, scan truncation, wallet drift,
program drift, or finance drift produces `review_required` and a critical
operational alert. Reconciliation reports the mismatch; it never silently
repairs financial data.

## Safe activation order

1. Complete legal, tax, salon-contract, customer-terms, and privacy approval.
2. Deploy the Firestore rules and indexes.
3. Deploy the Phase 1 and Phase 2 functions.
4. Fund a small, explicitly approved Proin budget.
5. Create inactive referral and coupon programs.
6. Create inactive coupons and retain the plain codes outside Firestore.
7. Run reconciliation and require a `balanced` result.
8. Approve only the pilot salons intended to qualify for salon referrals.
9. Activate one narrowly capped program and coupon.
10. Test a new award, repeat the exact event, and confirm one lot and one grant
    ledger entry.
11. Run reconciliation again before expanding the audience or budget.

No production deployment or data activation is part of the repository change.
