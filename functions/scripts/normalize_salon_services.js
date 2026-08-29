#!/usr/bin/env node
"use strict";

const {execFileSync} = require("child_process");
const fs = require("fs");
const path = require("path");
const {
  SERVICE_CATALOG,
  canonicalizeSalonServices,
} = require("../service_catalog");

const PROJECT_ID = "trimtime-46539";
const DATABASE_ID = "(default)";
const APPLY = process.argv.includes("--apply");

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
  if ("doubleValue" in value) return Number(value.doubleValue);
  if ("booleanValue" in value) return value.booleanValue;
  if ("timestampValue" in value) return value.timestampValue;
  if ("arrayValue" in value) {
    return (value.arrayValue.values || []).map(decodeValue);
  }
  if ("mapValue" in value) {
    return Object.fromEntries(
        Object.entries(value.mapValue.fields || {}).map(
            ([key, item]) => [key, decodeValue(item)],
        ),
    );
  }
  return null;
}

function encodeValue(value) {
  if (value === null || value === undefined) return {nullValue: null};
  if (typeof value === "string") return {stringValue: value};
  if (typeof value === "boolean") return {booleanValue: value};
  if (typeof value === "number") {
    return Number.isInteger(value) ?
      {integerValue: String(value)} : {doubleValue: value};
  }
  if (Array.isArray(value)) {
    return {arrayValue: {values: value.map(encodeValue)}};
  }
  if (typeof value === "object") {
    return {
      mapValue: {
        fields: Object.fromEntries(
            Object.entries(value).map(
                ([key, item]) => [key, encodeValue(item)],
            ),
        ),
      },
    };
  }
  throw new TypeError(`Cannot encode value of type ${typeof value}`);
}

async function requestJson(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
  });
  const body = await response.json();
  if (!response.ok) {
    throw new Error(`${response.status} ${JSON.stringify(body)}`);
  }
  return body;
}

async function listSalons() {
  const documents = [];
  let pageToken = "";
  do {
    const query = new URLSearchParams({pageSize: "300"});
    if (pageToken) query.set("pageToken", pageToken);
    const url = `${BASE_URL}/salons?${query}`;
    const page = await requestJson(url);
    documents.push(...(page.documents || []));
    pageToken = page.nextPageToken || "";
  } while (pageToken);
  return documents;
}

function serviceNames(services) {
  return services.map((service) => service.name);
}

function equalServices(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

const TOKEN = accessToken();
const BASE_URL =
  `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}` +
  `/databases/${encodeURIComponent(DATABASE_ID)}/documents`;

async function main() {
  const documents = await listSalons();
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const backupPath = path.join(
      "/private/tmp",
      `pritze-salon-services-backup-${timestamp}.json`,
  );
  fs.writeFileSync(backupPath, JSON.stringify(documents, null, 2));

  let changed = 0;
  const plans = [];
  for (const document of documents) {
    const id = document.name.split("/").pop();
    const fields = document.fields || {};
    const salonName = decodeValue(fields.name) || id;
    const existing = decodeValue(fields.services) || [];
    const canonical = canonicalizeSalonServices(existing);
    const needsChange = !equalServices(existing, canonical);
    if (!needsChange) continue;
    changed++;
    plans.push({
      id,
      salonName,
      beforeCount: existing.length,
      afterCount: canonical.length,
      removedNames: serviceNames(existing).filter(
          (name) => !SERVICE_CATALOG.some((item) => item.name === name),
      ),
      addedNames: serviceNames(canonical).filter(
          (name) => !serviceNames(existing).includes(name),
      ),
    });

    if (APPLY) {
      const mask = new URLSearchParams();
      mask.append("updateMask.fieldPaths", "services");
      mask.append("updateMask.fieldPaths", "legacyServiceCatalogV1");
      mask.append("updateMask.fieldPaths", "serviceCatalogMigration");
      const url = `${BASE_URL}/salons/${encodeURIComponent(id)}?${mask}`;
      await requestJson(url, {
        method: "PATCH",
        body: JSON.stringify({
          fields: {
            services: encodeValue(canonical),
            legacyServiceCatalogV1: encodeValue(existing),
            serviceCatalogMigration: encodeValue({
              version: "canonical-30-v1",
              originalServiceCount: existing.length,
              migratedAt: new Date().toISOString(),
              reversible: true,
            }),
          },
        }),
      });
    }
  }

  console.log(JSON.stringify({
    mode: APPLY ? "apply" : "dry-run",
    salonCount: documents.length,
    changedSalonCount: changed,
    backupPath,
    plans,
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
