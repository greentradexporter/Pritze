const {HttpsError} = require('firebase-functions/v2/https');
const {slotSegmentMillis, serviceAutoCompleteAtMillis, isWithinSalonHours} = require('./booking_workflow_logic');

function fail(message, code = 'failed-precondition') { throw new HttpsError(code, message); }
function id(value) {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(value)) fail('Invalid request.', 'invalid-argument');
  return value;
}

// Prices, participants, status and availability are all checked in the same
// transaction that changes the bill. A proposal does not change any charge.
async function updateBookingExtraServices({uid, data, firestore, Timestamp, now = Date.now()}) {
  if (!uid) fail('Sign in first.', 'unauthenticated');
  const bookingId = id(data?.bookingId);
  const requestId = id(data?.requestId);
  const action = data?.action;
  if (!['propose', 'approve', 'reject', 'cancel'].includes(action)) fail('Invalid action.', 'invalid-argument');
  const ref = firestore.collection('bookings').doc(bookingId);
  return firestore.runTransaction(async (tx) => {
    const booking = (await tx.get(ref)).data();
    if (!booking) fail('Booking not found.', 'not-found');
    const role = uid === booking.ownerUid ? 'owner' : uid === booking.customerUid ? 'customer' : '';
    if (!role) fail('This booking belongs to another account.', 'permission-denied');
    const decisions = booking.extraServiceDecisions || {};
    if (Object.hasOwn(decisions, requestId)) return {bookingId, resolved: true};
    if (booking.status !== 'inProgress') fail('Extra services can only be added while the visit is in progress.');
    const pending = booking.extraServiceRequest;
    const updatedAt = Timestamp.fromMillis(now);
    if (action === 'reject' || action === 'cancel') {
      if (pending?.id !== requestId) fail('This service request has changed. Refresh and try again.');
      if ((action === 'cancel') !== (pending.proposedByUid === uid)) fail('Only the other person can accept or reject this request.', 'permission-denied');
      tx.update(ref, {extraServiceRequest: null, extraServiceDecisions: {...decisions, [requestId]: action}, updatedAt});
      return {bookingId, resolved: true};
    }
    if (Object.keys(decisions).length >= 100) fail('This visit has reached its service request limit.');
    if (action === 'approve' && (pending?.id !== requestId || pending.proposedByUid === uid)) {
      fail('Only the other person can approve the current service request.', 'permission-denied');
    }
    if (action === 'propose' && pending) {
      if (pending.id === requestId && pending.proposedByUid === uid) return {bookingId, resolved: false};
      fail('Accept, decline or cancel the current service request first.');
    }
    const ids = action === 'approve' ? pending.serviceIds : data.serviceIds;
    if (!Array.isArray(ids) || ids.length < 1 || ids.length > 10 || new Set(ids).size !== ids.length) fail('Choose 1 to 10 extra services.', 'invalid-argument');
    ids.forEach(id);
    const existing = [...new Set([...(booking.serviceIds || []), booking.serviceId].filter(Boolean))];
    if (ids.some((value) => existing.includes(value))) fail('A selected service is already included in this visit.');
    const salon = (await tx.get(firestore.collection('salons').doc(booking.salonId))).data();
    const barber = (await tx.get(firestore.collection('barbers').doc(booking.barberId))).data();
    if (!salon || salon.ownerUid !== booking.ownerUid) fail('Salon details have changed.');
    const services = ids.map((value) => (salon.services || []).find((service) => service.id === value));
    if (services.some((service) => !service || service.isAvailable === false || !Number.isInteger(service.price) || service.price < 0 || !Number.isInteger(service.durationMinutes) || service.durationMinutes <= 0)) fail('A selected service is no longer available.');
    if (!barber || barber.isActive === false || !ids.every((value) => barber.serviceIds?.includes(value))) fail('The assigned barber cannot provide these services.');
    const amount = services.reduce((sum, service) => sum + service.price, 0);
    const duration = services.reduce((sum, service) => sum + service.durationMinutes, 0);
    const expectedPrices = action === 'approve' ? pending.prices : data.expectedPrices;
    if (!expectedPrices || ids.some((value, index) => expectedPrices[value] !== services[index].price) ||
        (action === 'approve' && pending.durationMinutes !== duration)) fail('The service price or duration changed. Cancel this request and select the services again.');
    const totalDuration = (booking.durationMinutes || 30) + duration;
    if (totalDuration > 720) fail('This visit would be too long.');
    const startMillis = booking.start.toMillis();
    const startedMillis = booking.startedAt?.toMillis?.() || startMillis;
    const endMillis = Math.max(startMillis, startedMillis) + totalDuration * 60000;
    if (!isWithinSalonHours({startMillis: Math.max(startMillis, startedMillis), durationMinutes: totalDuration, openTime: salon.openTime, closeTime: salon.closeTime})) fail('These services would finish after salon closing time.');
    const segments = slotSegmentMillis(startMillis, Math.ceil((endMillis - startMillis) / 60000));
    const lockRefs = segments.map((segment) => firestore.collection('slotLocks').doc(`${booking.barberId}_${segment}`));
    const locks = await Promise.all(lockRefs.map((lock) => tx.get(lock)));
    if (locks.some((lock) => lock.exists && lock.data().active !== false && lock.data().bookingId !== bookingId)) fail('The extra time overlaps another appointment. Choose a shorter service or ask the salon.');
    if (action === 'propose') {
      const proposal = {id: requestId, proposedByUid: uid, proposedByRole: role, serviceIds: ids,
        names: Object.fromEntries(services.map((service) => [service.id, service.name])),
        prices: Object.fromEntries(services.map((service) => [service.id, service.price])),
        amount, durationMinutes: duration, createdAt: updatedAt};
      tx.update(ref, {extraServiceRequest: proposal, updatedAt});
      return {bookingId, resolved: false};
    }
    const servicePrice = (booking.servicePrice || 0) + amount;
    const names = {...(booking.serviceNameBreakdown || {}), ...pending.names};
    const prices = {...(booking.servicePriceBreakdown || {}), ...pending.prices};
    const normalLockIds = new Set(slotSegmentMillis(startMillis, totalDuration).map((segment) => `${booking.barberId}_${segment}`));
    tx.update(ref, {
      serviceIds: [...existing, ...ids], serviceName: [booking.serviceName || 'Booked service', ...ids.map((value) => pending.names[value])].join(', '),
      serviceNameBreakdown: names, servicePriceBreakdown: prices, servicePrice,
      customerPayableAmount: (booking.customerPayableAmount ?? booking.servicePrice ?? 0) + amount,
      customerPayableBeforeProin: (booking.customerPayableBeforeProin ?? booking.customerPayableAmount ?? booking.servicePrice ?? 0) + amount,
      salonTotalEarning: (booking.salonTotalEarning ?? booking.servicePrice ?? 0) + amount,
      durationMinutes: totalDuration,
      autoCompleteAt: Timestamp.fromMillis(serviceAutoCompleteAtMillis({...booking, durationMinutes: totalDuration})),
      extraSlotLockIds: lockRefs.map((lock) => lock.id).filter((value) => !normalLockIds.has(value)),
      extraServiceRequest: null, extraServiceDecisions: {...decisions, [requestId]: 'approve'}, updatedAt,
    });
    lockRefs.forEach((lock, index) => tx.set(lock, {
      bookingId, salonId: booking.salonId, serviceId: booking.serviceId, barberId: booking.barberId,
      start: Timestamp.fromMillis(segments[index]), bookingStart: booking.start,
      active: true, createdAt: booking.createdAt, updatedAt,
    }, {merge: true}));
    return {bookingId, resolved: true};
  });
}
module.exports = {updateBookingExtraServices};
