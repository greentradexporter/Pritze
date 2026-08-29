#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");
const admin = require("firebase-admin");
const {
  adminCredentialId,
  createAdminPasswordHash,
  normalizeAdminPassword,
  normalizeAdminUserId,
} = require("../admin_password_auth_logic");

function usage() {
  console.error(
    "Usage: node scripts/provision_admin_password_users.js <credentials.json> " +
    "--project <firebase-project-id> --apply",
  );
}

function argumentValue(flag) {
  const index = process.argv.indexOf(flag);
  return index >= 0 ? String(process.argv[index + 1] || "").trim() : "";
}

async function authUser(auth, uid, displayName) {
  try {
    const existing = await auth.getUser(uid);
    return auth.updateUser(existing.uid, {displayName, disabled: false});
  } catch (error) {
    if (error.code !== "auth/user-not-found") throw error;
    return auth.createUser({uid, displayName, disabled: false});
  }
}

async function main() {
  const credentialPath = process.argv[2] ? path.resolve(process.argv[2]) : "";
  const projectId = argumentValue("--project");
  const apply = process.argv.includes("--apply");
  if (!credentialPath || !projectId || !apply) {
    usage();
    process.exitCode = 2;
    return;
  }

  const source = JSON.parse(fs.readFileSync(credentialPath, "utf8"));
  if (!Array.isArray(source) || source.length < 1 || source.length > 10) {
    throw new Error("Credentials must contain between one and ten administrators.");
  }
  const records = source.map((entry) => {
    const normalizedUserId = normalizeAdminUserId(entry.userId);
    const password = normalizeAdminPassword(entry.password);
    if (!normalizedUserId || !password) {
      throw new Error("Every administrator needs a valid userId and an 8–72 character password.");
    }
    const credentialId = adminCredentialId(normalizedUserId);
    return {
      userId: String(entry.userId).trim(),
      normalizedUserId,
      displayName: String(entry.displayName || entry.userId).trim(),
      password,
      credentialId,
      authUid: `pritze-admin-${credentialId.slice(0, 24)}`,
    };
  });
  if (new Set(records.map((record) => record.credentialId)).size !== records.length) {
    throw new Error("Administrator user IDs must be unique.");
  }

  admin.initializeApp({projectId});
  const auth = admin.auth();
  const firestore = admin.firestore();
  for (const record of records) {
    const user = await authUser(auth, record.authUid, record.displayName);
    await auth.setCustomUserClaims(user.uid, {
      ...(user.customClaims || {}),
      platformAdmin: true,
      adminProvider: "admin_password",
    });
    const passwordHash = createAdminPasswordHash(record.password);
    const batch = firestore.batch();
    batch.set(firestore.collection("platformAdmins").doc(user.uid), {
      active: true,
      displayName: record.displayName,
      loginProvider: "admin_password",
      provisionedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    batch.set(firestore.collection("platformAdminCredentials").doc(record.credentialId), {
      active: true,
      authUid: user.uid,
      displayName: record.displayName,
      normalizedUserId: record.normalizedUserId,
      passwordHash,
      failedAttempts: 0,
      failureWindowStartedAt: admin.firestore.FieldValue.delete(),
      lockedUntil: admin.firestore.FieldValue.delete(),
      passwordChangedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    await batch.commit();
    console.log(`Provisioned ${record.displayName} (${user.uid}).`);
  }
  console.log(`Provisioned ${records.length} Pritze administrator account(s).`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
