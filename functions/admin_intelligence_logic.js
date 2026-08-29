const DEFAULT_ADMIN_AUTOMATION_RULES = Object.freeze({
  instant_response: {enabled: true, threshold: 2},
  overdue_arrival: {enabled: true, threshold: 10},
  unassigned_booking: {enabled: true, threshold: 5},
  cancellation_spike: {enabled: true, threshold: 30},
  low_rating: {enabled: true, threshold: 3.5},
});

function asMillis(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (value && typeof value.toMillis === "function") return value.toMillis();
  if (value instanceof Date) return value.getTime();
  return 0;
}

function normalizedRules(storedRules = {}) {
  return Object.fromEntries(Object.entries(DEFAULT_ADMIN_AUTOMATION_RULES)
    .map(([id, defaults]) => {
      const stored = storedRules[id] || {};
      const threshold = Number(stored.threshold);
      return [id, {
        enabled: stored.enabled === undefined ? defaults.enabled :
          stored.enabled === true,
        threshold: Number.isFinite(threshold) && threshold > 0 ?
          threshold : defaults.threshold,
      }];
    }));
}

function evaluateOperationalAlerts({
  bookings = [],
  salons = [],
  storedRules = {},
  nowMillis = Date.now(),
}) {
  const rules = normalizedRules(storedRules);
  const alerts = [];
  const push = (alert) => alerts.push({
    ...alert,
    key: `${alert.type}:${alert.targetType}:${alert.targetId}`,
    detectedAtMillis: nowMillis,
  });

  for (const booking of bookings) {
    const bookingId = String(booking.id || booking.bookingId || "").trim();
    if (!bookingId) continue;
    const status = String(booking.status || "").trim();
    const createdAtMillis = asMillis(booking.createdAt);
    const startMillis = asMillis(booking.start);
    if (rules.instant_response.enabled && booking.isInstant === true &&
        status === "pending" && createdAtMillis > 0 &&
        nowMillis - createdAtMillis >= rules.instant_response.threshold * 60_000) {
      push({
        type: "instant_response",
        severity: "critical",
        targetType: "booking",
        targetId: bookingId,
        salonId: String(booking.salonId || ""),
        title: "Instant request needs a decision",
        detail: `Waiting ${Math.floor((nowMillis - createdAtMillis) / 60_000)} minutes.`,
        recommendedAction: "Accept or reject the request after checking capacity.",
      });
    }
    if (rules.overdue_arrival.enabled && status === "confirmed" &&
        startMillis > 0 && nowMillis - startMillis >=
          rules.overdue_arrival.threshold * 60_000) {
      push({
        type: "overdue_arrival",
        severity: "warning",
        targetType: "booking",
        targetId: bookingId,
        salonId: String(booking.salonId || ""),
        title: "Confirmed booking is overdue",
        detail: `Expected ${Math.floor((nowMillis - startMillis) / 60_000)} minutes ago.`,
        recommendedAction: "Contact the salon or customer before changing status.",
      });
    }
    const referenceMillis = status === "pending" ?
      createdAtMillis : startMillis || createdAtMillis;
    if (rules.unassigned_booking.enabled &&
        ["pending", "confirmed"].includes(status) &&
        !String(booking.barberId || "").trim() && referenceMillis > 0 &&
        nowMillis - referenceMillis >= rules.unassigned_booking.threshold * 60_000) {
      push({
        type: "unassigned_booking",
        severity: "warning",
        targetType: "booking",
        targetId: bookingId,
        salonId: String(booking.salonId || ""),
        title: "Booking has no assigned barber",
        detail: "The booking is active but no team member is attached.",
        recommendedAction: "Review the salon workload and assign an eligible barber.",
      });
    }
  }

  for (const salon of salons) {
    const salonId = String(salon.id || "").trim();
    if (!salonId) continue;
    const salonBookings = bookings.filter((booking) =>
      String(booking.salonId || "") === salonId);
    const terminal = salonBookings.filter((booking) =>
      ["completed", "cancelled", "rejected"].includes(booking.status));
    const cancelled = terminal.filter((booking) =>
      ["cancelled", "rejected"].includes(booking.status));
    const cancellationRate = terminal.length ?
      cancelled.length / terminal.length * 100 : 0;
    if (rules.cancellation_spike.enabled && terminal.length >= 5 &&
        cancellationRate >= rules.cancellation_spike.threshold) {
      push({
        type: "cancellation_spike",
        severity: "warning",
        targetType: "salon",
        targetId: salonId,
        salonId,
        title: "Cancellation rate needs review",
        detail: `${Math.round(cancellationRate)}% across ${terminal.length} completed or cancelled bookings.`,
        recommendedAction: "Review cancellation reasons and staffing before intervening.",
      });
    }
    const rating = Number(salon.rating) || 0;
    if (rules.low_rating.enabled && rating > 0 &&
        rating < rules.low_rating.threshold) {
      push({
        type: "low_rating",
        severity: "info",
        targetType: "salon",
        targetId: salonId,
        salonId,
        title: "Salon rating is below the quality threshold",
        detail: `${rating.toFixed(1)} stars against a ${rules.low_rating.threshold.toFixed(1)} threshold.`,
        recommendedAction: "Review recent feedback and recurring complaints.",
      });
    }
  }

  return alerts.sort((left, right) => {
    const rank = {critical: 0, warning: 1, info: 2};
    return rank[left.severity] - rank[right.severity] ||
      left.key.localeCompare(right.key);
  });
}

module.exports = {
  DEFAULT_ADMIN_AUTOMATION_RULES,
  evaluateOperationalAlerts,
  normalizedRules,
};
