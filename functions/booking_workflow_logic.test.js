const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const {
  INSTANT_RESPONSE_TIMEOUT_MS,
  SALON_ARRIVAL_GRACE_MS,
  SERVICE_AUTO_COMPLETE_GRACE_MS,
  bookingArrivalReminderDue,
  bookingTransitionError,
  canRescheduleBooking,
  isBlockingBooking,
  isWithinSalonHours,
  parseClockMinutes,
  serviceAutoCompleteAtMillis,
  shouldAutoCompleteService,
  slotSegmentMillis,
} = require("./booking_workflow_logic");

const start = Date.parse("2026-08-02T10:00:00.000Z");

test("instant requests have a strict 150-second response window", () => {
  assert.equal(INSTANT_RESPONSE_TIMEOUT_MS, 150 * 1000);
  const functionSource = fs.readFileSync(
    path.join(__dirname, "index.js"),
    "utf8",
  );
  assert.match(functionSource, /OWNER_ALERT_ATTEMPTS = 10/);
  assert.match(functionSource, /OWNER_ALERT_REPEAT_DELAY_MS = 15_000/);
  assert.match(functionSource, /expirePendingInstantBooking/);
  assert.match(functionSource, /No response from salon within 150 seconds/);
  assert.match(functionSource, /Oops, looks like the salon is busy/);
  assert.match(functionSource, /see other nearby salons/);
  assert.match(functionSource, /resolvedStatus: "cancelled"/);
});

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

test("platform administrators follow the salon booking transition rules", () => {
  const instant = {
    status: "pending",
    isInstant: true,
    start,
    durationMinutes: 30,
  };
  assert.equal(bookingTransitionError({
    booking: instant,
    actorRole: "admin",
    nextStatus: "confirmed",
    nowMillis: start,
  }), null);
  assert.equal(bookingTransitionError({
    booking: {...instant, status: "confirmed"},
    actorRole: "admin",
    nextStatus: "inProgress",
    nowMillis: start,
  }), null);
  assert.match(bookingTransitionError({
    booking: {...instant, status: "completed"},
    actorRole: "admin",
    nextStatus: "cancelled",
    nowMillis: start,
  }), /cannot be changed/);
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

test("started services auto-complete after duration plus five minutes", () => {
  const booking = {
    status: "inProgress",
    startedAt: start,
    durationMinutes: 30,
  };
  const deadline = start + 30 * 60 * 1000 + 5 * 60 * 1000;
  assert.equal(SERVICE_AUTO_COMPLETE_GRACE_MS, 5 * 60 * 1000);
  assert.equal(serviceAutoCompleteAtMillis(booking), deadline);
  assert.equal(shouldAutoCompleteService(booking, deadline - 1), false);
  assert.equal(shouldAutoCompleteService(booking, deadline), true);
  assert.equal(shouldAutoCompleteService({
    ...booking,
    status: "completed",
  }, deadline), false);

  const functionSource = fs.readFileSync(
    path.join(__dirname, "index.js"),
    "utf8",
  );
  assert.match(functionSource, /exports\.completeOverdueServices = onSchedule/);
  assert.match(functionSource, /\{systemActor: true\}/);
  assert.match(functionSource, /completionSource = systemActor/);
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
    "getDiscountQuote",
    "listCheckoutDiscountOffers",
    "applyCheckoutCoupon",
    "applyVisibleCheckoutDiscount",
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
    "discountCampaigns",
    "discountCampaignUsage",
    "discountSalonUsage",
    "discountCustomerUsage",
    "discountQuoteAttempts",
    "discountOfferAttempts",
    "voucherCodeRegistry",
    "platformFinance",
    "salonWallets",
    "salonSettlements",
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
  assert.match(
    functionSource,
    /if \(isInstant && !isWithinSalonHours\(\{[\s\S]*?startMillis: nowMillis/,
  );
});

test("Android update lookup activates only a Play-published candidate", () => {
  const functionSource = fs.readFileSync(
    path.join(__dirname, "index.js"),
    "utf8",
  );
  assert.match(functionSource, /exports\.getAndroidAppUpdate = onCall/);
  assert.match(
    functionSource,
    /ANDROID_LAST_CONFIRMED_PUBLIC_VERSION_CODE = 31/,
  );
  assert.match(functionSource, /getPlayPublishedAndroidVersion/);
  assert.match(functionSource, /resolveAndroidUpdateVersion/);
  assert.match(functionSource, /android_release\.json/);
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
