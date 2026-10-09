const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const {
  inferStoredRole,
  loginRoleConflictMessage,
  normalizeDisplayName,
  normalizeLoginProvider,
  normalizeVerifiedPhone,
  phoneKey,
  resolveClaimName,
  sameRolePhoneConflictMessage,
} = require("./auth_login_logic");

test("a registered salon is always restored as an owner", () => {
  assert.equal(
    inferStoredRole({role: "customer", roles: ["customer"]}, true),
    "owner",
  );
});

test("the singular role is authoritative over legacy role arrays", () => {
  assert.equal(
    inferStoredRole(
      {role: "customer", roles: ["customer", "owner"], activeRole: "owner"},
      false,
    ),
    "customer",
  );
});

test("legacy multi-role profiles use their last active role for migration", () => {
  assert.equal(
    inferStoredRole(
      {roles: ["customer", "owner"], activeRole: "owner"},
      false,
    ),
    "owner",
  );
});

test("phone-role conflict messages clearly identify both roles", () => {
  assert.equal(
    loginRoleConflictMessage("customer", "owner", true),
    "Unable to log in as customer because this phone number is already " +
      "registered as a salon owner.",
  );
  assert.equal(
    loginRoleConflictMessage("owner", "customer", true),
    "Unable to log in as salon owner because this phone number is already " +
      "registered as a customer.",
  );
});

test("a profile phone cannot silently become another owner login", () => {
  const message = sameRolePhoneConflictMessage("owner");
  // Never auto-link: proving control of the number does not prove ownership
  // of the account that registered it. The message must instead say how to
  // make this number usable, which the previous wording did not.
  assert.match(message, /sign in with google or email/i);
  assert.match(message, /turn on phone login/i);
  assert.doesNotMatch(message, /use the original login method/i);
});

test("a customer phone conflict points at the original sign-in method", () => {
  assert.match(
    sameRolePhoneConflictMessage("customer"),
    /belongs to another customer account/i,
  );
});

test("only verified E.164 phone numbers are accepted", () => {
  assert.equal(normalizeVerifiedPhone("+919876543210"), "+919876543210");
  assert.equal(normalizeVerifiedPhone("9876543210"), "");
  assert.equal(normalizeVerifiedPhone("+0123456789"), "");
});

test("phone providers and display names are normalized", () => {
  assert.equal(normalizeLoginProvider("google", "+919876543210"), "google");
  assert.equal(normalizeLoginProvider("phone", "+919876543210"), "phone");
  assert.equal(normalizeLoginProvider("google", ""), "google");
  assert.equal(normalizeDisplayName("  Asha   Patil  "), "Asha Patil");
});

test("registered customers keep their stored name during OTP login", () => {
  assert.equal(resolveClaimName({
    requestedRole: "customer",
    requestedName: "",
    storedRole: "customer",
    storedName: "Existing Customer",
    email: "",
  }), "Existing Customer");
  assert.equal(resolveClaimName({
    requestedRole: "customer",
    requestedName: "A Different Name",
    storedRole: "customer",
    storedName: "Existing Customer",
    email: "",
  }), "Existing Customer");
});

test("new customers require a one-time name after phone verification", () => {
  assert.equal(resolveClaimName({
    requestedRole: "customer",
    requestedName: "",
    storedRole: "",
    storedName: "",
    email: "",
  }), "");
  assert.equal(resolveClaimName({
    requestedRole: "customer",
    requestedName: "  New   Customer  ",
    storedRole: "",
    storedName: "",
    email: "",
  }), "New Customer");
});

test("phone registry keys are stable without exposing the phone", () => {
  const key = phoneKey("+919876543210");
  assert.equal(key, phoneKey("+919876543210"));
  assert.equal(key.length, 64);
  assert.equal(key.includes("9876543210"), false);
});

test("email OTP has no fixed review code and uses protected transactions", () => {
  const source = fs.readFileSync(path.join(__dirname, "index.js"), "utf8");
  assert.equal(source.includes("APP_REVIEW_CODE"), false);
  assert.equal(source.includes("APP_REVIEW_EMAIL"), false);
  assert.match(
    source,
    /exports\.sendEmailOtp[\s\S]*?enforceAppCheck: true/,
  );
  assert.match(
    source,
    /exports\.verifyEmailOtp[\s\S]*?runTransaction/,
  );
  assert.match(
    source,
    /exports\.claimLoginRole[\s\S]*?requiresName: true/,
  );
});

test("only Google-authenticated customers can supply an unverified phone", () => {
  const source = fs.readFileSync(path.join(__dirname, "index.js"), "utf8");
  assert.equal(source.includes('signInProvider === "google.com"'), true);
  assert.equal(source.includes('requestedRole === "customer"'), true);
  assert.equal(source.includes('/^\\+91\\d{10}$/'), true);
});
