function normalizeVerifiedPhone(value) {
  const phone = String(value ?? "").trim();
  return /^\+[1-9]\d{7,14}$/.test(phone) ? phone : "";
}

function normalizeDisplayName(value) {
  return String(value ?? "").trim().replace(/\s+/g, " ").slice(0, 120);
}

function normalizeLoginProvider(value, phone) {
  const provider = String(value ?? "").trim().toLowerCase();
  if (provider === "google") {
    return "google";
  }
  if (provider === "email") {
    return "email";
  }
  return phone ? "phone" : "email";
}

function normalizeRole(value) {
  return value === "customer" || value === "owner" ? value : "";
}

function inferStoredRole(data, ownsSalon) {
  if (ownsSalon) {
    return "owner";
  }
  const role = normalizeRole(data?.role);
  if (role) {
    return role;
  }
  const roles = Array.isArray(data?.roles) ?
    data.roles.map(normalizeRole).filter(Boolean) :
    [];
  const uniqueRoles = [...new Set(roles)];
  if (uniqueRoles.length === 1) {
    return uniqueRoles[0];
  }
  if (uniqueRoles.length > 1) {
    return normalizeRole(data?.activeRole);
  }
  return "";
}

function loginRoleConflictMessage(requestedRole, existingRole, hasPhone) {
  const requestedLabel = requestedRole === "customer" ?
    "customer" :
    "salon owner";
  const existingLabel = existingRole === "customer" ?
    "customer" :
    "salon owner";
  const identity = hasPhone ? "phone number" : "account";
  return `Unable to log in as ${requestedLabel} because this ${identity} ` +
    `is already registered as a ${existingLabel}.`;
}

// Reached when the phone is registered to a different account than the one
// signing in — typically an owner who registered with Google and is now
// trying the phone tab, which Firebase treats as a separate identity. The
// old wording ("use the original login method") named neither the method
// nor the way to make this number work in future.
function sameRolePhoneConflictMessage(role) {
  if (role === "owner") {
    return "This phone number belongs to a salon account that signs in a " +
      "different way. Sign in with Google or email, then turn on phone " +
      "login from your salon listing to use this number next time.";
  }
  return "This phone number belongs to another customer account. Sign in " +
    "the same way that account was created.";
}

function phoneKey(phone) {
  return crypto.createHash("sha256").update(phone).digest("hex");
}

function fallbackName(email) {
  return email ? email.split("@")[0] : "Pritze user";
}

function resolveClaimName({
  requestedRole,
  requestedName,
  storedRole,
  storedName,
  email,
}) {
  const normalizedRequestedName = normalizeDisplayName(requestedName);
  const normalizedStoredName = normalizeDisplayName(storedName);
  if (
    requestedRole === "customer" &&
    storedRole === "customer" &&
    normalizedStoredName
  ) {
    return normalizedStoredName;
  }
  if (normalizedRequestedName) {
    return normalizedRequestedName;
  }
  if (normalizedStoredName) {
    return normalizedStoredName;
  }
  return requestedRole === "owner" ? fallbackName(email) : "";
}

module.exports = {
  fallbackName,
  inferStoredRole,
  loginRoleConflictMessage,
  normalizeDisplayName,
  normalizeLoginProvider,
  normalizeRole,
  normalizeVerifiedPhone,
  phoneKey,
  resolveClaimName,
  sameRolePhoneConflictMessage,
};
const crypto = require("node:crypto");
