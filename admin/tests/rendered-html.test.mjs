import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the private Pritze team access page", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>Pritze Control Center<\/title>/i);
  assert.match(html, /One trusted place to run Pritze/);
  assert.match(html, /AUTHORIZED TEAM ACCESS/);
  assert.match(html, /User ID/);
  assert.match(html, /Password/);
  assert.match(html, /No email, OTP or ChatGPT account is required/);
  assert.doesNotMatch(html, /Good morning, Admin|Live bookings/);
  assert.doesNotMatch(html, /Connect Firebase|representative preview data/);
  assert.doesNotMatch(html, /The Groom Room|Aarav Patil|BK-1042/);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton|Your site is taking shape/i);
});

test("website authentication uses only the server-side password callable", () => {
  const source = fs.readFileSync(
    path.join(testDirectory, "..", "app", "AdminDashboard.tsx"),
    "utf8",
  );

  assert.match(source, /signInAdminWithPassword/);
  assert.match(source, /signInWithCustomToken/);
  assert.match(source, /There is no public registration/);
  assert.doesNotMatch(source, /sendAdminEmailOtp|verifyAdminEmailOtp/);
  assert.doesNotMatch(source, /User 1[^\n]*(password|Password)\s*[:=]/);
});

test("Proin operations stay behind privileged Firebase callables", () => {
  const source = fs.readFileSync(
    path.join(testDirectory, "..", "app", "AdminDashboard.tsx"),
    "utf8",
  );

  assert.match(source, /getProinPhaseOneDataAsAdmin/);
  assert.match(source, /revokeProinAsAdmin/);
  assert.match(source, /markProinReimbursementSettledAsAdmin/);
  assert.match(source, /runProinReconciliationAsAdmin/);
  assert.match(source, /upsertProinProgramAsAdmin/);
  assert.match(source, /upsertProinCouponAsAdmin/);
  assert.match(source, /setProinFinanceBudgetAsAdmin/);
  assert.match(source, /grantProinAsAdmin/);
  assert.match(source, /updateReferralCodeAsAdmin/);
  assert.match(source, /Manage the full Proin lifecycle/);
  assert.match(source, /Customer → customer inviter reward/);
  assert.match(source, /Salon → customer salon reward/);
  assert.match(source, /Salon → salon receiver reward/);
  assert.match(source, /Max rewards \/ invites per account/);
  assert.match(source, /Create WELCOME50 coupon/);
  assert.match(source, /Create SALON100 coupon/);
  assert.match(source, /The coupon code users type/);
  assert.match(source, /Referral codes/);
  assert.match(source, /View and edit the actual customer and salon referral codes/);
  assert.match(source, /Duplicate codes are rejected/);
  assert.match(source, /Customer rewards for customer Proin/);
  assert.match(source, /it does not initiate a bank or UPI transfer/i);
  assert.doesNotMatch(source, /from "firebase\/firestore"/);
});

test("discount operations stay behind privileged Firebase callables", () => {
  const source = fs.readFileSync(
    path.join(testDirectory, "..", "app", "AdminDashboard.tsx"),
    "utf8",
  );

  assert.match(source, /getDiscountAdministrationDataAsAdmin/);
  assert.match(source, /upsertDiscountCampaignAsAdmin/);
  assert.match(source, /setDiscountVaultBudgetAsAdmin/);
  assert.match(source, /Salon discount burn multiplier/);
  assert.match(source, /Change finance controls/);
  assert.match(source, /Manage discount eligibility and burn/);
  assert.match(source, /Coupon \/ voucher campaign/);
  assert.match(source, /Coupon visibility in app/);
  assert.match(source, /Visible checkout offer/);
  assert.match(source, /Hidden typed-code coupon/);
  assert.match(source, /Fixed rupee amount/);
  assert.match(source, /New discount \/ voucher/);
  assert.match(source, /Create automatic draft/);
  assert.match(source, /Create hidden coupon draft/);
  assert.match(source, /Create visible offer draft/);
  assert.match(source, /adminActionFieldHelp/);
  assert.match(source, /field-help/);
  assert.match(source, /one tappable row below the final price before booking/);
  assert.match(source, /Eligible salons \(leave all unchecked for every salon\)/);
  assert.match(source, /Copy ID/);
  assert.match(source, /third booking/);
  assert.match(source, /New journey campaign/);
  assert.match(source, /Booking reward milestones/);
  assert.match(source, /Create journey campaign/);
  assert.match(source, /Customers see only the ordinary discount or Proin result/);
  assert.match(source, /Maximum customer discount/);
  assert.match(source, /Salon compensation \(% of customer discount\)/);
  assert.match(source, /Compensation by customer booking number/);
  assert.match(source, /Campaigns enabled at each salon/);
  assert.match(source, /Manage campaigns/);
  assert.match(source, /New salon approval requests/);
  assert.match(source, /reviewSalonOnboardingAsAdmin/);
  assert.match(source, /These salons are saved by their owners but are hidden from customers until you approve them/);
  assert.doesNotMatch(source, /from "firebase\/firestore"/);
});

