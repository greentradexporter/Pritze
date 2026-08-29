const assert = require("node:assert/strict");
const test = require("node:test");
const {
  evaluateOperationalAlerts,
  normalizedRules,
} = require("./admin_intelligence_logic");

const now = Date.parse("2026-08-21T12:00:00.000Z");

test("operational intelligence detects urgent booking exceptions", () => {
  const alerts = evaluateOperationalAlerts({
    nowMillis: now,
    bookings: [{
      id: "booking-1",
      salonId: "salon-1",
      isInstant: true,
      status: "pending",
      createdAt: now - 6 * 60_000,
      start: now - 4 * 60_000,
      barberId: "",
    }],
  });
  assert.deepEqual(alerts.map((item) => item.type), [
    "instant_response",
    "unassigned_booking",
  ]);
  assert.equal(alerts[0].severity, "critical");
});

test("disabled rules do not generate alerts", () => {
  const alerts = evaluateOperationalAlerts({
    nowMillis: now,
    storedRules: {instant_response: {enabled: false}},
    bookings: [{
      id: "booking-1",
      isInstant: true,
      status: "pending",
      createdAt: now - 30 * 60_000,
    }],
  });
  assert.equal(alerts.some((item) => item.type === "instant_response"), false);
});

test("rule thresholds are bounded by safe defaults", () => {
  const rules = normalizedRules({
    overdue_arrival: {enabled: true, threshold: -5},
    low_rating: {enabled: false, threshold: 4},
  });
  assert.equal(rules.overdue_arrival.threshold, 10);
  assert.deepEqual(rules.low_rating, {enabled: false, threshold: 4});
});
