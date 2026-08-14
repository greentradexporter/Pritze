"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  normalizeBirthDate,
  normalizeProfileGender,
  normalizeVisitRating,
  sanitizePhotoUrls,
  sanitizeShortList,
} = require("./customer_profile_logic");

test("customer profile fields are normalized and bounded", () => {
  assert.equal(normalizeProfileGender("Woman"), "woman");
  assert.equal(normalizeProfileGender("unknown"), null);
  assert.equal(
    normalizeBirthDate("2000-02-29", new Date("2026-08-05T00:00:00Z")),
    "2000-02-29",
  );
  assert.equal(
    normalizeBirthDate("2027-01-01", new Date("2026-08-05T00:00:00Z")),
    null,
  );
  assert.deepEqual(sanitizeShortList(["Fade", "Fade", " Beard "]), [
    "Fade",
    "Beard",
  ]);
  assert.deepEqual(sanitizePhotoUrls(["http://bad", "https://good/image"]), [
    "https://good/image",
  ]);
});

test("visit ratings must be whole stars from one to five", () => {
  assert.equal(normalizeVisitRating(1), 1);
  assert.equal(normalizeVisitRating("5"), 5);
  assert.equal(normalizeVisitRating(0), null);
  assert.equal(normalizeVisitRating(4.5), null);
});
