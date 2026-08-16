const crypto = require("node:crypto");
const admin = require("firebase-admin");
const nodemailer = require("nodemailer");
const {
  inferStoredRole,
  loginRoleConflictMessage,
  normalizeDisplayName,
  normalizeLoginProvider,
  normalizeRole,
  normalizeVerifiedPhone,
  phoneKey,
  resolveClaimName,
  sameRolePhoneConflictMessage,
} = require("./auth_login_logic");
const {
  bookingRecipientRoles,
  bookingStatusRecipients,
} = require("./booking_notification_logic");
const {
  INSTANT_ARRIVAL_MINUTES,
  bookingArrivalReminderDue,
  bookingTransitionError,
  canRescheduleBooking,
  isBlockingBooking,
  isWithinSalonHours,
  slotSegmentMillis,
  zonedDateParts,
} = require("./booking_workflow_logic");
const {
  normalizeBirthDate,
  normalizeFeedbackNote,
  normalizeProfileGender,
  normalizeVisitRating,
  sanitizePhotoUrls,
  sanitizeShortList,
} = require("./customer_profile_logic");
const {HttpsError, onCall} = require("firebase-functions/v2/https");
const {
  onDocumentCreated,
  onDocumentUpdated,
} = require("firebase-functions/v2/firestore");
const {defineSecret} = require("firebase-functions/params");
const {onSchedule} = require("firebase-functions/v2/scheduler");

admin.initializeApp();

const smtpHost = defineSecret("SMTP_HOST");
const smtpPort = defineSecret("SMTP_PORT");
const smtpUser = defineSecret("SMTP_USER");
const smtpPass = defineSecret("SMTP_PASS");
const smtpFrom = defineSecret("SMTP_FROM");
const otpSecret = defineSecret("EMAIL_OTP_SECRET");

const OTP_TTL_MS = 10 * 60 * 1000;
const MAX_ATTEMPTS = 5;
const EMAIL_RESEND_DELAY_MS = 45_000;
const OWNER_BOOKING_REQUEST_CHANNEL = "pritze_owner_booking_requests_v3";
const LEGACY_OWNER_BOOKING_REQUEST_CHANNEL =
  "pritze_owner_booking_requests_v2";
const OWNER_BOOKING_REQUEST_SOUND = "owner_booking_request";
const IOS_OWNER_BOOKING_REQUEST_CATEGORY = "PRITZE_BOOKING_REQUEST_V2";
const OWNER_ALERT_REPEAT_DELAY_MS = 25_000;
const OWNER_ALERT_ATTEMPTS = 4;
const ANDROID_CURRENT_VERSION_CODE = 29;
const ANDROID_PLAY_STORE_URL =
  "https://play.google.com/store/apps/details?id=com.trimtime.app";
// Keep this aligned with the newest build that is publicly downloadable.
// Do not advance it merely because a newer build was uploaded for review.
const IOS_CURRENT_BUILD_NUMBER = 28;
const IOS_NEXT_VERSION = "1.0.16";
const IOS_NEXT_BUILD_NUMBER = 29;
const IOS_APP_STORE_LOOKUP_URL =
  "https://itunes.apple.com/lookup?id=6792811282&country=in";
const IOS_APP_STORE_URL =
  "https://apps.apple.com/in/app/pritze/id6792811282";

exports.getAndroidAppUpdate = onCall({invoker: "public"}, async () => {
  const snapshot = await admin.firestore()
    .collection("appConfig")
    .doc("android")
    .get();
  const configured = snapshot.data() || {};
  const latestVersionCode = positiveInteger(
    configured.latestVersionCode || configured.latestBuildNumber,
    ANDROID_CURRENT_VERSION_CODE,
  );
  const playStoreUrl = String(configured.playStoreUrl || "").trim() ||
    ANDROID_PLAY_STORE_URL;
  return {latestVersionCode, playStoreUrl};
});

exports.getIosAppUpdate = onCall({invoker: "public"}, async () => {
  const snapshot = await admin.firestore()
    .collection("appConfig")
    .doc("ios")
    .get();
  const configured = snapshot.data() || {};
  const configuredBuildNumber = positiveInteger(
    configured.latestBuildNumber || configured.latestVersionCode,
    IOS_CURRENT_BUILD_NUMBER,
  );
  let publicBuildNumber = IOS_CURRENT_BUILD_NUMBER;
  try {
    const response = await fetch(IOS_APP_STORE_LOOKUP_URL, {
      signal: AbortSignal.timeout(8000),
    });
    if (response.ok) {
      const payload = await response.json();
      const publicVersion = String(payload?.results?.[0]?.version || "");
      if (versionAtLeast(publicVersion, IOS_NEXT_VERSION)) {
        publicBuildNumber = IOS_NEXT_BUILD_NUMBER;
      }
    }
  } catch (error) {
    console.warn("App Store version lookup failed", {
      message: error?.message || String(error),
    });
  }
  const latestBuildNumber = publicBuildNumber >= IOS_NEXT_BUILD_NUMBER ?
    Math.max(configuredBuildNumber, publicBuildNumber) :
    Math.min(configuredBuildNumber, IOS_CURRENT_BUILD_NUMBER);
  const appStoreUrl = String(configured.appStoreUrl || "").trim() ||
    IOS_APP_STORE_URL;
  return {latestBuildNumber, appStoreUrl};
});

