const crypto = require("node:crypto");

const ADMIN_PASSWORD_HASH_PREFIX = "scrypt-v1";
const ADMIN_PASSWORD_KEY_LENGTH = 64;
const ADMIN_PASSWORD_MIN_LENGTH = 8;
const ADMIN_PASSWORD_MAX_LENGTH = 72;
const ADMIN_PASSWORD_MAX_FAILURES = 5;
const ADMIN_PASSWORD_LOCKOUT_MS = 15 * 60 * 1000;
const SCRYPT_OPTIONS = Object.freeze({
  N: 16_384,
  r: 8,
  p: 1,
  maxmem: 64 * 1024 * 1024,
});

function normalizeAdminUserId(value) {
  const normalized = String(value ?? "")
    .normalize("NFKC")
    .trim()
    .replace(/\s+/g, " ")
    .toLowerCase();
  if (normalized.length < 3 || normalized.length > 40) return "";
  return /^[a-z0-9][a-z0-9 ._-]*$/.test(normalized) ? normalized : "";
}

function normalizeAdminPassword(value) {
  const password = typeof value === "string" ? value.normalize("NFKC") : "";
  if (
    password.length < ADMIN_PASSWORD_MIN_LENGTH ||
    password.length > ADMIN_PASSWORD_MAX_LENGTH
  ) {
    return "";
  }
  return password;
}

function adminCredentialId(userId) {
  const normalized = normalizeAdminUserId(userId);
  if (!normalized) return "";
  return crypto.createHash("sha256").update(normalized).digest("hex");
}

function createAdminPasswordHash(passwordValue, saltValue) {
  const password = normalizeAdminPassword(passwordValue);
  if (!password) throw new Error("Administrator passwords must be 8–72 characters.");
  const salt = saltValue ? Buffer.from(saltValue) : crypto.randomBytes(16);
  if (salt.length < 16) throw new Error("Administrator password salts must be at least 16 bytes.");
  const derived = crypto.scryptSync(
    password,
    salt,
    ADMIN_PASSWORD_KEY_LENGTH,
    SCRYPT_OPTIONS,
  );
  return `${ADMIN_PASSWORD_HASH_PREFIX}$${salt.toString("base64url")}$${derived.toString("base64url")}`;
}

function verifyAdminPassword(passwordValue, storedHash) {
  const password = normalizeAdminPassword(passwordValue);
  const [prefix, saltEncoded, hashEncoded, ...extra] =
    String(storedHash ?? "").split("$");
  if (
    !password ||
    prefix !== ADMIN_PASSWORD_HASH_PREFIX ||
    !saltEncoded ||
    !hashEncoded ||
    extra.length > 0
  ) {
    return false;
  }
  try {
    const salt = Buffer.from(saltEncoded, "base64url");
    const expected = Buffer.from(hashEncoded, "base64url");
    if (salt.length < 16 || expected.length !== ADMIN_PASSWORD_KEY_LENGTH) {
      return false;
    }
    const actual = crypto.scryptSync(
      password,
      salt,
      expected.length,
      SCRYPT_OPTIONS,
    );
    return crypto.timingSafeEqual(actual, expected);
  } catch (_) {
    return false;
  }
}

function nextAdminPasswordFailure(data = {}, nowMillis = Date.now()) {
  const previousLockoutMillis = (
    data.lockedUntil?.toMillis?.() ?? Number(data.lockedUntilMillis)
  ) || 0;
  const failureWindowMillis = (
    data.failureWindowStartedAt?.toMillis?.() ??
      Number(data.failureWindowStartedAtMillis)
  ) || 0;
  const windowExpired = !failureWindowMillis ||
    nowMillis - failureWindowMillis >= ADMIN_PASSWORD_LOCKOUT_MS;
  const failedAttempts = windowExpired ? 1 :
    Math.max(0, Number(data.failedAttempts) || 0) + 1;
  const shouldLock = failedAttempts >= ADMIN_PASSWORD_MAX_FAILURES;
  return {
    failedAttempts,
    failureWindowStartedAtMillis: windowExpired ? nowMillis : failureWindowMillis,
    lockedUntilMillis: shouldLock ?
      Math.max(previousLockoutMillis, nowMillis + ADMIN_PASSWORD_LOCKOUT_MS) :
      previousLockoutMillis,
    shouldLock,
  };
}

module.exports = {
  ADMIN_PASSWORD_LOCKOUT_MS,
  ADMIN_PASSWORD_MAX_FAILURES,
  adminCredentialId,
  createAdminPasswordHash,
  nextAdminPasswordFailure,
  normalizeAdminPassword,
  normalizeAdminUserId,
  verifyAdminPassword,
};
