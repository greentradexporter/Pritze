const crypto = require("node:crypto");
const admin = require("firebase-admin");
const nodemailer = require("nodemailer");
const {
  bookingRecipientRoles,
  bookingStatusRecipients,
  excludeActor,
} = require("./booking_notification_logic");
const {HttpsError, onCall} = require("firebase-functions/v2/https");
const {
  onDocumentCreated,
  onDocumentUpdated,
} = require("firebase-functions/v2/firestore");
const {defineSecret} = require("firebase-functions/params");

admin.initializeApp();

const smtpHost = defineSecret("SMTP_HOST");
const smtpPort = defineSecret("SMTP_PORT");
const smtpUser = defineSecret("SMTP_USER");
const smtpPass = defineSecret("SMTP_PASS");
const smtpFrom = defineSecret("SMTP_FROM");
const otpSecret = defineSecret("EMAIL_OTP_SECRET");

const OTP_TTL_MS = 10 * 60 * 1000;
const MAX_ATTEMPTS = 5;
const APP_REVIEW_EMAIL = "greentradexporter+appreview@gmail.com";
const APP_REVIEW_CODE = "246810";
const OWNER_BOOKING_REQUEST_CHANNEL = "pritze_owner_booking_requests_v3";
const LEGACY_OWNER_BOOKING_REQUEST_CHANNEL =
  "pritze_owner_booking_requests_v2";
const OWNER_BOOKING_REQUEST_SOUND = "owner_booking_request";
const OWNER_ALERT_REPEAT_DELAY_MS = 25_000;
const OWNER_ALERT_ATTEMPTS = 4;

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

  if (event === "created") {
    return {ok: true, handledBy: "alertOwnerOnBookingCreated"};
  }

  const message = bookingStatusMessage(booking);
  const recipients = bookingStatusRecipients({}, booking);
  const intendedRecipients = excludeActor(recipients, uid);
  const delivery = await sendToUsers(intendedRecipients, {
    title: message.title,
    body: message.body,
    data: bookingNotificationData(bookingId, booking),
    requiredActiveRolesByUser: bookingRecipientRoles(booking),
  });
  console.log("sendBookingPush statusUpdated", {
    bookingId,
    recipients: intendedRecipients,
    delivery,
  });
  return {ok: true, delivery};
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
    const claimed = await claimOwnerBookingAlert(bookingRef, event.id);
    if (!claimed) {
      return;
    }

    for (let attempt = 0; attempt < OWNER_ALERT_ATTEMPTS; attempt += 1) {
      if (attempt > 0) {
        await delay(OWNER_ALERT_REPEAT_DELAY_MS);
      }
      const snapshot = await bookingRef.get();
      const current = snapshot.data();
      if (!current || current.status !== "pending") {
        console.log("owner booking alert stopped", {
          bookingId,
          status: current?.status || "deleted",
          attempt,
        });
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
          title: booking.isInstant
            ? "Instant booking assigned"
            : "New booking request",
          body: booking.isInstant
            ? `${booking.serviceName || "A service"} is assigned. Customer ETA ${customerArrivalMinutes} min; salon window ${salonArrivalMinutes} min.`
            : `${booking.serviceName || "A service"} is assigned to you.`,
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
      after.status === "pending"
    ) {
      return;
    }
    const booking = await hydrateBookingRecipients(after);
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
    enforceAppCheck: false,
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
    if (email === APP_REVIEW_EMAIL) {
      await docRef.set({
        email,
        codeHash: hashCode(email, APP_REVIEW_CODE),
        attempts: 0,
        sentAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt: admin.firestore.Timestamp.fromMillis(now + OTP_TTL_MS),
        appReview: true,
      });
      console.log("sendEmailOtp prepared App Review account");
      return {ok: true};
    }

    const snapshot = await docRef.get();
    const previous = snapshot.data();
    if (previous?.sentAt?.toMillis && now - previous.sentAt.toMillis() < 45_000) {
      throw new HttpsError(
        "resource-exhausted",
        "Please wait before requesting another email OTP.",
      );
    }

    const code = crypto.randomInt(100000, 1000000).toString();
    const expiresAt = admin.firestore.Timestamp.fromMillis(now + OTP_TTL_MS);
    await docRef.set({
      email,
      codeHash: hashCode(email, code),
      attempts: 0,
      sentAt: admin.firestore.FieldValue.serverTimestamp(),
      expiresAt,
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
  {enforceAppCheck: false, invoker: "public", secrets: [otpSecret]},
  async (request) => {
    const email = normalizeEmail(request.data?.email);
    const code = String(request.data?.code ?? "").trim();
    if (!email || !/^\d{6}$/.test(code)) {
      throw new HttpsError("invalid-argument", "Enter the 6-digit email OTP.");
    }

    const docRef = admin.firestore().collection("emailOtps").doc(emailKey(email));
    const snapshot = await docRef.get();
    const data = snapshot.data();
    if (!data) {
      throw new HttpsError("not-found", "Request a new email OTP.");
    }
    if (!data.expiresAt?.toMillis || data.expiresAt.toMillis() < Date.now()) {
      await docRef.delete();
      throw new HttpsError("deadline-exceeded", "This email OTP expired.");
    }
    if ((data.attempts ?? 0) >= MAX_ATTEMPTS) {
      await docRef.delete();
      throw new HttpsError("resource-exhausted", "Too many OTP attempts.");
    }
    if (data.codeHash !== hashCode(email, code)) {
      await docRef.update({
        attempts: admin.firestore.FieldValue.increment(1),
      });
      throw new HttpsError("permission-denied", "Incorrect email OTP.");
    }

    try {
      const user = await getOrCreateEmailUser(email);
      const customToken = await admin.auth().createCustomToken(user.uid, {
        provider: "email_otp",
      });
      await docRef.delete();
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

function normalizeEmail(value) {
  const email = String(value ?? "").trim().toLowerCase();
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) ? email : "";
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
            body: `Your ${service} request was accepted. Continue to arrive within ${booking.arrivalMinutes || 15} minutes of your request.`,
          }
        : {
            title: "Booking accepted",
            body: `Your ${service} booking was accepted by the salon.`,
          };
    case "rejected":
      return {
        title: "Booking rejected",
        body: `Your ${service} booking was rejected by the salon.`,
      };
    case "inProgress":
      return {
        title: "Service started",
        body: `${service} is now in progress.`,
      };
    case "completed":
      return {
        title: "Service completed",
        body: `${service} is completed. Thanks for visiting.`,
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
        body: `The salon cancelled your ${service} booking.${booking.cancellationReason ? ` Reason: ${booking.cancellationReason}.` : ""}`,
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

async function claimOwnerBookingAlert(bookingRef, eventId) {
  return admin.firestore().runTransaction(async (transaction) => {
    const snapshot = await transaction.get(bookingRef);
    const booking = snapshot.data();
    if (!booking || booking.status !== "pending" || booking.ownerAlertEventId) {
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
            : message.androidDataOnly
            ? {alert: {title: message.title, body: message.body}}
            : {}),
          ...(!message.controlOnly
            ? {
                sound: message.apnsSound || "default",
                category: message.androidDataOnly
                  ? "PRITZE_BOOKING_REQUEST"
                  : "PRITZE_BOOKING_UPDATE",
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
