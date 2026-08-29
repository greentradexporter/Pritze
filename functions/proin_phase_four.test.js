const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

function source(relativePath) {
  return fs.readFileSync(path.join(__dirname, "..", relativePath), "utf8");
}

test("Phase 4 Proin corrections and settlement records are privileged", () => {
  const indexSource = source("functions/index.js");
  const backendSource = source("functions/proin_backend.js");
  const rulesSource = source("firestore.rules");

  for (const callable of [
    "revokeProinAsAdmin",
    "markProinReimbursementSettledAsAdmin",
  ]) {
    assert.match(indexSource, new RegExp(`exports\\.${callable} = onCall`));
  }
  assert.match(indexSource, /requirePlatformAdministrator\(request\)/);
  assert.match(indexSource, /requiredAdminReason\(request\.data\?\.reason\)/);
  assert.match(backendSource, /Only active, unexpired and unused Proin/);
  assert.match(backendSource, /proinIdempotencyKeys/);
  assert.match(backendSource, /proinSettlementPaymentReferences/);
  assert.match(backendSource, /paymentReferenceHash/);
  assert.match(backendSource, /proin\.available_lot_revoked/);
  assert.match(backendSource, /proin\.reimbursement_settled/);
  assert.match(
    rulesSource,
    /match \/proinSettlementPaymentReferences\/\{referenceHash\}/,
  );
});

test("Phase 4 gives customers a server-filtered Proin statement", () => {
  const indexSource = source("functions/index.js");
  const backendSource = source("functions/proin_backend.js");
  const stateSource = source("lib/state/app_state.dart");
  const profileSource = source(
    "lib/screens/customer/customer_profile_screen.dart",
  );

  assert.match(indexSource, /exports\.getCustomerProinActivity = onCall/);
  assert.match(backendSource, /where\("walletId", "==", walletId\)/);
  assert.match(backendSource, /orderBy\("createdAt", "desc"\)/);
  assert.match(stateSource, /refreshCustomerProinActivity/);
  assert.match(profileSource, /customer-proin-view-activity/);
  assert.match(profileSource, /customer-proin-activity-sheet/);
  assert.match(profileSource, /Unused promotional Proin removed by Pritze/);
  assert.match(profileSource, /Upcoming expiries/);
  assert.match(profileSource, /Valid until/);
});

test("salon owners can view only their promotional credit wallet and expiry", () => {
  const indexSource = source("functions/index.js");
  const backendSource = source("functions/proin_backend.js");
  const stateSource = source("lib/state/app_state.dart");
  const dashboardSource = source(
    "lib/screens/salon/salon_dashboard_screen.dart",
  );

  assert.match(indexSource, /exports\.getSalonProinWallet = onCall/);
  assert.match(indexSource, /exports\.claimSalonProinCoupon = onCall/);
  assert.match(indexSource, /salonSnapshot\.data\(\)\?\.ownerUid/);
  assert.match(backendSource, /salonWalletData/);
  assert.match(backendSource, /salon_promotion_credits/);
  assert.match(stateSource, /refreshSalonProinWallet/);
  assert.match(stateSource, /claimSalonProinCoupon/);
  assert.match(dashboardSource, /Promotional credits/);
  assert.match(dashboardSource, /salon-proin-coupon-field/);
  assert.match(dashboardSource, /Upcoming expiries/);
  assert.match(dashboardSource, /Reward reimbursement/);
});

test("Phase 4 reconciliation includes settled reimbursement evidence", () => {
  const backendSource = source("functions/proin_backend.js");

  assert.match(backendSource, /settledFromReimbursements/);
  assert.match(backendSource, /invalidSettlementReferences/);
  assert.match(backendSource, /settlementReferenceScanTruncated/);
  assert.match(
    backendSource,
    /settledFromReimbursements === finance\.settledExpenseInr/,
  );
});
