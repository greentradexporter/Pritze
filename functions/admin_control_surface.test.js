const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const source = fs.readFileSync(path.join(__dirname, "index.js"), "utf8");
const rules = fs.readFileSync(path.join(__dirname, "..", "firestore.rules"), "utf8");
const storageRules = fs.readFileSync(
  path.join(__dirname, "..", "storage.rules"),
  "utf8",
);

test("Phase 2 administrator controls stay behind privileged callable functions", () => {
  for (const callable of [
    "updateBookingStatusAsAdmin",
    "rescheduleBookingAsAdmin",
    "updateSalonControlAsAdmin",
    "reviewSalonOnboardingAsAdmin",
    "updateCustomerProfileAsAdmin",
    "updateCustomerControlAsAdmin",
    "updateSalonProfileAsAdmin",
    "updateSalonServiceAsAdmin",
    "updateBarberProfileAsAdmin",
    "updateBarberStatusAsAdmin",
    "resolveJoinRequestAsAdmin",
    "addAdminNote",
    "updateAdminAutomationRule",
    "acknowledgeAdminOperationalAlert",
    "runAdminIntelligenceScan",
    "getDiscountAdministrationDataAsAdmin",
    "upsertDiscountCampaignAsAdmin",
    "setDiscountVaultBudgetAsAdmin",
    "setSalonPromotionCreditLimitAsAdmin",
    "recordSalonSettlementPaymentAsAdmin",
    "updateReferralCodeAsAdmin",
  ]) {
    assert.match(source, new RegExp(`exports\\.${callable} = onCall`));
  }
  assert.match(source, /requirePlatformAdministrator\(request\)/);
  assert.match(source, /requiredAdminReason\(request\.data\?\.reason\)/);
});

test("administrator writes create immutable audit records", () => {
  assert.match(source, /collection\("adminAuditLogs"\)\.doc\(\)/);
  assert.match(source, /transaction\.create\(auditRef, adminAuditRecord/);
  assert.match(source, /action: "booking\.status_changed"/);
  assert.match(source, /action: "booking\.rescheduled"/);
  assert.match(source, /action: "customer\.profile_updated"/);
  assert.match(source, /"customer\.account_suspended"/);
  assert.match(source, /action: "salon\.profile_updated"/);
  assert.match(source, /action: "salon\.service_updated"/);
  assert.match(source, /action: "barber\.profile_updated"/);
  assert.match(source, /action: "note\.created"/);
  assert.match(source, /action: "automation\.rule_updated"/);
  assert.match(source, /action: "intelligence\.alert_acknowledged"/);
  assert.match(source, /exports\.generateAdminOperationalAlerts = onSchedule/);
  assert.match(source, /collection\("discountCampaignVersions"\)/);
  assert.match(source, /action: "discount\.vault_budget_changed"/);
  assert.match(source, /action: "salon\.promotion_credit_limit_changed"/);
  assert.match(source, /action: "salon\.settlement_payment_recorded"/);
  assert.match(source, /paymentMethod/);
  assert.match(source, /salonDiscountBurnMultiplier/);
  assert.match(source, /salon\.onboarding_\$\{decision\}/);
  assert.match(source, /approvalStatus: decision/);
  assert.match(source, /"referral\.code_replaced"/);
});

test("new salons remain pending until an administrator reviews the listing", () => {
  assert.match(source, /function salonApprovalStatus/);
  assert.match(source, /function isSalonApproved/);
  assert.match(source, /!isSalonApproved\(salon\)/);
  assert.match(
      rules,
      /request\.resource\.data\.get\('approvalStatus', ''\) == 'pending'/,
  );
  // Missing properties raise in rules, so the approval gate must read the
  // field through get(): half the live salons predate it.
  assert.doesNotMatch(rules, /resource\.data\.approvalStatus\b/);
  assert.match(rules, /keepsSalonApprovalState\(\)/);
});

test("private salon payment details are exposed only through admin data", () => {
  assert.match(source, /collection\("salonPaymentProfiles"\)/);
  assert.match(source, /paymentUpiId: adminString\(paymentProfile\.upiId\)/);
  assert.match(
    source,
    /paymentQrCodeUrl: adminString\(paymentProfile\.qrCodeUrl\)/,
  );
  assert.match(rules, /match \/salonPaymentProfiles\/\{salonId\}/);
  assert.match(rules, /allow read: if ownsSalon\(salonId\)/);
  assert.match(
    storageRules,
    /match \/salons\/\{salonId\}\/payments\/\{paymentFile\}/,
  );
  assert.match(storageRules, /allow read: if ownsSalon\(salonId\)/);
  assert.match(
    storageRules,
    /allow create, update: if \(ownsSalon\(salonId\) \|\| ownerSalonId\(salonId\)\)/,
  );
});

test("team password sign-in is server-verified, rate-limited and audited", () => {
  assert.match(source, /exports\.signInAdminWithPassword = onCall/);
  assert.match(source, /collection\("platformAdminCredentials"\)/);
  assert.match(source, /verifyAdminPassword/);
  assert.match(source, /enforceAdminPasswordAttemptLimit/);
  assert.match(source, /action: "administrator\.signed_in"/);
  assert.match(source, /collection\("adminAuthenticationEvents"\)/);
  assert.match(source, /createCustomToken\(authUid/);
  for (const collection of [
    "platformAdmins",
    "platformAdminCredentials",
    "adminPasswordAttemptBuckets",
    "adminAuthenticationEvents",
  ]) {
    assert.match(
      rules,
      new RegExp(`match \\/${collection}\\/\\{[^}]+\\} \\{\\s*` +
        "allow read, write: if false;"),
    );
  }
});
