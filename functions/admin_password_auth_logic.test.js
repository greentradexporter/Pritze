const assert = require("node:assert/strict");
const test = require("node:test");
const {
  ADMIN_PASSWORD_LOCKOUT_MS,
  adminCredentialId,
  createAdminPasswordHash,
  nextAdminPasswordFailure,
  normalizeAdminPassword,
  normalizeAdminUserId,
  verifyAdminPassword,
} = require("./admin_password_auth_logic");

test("administrator user IDs are case-insensitive and safely normalized", () => {
  assert.equal(normalizeAdminUserId("  User   1 "), "user 1");
  assert.equal(normalizeAdminUserId("Operations_Admin"), "operations_admin");
  assert.equal(normalizeAdminUserId("bad/user"), "");
  assert.equal(adminCredentialId("User 1"), adminCredentialId(" user  1 "));
  assert.equal(adminCredentialId("User 1").length, 64);
});

test("administrator passwords are salted, hashed and compared safely", () => {
  const password = "S9ecurePwd";
  const firstHash = createAdminPasswordHash(password);
  const secondHash = createAdminPasswordHash(password);

  assert.notEqual(firstHash, secondHash);
  assert.equal(verifyAdminPassword(password, firstHash), true);
  assert.equal(verifyAdminPassword("incorrect1", firstHash), false);
  assert.equal(verifyAdminPassword(password, "not-a-valid-hash"), false);
  assert.equal(normalizeAdminPassword("short"), "");
});

test("five failed attempts create a fifteen-minute account lock", () => {
  const now = Date.parse("2026-08-24T10:00:00.000Z");
  let state = {};
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    state = nextAdminPasswordFailure({
      failedAttempts: state.failedAttempts,
      failureWindowStartedAtMillis: state.failureWindowStartedAtMillis,
      lockedUntilMillis: state.lockedUntilMillis,
    }, now + attempt);
  }

  assert.equal(state.failedAttempts, 5);
  assert.equal(state.shouldLock, true);
  assert.ok(state.lockedUntilMillis >= now + ADMIN_PASSWORD_LOCKOUT_MS);
});
