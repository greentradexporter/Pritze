const assert = require("node:assert/strict");
const test = require("node:test");
const admin = require("firebase-admin");
const functions = require("./index");

// Exercise the real callable and trigger handlers with in-memory storage and
// captured FCM sends. No credentials, live bookings or network are used.
function fixture(t, {failPush = false, beforeTransaction = null} = {}) {
  const firestoreApi = admin.firestore;
  const timestamp = (millis) => firestoreApi.Timestamp.fromMillis(millis);
  const rows = new Map([
    // The same token listed in every generation: the server must pick one
    // channel for it, never ring it once per generation.
    ["users/owner", {role: "owner", activeRole: "owner", ownerNotificationsEnabled: true,
      ownerAlertV4Tokens: ["owner-token"], ownerAlertV3Tokens: ["owner-token"],
      fcmTokens: ["owner-token"]}],
    ["users/customer", {role: "customer", activeRole: "customer", phone: "+919000000001", completedBookingCount: 0, fcmTokens: ["customer-token"]}],
    ["customerSalonStats/customer__salon", {completedBookingCount: 0}],
    ["salons/salon", {ownerUid: "owner", isOpen: true, approvalStatus: "approved",
      instantBookingsEnabled: true, openTime: "12:00 AM", closeTime: "11:59 PM",
      services: [{id: "haircut", name: "Haircut Men", price: 399, durationMinutes: 30}]}],
    ["users/barber", {role: "barber", activeRole: "barber", fcmTokens: []}],
    ["barbers/barber", {salonId: "salon", uid: "barber", serviceIds: ["haircut"]}],
  ]);
  const messages = [];
  const document = (path) => ({
    path, id: path.split("/").at(-1),
    get: async () => snapshot(path),
    set: async (data) => rows.set(path, {...rows.get(path), ...data}),
    update: async (data) => rows.set(path, {...rows.get(path), ...data}),
  });
  const snapshot = (path) => ({
    id: path.split("/").at(-1), ref: document(path), exists: rows.has(path),
    data: () => rows.get(path),
  });
  const collection = (name, filters = []) => ({
    doc: (id = "new-booking") => document(`${name}/${id}`),
    where: (key, op, value) => {
      assert.equal(op, "==");
      return collection(name, [...filters, [key, value]]);
    },
    limit: () => collection(name, filters),
    get: async () => {
      const docs = [...rows.keys()].filter((path) => path.startsWith(`${name}/`))
        .filter((path) => filters.every(([key, value]) => rows.get(path)[key] === value))
        .map(snapshot);
      return {docs, size: docs.length};
    },
  });
  const db = {
    collection,
    runTransaction: async (callback) => {
      beforeTransaction?.(rows);
      return callback({
      get: (ref) => ref.get(),
      update: (ref, data) => rows.set(ref.path, {...rows.get(ref.path), ...data}),
      set: (ref, data) => rows.set(ref.path, {...rows.get(ref.path), ...data}),
      create: (ref, data) => rows.set(ref.path, data),
    }); },
  };
  Object.defineProperty(admin, "firestore", {
    configurable: true,
    value: Object.assign(() => db, {FieldValue: firestoreApi.FieldValue, Timestamp: firestoreApi.Timestamp}),
  });
  Object.defineProperty(admin, "messaging", {
    configurable: true,
    value: () => ({sendEachForMulticast: async (message) => {
      messages.push(message);
      if (failPush) throw new Error("FCM temporarily unavailable");
      return {successCount: message.tokens.length, failureCount: 0,
        responses: message.tokens.map(() => ({success: true}))};
    }}),
  });
  t.after(() => {
    delete admin.firestore;
    delete admin.messaging;
  });
  const booking = (id, overrides = {}) => {
    const data = {
      isInstant: true, status: "pending", ownerUid: "owner", customerUid: "customer",
      barberUid: "barber", barberId: "", salonId: "salon", serviceId: "haircut",
      serviceName: "Haircut", durationMinutes: 30, arrivalMinutes: 15,
      createdAt: timestamp(Date.now()), start: timestamp(Date.now() + 15 * 60_000),
      ...overrides,
    };
    rows.set(`bookings/${id}`, data);
    return data;
  };
  const resolve = (id, before) => functions.stopOwnerAlertOnBookingResolved.run({
    params: {bookingId: id},
    data: {before: {data: () => before}, after: snapshot(`bookings/${id}`)},
  });
  return {rows, messages, booking, resolve, timestamp};
}

for (const status of ["confirmed", "rejected"]) {
  test(`notification ${status} updates booking, informs customer and sends owner stop`, async (t) => {
    const f = fixture(t);
    const before = f.booking("request");
    const request = {auth: {uid: "owner"}, data: {
      bookingId: "request", status, actionSource: "notification_action",
    }};
    await functions.updateBookingStatus.run(request);
    const after = f.rows.get("bookings/request");
    assert.equal(after.status, status);
    if (status === "confirmed") {
      assert.ok(after.start.toMillis() >= before.start.toMillis());
      assert.equal(after.barberId, "barber");
    }
    assert.ok(f.messages.some((message) => message.tokens.includes("customer-token") &&
      message.data.status === status && message.data.bookingId === "request"));
    // FCM may retry the action; a duplicate must not change the arrival time.
    const repeated = await functions.updateBookingStatus.run(request);
    assert.equal(repeated.unchanged, true);
    await f.resolve("request", before);
    assert.ok(f.messages.some((message) =>
      message.data.action === "stop_owner_booking_alarm" &&
      message.data.bookingId === "request"));
  });
}

