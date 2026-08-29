# Discount operations

Discounts are controlled through the authenticated Pritze Control Center. The
mobile apps and website cannot read or write campaign budgets, the Pritze
vault, usage ledgers, or settlement records directly. The website calls
privileged Firebase functions; every change requires a reason, creates an
administrator audit entry, and every campaign save creates an immutable
version record.

## Fund the Pritze discount vault

Use **Discount control → Change vault budget** and enter the approved integer
rupee amount. The protected `platformFinance/discountVault` record maintains:

```text
approvedAmount: 100000
availableAmount: 100000
reservedAmount: 0
spentAmount: 0
budgetVersion: 1
```

`availableAmount` is reduced when a booking receives an offer. A cancelled,
rejected, or timed-out booking returns the reservation. Completion moves it to
`spentAmount` and creates a salon payable.

## Create a campaign

Use **Discount control → New campaign**. Save the campaign inactive first,
review its audience, dates and burn limits, then activate it. No discount is
granted unless the campaign is active and both the campaign and vault have
enough budget. Do not create or edit campaign documents manually.

Required fields:

```text
name: "First visit 10%"
active: true
discountPercent: 10
payoutMultiplier: 2
totalPayoutBudget: 50000
maximumUsesPerCustomer: 1
```

Optional controls:

```text
priority: 100
maximumDiscountAmount: 250
minimumServiceAmount: 100
perSalonPayoutBudget: 5000
perCustomerPayoutBudget: 500
startsAt: Firestore timestamp
endsAt: Firestore timestamp
salonIds: ["salon-id"]
excludedSalonIds: ["salon-id"]
customerUids: ["customer-uid"]
serviceIds: ["service-id"]
eligibleBookingNumbers: [1, 2]
minimumBookingNumber: 1
maximumBookingNumber: 2
newToSalonOnly: true
returningToSalonOnly: false
```

When multiple campaigns qualify, the backend gives the customer the largest
discount; campaign priority breaks a tie.

## Accounting example

For a ₹100 service with 10% off and a payout multiplier of 2:

- Customer pays ₹90 at the salon counter.
- Pritze discount is ₹10.
- Pritze credits ₹20 to the salon payable wallet.
- Salon total earning is ₹110.
- The protected Pritze vault burn is ₹20.

## Burn and settlement records

The Control Center shows the platform vault, campaign burn, per-salon burn and
per-customer burn. It receives these values from
`getDiscountAdministrationDataAsAdmin`; the browser never receives direct
Firestore financial permissions.

- `discountCampaignUsage/{campaignId}`: platform campaign burn.
- `discountSalonUsage/{campaignId}__{salonId}`: per-salon burn.
- `discountCustomerUsage/{campaignId}__{customerUid}`: per-customer burn.
- `platformFinance/discountVault`: available, reserved, and spent totals.
- `salonWallets/{salonId}`: payable Pritze balance and lifetime earnings.
- `salonSettlements/{bookingId}`: immutable booking-level payable record.

A settlement remains `payable` until the external/offline salon payout process
marks it paid. The customer counter payment is never represented as an in-app
payment.

## Customer and salon visibility

- Customers see the original amount, discount, final counter amount, offer
  expiry, and the separate ten-minute locked-price expiry.
- Salon owners see discount support and Proin reimbursement separately, plus
  their combined Pritze contribution and total salon earning.
- Customer reward Proin and salon promotional Proin show the next expiry and
  individual upcoming reward lots. Salon promotional Proin is not cash or
  booking revenue.
