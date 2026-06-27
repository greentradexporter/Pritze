const crypto = require("node:crypto");
const admin = require("firebase-admin");
const nodemailer = require("nodemailer");
const {HttpsError, onCall} = require("firebase-functions/v2/https");
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
  const booking = snapshot.data();
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

  let recipients;
  let title;
  let body;
  if (event === "created") {
    recipients = [booking.ownerUid, booking.barberUid];
    title = "New booking request";
    body = `${booking.customerName || "A customer"} booked ${booking.serviceName || "a service"}.`;
    const delivery = await sendToUsers(recipients.filter((id) => id && id !== uid), {
      title,
      body,
      data: bookingNotificationData(bookingId, booking),
    });
    console.log("sendBookingPush created", {
      bookingId,
      recipients: recipients.filter((id) => id && id !== uid),
      delivery,
    });
    return {ok: true, delivery};
  }

  const message = bookingStatusMessage(booking);
  recipients = bookingStatusRecipients({}, booking);
  title = message.title;
  body = message.body;
  const delivery = await sendToUsers(recipients.filter((id) => id && id !== uid), {
    title,
    body,
    data: bookingNotificationData(bookingId, booking),
  });
  console.log("sendBookingPush statusUpdated", {
    bookingId,
    recipients: recipients.filter((id) => id && id !== uid),
    delivery,
  });
  return {ok: true, delivery};
});

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
    const snapshot = await docRef.get();
    const now = Date.now();
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

    await sendOtpMail(email, code);
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
    if (data.expiresAt.toMillis() < Date.now()) {
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

    await docRef.delete();
    try {
      const user = await getOrCreateEmailUser(email);
      const customToken = await admin.auth().createCustomToken(user.uid, {
        provider: "email_otp",
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
      return {
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
      return {
        title: "Booking cancelled",
        body: `${booking.customerName || "The customer"} cancelled ${service}.`,
      };
    default:
      return {
        title: "Booking updated",
        body: `${service} status changed to ${booking.status || "updated"}.`,
      };
  }
}

function bookingStatusRecipients(before, after) {
  if (after.status === "cancelled" && before.customerUid === after.customerUid) {
    return [after.ownerUid, after.barberUid];
  }
  if (after.status === "confirmed") {
    return [after.customerUid, after.barberUid];
  }
  if (after.status === "rejected") {
    return [after.customerUid, after.barberUid];
  }
  if (after.status === "inProgress" || after.status === "completed") {
    return [after.customerUid, after.ownerUid, after.barberUid];
  }
  return [after.customerUid, after.ownerUid, after.barberUid];
}

function bookingNotificationData(bookingId, booking) {
  return {
    type: "booking",
    bookingId,
    salonId: booking.salonId || "",
    status: booking.status || "",
    destination: "bookings",
  };
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
    const tokens = Array.isArray(data.fcmTokens) ? data.fcmTokens : [];
    for (const token of tokens) {
      if (typeof token === "string" && token.trim()) {
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
  const response = await admin.messaging().sendEachForMulticast({
    tokens: tokens.slice(0, 500),
    notification: {
      title: message.title,
      body: message.body,
    },
    data: stringifyData(message.data || {}),
    android: {
      priority: "high",
      notification: {
        sound: "default",
      },
    },
    apns: {
      payload: {
        aps: {
          sound: "default",
        },
      },
    },
  });
  await cleanupInvalidTokens(tokens, tokenEntries, response.responses);
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

async function cleanupInvalidTokens(sentTokens, tokenEntries, responses) {
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
    return admin.firestore().collection("users").doc(uid).set({
      fcmTokens: admin.firestore.FieldValue.arrayRemove(...tokens),
    }, {merge: true});
  }));
}