test("resolution always stops A; only a fresh pending B may ring next", async (t) => {
  const f = fixture(t);
  const before = f.booking("a");
  f.booking("a", {status: "confirmed"});
  f.booking("expired", {createdAt: f.timestamp(Date.now() - 121_000)});
  const fresh = f.booking("b", {createdAt: f.timestamp(Date.now() - 100_000)});
  await f.resolve("a", before);
  assert.equal(f.messages[0].data.action, "stop_owner_booking_alarm");
  assert.equal(f.messages[0].data.bookingId, "a");
  const alerts = f.messages.filter((message) => message.data.channel);
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].data.channel, "pritze_owner_booking_requests_v4");
  assert.equal(alerts[0].android.notification, undefined);
  assert.equal(alerts[0].data.bookingId, "b");
  assert.equal(Number(alerts[0].data.responseDeadlineMillis), fresh.createdAt.toMillis() + 120_000);
  assert.ok(alerts[0].android.ttl > 0 && alerts[0].android.ttl <= 20_000);
});

test("a signed-out owner is not alerted, even with a stale token", async (t) => {
  const f = fixture(t);
  // What sign-out writes. The token lists are deliberately left dirty: FCM
  // rotates tokens, so a device's old entries survive de-registration.
  const owner = f.rows.get("users/owner");
  f.rows.set("users/owner", {
    ...owner,
    notificationsEnabled: false,
    ownerNotificationsEnabled: false,
    activeRole: undefined,
  });
  const before = f.booking("a");
  f.booking("a", {status: "confirmed"});
  f.booking("b", {createdAt: f.timestamp(Date.now() - 100_000)});
  await f.resolve("a", before);
  assert.deepEqual(f.messages, []);
});

test("an account predating the flag still receives notifications", async (t) => {
  const f = fixture(t);
  const owner = f.rows.get("users/owner");
  delete owner.notificationsEnabled;
  const before = f.booking("a");
  f.booking("a", {status: "confirmed"});
  f.booking("b", {createdAt: f.timestamp(Date.now() - 100_000)});
  await f.resolve("a", before);
  assert.ok(f.messages.some((message) => message.data.channel));
});

test("an owner whose profile still says customer is alerted", async (t) => {
  const f = fixture(t);
  // Signed up as a customer, then registered a salon. The app promotes
  // activeRole when it registers the push token; role itself stays customer.
  const owner = f.rows.get("users/owner");
  f.rows.set("users/owner", {...owner, role: "customer", activeRole: "owner"});
  const before = f.booking("a");
  f.booking("a", {status: "confirmed"});
  f.booking("b", {createdAt: f.timestamp(Date.now() - 100_000)});
  await f.resolve("a", before);
  const alerts = f.messages.filter((message) => message.data.channel);
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].data.bookingId, "b");
});

test("a stale customer activeRole is not alerted", async (t) => {
  const f = fixture(t);
  const owner = f.rows.get("users/owner");
  f.rows.set("users/owner", {...owner, activeRole: "customer"});
  const before = f.booking("a");
  f.booking("a", {status: "confirmed"});
  f.booking("b", {createdAt: f.timestamp(Date.now() - 100_000)});
  await f.resolve("a", before);
  assert.equal(f.messages.filter((message) => message.data.channel).length, 0);
});

test("owner can add a barber through the production callable", async (t) => {
  const f = fixture(t);
  const result = await functions.saveOwnerBarber.run({auth: {uid: "owner"}, data: {
    salonId: "salon", barberId: "new-barber", name: "New barber", phone: "",
    speciality: "Haircut specialist", experienceYears: 2, serviceIds: ["haircut"],
  }});
  assert.equal(result.barberId, "new-barber");
  assert.equal(f.rows.get("barbers/new-barber").ownerUid, "owner");
  assert.deepEqual(f.rows.get("barbers/new-barber").serviceIds, ["haircut"]);
});

for (const failPush of [false, true]) {
  test(`Start then Complete commits even when push fails: ${failPush}`, async (t) => {
    const f = fixture(t, {failPush});
    f.booking("service", {status: "confirmed", barberId: "barber"});
    for (const status of ["inProgress", "completed"]) {
      const request = {auth: {uid: "owner"}, data: {bookingId: "service", status}};
      const result = await functions.updateBookingStatus.run(request);
      assert.equal(result.status, status);
      assert.equal(f.rows.get("bookings/service").status, status);
      assert.equal((await functions.updateBookingStatus.run(request)).unchanged, true);
    }
    assert.equal(f.rows.get("bookingArrivalSessions/service").sharingActive, false);
  });
}