test("customer and salon records have audited full-profile controls", () => {
  const source = fs.readFileSync(
    path.join(testDirectory, "..", "app", "AdminDashboard.tsx"),
    "utf8",
  );

  assert.match(source, /updateCustomerProfileAsAdmin/);
  assert.match(source, /updateCustomerControlAsAdmin/);
  assert.match(source, /updateSalonProfileAsAdmin/);
  assert.match(source, /updateSalonServiceAsAdmin/);
  assert.match(source, /updateBarberProfileAsAdmin/);
  assert.match(source, /Save customer/);
  assert.match(source, /Save salon/);
  assert.match(source, /Manage all \{salon\.services\.length\} services/);
  assert.match(source, /Sign-in provider identities remain protected/);
  assert.match(source, /same number cannot belong to a customer and salon owner/);
  assert.match(source, /Private payout details/);
  assert.match(source, /View payment QR/);
  assert.match(source, /Salon finance/);
  assert.match(source, /setSalonPromotionCreditLimitAsAdmin/);
  assert.match(source, /recordSalonSettlementPaymentAsAdmin/);
  assert.match(source, /Record external payment/);
  assert.match(source, /Settle full amount/);
  assert.match(source, /Add promotional credit/);
  assert.match(source, /Payment method/);
  assert.match(source, /Bank transfer/);
  assert.match(source, /cash receipt or ledger reference/);
  assert.match(source, /Add promotional credit when needed/);
});

test("the authenticated Control Center includes a practical operating guide", () => {
  const source = fs.readFileSync(
    path.join(testDirectory, "..", "app", "AdminDashboard.tsx"),
    "utf8",
  );
  const styles = fs.readFileSync(
    path.join(testDirectory, "..", "app", "globals.css"),
    "utf8",
  );

  assert.match(source, /How to use/);
  assert.match(source, /How to set a discount/);
  assert.match(source, /How to set Proin, referrals and coupons/);
  assert.match(source, /Create paired referral rewards/);
  assert.match(source, /View or edit referral codes/);
  assert.match(source, /old referral history stays attached to the old code/);
  assert.match(source, /both people earn/);
  assert.match(source, /FIRST SETUP ORDER/);
  assert.match(source, /Discount, coupon and Proin testing in the safest sequence/);
  assert.match(source, /Save new campaigns and programs inactive first/);
  assert.match(source, /Budget exhausted/);
  assert.match(source, /Funding unavailable/);
  assert.match(source, /Customer, salon, service and use limits are checked at checkout/);
  assert.match(styles, /\.proin-state\.exhausted/);
  assert.match(source, /Nothing from the starter buttons reaches customers until/);
  assert.match(source, /verbally shared and work only when typed/);
  assert.match(source, /Visible checkout offers appear as a small tappable row/);
  assert.match(source, /booking 1 discount only, booking 2 discount \+ Proin/);
  assert.match(source, /Pritze owes salon/);
  assert.match(source, /view === "guide" && <GuideView/);
  assert.match(source, /className="sidebar-guide"/);
  assert.match(source, /navItems\.filter\(\(item\) => item\.id !== "guide"\)/);
  assert.match(styles, /\.sidebar nav \{[^}]*overflow-y:auto/s);
  assert.match(styles, /\.starter-panel/);
  assert.match(styles, /\.guide-setup-flow/);
  assert.match(styles, /\.field-help:hover::after/);
});

// The backend pins every callable to asia-south1 via setGlobalOptions. The
// default us-central1 copies are pre-migration leftovers running stale code,
// so a dashboard pointed there silently talks to the wrong backend.
test("the Control Center calls functions in the backend's region", () => {
  const source = fs.readFileSync(
    path.join(testDirectory, "..", "app", "AdminDashboard.tsx"),
    "utf8",
  );
  assert.match(source, /getFunctions\(app, "asia-south1"\)/);
  assert.doesNotMatch(source, /getFunctions\(app, "us-central1"\)/);
});
