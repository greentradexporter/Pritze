const TERMINAL_BOOKING_STATUSES = new Set([
  "completed",
  "cancelled",
  "rejected",
]);

const INSTANT_ARRIVAL_MINUTES = new Set([15, 20, 25]);
const RESCHEDULE_CUTOFF_MS = 2 * 60 * 60 * 1000;
const SALON_ARRIVAL_GRACE_MS = 5 * 60 * 1000;

function asMillis(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (value && typeof value.toMillis === "function") {
    return value.toMillis();
  }
  if (value instanceof Date) {
    return value.getTime();
  }
  return NaN;
}

function bookingEndMillis(booking) {
  const startMillis = asMillis(booking?.start);
  const duration = Number(booking?.durationMinutes) > 0 ?
    Number(booking.durationMinutes) : 30;
  return startMillis + duration * 60 * 1000;
}

function isBlockingBooking(booking, nowMillis = Date.now()) {
  if (!booking || TERMINAL_BOOKING_STATUSES.has(booking.status)) {
    return false;
  }
  if (booking.status === "inProgress") {
    return true;
  }
  if (booking.status === "pending") {
    if (booking.isInstant === true) {
      return true;
    }
    return nowMillis < asMillis(booking.start);
  }
  if (booking.status === "confirmed") {
    return nowMillis < bookingEndMillis(booking);
  }
  return false;
}

function canRescheduleBooking(booking, nowMillis = Date.now()) {
  return Boolean(
    booking &&
    booking.isInstant !== true &&
    booking.status === "confirmed" &&
    nowMillis < asMillis(booking.start) - RESCHEDULE_CUTOFF_MS
  );
}

function bookingArrivalReminderDue({
  booking,
  audience,
  nowMillis = Date.now(),
}) {
  if (
    !booking ||
    booking.status !== "confirmed"
  ) {
    return false;
  }
  const startMillis = asMillis(booking.start);
  if (!Number.isFinite(startMillis) || nowMillis >= startMillis) {
    return false;
  }
  const leadMinutes = audience === "owner" || booking.isInstant === true ?
    5 : 30;
  return nowMillis >= startMillis - leadMinutes * 60 * 1000;
}

function bookingTransitionError({
  booking,
  actorRole,
  nextStatus,
  nowMillis = Date.now(),
}) {
  if (!booking) {
    return "Booking not found.";
  }
  if (booking.status === nextStatus) {
    return null;
  }
  if (TERMINAL_BOOKING_STATUSES.has(booking.status)) {
    return `A ${booking.status} booking cannot be changed.`;
  }

  const isInstant = booking.isInstant === true;
  const currentStatus = booking.status;
  const endMillis = bookingEndMillis(booking);
  const startMillis = asMillis(booking.start);

  if (actorRole === "customer") {
    const mayCancel = nextStatus === "cancelled" &&
      (currentStatus === "pending" || currentStatus === "confirmed") &&
      (isInstant || nowMillis < startMillis);
    return mayCancel ? null : "Customers can only cancel an active booking.";
  }

  if (actorRole !== "owner") {
    return "Only the customer or salon owner can update this booking.";
  }

  if (currentStatus === "pending") {
    if (!isInstant) {
      return "Scheduled bookings do not require owner acceptance.";
    }
    if (nextStatus === "rejected") {
      return null;
    }
    if (nextStatus !== "confirmed") {
      return "An instant request can only be accepted or rejected.";
    }
    return null;
  }

  if (currentStatus === "confirmed") {
    if (nextStatus === "cancelled" && nowMillis < endMillis) {
      return null;
    }
    if (
      nextStatus === "inProgress" &&
      (isInstant || isSameLocalDate(nowMillis, startMillis)) &&
      nowMillis < endMillis
    ) {
      return null;
    }
    return "This confirmed booking cannot move to that status now.";
  }

  if (currentStatus === "inProgress") {
    return nextStatus === "completed" || nextStatus === "cancelled" ?
      null : "An active service can only be completed or cancelled.";
  }

  return "This booking transition is not allowed.";
}

function isSameLocalDate(firstMillis, secondMillis) {
  const first = zonedDateParts(new Date(firstMillis));
  const second = zonedDateParts(new Date(secondMillis));
  return first.year === second.year &&
    first.month === second.month &&
    first.day === second.day;
}

function parseClockMinutes(value) {
  const text = String(value ?? "").trim();
  const match = text.match(/^(\d{1,2}):(\d{2})(?:\s*([AaPp][Mm]))?$/);
  if (!match) {
    return null;
  }
  let hour = Number(match[1]);
  const minute = Number(match[2]);
  const meridiem = match[3]?.toUpperCase();
  if (minute > 59 || (meridiem ? hour < 1 || hour > 12 : hour > 23)) {
    return null;
  }
  if (meridiem) {
    hour %= 12;
    if (meridiem === "PM") {
      hour += 12;
    }
  }
  return hour * 60 + minute;
}

function zonedDateParts(date, timeZone = "Asia/Kolkata") {
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  });
  const parts = Object.fromEntries(
    formatter.formatToParts(date).map((part) => [part.type, part.value]),
  );
  return {
    dateKey: `${parts.year}-${parts.month}-${parts.day}`,
    minuteOfDay: Number(parts.hour) * 60 + Number(parts.minute),
  };
}

function isWithinSalonHours({
  startMillis,
  durationMinutes,
  openTime,
  closeTime,
  timeZone = "Asia/Kolkata",
}) {
  const opening = parseClockMinutes(openTime);
  const closing = parseClockMinutes(closeTime);
  if (opening === null || closing === null || closing <= opening) {
    return false;
  }
  const local = zonedDateParts(new Date(startMillis), timeZone);
  return local.minuteOfDay >= opening &&
    local.minuteOfDay + durationMinutes <= closing;
}

function slotSegmentMillis(startMillis, durationMinutes) {
  const safeDuration = durationMinutes > 0 ? durationMinutes : 30;
  const segments = [];
  for (let offset = 0; offset < safeDuration; offset += 5) {
    segments.push(startMillis + offset * 60 * 1000);
  }
  return segments;
}

module.exports = {
  INSTANT_ARRIVAL_MINUTES,
  RESCHEDULE_CUTOFF_MS,
  SALON_ARRIVAL_GRACE_MS,
  TERMINAL_BOOKING_STATUSES,
  asMillis,
  bookingArrivalReminderDue,
  bookingEndMillis,
  bookingTransitionError,
  canRescheduleBooking,
  isBlockingBooking,
  isWithinSalonHours,
  parseClockMinutes,
  slotSegmentMillis,
  zonedDateParts,
};
