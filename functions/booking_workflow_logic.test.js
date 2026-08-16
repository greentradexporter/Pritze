const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const {
  SALON_ARRIVAL_GRACE_MS,
  bookingArrivalReminderDue,
  bookingTransitionError,
  canRescheduleBooking,
  isBlockingBooking,
  isWithinSalonHours,
  parseClockMinutes,
  slotSegmentMillis,
} = require("./booking_workflow_logic");

const start = Date.parse("2026-08-02T10:00:00.000Z");

test("scheduled bookings are registered confirmed and never accepted", () => {
  const booking = {
    status: "confirmed",
    isInstant: false,
    start,
    durationMinutes: 30,
  };
  assert.match(
    bookingTransitionError({
      booking: {...booking, status: "pending"},
      actorRole: "owner",
      nextStatus: "confirmed",
      nowMillis: start - 60_000,
    }),
    /do not require owner acceptance/,
  );
  assert.equal(
    bookingTransitionError({
      booking,
      actorRole: "owner",
      nextStatus: "cancelled",
      nowMillis: start - 60_000,
    }),
    null,
  );
});

test("only instant requests support owner accept or reject", () => {
  const booking = {
    status: "pending",
    isInstant: true,
    start,
    durationMinutes: 30,
  };
  assert.equal(
    bookingTransitionError({
      booking,
      actorRole: "owner",
      nextStatus: "confirmed",
      nowMillis: start + SALON_ARRIVAL_GRACE_MS,
    }),
    null,
  );
  assert.equal(
    bookingTransitionError({
      booking,
      actorRole: "owner",
      nextStatus: "confirmed",
      nowMillis: start + SALON_ARRIVAL_GRACE_MS + 1,
    }),
    null,
  );
  assert.equal(
    bookingTransitionError({
      booking,
      actorRole: "owner",
      nextStatus: "rejected",
      nowMillis: start + SALON_ARRIVAL_GRACE_MS + 1,
    }),
    null,
  );
});

test("rescheduling closes exactly two hours before scheduled start", () => {
  const booking = {status: "confirmed", isInstant: false, start};
  assert.equal(canRescheduleBooking(booking, start - 2 * 60 * 60 * 1000 - 1), true);
  assert.equal(canRescheduleBooking(booking, start - 2 * 60 * 60 * 1000), false);
  assert.equal(canRescheduleBooking({...booking, isInstant: true}, start - 99_000_000), false);
});

test("arrival reminders begin only after confirmation", () => {
  const scheduled = {status: "confirmed", isInstant: false, start};
  const instant = {status: "pending", isInstant: true, start};
  assert.equal(bookingArrivalReminderDue({
    booking: scheduled,
    audience: "customer",
    nowMillis: start - 30 * 60 * 1000,
  }), true);
  assert.equal(bookingArrivalReminderDue({
    booking: scheduled,
    audience: "owner",
    nowMillis: start - 6 * 60 * 1000,
  }), false);
  assert.equal(bookingArrivalReminderDue({
    booking: scheduled,
    audience: "owner",
    nowMillis: start - 5 * 60 * 1000,
  }), true);
  assert.equal(bookingArrivalReminderDue({
    booking: instant,
    audience: "customer",
    nowMillis: start - 5 * 60 * 1000,
  }), false);
  assert.equal(bookingArrivalReminderDue({
    booking: {...instant, status: "confirmed"},
    audience: "customer",
    nowMillis: start - 5 * 60 * 1000,
  }), true);
  assert.equal(bookingArrivalReminderDue({
    booking: {...instant, status: "cancelled"},
    audience: "owner",
    nowMillis: start - 60 * 1000,
  }), false);
});

test("active markers stop blocking after a confirmed booking has ended", () => {
  const booking = {
    status: "confirmed",
    isInstant: false,
    start,
    durationMinutes: 30,
  };
  assert.equal(isBlockingBooking(booking, start + 29 * 60 * 1000), true);
  assert.equal(isBlockingBooking(booking, start + 30 * 60 * 1000), false);
  assert.equal(isBlockingBooking({...booking, status: "pending", isInstant: true}, start + 99_000_000), true);
});

test("clock parsing, salon hours, and five-minute locks are deterministic", () => {
  assert.equal(parseClockMinutes("9:30 AM"), 570);
  assert.equal(parseClockMinutes("18:15"), 1095);
  assert.equal(parseClockMinutes("25:00"), null);
  assert.equal(isWithinSalonHours({
    startMillis: Date.parse("2026-08-02T09:30:00.000Z"),
    durationMinutes: 30,
    openTime: "2:00 PM",
    closeTime: "4:00 PM",
  }), true);
  assert.deepEqual(slotSegmentMillis(1_000, 16), [
    1_000,
    301_000,
    601_000,
    901_000,
  ]);
});

test("booking writes are server-only and all authoritative callables exist", () => {
  const functionSource = fs.readFileSync(
    path.join(__dirname, "index.js"),
    "utf8",
  );
  for (const callable of [
    "createBooking",
    "updateBookingStatus",
    "rescheduleBooking",
  ]) {
    assert.match(functionSource, new RegExp(`exports\\.${callable} = onCall`));
  }
  const ruleSource = fs.readFileSync(
    path.join(__dirname, "..", "firestore.rules"),
    "utf8",
  );
  for (const collection of [
    "slotLocks",
    "activeInstantBookings",
    "activeCustomerBookings",
    "bookings",
  ]) {
    assert.match(
      ruleSource,
      new RegExp(`match /${collection}/\\{[^}]+\\} \\{[\\s\\S]*?allow write: if false;`),
    );
  }
});

test("instant bookings validate and preserve grouped services", () => {
  const functionSource = fs.readFileSync(
    path.join(__dirname, "index.js"),
    "utf8",
  );
  assert.match(functionSource, /request\.data\?\.serviceIds/);
  assert.match(functionSource, /serviceIds\.length > 6/);
  assert.match(
    functionSource,
    /serviceIds\.every\(\(id\) => barberCanServe\(doc\.data\(\), id\)\)/,
  );
  assert.match(functionSource, /serviceIds,\n\s+barberId:/);
  assert.match(functionSource, /services\.reduce\(/);
  assert.match(functionSource, /This salon is currently closed\./);
});

test("Android update lookup has a safe current-build fallback", () => {
  const functionSource = fs.readFileSync(
    path.join(__dirname, "index.js"),
    "utf8",
  );
  assert.match(functionSource, /exports\.getAndroidAppUpdate = onCall/);
  assert.match(functionSource, /ANDROID_CURRENT_VERSION_CODE = 29/);
  assert.match(functionSource, /collection\("appConfig"\)/);
  assert.match(functionSource, /details\?id=com\.trimtime\.app/);
});

test("iOS update lookup has a safe App Store fallback", () => {
  const functionSource = fs.readFileSync(
    path.join(__dirname, "index.js"),
    "utf8",
  );
  assert.match(functionSource, /exports\.getIosAppUpdate = onCall/);
  assert.match(functionSource, /IOS_CURRENT_BUILD_NUMBER = 28/);
  assert.match(functionSource, /IOS_NEXT_VERSION = "1\.0\.16"/);
  assert.match(functionSource, /IOS_NEXT_BUILD_NUMBER = 29/);
  assert.match(functionSource, /itunes\.apple\.com\/lookup/);
  assert.match(functionSource, /versionAtLeast\(publicVersion, IOS_NEXT_VERSION\)/);
  assert.match(functionSource, /doc\("ios"\)/);
  assert.match(functionSource, /apps\.apple\.com\/in\/app\/pritze\/id6792811282/);
});
