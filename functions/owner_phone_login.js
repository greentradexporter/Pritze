const {HttpsError} = require('firebase-functions/v2/https');

// Both credentials are proved: the caller owns the email salon account, and
// the separate phone token was obtained by a recent Firebase phone OTP.
async function linkOwnerPhoneLogin({uid, phoneIdToken, firestore, auth, now = Date.now()}) {
  if (!uid) throw new HttpsError('unauthenticated', 'Sign in as the salon owner first.');
  if (typeof phoneIdToken !== 'string' || !phoneIdToken) {
    throw new HttpsError('invalid-argument', 'Verify the phone number first.');
  }
  const proof = await auth.verifyIdToken(phoneIdToken, true);
  const phone = String(proof.phone_number || '');
  if (proof.firebase?.sign_in_provider !== 'phone' || !/^\+91\d{10}$/.test(phone) ||
      !Number.isFinite(proof.auth_time) || now / 1000 - proof.auth_time > 300) {
    throw new HttpsError('failed-precondition', 'Request a new phone OTP and try again.');
  }
  const owner = (await firestore.collection('users').doc(uid).get()).data();
  const salons = await firestore.collection('salons').where('ownerUid', '==', uid).limit(1).get();
  if (owner?.role !== 'owner' || salons.empty) {
    throw new HttpsError('permission-denied', 'Save your salon profile before enabling phone login.');
  }
  if (owner.profilePhone !== phone || salons.docs[0].data().phone !== phone) {
    throw new HttpsError('failed-precondition', 'Save this phone number in your salon profile first.');
  }
  const target = await auth.getUser(uid);
  if (target.disabled) throw new HttpsError('permission-denied', 'This account is disabled.');
  if (proof.uid === uid || target.phoneNumber === phone) return {phone, linked: true};

  const source = await auth.getUser(proof.uid);
  const [sourceProfile, sourceSalons, sourceBookings] = await Promise.all([
    firestore.collection('users').doc(proof.uid).get(),
    firestore.collection('salons').where('ownerUid', '==', proof.uid).limit(1).get(),
    firestore.collection('bookings').where('customerUid', '==', proof.uid).limit(1).get(),
  ]);
  // Only transfer an otherwise unused phone-auth identity left by an earlier
  // OTP attempt. Never merge two registered accounts or move their data.
  if (source.phoneNumber !== phone || source.email || sourceProfile.exists ||
      !sourceSalons.empty || !sourceBookings.empty ||
      (source.providerData || []).some((provider) => provider.providerId !== 'phone')) {
    throw new HttpsError('already-exists', 'This phone number is linked to another registered account.');
  }
  await auth.updateUser(proof.uid, {phoneNumber: null});
  try {
    await auth.updateUser(uid, {phoneNumber: phone});
  } catch (error) {
    await auth.updateUser(proof.uid, {phoneNumber: phone});
    throw error;
  }
  await auth.revokeRefreshTokens(proof.uid);
  return {phone, linked: true};
}

module.exports = {linkOwnerPhoneLogin};
