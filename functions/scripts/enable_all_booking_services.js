#!/usr/bin/env node
"use strict";

const {execFileSync} = require("child_process");
const fs = require("fs");
const path = require("path");
const {canonicalizeSalonServices} = require("../service_catalog");

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

const TOKEN = accessToken();
const BASE_URL =
  `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}` +
  `/databases/${encodeURIComponent(DATABASE_ID)}/documents`;

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

async function listCollection(collection) {
  const documents = [];
  let pageToken = "";
  do {
    const query = new URLSearchParams({pageSize: "300"});
    if (pageToken) query.set("pageToken", pageToken);
    const page = await requestJson(`${BASE_URL}/${collection}?${query}`);
    documents.push(...(page.documents || []));
    pageToken = page.nextPageToken || "";
  } while (pageToken);
  return documents;
}

function documentId(document) {
  return document.name.split("/").pop();
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

async function patchDocument(collection, id, fields) {
  const mask = new URLSearchParams();
  for (const field of Object.keys(fields)) {
    mask.append("updateMask.fieldPaths", field);
  }
  await requestJson(
      `${BASE_URL}/${collection}/${encodeURIComponent(id)}?${mask}`,
      {
        method: "PATCH",
        body: JSON.stringify({
          fields: Object.fromEntries(
              Object.entries(fields).map(
                  ([key, value]) => [key, encodeValue(value)],
              ),
          ),
        }),
      },
  );
}

async function main() {
  const [salonDocuments, barberDocuments] = await Promise.all([
    listCollection("salons"),
    listCollection("barbers"),
  ]);
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const backupPath = path.join(
      "/private/tmp",
      `pritze-all-booking-services-backup-${timestamp}.json`,
  );
  fs.writeFileSync(backupPath, JSON.stringify({
    salons: salonDocuments,
    barbers: barberDocuments,
  }, null, 2));

  const barbersBySalon = new Map();
  for (const document of barberDocuments) {
    const salonId = String(decodeValue(document.fields?.salonId) || "").trim();
    if (!salonId) continue;
    const entries = barbersBySalon.get(salonId) || [];
    entries.push(document);
    barbersBySalon.set(salonId, entries);
  }

  const plans = [];
  let changedSalonCount = 0;
  let changedBarberCount = 0;
  for (const document of salonDocuments) {
    const id = documentId(document);
    const fields = document.fields || {};
    const existingServices = decodeValue(fields.services) || [];
    const services = canonicalizeSalonServices(existingServices).map(
        (service) => ({
          ...service,
          isAvailable: true,
          instantBookingEnabled: true,
        }),
    );
    const serviceIds = services.map((service) => service.id);
    const existingInstantEnabled = decodeValue(fields.instantBookingsEnabled);
    const salonNeedsChange = !same(existingServices, services) ||
      existingInstantEnabled !== true;
    const barberPlans = [];

    for (const barberDocument of barbersBySalon.get(id) || []) {
      const barberId = documentId(barberDocument);
      const existingIds = decodeValue(barberDocument.fields?.serviceIds) || [];
      if (same(existingIds, serviceIds)) continue;
      barberPlans.push({
        barberId,
        beforeServiceCount: existingIds.length,
        afterServiceCount: serviceIds.length,
      });
      changedBarberCount++;
      if (APPLY) {
        await patchDocument("barbers", barberId, {
          serviceIds,
        });
      }
    }

    if (salonNeedsChange) {
      changedSalonCount++;
      if (APPLY) {
        await patchDocument("salons", id, {
          services,
          instantBookingsEnabled: true,
          bookingModesMigration: {
            version: "all-services-instant-and-scheduled-v1",
            migratedAt: new Date().toISOString(),
            serviceCount: services.length,
          },
        });
      }
    }

    if (salonNeedsChange || barberPlans.length > 0) {
      plans.push({
        salonId: id,
        salonName: decodeValue(fields.name) || id,
        beforeServiceCount: existingServices.length,
        afterServiceCount: services.length,
        salonNeedsChange,
        barberPlans,
      });
    }
  }

  console.log(JSON.stringify({
    mode: APPLY ? "apply" : "dry-run",
    salonCount: salonDocuments.length,
    barberCount: barberDocuments.length,
    changedSalonCount,
    changedBarberCount,
    backupPath,
    plans,
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