test("owner off switch is enforced even with an empty legacy pause date", async (t) => {
  const f = fixture(t);
  await functions.setOwnerInstantBookingEnabled.run({auth: {uid: "owner"},
    data: {salonId: "salon", enabled: false}});
  assert.equal(f.rows.get("salons/salon").instantBookingsEnabled, false);
  await assert.rejects(functions.createBooking.run({auth: {uid: "customer"}, data: {
    salonId: "salon", serviceId: "haircut", isInstant: true, arrivalMinutes: 15,
  }}), (error) => error.code === "failed-precondition");
  assert.equal([...f.rows.keys()].filter((key) => key.startsWith("bookings/")).length, 0);
});

test("turning instant off during checkout is rechecked at commit", async (t) => {
  const f = fixture(t, {beforeTransaction: (rows) => {
    rows.get("salons/salon").instantBookingsEnabled = false;
  }});
  await assert.rejects(functions.createBooking.run({auth: {uid: "customer"}, data: {
    salonId: "salon", serviceId: "haircut", isInstant: true, arrivalMinutes: 15,
  }}), (error) => error.code === "failed-precondition" &&
    error.message.includes("not accepting instant bookings"));
  assert.equal([...f.rows.keys()].filter((key) => key.startsWith("bookings/")).length, 0);
});

test("timeout recovery cancels the request and sends the customer busy message", async (t) => {
  const f = fixture(t);
  f.booking("expired", {createdAt: f.timestamp(Date.now() - 121_000)});
  await functions.expireStaleInstantBookings.run({});
  assert.equal(f.rows.get("bookings/expired").status, "cancelled");
  assert.ok(f.messages.some((message) => message.tokens.includes("customer-token") &&
    message.data.event === "response_timeout" && message.data.status === "cancelled" &&
    message.data.notificationTitle === "Oops, looks like the salon is busy"));
});

test("extra-service callable and notification trigger update both participants without restarting the alarm", async (t) => {
  const f = fixture(t);
  f.rows.get('salons/salon').services.push({id: 'beard', name: 'Beard', price: 100, durationMinutes: 15});
  f.rows.get('barbers/barber').serviceIds.push('beard');
  // Fixed daytime timestamps keep this independent of the machine's timezone.
  const start = f.timestamp(Date.parse('2026-10-02T06:30:00Z'));
  const before = f.booking('extras', {status: 'inProgress', barberId: 'barber', servicePrice: 399,
    customerPayableAmount: 399, start, startedAt: start});
  const request = {auth: {uid: 'customer'}, data: {bookingId: 'extras', requestId: 'extra1', action: 'propose',
    serviceIds: ['beard'], expectedPrices: {beard: 100}}};
  await functions.updateBookingExtraServices.run(request);
  const proposed = f.rows.get('bookings/extras');
  await functions.notifyBookingExtraServices.run({params: {bookingId: 'extras'}, data: {
    before: {data: () => before}, after: {data: () => proposed},
  }});
  assert.ok(f.messages.some((message) => message.tokens.includes('owner-token') && message.notification.title === 'Review extra services'));
  await functions.updateBookingExtraServices.run({auth: {uid: 'owner'}, data: {...request.data, action: 'approve'}});
  const approved = f.rows.get('bookings/extras');
  assert.equal(approved.customerPayableAmount, 499);
  await functions.notifyBookingExtraServices.run({params: {bookingId: 'extras'}, data: {
    before: {data: () => proposed}, after: {data: () => approved},
  }});
  assert.ok(f.messages.some((message) => message.tokens.includes('customer-token') && message.notification.title === 'Extra services approved'));
  assert.ok(f.messages.every((message) => message.data.channel !== 'owner_booking_alerts'));
});

test('automatic completion rechecks a duration extended after its initial query', async (t) => {
  const f = fixture(t, {beforeTransaction: (rows) => {
    const booking = rows.get('bookings/extended');
    if (booking) rows.set('bookings/extended', {...booking, durationMinutes: 90});
  }});
  f.booking('extended', {status: 'inProgress', barberId: 'barber',
    start: f.timestamp(Date.now() - 40 * 60000), startedAt: f.timestamp(Date.now() - 40 * 60000)});
  await functions.completeOverdueServices.run({});
  assert.equal(f.rows.get('bookings/extended').status, 'inProgress');
  assert.equal(f.rows.get('bookings/extended').durationMinutes, 90);
});

test('completing a visit releases additional late-start locks and discards unapproved additions', async (t) => {
  const f = fixture(t);
  const extraLock = 'barber_late_segment';
  f.booking('extended', {status: 'inProgress', barberId: 'barber',
    startedAt: f.timestamp(Date.now()), extraSlotLockIds: [extraLock],
    extraServiceRequest: {id: 'unapproved', amount: 100}});
  f.rows.set(`slotLocks/${extraLock}`, {active: true, bookingId: 'extended'});
  await functions.updateBookingStatus.run({auth: {uid: 'owner'}, data: {bookingId: 'extended', status: 'completed'}});
  assert.equal(f.rows.get(`slotLocks/${extraLock}`).active, false);
  assert.equal(f.rows.get('bookings/extended').extraServiceRequest, null);
});
