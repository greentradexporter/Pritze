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

function sameRolePhoneConflictMessage(role) {
  const roleLabel = role === "owner" ? "salon owner" : "customer";
  return `Unable to log in because this phone number is already registered ` +
    `to another ${roleLabel} account. Use the original login method.`;
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