exports.createBooking = onCall({invoker: "public"}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const firestore = admin.firestore();
  const salonId = requiredId(request.data?.salonId, "salon id");
  const isInstant = request.data?.isInstant === true;
  const suppliedServiceIds = Array.isArray(request.data?.serviceIds) ?
    request.data.serviceIds : [];
  const serviceIds = [...new Set([
    ...suppliedServiceIds,
    request.data?.serviceId,
  ].map((value) => String(value ?? "").trim()).filter(Boolean))];
  if (serviceIds.length === 0 || serviceIds.length > 6) {
    throw new HttpsError(
      "invalid-argument",
      "Choose between 1 and 6 services.",
    );
  }
  if (!isInstant && serviceIds.length !== 1) {
    throw new HttpsError(
      "invalid-argument",
      "Scheduled appointments support one service at a time.",
    );
  }
  const serviceId = serviceIds[0];
  const arrivalMinutes = isInstant ? Number(request.data?.arrivalMinutes) : 0;
  const requestedStartMillis = Number(request.data?.startMillis);
  const requestedBarberId = String(request.data?.barberId ?? "").trim();
  if (isInstant && !INSTANT_ARRIVAL_MINUTES.has(arrivalMinutes)) {
    throw new HttpsError(
      "invalid-argument",
      "Choose an arrival time of 15, 20, or 25 minutes.",
    );
  }
  if (!isInstant && (!requestedBarberId || !Number.isFinite(requestedStartMillis))) {
    throw new HttpsError(
      "invalid-argument",
      "Choose an available barber and appointment time.",
    );
  }

  const userRef = firestore.collection("users").doc(uid);
  const salonRef = firestore.collection("salons").doc(salonId);
  const [userSnapshot, salonSnapshot] = await Promise.all([
    userRef.get(),
    salonRef.get(),
  ]);
  const user = userSnapshot.data();
  const salon = salonSnapshot.data();
  requireStoredRole(user, "customer");
  if (!salon || salon.isOpen !== true) {
    throw new HttpsError("failed-precondition", "This salon is not bookable.");
  }
  const ownerUid = String(salon.ownerUid ?? "").trim();
  if (!ownerUid) {
    throw new HttpsError(
      "failed-precondition",
      "This salon cannot receive bookings right now.",
    );
  }
  const services = serviceIds.map((id) => findSalonService(salon, id));
  if (services.some((service) => !service || service.isAvailable === false)) {
    throw new HttpsError(
      "failed-precondition",
      "One or more selected services are no longer available.",
    );
  }
  const durationMinutes = services.reduce(
    (total, service) => total + positiveInteger(service.durationMinutes, 30),
    0,
  );
  const nowMillis = Date.now();
  if (!isWithinSalonHours({
    startMillis: nowMillis,
    durationMinutes: 1,
    openTime: salon.openTime,
    closeTime: salon.closeTime,
  })) {
    throw new HttpsError(
      "failed-precondition",
      "This salon is currently closed.",
    );
  }
  const startMillis = isInstant ?
    nowMillis + arrivalMinutes * 60 * 1000 : requestedStartMillis;
  if (!isInstant && startMillis <= nowMillis) {
    throw new HttpsError(
      "failed-precondition",
      "Choose a future appointment time.",
    );
  }
  if (!isWithinSalonHours({
    startMillis,
    durationMinutes,
    openTime: salon.openTime,
    closeTime: salon.closeTime,
  })) {
    throw new HttpsError(
      "failed-precondition",
      "This appointment does not fit within salon hours.",
    );
  }

  const barbersSnapshot = await firestore
    .collection("barbers")
    .where("salonId", "==", salonId)
    .get();
  const eligibleBarbers = barbersSnapshot.docs
    .filter((doc) => serviceIds.every((id) => barberCanServe(doc.data(), id)))
    .sort((a, b) => a.id.localeCompare(b.id));
  if (eligibleBarbers.length === 0) {
    throw new HttpsError(
      "failed-precondition",
      "No barber is available for this service.",
    );
  }
  let scheduledBarber = null;
  if (isInstant) {
    if (services.some((service) => service.instantBookingEnabled === false) ||
        !isInstantEnabledForSalon(salon, nowMillis)) {
      throw new HttpsError(
        "failed-precondition",
        "This service is not available for instant booking.",
      );
    }
  } else {
    scheduledBarber = eligibleBarbers.find((doc) => doc.id === requestedBarberId);
    if (!scheduledBarber) {
      throw new HttpsError(
        "failed-precondition",
        "The selected barber is no longer available for this service.",
      );
    }
  }

  const bookingRef = firestore.collection("bookings").doc();
  const activeCustomerRef = firestore
    .collection("activeCustomerBookings")
    .doc(uid);
  const activeInstantRef = firestore
    .collection("activeInstantBookings")
    .doc(uid);
  const lockMillis = isInstant ? [] :
    slotSegmentMillis(startMillis, durationMinutes);
  const lockRefs = lockMillis.map((segmentMillis) => firestore
    .collection("slotLocks")
    .doc(slotLockId(requestedBarberId, segmentMillis)));
  const createdAt = admin.firestore.Timestamp.fromMillis(nowMillis);
  const start = admin.firestore.Timestamp.fromMillis(startMillis);
  const customerName = String(user.name ?? request.auth?.token?.name ?? "Customer")
    .trim() || "Customer";
  const customerPhone = normalizeVerifiedPhone(
    user.phone || user.contact || request.auth?.token?.phone_number,
  );
  if (!customerPhone) {
    throw new HttpsError(
      "failed-precondition",
      "A verified customer phone number is required to book.",
    );
  }
  const booking = {
    salonId,
    serviceId,
    serviceIds,
    barberId: isInstant ? "" : scheduledBarber.id,
    customerUid: uid,
    ownerUid,
    barberUid: isInstant ? null : normalizedOptionalString(scheduledBarber.data().uid),
    customerName,
    customerPhone,
    start,
    durationMinutes,
    serviceName: services
      .map((service) => String(service.name ?? "Service").trim() || "Service")
      .join(", "),
    servicePrice: services.reduce(
      (total, service) => total + Math.max(0, Number(service.price) || 0),
      0,
    ),
    bookingFee: 0,
    paymentRequired: false,
    paymentStatus: "not_required",
    status: isInstant ? "pending" : "confirmed",
    createdAt,
    isInstant,
    acceptedAt: null,
    arrivalMinutes,
    salonArrivalMinutes: isInstant ? arrivalMinutes + 5 : 0,
    cancellationReason: "",
    cancelledBy: "",
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  await firestore.runTransaction(async (transaction) => {
    const activeCustomer = await transaction.get(activeCustomerRef);
    const activeInstant = await transaction.get(activeInstantRef);
    await assertNoBlockingMarker(
      transaction,
      [activeCustomer, activeInstant],
      nowMillis,
    );
    const lockSnapshots = [];
    for (const lockRef of lockRefs) {
      lockSnapshots.push(await transaction.get(lockRef));
    }
    if (lockSnapshots.some((snapshot) =>
      snapshot.exists && snapshot.data()?.active !== false)) {
      throw new HttpsError(
        "already-exists",
        "This slot was just booked. Please choose another time.",
      );
    }

    transaction.create(bookingRef, booking);
    transaction.set(activeCustomerRef, activeBookingMarker({
      bookingId: bookingRef.id,
      salonId,
      customerUid: uid,
      isInstant,
      createdAt,
    }));
    transaction.set(activeInstantRef, isInstant ? activeBookingMarker({
      bookingId: bookingRef.id,
      salonId,
      customerUid: uid,
      isInstant: true,
      createdAt,
    }) : {
      active: false,
      customerUid: uid,
      resolvedStatus: "not_instant",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    for (let index = 0; index < lockRefs.length; index += 1) {
      transaction.set(lockRefs[index], slotLockData({
        bookingId: bookingRef.id,
        salonId,
        serviceId,
        barberId: requestedBarberId,
        segmentMillis: lockMillis[index],
        bookingStartMillis: startMillis,
        createdAt,
      }));
    }
  });

  return {bookingId: bookingRef.id};
});

exports.updateBookingStatus = onCall({invoker: "public"}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const bookingId = requiredId(request.data?.bookingId, "booking id");
  const nextStatus = String(request.data?.status ?? "").trim();
  const allowedStatuses = new Set([
    "confirmed",
    "inProgress",
    "completed",
    "cancelled",
    "rejected",
  ]);
  if (!allowedStatuses.has(nextStatus)) {
    throw new HttpsError("invalid-argument", "Invalid booking status.");
  }
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const initialBookingSnapshot = await bookingRef.get();
  const initialBooking = initialBookingSnapshot.data();
  if (!initialBooking) {
    throw new HttpsError("not-found", "Booking not found.");
  }
  let instantCandidates = [];
  if (
    initialBooking.isInstant === true &&
    initialBooking.status === "pending" &&
    nextStatus === "confirmed"
  ) {
    const barbers = await firestore.collection("barbers")
      .where("salonId", "==", initialBooking.salonId)
      .get();
    instantCandidates = barbers.docs
      .filter((doc) => bookingServiceIds(initialBooking)
        .every((serviceId) => barberCanServe(doc.data(), serviceId)))
      .sort((a, b) => a.id.localeCompare(b.id));
  }

  const nowMillis = Date.now();
  const acceptedStartMillis =
    initialBooking.isInstant === true &&
    initialBooking.status === "pending" &&
    nextStatus === "confirmed" ?
      nowMillis + positiveInteger(initialBooking.arrivalMinutes, 15) * 60 * 1000 :
      initialBooking.start?.toMillis?.();
  const cancellationReason = String(request.data?.cancellationReason ?? "")
    .trim();
  let actorRole = "";
  let updatedBooking = null;
  await firestore.runTransaction(async (transaction) => {
    const bookingSnapshot = await transaction.get(bookingRef);
    const actorSnapshot = await transaction.get(
      firestore.collection("users").doc(uid),
    );
    const booking = bookingSnapshot.data();
    if (!booking) {
      throw new HttpsError("not-found", "Booking not found.");
    }
    actorRole = normalizeRole(actorSnapshot.data()?.role) || "";
    if (
      (actorRole === "customer" && booking.customerUid !== uid) ||
      (actorRole === "owner" && booking.ownerUid !== uid) ||
      (actorRole !== "customer" && actorRole !== "owner")
    ) {
      throw new HttpsError("permission-denied", "Not allowed.");
    }
    const transitionError = bookingTransitionError({
      booking,
      actorRole,
      nextStatus,
      nowMillis,
    });
    if (transitionError) {
      throw new HttpsError("failed-precondition", transitionError);
    }

    let assignedBarber = null;
    const lockReads = new Map();
    if (
      booking.isInstant === true &&
      booking.status === "pending" &&
      nextStatus === "confirmed"
    ) {
      for (const barber of instantCandidates) {
        const candidateLocks = [];
        for (const segmentMillis of slotSegmentMillis(
          acceptedStartMillis,
          positiveInteger(booking.durationMinutes, 30),
        )) {
          const lockRef = firestore.collection("slotLocks")
            .doc(slotLockId(barber.id, segmentMillis));
          const lockSnapshot = await transaction.get(lockRef);
          lockReads.set(lockRef.path, lockSnapshot);
          candidateLocks.push(lockSnapshot);
        }
        if (candidateLocks.every((snapshot) =>
          !snapshot.exists || snapshot.data()?.active === false ||
          snapshot.data()?.bookingId === bookingId)) {
          assignedBarber = barber;
          break;
        }
      }
      if (!assignedBarber) {
        throw new HttpsError(
          "resource-exhausted",
          "No barber is free for this instant booking. Reject the request.",
        );
      }
    }

    const shouldReleaseLocks = ["cancelled", "rejected", "completed"]
      .includes(nextStatus);
    const previousLockRefs = [];
    const previousLockSnapshots = [];
    if (shouldReleaseLocks && String(booking.barberId ?? "").trim()) {
      for (const segmentMillis of slotSegmentMillis(
        booking.start.toMillis(),
        positiveInteger(booking.durationMinutes, 30),
      )) {
        const lockRef = firestore.collection("slotLocks")
          .doc(slotLockId(booking.barberId, segmentMillis));
        previousLockRefs.push(lockRef);
        const cached = lockReads.get(lockRef.path);
        previousLockSnapshots.push(cached || await transaction.get(lockRef));
      }
    }
    const activeCustomerRef = firestore.collection("activeCustomerBookings")
      .doc(booking.customerUid);
    const activeInstantRef = firestore.collection("activeInstantBookings")
      .doc(booking.customerUid);
    const isTerminal = ["cancelled", "rejected", "completed"]
      .includes(nextStatus);
    const activeCustomerSnapshot = isTerminal ?
      await transaction.get(activeCustomerRef) : null;
    const activeInstantSnapshot = isTerminal && booking.isInstant === true ?
      await transaction.get(activeInstantRef) : null;

    const update = {
      status: nextStatus,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (nextStatus === "confirmed" && booking.status === "pending") {
      update.acceptedAt = admin.firestore.FieldValue.serverTimestamp();
      update.start = admin.firestore.Timestamp.fromMillis(acceptedStartMillis);
      update.customerArrivalReminderSentAt = null;
      update.ownerArrivalReminderSentAt = null;
      update.barberId = assignedBarber.id;
      update.barberUid = normalizedOptionalString(assignedBarber.data().uid);
    }
    if (nextStatus === "inProgress") {
      update.startedAt = admin.firestore.FieldValue.serverTimestamp();
    }
    if (nextStatus === "completed") {
      update.completedAt = admin.firestore.FieldValue.serverTimestamp();
    }
    if (nextStatus === "cancelled") {
      update.cancelledBy = actorRole;
      update.cancellationReason = cancellationReason ||
        (actorRole === "owner" ? "Cancelled by salon" : "Cancelled by customer");
      update.cancelledAt = admin.firestore.FieldValue.serverTimestamp();
    }
    if (nextStatus === "rejected") {
      update.cancelledBy = "owner";
      update.cancellationReason = cancellationReason || "Rejected by salon";
      update.rejectedAt = admin.firestore.FieldValue.serverTimestamp();
    }
    transaction.update(bookingRef, update);

    if (assignedBarber) {
      const createdAt = booking.createdAt ||
        admin.firestore.Timestamp.fromMillis(nowMillis);
      for (const segmentMillis of slotSegmentMillis(
        acceptedStartMillis,
        positiveInteger(booking.durationMinutes, 30),
      )) {
        const lockRef = firestore.collection("slotLocks")
          .doc(slotLockId(assignedBarber.id, segmentMillis));
        transaction.set(lockRef, slotLockData({
          bookingId,
          salonId: booking.salonId,
          serviceId: booking.serviceId,
          barberId: assignedBarber.id,
          segmentMillis,
          bookingStartMillis: acceptedStartMillis,
          createdAt,
        }));
      }
    }
    for (let index = 0; index < previousLockRefs.length; index += 1) {
      if (previousLockSnapshots[index].data()?.bookingId === bookingId) {
        transaction.set(previousLockRefs[index], {
          active: false,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, {merge: true});
      }
    }
    if (activeCustomerSnapshot?.data()?.bookingId === bookingId) {
      transaction.set(activeCustomerRef, {
        active: false,
        resolvedStatus: nextStatus,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
    }
    if (activeInstantSnapshot?.data()?.bookingId === bookingId) {
      transaction.set(activeInstantRef, {
        active: false,
        resolvedStatus: nextStatus,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
    }
    updatedBooking = {...booking, ...update};
    if (assignedBarber) {
      updatedBooking.barberId = assignedBarber.id;
      updatedBooking.barberUid = normalizedOptionalString(assignedBarber.data().uid);
    }
  });

  const hydrated = await hydrateBookingRecipients(updatedBooking);
  const message = bookingStatusMessage(hydrated);
  const recipients = bookingStatusRecipients({}, hydrated);
  await sendToUsers(recipients, {
    title: message.title,
    body: message.body,
    data: bookingNotificationData(bookingId, hydrated),
    requiredActiveRolesByUser: bookingRecipientRoles(hydrated),
  });
  return {bookingId, status: nextStatus};
});

exports.rescheduleBooking = onCall({invoker: "public"}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const bookingId = requiredId(request.data?.bookingId, "booking id");
  const barberId = requiredId(request.data?.barberId, "barber id");
  const startMillis = Number(request.data?.startMillis);
  if (!Number.isFinite(startMillis)) {
    throw new HttpsError("invalid-argument", "Choose a new appointment time.");
  }
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const initial = (await bookingRef.get()).data();
  if (!initial) {
    throw new HttpsError("not-found", "Booking not found.");
  }
  const salonRef = firestore.collection("salons").doc(initial.salonId);
  const barberRef = firestore.collection("barbers").doc(barberId);
  const nowMillis = Date.now();
  let updatedBooking = null;
  await firestore.runTransaction(async (transaction) => {
    const bookingSnapshot = await transaction.get(bookingRef);
    const actorSnapshot = await transaction.get(
      firestore.collection("users").doc(uid),
    );
    const salonSnapshot = await transaction.get(salonRef);
    const barberSnapshot = await transaction.get(barberRef);
    const booking = bookingSnapshot.data();
    const salon = salonSnapshot.data();
    const barber = barberSnapshot.data();
    requireStoredRole(actorSnapshot.data(), "customer");
    if (!booking || booking.customerUid !== uid) {
      throw new HttpsError("permission-denied", "Not allowed.");
    }
    if (!canRescheduleBooking(booking, nowMillis)) {
      throw new HttpsError(
        "failed-precondition",
        "Rescheduling closes two hours before the appointment.",
      );
    }
    if (startMillis <= nowMillis) {
      throw new HttpsError("failed-precondition", "Choose a future time.");
    }
    if (!salon || !barberCanServe(barber, booking.serviceId) ||
        barber.salonId !== booking.salonId) {
      throw new HttpsError(
        "failed-precondition",
        "The selected barber is no longer available for this service.",
      );
    }
    const service = findSalonService(salon, booking.serviceId);
    const durationMinutes = positiveInteger(
      booking.durationMinutes || service?.durationMinutes,
      30,
    );
    if (!service || service.isAvailable === false || !isWithinSalonHours({
      startMillis,
      durationMinutes,
      openTime: salon.openTime,
      closeTime: salon.closeTime,
    })) {
      throw new HttpsError(
        "failed-precondition",
        "The selected appointment is no longer available.",
      );
    }

    const oldSegments = slotSegmentMillis(
      booking.start.toMillis(),
      durationMinutes,
    );
    const newSegments = slotSegmentMillis(startMillis, durationMinutes);
    const oldRefs = oldSegments.map((segmentMillis) => firestore
      .collection("slotLocks")
      .doc(slotLockId(booking.barberId, segmentMillis)));
    const newRefs = newSegments.map((segmentMillis) => firestore
      .collection("slotLocks")
      .doc(slotLockId(barberId, segmentMillis)));
    const oldSnapshots = [];
    const newSnapshots = [];
    for (const ref of oldRefs) {
      oldSnapshots.push(await transaction.get(ref));
    }
    for (const ref of newRefs) {
      newSnapshots.push(await transaction.get(ref));
    }
    if (newSnapshots.some((snapshot) =>
      snapshot.exists && snapshot.data()?.active !== false &&
      snapshot.data()?.bookingId !== bookingId)) {
      throw new HttpsError(
        "already-exists",
        "This slot was just booked. Please choose another time.",
      );
    }

    transaction.update(bookingRef, {
      barberId,
      barberUid: normalizedOptionalString(barber.uid),
      start: admin.firestore.Timestamp.fromMillis(startMillis),
      rescheduledAt: admin.firestore.FieldValue.serverTimestamp(),
      rescheduledFrom: booking.start,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    for (let index = 0; index < oldRefs.length; index += 1) {
      if (oldSnapshots[index].data()?.bookingId === bookingId) {
        transaction.set(oldRefs[index], {
          active: false,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, {merge: true});
      }
    }
    const createdAt = booking.createdAt ||
      admin.firestore.Timestamp.fromMillis(nowMillis);
    for (let index = 0; index < newRefs.length; index += 1) {
      transaction.set(newRefs[index], slotLockData({
        bookingId,
        salonId: booking.salonId,
        serviceId: booking.serviceId,
        barberId,
        segmentMillis: newSegments[index],
        bookingStartMillis: startMillis,
        createdAt,
      }));
    }
    updatedBooking = {
      ...booking,
      barberId,
      barberUid: normalizedOptionalString(barber.uid),
      start: admin.firestore.Timestamp.fromMillis(startMillis),
    };
  });

  const hydrated = await hydrateBookingRecipients(updatedBooking);
  await sendToUsers([hydrated.ownerUid].filter(Boolean), {
    title: "Booking rescheduled",
    body: `${hydrated.customerName || "A customer"} rescheduled ${hydrated.serviceName || "a service"}.`,
    data: bookingNotificationData(bookingId, hydrated),
    requiredActiveRolesByUser: bookingRecipientRoles(hydrated),
  });
  return {bookingId};
});

exports.sendBookingPush = onCall({invoker: "public"}, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }

  const bookingId = String(request.data?.bookingId ?? "").trim();
  const event = String(request.data?.event ?? "").trim();
  if (!bookingId) {
    throw new HttpsError("invalid-argument", "Missing booking id.");
  }

  const snapshot = await admin.firestore()
    .collection("bookings")
    .doc(bookingId)
    .get();
  const booking = await hydrateBookingRecipients(snapshot.data());
  if (!booking) {
    throw new HttpsError("not-found", "Booking not found.");
  }

  const participants = [
    booking.customerUid,
    booking.ownerUid,
    booking.barberUid,
  ].filter(Boolean);
  if (!participants.includes(uid)) {
    throw new HttpsError("permission-denied", "Not allowed.");
  }

  return {
    ok: true,
    event,
    handledBy: "authoritativeBookingWorkflow",
  };
});

exports.alertOwnerOnBookingCreated = onDocumentCreated(
  {
    document: "bookings/{bookingId}",
    timeoutSeconds: 120,
    memory: "256MiB",
  },
  async (event) => {
    const bookingId = event.params.bookingId;
    const bookingRef = event.data?.ref;
    if (!bookingRef) {
      return;
    }
    const createdBooking = event.data?.data();
    const hydratedCreatedBooking = await hydrateBookingRecipients(
      createdBooking,
    );
    const customerDeliveryPromise = sendToUsers(
      [hydratedCreatedBooking?.customerUid].filter(Boolean),
      {
        title: createdBooking?.isInstant === true ?
          "Instant booking request sent" : "Booking confirmed",
        body: createdBooking?.isInstant === true ?
          `${createdBooking.serviceName || "Your service"} was sent to the salon. Your reach-by time will appear after the salon accepts.` :
          `${createdBooking?.serviceName || "Your service"} is booked for your selected appointment time.`,
        data: {
          ...bookingNotificationData(bookingId, createdBooking || {}),
          event: "created",
        },
        requiredActiveRolesByUser: bookingRecipientRoles(
          hydratedCreatedBooking || {},
        ),
      },
    );
    if (
      createdBooking?.isInstant !== true &&
      createdBooking?.status === "confirmed"
    ) {
      const booking = hydratedCreatedBooking;
      const [delivery] = await Promise.all([
        sendToUsers([booking.ownerUid].filter(Boolean), {
        title: "New scheduled booking",
        body: `${booking.customerName || "A customer"} booked ${booking.serviceName || "a service"}.`,
        data: bookingNotificationData(bookingId, booking),
        requiredActiveRolesByUser: bookingRecipientRoles(booking),
        }),
        customerDeliveryPromise,
      ]);
      console.log("scheduled booking delivered", {bookingId, delivery});
      return;
    }
    if (
      createdBooking?.isInstant !== true ||
      createdBooking?.status !== "pending"
    ) {
      return;
    }
    const claimed = await claimOwnerBookingAlert(bookingRef, event.id);
    if (!claimed) {
      await customerDeliveryPromise;
      return;
    }

    for (let attempt = 0; attempt < OWNER_ALERT_ATTEMPTS; attempt += 1) {
      if (attempt > 0) {
        await delay(OWNER_ALERT_REPEAT_DELAY_MS);
      }
      const snapshot = await bookingRef.get();
      const current = snapshot.data();
      if (
        !current ||
        current.isInstant !== true ||
        current.status !== "pending"
      ) {
        console.log("owner booking alert stopped", {
          bookingId,
          status: current?.status || "deleted",
          attempt,
        });
        await customerDeliveryPromise;
        return;
      }
      const booking = await hydrateBookingRecipients(current);
      const ownerDelivery = await sendOwnerBookingRequest(
        bookingId,
        booking,
        attempt,
      );
      if (attempt === 0) {
        const customerArrivalMinutes = booking.arrivalMinutes || 15;
        const salonArrivalMinutes =
          booking.salonArrivalMinutes || customerArrivalMinutes + 5;
        await sendToUsers([booking.barberUid].filter(Boolean), {
          title: "Instant booking assigned",
          body: `${booking.serviceName || "A service"} is assigned. Customer ETA ${customerArrivalMinutes} min; salon window ${salonArrivalMinutes} min.`,
          data: bookingNotificationData(bookingId, booking),
          requiredActiveRolesByUser: bookingRecipientRoles(booking),
        });
      }
      console.log("owner booking alert delivered", {
        bookingId,
        attempt: attempt + 1,
        delivery: ownerDelivery,
      });
    }
    await customerDeliveryPromise;
  },
);

exports.stopOwnerAlertOnBookingResolved = onDocumentUpdated(
  {
    document: "bookings/{bookingId}",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (
      !before ||
      !after ||
      before.status !== "pending" ||
      after.status === "pending" ||
      after.isInstant !== true
    ) {
      return;
    }
    const booking = await hydrateBookingRecipients(after);
    const ownerUid = String(booking.ownerUid ?? "").trim();
    if (ownerUid) {
      const ownerBookings = await admin.firestore()
        .collection("bookings")
        .where("ownerUid", "==", ownerUid)
        .get();
      const remainingRequests = ownerBookings.docs
        .filter((doc) => doc.id !== event.params.bookingId)
        .filter((doc) => {
          const data = doc.data();
          return data.isInstant === true && data.status === "pending";
        })
        .sort((left, right) => {
          const leftMillis = left.data().createdAt?.toMillis?.() || 0;
          const rightMillis = right.data().createdAt?.toMillis?.() || 0;
          return leftMillis - rightMillis;
        });
      if (remainingRequests.length > 0) {
        const next = remainingRequests[0];
        const nextBooking = await hydrateBookingRecipients(next.data());
        const delivery = await sendOwnerBookingRequest(
          next.id,
          nextBooking,
          0,
        );
        console.log("owner booking alert continued", {
          resolvedBookingId: event.params.bookingId,
          nextBookingId: next.id,
          delivery,
        });
        return;
      }
    }
    const delivery = await sendToUsers([booking.ownerUid].filter(Boolean), {
      title: "",
      body: "",
      data: {
        type: "bookingAlertControl",
        action: "stop_owner_booking_alarm",
        bookingId: event.params.bookingId,
        status: after.status || "",
      },
      androidDataOnly: true,
      controlOnly: true,
      collapseKey: `booking-${event.params.bookingId}`,
      tokenField: "ownerAlertV3Tokens",
    });
    console.log("owner booking alert stop delivered", {
      bookingId: event.params.bookingId,
      status: after.status,
      delivery,
    });
  },
);

exports.sendBookingArrivalReminders = onSchedule(
  {
    schedule: "every 1 minutes",
    timeZone: "Asia/Kolkata",
    timeoutSeconds: 120,
    memory: "256MiB",
  },
  async () => {
    const firestore = admin.firestore();
    const nowMillis = Date.now();
    const lowerBound = admin.firestore.Timestamp.fromMillis(
      nowMillis - 60 * 1000,
    );
    const upperBound = admin.firestore.Timestamp.fromMillis(
      nowMillis + 31 * 60 * 1000,
    );
    const snapshot = await firestore.collection("bookings")
      .where("start", ">=", lowerBound)
      .where("start", "<=", upperBound)
      .get();

    const tasks = [];
    for (const document of snapshot.docs) {
      const booking = document.data();
      for (const audience of ["customer", "owner"]) {
        if (!bookingArrivalReminderDue({booking, audience, nowMillis})) {
          continue;
        }
        tasks.push(sendClaimedArrivalReminder({
          bookingRef: document.ref,
          bookingId: document.id,
          audience,
          nowMillis,
        }));
      }
    }
    const results = await Promise.allSettled(tasks);
    for (const result of results) {
      if (result.status === "rejected") {
        console.error("booking arrival reminder failed", result.reason);
      }
    }
    console.log("booking arrival reminders checked", {
      candidateCount: snapshot.size,
      reminderCount: tasks.length,
    });
  },
);

exports.sendJoinRequestPush = onCall({invoker: "public"}, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }

  const requestId = String(request.data?.requestId ?? "").trim();
  const event = String(request.data?.event ?? "").trim();
  if (!requestId) {
    throw new HttpsError("invalid-argument", "Missing request id.");
  }

  const snapshot = await admin.firestore()
    .collection("joinRequests")
    .doc(requestId)
    .get();
  const joinRequest = snapshot.data();
  if (!joinRequest) {
    throw new HttpsError("not-found", "Request not found.");
  }

  const participants = [
    joinRequest.requesterUid,
    joinRequest.ownerUid,
  ].filter(Boolean);
  if (!participants.includes(uid)) {
    throw new HttpsError("permission-denied", "Not allowed.");
  }

  let recipients;
  let title;
  let body;
  if (event === "created") {
    recipients = [joinRequest.ownerUid];
    title = "New barber request";
    body = `${joinRequest.barberName || "A barber"} wants to join your salon.`;
  } else if (event === "withdrawn" || joinRequest.status === "withdrawn") {
    recipients = [joinRequest.ownerUid];
    title = "Barber request withdrawn";
    body = `${joinRequest.barberName || "A barber"} withdrew the join request.`;
  } else {
    recipients = [joinRequest.requesterUid];
    title = joinRequest.status === "approved"
      ? "Salon request accepted"
      : "Salon request rejected";
    body = joinRequest.status === "approved"
      ? "Your barber request was accepted. You can now see assigned bookings."
      : "Your barber request was rejected by the salon.";
  }

  const delivery = await sendToUsers(recipients.filter((id) => id && id !== uid), {
    title,
    body,
    data: {
      type: "joinRequest",
      requestId,
      salonId: joinRequest.salonId || "",
      status: joinRequest.status || "",
      destination: "team",
    },
  });
  console.log("sendJoinRequestPush", {
    requestId,
    recipients: recipients.filter((id) => id && id !== uid),
    delivery,
  });
  return {ok: true, delivery};
});

exports.sendEmailOtp = onCall(
  {
    enforceAppCheck: true,
    invoker: "public",
    secrets: [smtpHost, smtpPort, smtpUser, smtpPass, smtpFrom, otpSecret],
  },
  async (request) => {
    const email = normalizeEmail(request.data?.email);
    if (!email) {
      throw new HttpsError("invalid-argument", "Enter a valid email address.");
    }

    const docRef = admin.firestore().collection("emailOtps").doc(emailKey(email));
    const now = Date.now();
    const code = crypto.randomInt(100000, 1000000).toString();
    const expiresAt = admin.firestore.Timestamp.fromMillis(now + OTP_TTL_MS);
    const codeHash = hashCode(email, code);
    await admin.firestore().runTransaction(async (transaction) => {
      const snapshot = await transaction.get(docRef);
      const previous = snapshot.data();
      if (
        previous?.sentAt?.toMillis &&
        now - previous.sentAt.toMillis() < EMAIL_RESEND_DELAY_MS
      ) {
        throw new HttpsError(
          "resource-exhausted",
          "Please wait before requesting another email OTP.",
        );
      }
      transaction.set(docRef, {
        email,
        codeHash,
        attempts: 0,
        sentAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt,
      });
    });

    try {
      await sendOtpMail(email, code);
    } catch (error) {
      await docRef.delete();
      console.error("sendEmailOtp delivery failed", {
        emailDomain: email.split("@").pop(),
        error: error.message,
      });
      throw new HttpsError(
        "unavailable",
        "The email could not be sent. Please try again.",
      );
    }
    console.log("sendEmailOtp delivered", {
      emailDomain: email.split("@").pop(),
    });
    return {ok: true};
  },
);

exports.verifyEmailOtp = onCall(
  {enforceAppCheck: true, invoker: "public", secrets: [otpSecret]},
  async (request) => {
    const email = normalizeEmail(request.data?.email);
    const code = String(request.data?.code ?? "").trim();
    if (!email || !/^\d{6}$/.test(code)) {
      throw new HttpsError("invalid-argument", "Enter the 6-digit email OTP.");
    }

    const docRef = admin.firestore().collection("emailOtps").doc(emailKey(email));
    const verification = await admin.firestore().runTransaction(async (
      transaction,
    ) => {
      const snapshot = await transaction.get(docRef);
      const data = snapshot.data();
      if (!data) {
        return {code: "not-found", message: "Request a new email OTP."};
      }
      if (!data.expiresAt?.toMillis || data.expiresAt.toMillis() < Date.now()) {
        transaction.delete(docRef);
        return {
          code: "deadline-exceeded",
          message: "This email OTP expired.",
        };
      }
      if ((data.attempts ?? 0) >= MAX_ATTEMPTS) {
        transaction.delete(docRef);
        return {
          code: "resource-exhausted",
          message: "Too many OTP attempts.",
        };
      }
      if (data.codeHash !== hashCode(email, code)) {
        transaction.update(docRef, {
          attempts: admin.firestore.FieldValue.increment(1),
        });
        return {
          code: "permission-denied",
          message: "Incorrect email OTP.",
        };
      }
      transaction.delete(docRef);
      return {code: "ok", message: ""};
    });
    if (verification.code !== "ok") {
      throw new HttpsError(verification.code, verification.message);
    }

    try {
      const user = await getOrCreateEmailUser(email);
      const customToken = await admin.auth().createCustomToken(user.uid, {
        provider: "email_otp",
      });
      console.log("verifyEmailOtp succeeded", {
        uid: user.uid,
        emailDomain: email.split("@").pop(),
      });
      return {customToken};
    } catch (error) {
      if (error.code === "auth/insufficient-permission") {
        throw new HttpsError(
          "failed-precondition",
          "Email OTP sign-in needs the Cloud Function service account to have Service Account Token Creator permission.",
        );
      }
      throw error;
    }
  },
);

exports.claimLoginRole = onCall(
  {enforceAppCheck: false, invoker: "public"},
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in first.");
    }

    const requestedRole = String(request.data?.role ?? "").trim();
    if (requestedRole !== "customer" && requestedRole !== "owner") {
      throw new HttpsError(
        "invalid-argument",
        "Login role must be customer or owner.",
      );
    }

    const token = request.auth.token ?? {};
    const authPhone = normalizeVerifiedPhone(token.phone_number);
    const normalizedSuppliedPhone = normalizeVerifiedPhone(
      request.data?.phone,
    );
    const suppliedPhone = /^\+91\d{10}$/.test(normalizedSuppliedPhone) ?
      normalizedSuppliedPhone : "";
    const signInProvider = String(
      token.firebase?.sign_in_provider ?? "",
    ).trim();
    const googleIdentities = token.firebase?.identities?.["google.com"];
    const hasGoogleIdentity = Array.isArray(googleIdentities) &&
      googleIdentities.length > 0;
    const canSupplyCustomerPhone =
      requestedRole === "customer" &&
      (signInProvider === "google.com" || hasGoogleIdentity);
    const phone = authPhone || (canSupplyCustomerPhone ? suppliedPhone : "");
    const email = normalizeEmail(token.email);
    const name = normalizeDisplayName(request.data?.name);
    const provider = normalizeLoginProvider(request.data?.provider, phone);
    if (requestedRole === "customer" && !phone) {
      throw new HttpsError(
        "failed-precondition",
        signInProvider === "google.com" ?
          "Enter a valid 10-digit Indian mobile number." :
          "Customers must sign in with a verified phone number.",
      );
    }
    const firestore = admin.firestore();
    const userRef = firestore.collection("users").doc(uid);
    const phoneRef = phone ?
      firestore.collection("loginIdentifiers").doc(phoneKey(phone)) :
      null;
    const ownerSalons = await firestore
      .collection("salons")
      .where("ownerUid", "==", uid)
      .limit(1)
      .get();

    const claim = await firestore.runTransaction(async (transaction) => {
      const userSnapshot = await transaction.get(userRef);
      const phoneSnapshot = phoneRef ? await transaction.get(phoneRef) : null;
      const storedRole = inferStoredRole(
        userSnapshot.data(),
        !ownerSalons.empty,
      );
      const claimedPhoneRole = normalizeRole(phoneSnapshot?.data()?.role);

      if (storedRole && storedRole !== requestedRole) {
        throw loginRoleConflict(requestedRole, storedRole, Boolean(phone));
      }
      if (claimedPhoneRole && claimedPhoneRole !== requestedRole) {
        throw loginRoleConflict(requestedRole, claimedPhoneRole, true);
      }
      if (phoneSnapshot?.exists && phoneSnapshot.data()?.uid !== uid) {
        throw new HttpsError(
          "already-exists",
          sameRolePhoneConflictMessage(requestedRole),
        );
      }

      const storedName = normalizeDisplayName(userSnapshot.data()?.name);
      const resolvedName = resolveClaimName({
        requestedRole,
        requestedName: name,
        storedRole,
        storedName,
        email,
      });
      if (requestedRole === "customer" && !resolvedName) {
        return {
          role: requestedRole,
          name: "",
          requiresName: true,
        };
      }

      const contact = phone || email;
      transaction.set(userRef, {
        role: requestedRole,
        roles: [requestedRole],
        activeRole: requestedRole,
        name: resolvedName,
        contact,
        email: email || null,
        phone: phone || null,
        provider,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});

      if (phoneRef) {
        transaction.set(phoneRef, {
          phone,
          role: requestedRole,
          uid,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      return {
        role: requestedRole,
        name: resolvedName,
        requiresName: false,
      };
    });

    return claim;
  },
);

exports.claimOwnerProfilePhone = onCall(
  {enforceAppCheck: false, invoker: "public"},
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in first.");
    }

    const phone = normalizeVerifiedPhone(request.data?.phone);
    if (!phone) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a valid salon phone number.",
      );
    }

    const firestore = admin.firestore();
    const userRef = firestore.collection("users").doc(uid);
    const phoneRef = firestore
      .collection("loginIdentifiers")
      .doc(phoneKey(phone));
    const ownerSalons = await firestore
      .collection("salons")
      .where("ownerUid", "==", uid)
      .limit(1)
      .get();
    const salonsUsingPhone = await firestore
      .collection("salons")
      .where("phone", "==", phone)
      .limit(2)
      .get();
    if (salonsUsingPhone.docs.some((doc) => doc.data().ownerUid !== uid)) {
      throw new HttpsError(
        "already-exists",
        "Unable to save this salon because this phone number is already " +
          "registered to another salon owner account.",
      );
    }

    let phoneAuthUser = null;
    try {
      phoneAuthUser = await admin.auth().getUserByPhoneNumber(phone);
    } catch (error) {
      if (error.code !== "auth/user-not-found") {
        throw error;
      }
    }
    const otherUserRef = phoneAuthUser && phoneAuthUser.uid !== uid ?
      firestore.collection("users").doc(phoneAuthUser.uid) :
      null;

    await firestore.runTransaction(async (transaction) => {
      const userSnapshot = await transaction.get(userRef);
      const phoneSnapshot = await transaction.get(phoneRef);
      const otherUserSnapshot = otherUserRef ?
        await transaction.get(otherUserRef) :
        null;
      const userData = userSnapshot.data() ?? {};
      const storedRole = inferStoredRole(userData, !ownerSalons.empty);
      if (storedRole !== "owner") {
        throw new HttpsError(
          "permission-denied",
          "Only a signed-in salon owner can save a salon phone number.",
        );
      }

      const claimedPhoneRole = normalizeRole(phoneSnapshot.data()?.role);
      if (claimedPhoneRole === "customer") {
        throw new HttpsError(
          "already-exists",
          "Unable to save this salon because this phone number is already " +
            "registered as a customer.",
        );
      }
      if (phoneSnapshot.exists && phoneSnapshot.data()?.uid !== uid) {
        throw new HttpsError(
          "already-exists",
          "Unable to save this salon because this phone number is already " +
            "registered to another salon owner account.",
        );
      }

      const phoneAlreadyClaimedByThisOwner =
        phoneSnapshot.exists &&
        claimedPhoneRole === "owner" &&
        phoneSnapshot.data()?.uid === uid;
      if (otherUserSnapshot && !phoneAlreadyClaimedByThisOwner) {
        const otherRole = inferStoredRole(otherUserSnapshot.data(), false);
        if (otherRole === "customer") {
          throw new HttpsError(
            "already-exists",
            "Unable to save this salon because this phone number is already " +
              "registered as a customer.",
          );
        }
        throw new HttpsError(
          "already-exists",
          "Unable to save this salon because this phone number belongs to " +
            "another account.",
        );
      }

      const previousProfilePhone = normalizeVerifiedPhone(
        userData.profilePhone,
      );
      let previousPhoneRef = null;
      let previousPhoneSnapshot = null;
      if (previousProfilePhone && previousProfilePhone !== phone) {
        previousPhoneRef = firestore
          .collection("loginIdentifiers")
          .doc(phoneKey(previousProfilePhone));
        previousPhoneSnapshot = await transaction.get(previousPhoneRef);
      }

      transaction.set(userRef, {
        profilePhone: phone,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.set(phoneRef, {
        phone,
        role: "owner",
        uid,
        source: "salon_profile",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      const authPhone = normalizeVerifiedPhone(userData.phone);
      if (
        previousPhoneRef &&
        previousProfilePhone !== authPhone &&
        previousPhoneSnapshot?.data()?.uid === uid
      ) {
        transaction.delete(previousPhoneRef);
      }
    });

    return {phone, role: "owner"};
  },
);

exports.updateCustomerProfile = onCall(
  {enforceAppCheck: false, invoker: "public"},
  async (request) => {
    const uid = requireAuthenticatedUid(request);
    const name = normalizeDisplayName(request.data?.name);
    const phone = normalizeVerifiedPhone(request.data?.phone);
    const gender = normalizeProfileGender(request.data?.gender);
    const birthDate = normalizeBirthDate(request.data?.birthDate);
    const preferredStyles = sanitizeShortList(request.data?.preferredStyles);
    const stylePhotoUrls = sanitizePhotoUrls(request.data?.stylePhotoUrls);
    const photoUrl = sanitizePhotoUrls([request.data?.photoUrl], 1)[0] || "";
    if (!name) {
      throw new HttpsError("invalid-argument", "Enter your name.");
    }
    if (!/^\+91\d{10}$/.test(phone)) {
      throw new HttpsError(
        "invalid-argument",
        "Enter a valid 10-digit Indian mobile number.",
      );
    }
    if (gender === null || birthDate === null) {
      throw new HttpsError("invalid-argument", "Check your profile details.");
    }

    const firestore = admin.firestore();
    const userRef = firestore.collection("users").doc(uid);
    const userSnapshot = await userRef.get();
    const userData = userSnapshot.data();
    requireStoredRole(userData, "customer");
    const oldPhone = normalizeVerifiedPhone(userData?.phone || userData?.contact);
    const newPhoneRef = firestore.collection("loginIdentifiers").doc(phoneKey(phone));

    let phoneAuthUser = null;
    try {
      phoneAuthUser = await admin.auth().getUserByPhoneNumber(phone);
    } catch (error) {
      if (error.code !== "auth/user-not-found") throw error;
    }
    if (phoneAuthUser && phoneAuthUser.uid !== uid) {
      throw new HttpsError(
        "already-exists",
        "This phone number already belongs to another account.",
      );
    }

    await firestore.runTransaction(async (transaction) => {
      const latestUser = await transaction.get(userRef);
      const phoneSnapshot = await transaction.get(newPhoneRef);
      requireStoredRole(latestUser.data(), "customer");
      const claimedRole = normalizeRole(phoneSnapshot.data()?.role);
      if (claimedRole === "owner") {
        throw new HttpsError(
          "already-exists",
          "Unable to save this number because it is already registered as a salon owner.",
        );
      }
      if (phoneSnapshot.exists && phoneSnapshot.data()?.uid !== uid) {
        throw new HttpsError(
          "already-exists",
          "This phone number already belongs to another customer.",
        );
      }

      let oldPhoneRef = null;
      let oldPhoneSnapshot = null;
      if (oldPhone && oldPhone !== phone) {
        oldPhoneRef = firestore.collection("loginIdentifiers")
          .doc(phoneKey(oldPhone));
        oldPhoneSnapshot = await transaction.get(oldPhoneRef);
      }

      transaction.set(userRef, {
        name,
        contact: phone,
        phone,
        gender,
        birthDate,
        preferredStyles,
        photoUrl,
        stylePhotoUrls,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      transaction.set(newPhoneRef, {
        phone,
        role: "customer",
        uid,
        source: "customer_profile",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      if (oldPhoneRef && oldPhoneSnapshot?.data()?.uid === uid) {
          transaction.delete(oldPhoneRef);
      }
    });

    await admin.auth().updateUser(uid, {displayName: name, phoneNumber: phone});
    return {name, phone};
  },
);

exports.submitSalonFeedback = onCall({invoker: "public"}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const bookingId = requiredId(request.data?.bookingId, "booking id");
  const rating = normalizeVisitRating(request.data?.rating);
  const note = normalizeFeedbackNote(request.data?.note);
  if (rating === null) {
    throw new HttpsError("invalid-argument", "Choose a rating from 1 to 5.");
  }
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const feedbackRef = firestore.collection("salonFeedback").doc(bookingId);
  await firestore.runTransaction(async (transaction) => {
    const bookingSnapshot = await transaction.get(bookingRef);
    const userSnapshot = await transaction.get(
      firestore.collection("users").doc(uid),
    );
    const booking = bookingSnapshot.data();
    requireStoredRole(userSnapshot.data(), "customer");
    if (!booking || booking.customerUid !== uid || booking.status !== "completed") {
      throw new HttpsError(
        "failed-precondition",
        "Feedback is available after a completed appointment.",
      );
    }
    const salonRef = firestore.collection("salons").doc(booking.salonId);
    const salonSnapshot = await transaction.get(salonRef);
    const existing = await transaction.get(feedbackRef);
    const salon = salonSnapshot.data() || {};
    const oldRating = Number(existing.data()?.rating || 0);
    const currentCount = Number(salon.reviewCount || 0);
    const nextCount = existing.exists ? Math.max(1, currentCount) : currentCount + 1;
    const nextTotal = Number(salon.rating || 0) * currentCount - oldRating + rating;
    transaction.set(feedbackRef, {
      bookingId,
      customerUid: uid,
      ownerUid: booking.ownerUid,
      salonId: booking.salonId,
      salonName: String(salon.name || "Salon"),
      rating,
      note,
      createdAt: existing.data()?.createdAt ||
        admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    transaction.set(salonRef, {
      rating: nextTotal / nextCount,
      reviewCount: nextCount,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
  });
  return {bookingId, rating};
});

exports.submitCustomerRating = onCall({invoker: "public"}, async (request) => {
  const uid = requireAuthenticatedUid(request);
  const bookingId = requiredId(request.data?.bookingId, "booking id");
  const rating = normalizeVisitRating(request.data?.rating);
  const note = normalizeFeedbackNote(request.data?.note);
  if (rating === null) {
    throw new HttpsError("invalid-argument", "Choose a rating from 1 to 5.");
  }
  const firestore = admin.firestore();
  const bookingRef = firestore.collection("bookings").doc(bookingId);
  const ratingRef = firestore.collection("customerRatings").doc(bookingId);
  await firestore.runTransaction(async (transaction) => {
    const bookingSnapshot = await transaction.get(bookingRef);
    const ownerSnapshot = await transaction.get(
      firestore.collection("users").doc(uid),
    );
    const booking = bookingSnapshot.data();
    requireStoredRole(ownerSnapshot.data(), "owner");
    if (!booking || booking.ownerUid !== uid || booking.status !== "completed") {
      throw new HttpsError(
        "failed-precondition",
        "Customer ratings are available after completed visits.",
      );
    }
    const customerUid = String(booking.customerUid || "").trim();
    if (!customerUid) {
      throw new HttpsError("failed-precondition", "Customer account not found.");
    }
    const customerRef = firestore.collection("users").doc(customerUid);
    const salonRef = firestore.collection("salons").doc(booking.salonId);
    const customerSnapshot = await transaction.get(customerRef);
    const salonSnapshot = await transaction.get(salonRef);
    const existing = await transaction.get(ratingRef);
    requireStoredRole(customerSnapshot.data(), "customer");
    const customer = customerSnapshot.data() || {};
    const oldRating = Number(existing.data()?.rating || 0);
    const currentCount = Number(customer.salonRatingCount || 0);
    const nextCount = existing.exists ? Math.max(1, currentCount) : currentCount + 1;
    const nextTotal = Number(customer.salonRating || 0) * currentCount - oldRating + rating;
    transaction.set(ratingRef, {
      bookingId,
      customerUid,
      ownerUid: uid,
      salonId: booking.salonId,
      salonName: String(salonSnapshot.data()?.name || "Salon"),
      rating,
      note,
      createdAt: existing.data()?.createdAt ||
        admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
    transaction.set(customerRef, {
      salonRating: nextTotal / nextCount,
      salonRatingCount: nextCount,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
  });
  return {bookingId, rating};
});

function requireAuthenticatedUid(request) {
  const uid = String(request.auth?.uid ?? "").trim();
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }
  return uid;
}

function requiredId(value, label) {
  const id = String(value ?? "").trim();
  if (!id) {
    throw new HttpsError("invalid-argument", `Missing ${label}.`);
  }
  return id;
}

function requireStoredRole(user, expectedRole) {
  if (normalizeRole(user?.role) !== expectedRole) {
    throw new HttpsError(
      "permission-denied",
      `Only a signed-in ${expectedRole} can perform this action.`,
    );
  }
}

function positiveInteger(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : fallback;
}

function versionAtLeast(value, minimum) {
  const parts = (version) => String(version || "")
    .split(/[+-]/, 1)[0]
    .split(".")
    .map((part) => Number.parseInt(part, 10) || 0);
  const actual = parts(value);
  const required = parts(minimum);
  const length = Math.max(actual.length, required.length);
  for (let index = 0; index < length; index++) {
    const actualPart = actual[index] || 0;
    const requiredPart = required[index] || 0;
    if (actualPart !== requiredPart) {
      return actualPart > requiredPart;
    }
  }
  return true;
}

function normalizedOptionalString(value) {
  const text = String(value ?? "").trim();
  return text || null;
}

function findSalonService(salon, serviceId) {
  const services = Array.isArray(salon?.services) ? salon.services : [];
  return services.find((service) => String(service?.id ?? "") === serviceId) ||
    null;
}

function barberCanServe(barber, serviceId) {
  return Boolean(
    barber &&
    barber.isActive !== false &&
    Array.isArray(barber.serviceIds) &&
    barber.serviceIds.includes(serviceId)
  );
}

function bookingServiceIds(booking) {
  const supplied = Array.isArray(booking?.serviceIds) ? booking.serviceIds : [];
  return [...new Set([
    ...supplied,
    booking?.serviceId,
  ].map((value) => String(value ?? "").trim()).filter(Boolean))];
}

function isInstantEnabledForSalon(salon, nowMillis) {
  if (salon.instantBookingsEnabled !== false) {
    return true;
  }
  const pausedDate = String(salon.instantBookingsPausedDate ?? "").trim();
  return !pausedDate ||
    pausedDate !== zonedDateParts(new Date(nowMillis)).dateKey;
}

function slotLockId(barberId, segmentMillis) {
  return `${barberId}_${segmentMillis}`;
}

function activeBookingMarker({
  bookingId,
  salonId,
  customerUid,
  isInstant,
  createdAt,
}) {
  return {
    active: true,
    bookingId,
    salonId,
    customerUid,
    isInstant,
    createdAt,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

function slotLockData({
  bookingId,
  salonId,
  serviceId,
  barberId,
  segmentMillis,
  bookingStartMillis,
  createdAt,
}) {
  return {
    bookingId,
    salonId,
    serviceId,
    barberId,
    start: admin.firestore.Timestamp.fromMillis(segmentMillis),
    bookingStart: admin.firestore.Timestamp.fromMillis(bookingStartMillis),
    active: true,
    createdAt,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

async function assertNoBlockingMarker(transaction, markerSnapshots, nowMillis) {
  const bookingIds = [...new Set(markerSnapshots
    .filter((snapshot) => snapshot.data()?.active === true)
    .map((snapshot) => String(snapshot.data()?.bookingId ?? "").trim())
    .filter(Boolean))];
  for (const bookingId of bookingIds) {
    const snapshot = await transaction.get(
      admin.firestore().collection("bookings").doc(bookingId),
    );
    if (isBlockingBooking(snapshot.data(), nowMillis)) {
      throw new HttpsError(
        "already-exists",
        "Cancel or complete your current booking before making another.",
      );
    }
  }
}

function normalizeEmail(value) {
  const email = String(value ?? "").trim().toLowerCase();
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) ? email : "";
}

function loginRoleConflict(requestedRole, existingRole, hasPhone) {
  return new HttpsError(
    "already-exists",
    loginRoleConflictMessage(requestedRole, existingRole, hasPhone),
  );
}

function emailKey(email) {
  return Buffer.from(email).toString("base64url");
}

function hashCode(email, code) {
  return crypto
    .createHmac("sha256", otpSecret.value())
    .update(`${email}:${code}`)
    .digest("hex");
}

async function getOrCreateEmailUser(email) {
  try {
    return await admin.auth().getUserByEmail(email);
  } catch (error) {
    if (error.code !== "auth/user-not-found") {
      throw error;
    }
    return admin.auth().createUser({email, emailVerified: true});
  }
}

async function sendOtpMail(email, code) {
  const transporter = nodemailer.createTransport({
    host: smtpHost.value(),
    port: Number(smtpPort.value() || 587),
    secure: Number(smtpPort.value()) === 465,
    auth: {
      user: smtpUser.value(),
      pass: smtpPass.value(),
    },
  });
  await transporter.sendMail({
    from: smtpFrom.value(),
    to: email,
    subject: "Your Pritze login OTP",
    text: `Your Pritze login OTP is ${code}. It expires in 10 minutes.`,
    html: `
      <div style="font-family:Arial,sans-serif;line-height:1.5">
        <h2>Your Pritze login OTP</h2>
        <p>Use this code to sign in:</p>
        <p style="font-size:28px;font-weight:700;letter-spacing:4px">${code}</p>
        <p>This code expires in 10 minutes.</p>
      </div>
    `,
  });
}

function bookingStatusMessage(booking) {
  const service = booking.serviceName || "your booking";
  switch (booking.status) {
    case "confirmed":
      return booking.isInstant
        ? {
            title: "Instant booking accepted",
            body: `${booking.customerName || "The customer"}'s ${service} request was accepted by the salon. Arrival time: ${booking.arrivalMinutes || 15} minutes.`,
          }
        : {
            title: "Booking confirmed",
            body: `${booking.customerName || "The customer"}'s ${service} appointment is confirmed.`,
          };
    case "rejected":
      return {
        title: "Booking rejected",
        body: `${booking.customerName || "The customer"}'s ${service} booking was rejected by the salon.`,
      };
    case "inProgress":
      return {
        title: "Service started",
        body: `${service} for ${booking.customerName || "the customer"} is now in progress.`,
      };
    case "completed":
      return {
        title: "Service completed",
        body: `${service} for ${booking.customerName || "the customer"} is completed.`,
      };
    case "cancelled":
      if (booking.cancelledBy === "customer") {
        return {
          title: "Customer cancelled booking",
          body: `${booking.customerName || "The customer"} cancelled ${service}.${booking.cancellationReason ? ` Reason: ${booking.cancellationReason}.` : ""}`,
        };
      }
      return {
        title: "Salon cancelled booking",
        body: `The salon cancelled ${booking.customerName || "the customer"}'s ${service} booking.${booking.cancellationReason ? ` Reason: ${booking.cancellationReason}.` : ""}`,
      };
    default:
      return {
        title: "Booking updated",
        body: `${service} status changed to ${booking.status || "updated"}.`,
      };
  }
}

async function hydrateBookingRecipients(booking) {
  if (!booking) {
    return null;
  }
  const hydrated = {...booking};
  if (!hydrated.ownerUid && hydrated.salonId) {
    const salonSnapshot = await admin.firestore()
      .collection("salons")
      .doc(hydrated.salonId)
      .get();
    const salon = salonSnapshot.data() || {};
    if (typeof salon.ownerUid === "string" && salon.ownerUid.trim()) {
      hydrated.ownerUid = salon.ownerUid.trim();
    }
  }
  if (!hydrated.barberUid && hydrated.barberId) {
    const barberSnapshot = await admin.firestore()
      .collection("barbers")
      .doc(hydrated.barberId)
      .get();
    const barber = barberSnapshot.data() || {};
    if (typeof barber.uid === "string" && barber.uid.trim()) {
      hydrated.barberUid = barber.uid.trim();
    }
  }
  return hydrated;
}

function bookingNotificationData(bookingId, booking) {
  const customerArrivalMinutes = booking.arrivalMinutes || 0;
  const salonArrivalMinutes = booking.salonArrivalMinutes ||
    (customerArrivalMinutes > 0 ? customerArrivalMinutes + 5 : 0);
  return {
    type: "booking",
    bookingId,
    salonId: booking.salonId || "",
    status: booking.status || "",
    isInstant: booking.isInstant ? "true" : "false",
    arrivalMinutes: customerArrivalMinutes,
    salonArrivalMinutes,
    bookingFee: booking.bookingFee ?? 0,
    paymentRequired: booking.paymentRequired ? "true" : "false",
    paymentStatus: booking.paymentStatus || "not_required",
    destination: "bookings",
  };
}

async function sendClaimedArrivalReminder({
  bookingRef,
  bookingId,
  audience,
  nowMillis,
}) {
  const firestore = admin.firestore();
  const sentField = audience === "owner" ?
    "ownerArrivalReminderSentAt" : "customerArrivalReminderSentAt";
  const claimField = audience === "owner" ?
    "ownerArrivalReminderClaimedAt" : "customerArrivalReminderClaimedAt";
  const claimExpiryMillis = nowMillis - 3 * 60 * 1000;
  let claimedBooking = null;
  const claimed = await firestore.runTransaction(async (transaction) => {
    const currentSnapshot = await transaction.get(bookingRef);
    const current = currentSnapshot.data();
    if (
      !current ||
      current[sentField] ||
      !bookingArrivalReminderDue({booking: current, audience, nowMillis})
    ) {
      return false;
    }
    const previousClaimMillis = current[claimField]?.toMillis?.() || 0;
    if (previousClaimMillis > claimExpiryMillis) {
      return false;
    }
    claimedBooking = current;
    transaction.update(bookingRef, {
      [claimField]: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });
  if (!claimed || !claimedBooking) {
    return false;
  }

  try {
    const booking = await hydrateBookingRecipients(claimedBooking);
    const recipientUid = audience === "owner" ?
      booking.ownerUid : booking.customerUid;
    const service = booking.serviceName || "your service";
    const title = audience === "owner" ?
      "Customer arriving within 5 minutes" :
      booking.isInstant === true ?
        "Your appointment starts in 5 minutes" :
        "Your appointment starts soon";
    const body = audience === "owner" ?
      `${booking.customerName || "A customer"} is expected within 5 minutes for ${service}.` :
      booking.isInstant === true ?
      `Your ${service} appointment is scheduled to start in about 5 minutes.` :
      `Your ${service} appointment starts in about 30 minutes.`;
    const delivery = await sendToUsers([recipientUid].filter(Boolean), {
      title,
      body,
      data: {
        ...bookingNotificationData(bookingId, booking),
        event: "arrivalReminder",
        audience,
      },
      requiredActiveRolesByUser: bookingRecipientRoles(booking),
    });
    await bookingRef.update({
      [sentField]: admin.firestore.FieldValue.serverTimestamp(),
      [claimField]: admin.firestore.FieldValue.delete(),
    });
    console.log("booking arrival reminder delivered", {
      bookingId,
      audience,
      delivery,
    });
    return true;
  } catch (error) {
    await bookingRef.update({
      [claimField]: admin.firestore.FieldValue.delete(),
    });
    throw error;
  }
}

async function claimOwnerBookingAlert(bookingRef, eventId) {
  return admin.firestore().runTransaction(async (transaction) => {
    const snapshot = await transaction.get(bookingRef);
    const booking = snapshot.data();
    if (
      !booking ||
      booking.isInstant !== true ||
      booking.status !== "pending" ||
      booking.ownerAlertEventId
    ) {
      return false;
    }
    transaction.update(bookingRef, {
      ownerAlertEventId: eventId,
      ownerAlertStartedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });
}

async function sendOwnerBookingRequest(bookingId, booking, attempt) {
  const title = booking.isInstant
    ? "Instant booking request"
    : "New booking request";
  const customerArrivalMinutes = booking.arrivalMinutes || 15;
  const salonArrivalMinutes =
    booking.salonArrivalMinutes || customerArrivalMinutes + 5;
  const body = booking.isInstant
    ? `${booking.customerName || "A customer"} requested ${booking.serviceName || "a service"}. Customer ETA ${customerArrivalMinutes} min; salon window ${salonArrivalMinutes} min.`
    : `${booking.customerName || "A customer"} booked ${booking.serviceName || "a service"}.`;
  const recipients = [booking.ownerUid].filter(Boolean);
  const modernDelivery = await sendToUsers(recipients, {
    title,
    body,
    data: {
      ...bookingNotificationData(bookingId, booking),
      channel: OWNER_BOOKING_REQUEST_CHANNEL,
      alertAttempt: attempt + 1,
    },
    androidChannelId: OWNER_BOOKING_REQUEST_CHANNEL,
    androidSound: OWNER_BOOKING_REQUEST_SOUND,
    androidDataOnly: true,
    apnsSound: "owner_booking_request.wav",
    apnsCategory: IOS_OWNER_BOOKING_REQUEST_CATEGORY,
    collapseKey: `booking-${bookingId}`,
    tokenField: "ownerAlertV3Tokens",
    requireActiveOwnerSession: true,
  });
  const legacyDelivery = await sendToUsers(recipients, {
    title,
    body,
    data: {
      ...bookingNotificationData(bookingId, booking),
      channel: LEGACY_OWNER_BOOKING_REQUEST_CHANNEL,
      alertAttempt: attempt + 1,
    },
    androidChannelId: LEGACY_OWNER_BOOKING_REQUEST_CHANNEL,
    androidSound: OWNER_BOOKING_REQUEST_SOUND,
    apnsSound: "owner_booking_request.wav",
    apnsCategory: IOS_OWNER_BOOKING_REQUEST_CATEGORY,
    collapseKey: `booking-${bookingId}`,
    tokenField: "fcmTokens",
    excludeTokenField: "ownerAlertV3Tokens",
    requireActiveOwnerSession: true,
  });
  return mergeDelivery(modernDelivery, legacyDelivery);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function mergeDelivery(...deliveries) {
  return deliveries.reduce((total, delivery) => {
    return {
      userCount: total.userCount + (delivery?.userCount || 0),
      tokenCount: total.tokenCount + (delivery?.tokenCount || 0),
      successCount: total.successCount + (delivery?.successCount || 0),
      failureCount: total.failureCount + (delivery?.failureCount || 0),
    };
  }, {userCount: 0, tokenCount: 0, successCount: 0, failureCount: 0});
}

async function sendToUsers(userIds, message) {
  const uniqueUserIds = [...new Set((userIds || []).filter(Boolean))];
  if (uniqueUserIds.length === 0) {
    return {userCount: 0, tokenCount: 0, successCount: 0, failureCount: 0};
  }
  const tokenEntries = [];
  await Promise.all(uniqueUserIds.map(async (uid) => {
    const snapshot = await admin.firestore().collection("users").doc(uid).get();
    const data = snapshot.data() || {};
    if (
      message.requireActiveOwnerSession &&
      (data.activeRole !== "owner" || data.ownerNotificationsEnabled !== true)
    ) {
      return;
    }
    const requiredRoles = message.requiredActiveRolesByUser?.[uid];
    if (
      Array.isArray(requiredRoles) &&
      requiredRoles.length > 0 &&
      !requiredRoles.includes(data.activeRole)
    ) {
      return;
    }
    const tokenField = message.tokenField || "fcmTokens";
    const tokens = Array.isArray(data[tokenField]) ? data[tokenField] : [];
    const excludedTokens = new Set(
      message.excludeTokenField && Array.isArray(data[message.excludeTokenField])
        ? data[message.excludeTokenField]
        : [],
    );
    for (const token of tokens) {
      if (
        typeof token === "string" &&
        token.trim() &&
        !excludedTokens.has(token)
      ) {
        tokenEntries.push({uid, token});
      }
    }
  }));
  const tokens = [...new Set(tokenEntries.map((entry) => entry.token))];
  if (tokens.length === 0) {
    console.log("sendToUsers no tokens", {userIds: uniqueUserIds});
    return {
      userCount: uniqueUserIds.length,
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
    };
  }
  const data = stringifyData({
    ...message.data,
    notificationTitle: message.title,
    notificationBody: message.body,
  });
  const multicastMessage = {
    tokens: tokens.slice(0, 500),
    data,
    android: {
      priority: "high",
      ttl: 2 * 60 * 1000,
      ...(message.collapseKey ? {collapseKey: message.collapseKey} : {}),
    },
    apns: {
      headers: {
        "apns-priority": message.controlOnly ? "5" : "10",
        "apns-push-type": message.controlOnly ? "background" : "alert",
        "apns-expiration": String(Math.floor(Date.now() / 1000) + 120),
        ...(message.collapseKey
          ? {"apns-collapse-id": message.collapseKey}
          : {}),
      },
      payload: {
        aps: {
          ...(message.controlOnly
            ? {"content-available": 1}
            : {alert: {title: message.title, body: message.body}}),
          ...(!message.controlOnly
            ? {
                sound: message.apnsSound || "default",
                category: message.apnsCategory || "PRITZE_BOOKING_UPDATE",
                "interruption-level": "active",
              }
            : {}),
        },
      },
    },
  };
  if (!message.androidDataOnly) {
    multicastMessage.notification = {
      title: message.title,
      body: message.body,
    };
    multicastMessage.android.notification = {
      channelId: message.androidChannelId || "pritze_booking_updates",
      sound: message.androidSound || "default",
    };
  }
  const response = await admin.messaging().sendEachForMulticast(
    multicastMessage,
  );
  logPushDeliveryFailures(
    tokens,
    tokenEntries,
    response.responses,
    message.tokenField || "fcmTokens",
  );
  await cleanupInvalidTokens(
    tokens,
    tokenEntries,
    response.responses,
    message.tokenField || "fcmTokens",
  );
  return {
    userCount: uniqueUserIds.length,
    tokenCount: tokens.length,
    successCount: response.successCount,
    failureCount: response.failureCount,
  };
}

function logPushDeliveryFailures(
  sentTokens,
  tokenEntries,
  responses,
  tokenField,
) {
  responses.forEach((result, index) => {
    if (result.success) {
      return;
    }
    const failedToken = sentTokens[index];
    const owners = tokenEntries
      .filter((entry) => entry.token === failedToken)
      .map((entry) => entry.uid);
    console.error("push delivery failed", {
      code: result.error?.code || "unknown",
      message: result.error?.message || "Unknown messaging error",
      tokenField,
      userIds: [...new Set(owners)],
      tokenSuffix: String(failedToken || "").slice(-8),
    });
  });
}

function stringifyData(data) {
  return Object.fromEntries(
    Object.entries(data).map(([key, value]) => [key, String(value ?? "")]),
  );
}

async function cleanupInvalidTokens(
  sentTokens,
  tokenEntries,
  responses,
  tokenField,
) {
  const invalidByUser = new Map();
  responses.forEach((result, index) => {
    if (result.success) {
      return;
    }
    const code = result.error?.code || "";
    if (
      code !== "messaging/registration-token-not-registered" &&
      code !== "messaging/invalid-registration-token"
    ) {
      return;
    }
    const failedToken = sentTokens[index];
    for (const entry of tokenEntries) {
      if (entry.token !== failedToken) {
        continue;
      }
      const tokens = invalidByUser.get(entry.uid) || [];
      tokens.push(entry.token);
      invalidByUser.set(entry.uid, tokens);
    }
  });
  await Promise.all([...invalidByUser.entries()].map(([uid, tokens]) => {
    const updates = {
      [tokenField]: admin.firestore.FieldValue.arrayRemove(...tokens),
    };
    if (tokenField !== "fcmTokens") {
      updates.fcmTokens = admin.firestore.FieldValue.arrayRemove(...tokens);
    }
    return admin.firestore().collection("users").doc(uid).set(
      updates,
      {merge: true},
    );
  }));
}
