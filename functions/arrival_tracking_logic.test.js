const assert = require("node:assert/strict");
const test = require("node:test");
const {
  MAX_SHARING_DURATION_MS,
  coordinatesFromSalon,
  distanceMeters,
  estimatedArrivalMinutes,
  sharingExpiresAtMillis,
  validArrivalStatus,
  validLocationUpdate,
} = require("./arrival_tracking_logic");

const now = Date.parse("2026-08-21T12:00:00.000Z");

test("arrival states are explicit and bounded", () => {
  assert.equal(validArrivalStatus("onTheWay"), true);
  assert.equal(validArrivalStatus("arrived"), true);
  assert.equal(validArrivalStatus("trackingForever"), false);
});

test("location updates reject stale, inaccurate, and invalid coordinates", () => {
  const valid = {
    latitude: 19.9975,
    longitude: 73.7898,
    accuracyMeters: 20,
    capturedAtMillis: now,
    nowMillis: now,
  };
  assert.equal(validLocationUpdate(valid), true);
  assert.equal(validLocationUpdate({...valid, latitude: 91}), false);
  assert.equal(validLocationUpdate({...valid, accuracyMeters: 3000}), false);
  assert.equal(validLocationUpdate({...valid, capturedAtMillis: now - 6 * 60_000}), false);
});

test("sharing expires within one hour and never beyond the booking cutoff", () => {
  assert.equal(sharingExpiresAtMillis({
    nowMillis: now,
    bookingStartMillis: now + 5 * 60 * 60_000,
    durationMinutes: 30,
  }), now + MAX_SHARING_DURATION_MS);
  assert.equal(sharingExpiresAtMillis({
    nowMillis: now,
    bookingStartMillis: now - 10 * 60_000,
    durationMinutes: 30,
  }), now + 50 * 60_000);
});

test("distance and ETA are calculated only from valid map pins", () => {
  const distance = distanceMeters(
    {latitude: 19.9975, longitude: 73.7898},
    {latitude: 20.0059, longitude: 73.7910},
  );
  assert.ok(distance > 800 && distance < 1200);
  assert.ok(estimatedArrivalMinutes(distance, 5) >= 2);
  assert.equal(distanceMeters(
    {latitude: 999, longitude: 73},
    {latitude: 20, longitude: 73},
  ), null);
});

test("salon coordinates accept explicit pins and coordinate-based map links", () => {
  assert.deepEqual(coordinatesFromSalon({
    latitude: 19.9975,
    longitude: 73.7898,
  }), {latitude: 19.9975, longitude: 73.7898});
  assert.deepEqual(coordinatesFromSalon({
    directionsUrl: "https://www.google.com/maps/@19.9975,73.7898,16z",
  }), {latitude: 19.9975, longitude: 73.7898});
  assert.equal(coordinatesFromSalon({
    directionsUrl: "https://maps.app.goo.gl/short-link-without-a-pin",
  }), null);
});
