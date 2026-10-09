#!/usr/bin/env node
"use strict";

// Read-only audit. Answers one question for every salon: would a booking
// request actually ring its owner's phone?
//
// The server routes owner alerts on users/{ownerUid}, and three fields there
// can silently refuse them:
//   activeRole               must be "owner"  (sendToUsers gate)
//   ownerNotificationsEnabled must be true    (sendToUsers gate)
//   ownerAlertV4Tokens       must list a device
// A fourth, `role`, gates the Firestore rules instead: an owner whose role
// says "customer" also cannot edit their own salon, because signedInAs('owner')
// reads that field.
//
// This script never writes. It has no --apply flag on purpose: the repair is a
// field update that needs a human to look at this output first.

const {execFileSync} = require("child_process");

const PROJECT_ID = process.env.PRITZE_PROJECT_ID || "trimtime-46539";
const DATABASE_ID = "(default)";

function accessToken() {
  return execFileSync("gcloud", ["auth", "print-access-token"], {
    encoding: "utf8",
  }).trim();
}

function decodeValue(value) {
  if (!value || typeof value !== "object") return null;
  if ("nullValue" in value) return null;
  if ("stringValue" in value) return value.stringValue;
  if ("integerValue" in value) return Number(value.integerValue);
  if ("booleanValue" in value) return value.booleanValue;
  if ("timestampValue" in value) return value.timestampValue;
  if ("arrayValue" in value) {
    return (value.arrayValue.values || []).map(decodeValue);
  }
  return null;
}

function decodeFields(document) {
  return Object.fromEntries(
      Object.entries(document.fields || {}).map(
          ([key, value]) => [key, decodeValue(value)],
      ),
  );
}

const TOKEN = accessToken();
const BASE_URL =
  `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}` +
  `/databases/${encodeURIComponent(DATABASE_ID)}/documents`;

async function requestJson(url) {
  const response = await fetch(url, {
    headers: {Authorization: `Bearer ${TOKEN}`},
  });
  const body = await response.json();
  if (!response.ok) {
    throw new Error(`${response.status} ${JSON.stringify(body)}`);
  }
  return body;
}

async function listCollection(collection) {
  const documents = [];
  let pageToken = "";
  do {
    const query = new URLSearchParams({pageSize: "300"});
    if (pageToken) query.set("pageToken", pageToken);
    const page = await requestJson(`${BASE_URL}/${collection}?${query}`);
    for (const document of page.documents || []) {
      documents.push({
        id: document.name.split("/").at(-1),
        data: decodeFields(document),
      });
    }
    pageToken = page.nextPageToken || "";
  } while (pageToken);
  return documents;
}

async function getDocument(path) {
  try {
    const document = await requestJson(`${BASE_URL}/${path}`);
    return decodeFields(document);
  } catch (error) {
    if (String(error.message).startsWith("404")) return null;
    throw error;
  }
}

function auditOwner(user) {
  if (!user) return ["no users/ document for this ownerUid"];
  const problems = [];
  if (user.activeRole !== "owner") {
    problems.push(`activeRole=${JSON.stringify(user.activeRole)} (needs "owner")`);
  }
  if (user.ownerNotificationsEnabled !== true) {
    problems.push(
        `ownerNotificationsEnabled=${JSON.stringify(user.ownerNotificationsEnabled)}`,
    );
  }
  if (user.notificationsEnabled === false) {
    problems.push("notificationsEnabled=false (signed out on every device)");
  }
  const v4 = Array.isArray(user.ownerAlertV4Tokens) ?
    user.ownerAlertV4Tokens.length : 0;
  const v3 = Array.isArray(user.ownerAlertV3Tokens) ?
    user.ownerAlertV3Tokens.length : 0;
  if (v4 === 0 && v3 === 0) {
    problems.push("no owner-alert tokens registered");
  }
  if (user.role !== "owner") {
    problems.push(
        `role=${JSON.stringify(user.role)} — also blocks editing their own salon`,
    );
  }
  return problems;
}

async function main() {
  const salons = await listCollection("salons");
  const seen = new Map();
  const rows = [];
  for (const salon of salons) {
    const ownerUid = String(salon.data.ownerUid || "").trim();
    const name = salon.data.name || "(unnamed)";
    if (!ownerUid) {
      rows.push({name, salonId: salon.id, ownerUid: "", problems: ["salon has no ownerUid"]});
      continue;
    }
    if (!seen.has(ownerUid)) {
      seen.set(ownerUid, await getDocument(`users/${ownerUid}`));
    }
    const user = seen.get(ownerUid);
    rows.push({
      name,
      salonId: salon.id,
      ownerUid,
      role: user?.role,
      activeRole: user?.activeRole,
      ownerNotificationsEnabled: user?.ownerNotificationsEnabled,
      tokens: (user?.ownerAlertV4Tokens || []).length,
      legacyTokens: (user?.ownerAlertV3Tokens || []).length,
      problems: auditOwner(user),
    });
  }

  const broken = rows.filter((row) => row.problems.length > 0);
  if (process.argv.includes("--all")) {
    for (const row of rows) {
      console.log(
          `${row.problems.length ? "✗" : "✓"} ${row.name}` +
          `\n    role=${JSON.stringify(row.role)}` +
          ` activeRole=${JSON.stringify(row.activeRole)}` +
          ` ownerNotificationsEnabled=${JSON.stringify(row.ownerNotificationsEnabled)}` +
          ` v4Tokens=${row.tokens} v3Tokens=${row.legacyTokens}`,
      );
    }
    console.log("");
  }
  console.log(`project: ${PROJECT_ID}`);
  console.log(`salons: ${rows.length}  owners: ${seen.size}  would not ring: ${broken.length}\n`);
  for (const row of broken) {
    console.log(`✗ ${row.name}  (salon ${row.salonId}, owner ${row.ownerUid})`);
    for (const problem of row.problems) console.log(`    - ${problem}`);
  }
  const healthy = rows.filter((row) => row.problems.length === 0);
  if (healthy.length > 0) {
    console.log(`\n✓ would ring: ${healthy.map((row) => row.name).join(", ")}`);
  }
  console.log("\nRead-only: nothing was changed.");
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
