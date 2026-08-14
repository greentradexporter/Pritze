"use strict";

const ALLOWED_GENDERS = new Set([
  "",
  "woman",
  "man",
  "non-binary",
  "prefer-not-to-say",
]);

function normalizeProfileGender(value) {
  const gender = String(value ?? "").trim().toLowerCase();
  return ALLOWED_GENDERS.has(gender) ? gender : null;
}

function normalizeBirthDate(value, now = new Date()) {
  const birthDate = String(value ?? "").trim();
  if (!birthDate) return "";
  if (!/^\d{4}-\d{2}-\d{2}$/.test(birthDate)) return null;
  const parsed = new Date(`${birthDate}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime()) || parsed > now) return null;
  if (parsed.toISOString().slice(0, 10) !== birthDate) return null;
  if (parsed.getUTCFullYear() < 1920) return null;
  return birthDate;
}

function sanitizeShortList(value, {limit = 12, itemLimit = 40} = {}) {
  if (!Array.isArray(value)) return [];
  return [...new Set(value
    .map((item) => String(item ?? "").trim())
    .filter((item) => item && item.length <= itemLimit))]
    .slice(0, limit);
}

function sanitizePhotoUrls(value, limit = 8) {
  if (!Array.isArray(value)) return [];
  return [...new Set(value
    .map((item) => String(item ?? "").trim())
    .filter((item) => /^https:\/\//.test(item) && item.length <= 2048))]
    .slice(0, limit);
}

function normalizeVisitRating(value) {
  const rating = Number(value);
  return Number.isInteger(rating) && rating >= 1 && rating <= 5 ? rating : null;
}

function normalizeFeedbackNote(value) {
  return String(value ?? "").trim().slice(0, 500);
}

module.exports = {
  normalizeBirthDate,
  normalizeFeedbackNote,
  normalizeProfileGender,
  normalizeVisitRating,
  sanitizePhotoUrls,
  sanitizeShortList,
};
