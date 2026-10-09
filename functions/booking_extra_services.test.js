const test = require('node:test');
const assert = require('node:assert/strict');
const {Timestamp} = require('firebase-admin/firestore');
const {updateBookingExtraServices} = require('./booking_extra_services');
const {memoryFirestore} = require('./test_support/memory_firestore');
const {slotSegmentMillis, shouldAutoCompleteService} = require('./booking_workflow_logic');
function fixture() {
  const now = Date.parse('2026-10-02T06:30:00Z');
  const {rows, firestore} = memoryFirestore({
    'bookings/visit': {ownerUid: 'owner', customerUid: 'customer', salonId: 'salon', barberId: 'barber',
      status: 'inProgress', serviceId: 'hair', serviceIds: ['hair'], servicePrice: 200,
      servicePriceBreakdown: {hair: 200}, serviceNameBreakdown: {hair: 'Haircut'}, serviceName: 'Haircut',
      customerPayableAmount: 140, customerPayableBeforeProin: 160, discountAmount: 40,
      discountBaseAmount: 200, proinReservedAmount: 20, salonTotalEarning: 200,
      durationMinutes: 30, start: Timestamp.fromMillis(now), startedAt: Timestamp.fromMillis(now), createdAt: Timestamp.fromMillis(now)},
    'salons/salon': {ownerUid: 'owner', openTime: '9:00 AM', closeTime: '8:00 PM', services: [
      {id: 'hair', name: 'Haircut', price: 200, durationMinutes: 30},
      {id: 'beard', name: 'Beard trim', price: 100, durationMinutes: 15},
      {id: 'wash', name: 'Hair wash', price: 50, durationMinutes: 10},
    ]},
    'barbers/barber': {serviceIds: ['hair', 'beard', 'wash']},
  });
  const call = (uid, action, other = {}) => updateBookingExtraServices({uid, data: {
    bookingId: 'visit', requestId: 'addition1', action, serviceIds: ['beard', 'wash'], expectedPrices: {beard: 100, wash: 50}, ...other,
  }, firestore, Timestamp, now});
  return {rows, call, now, booking: () => rows.get('bookings/visit')};
}
for (const proposer of ['owner', 'customer']) {
  test(`${proposer} can propose; other party approves once with cumulative price and duration`, async () => {
    const f = fixture();
    await f.call(proposer, 'propose');
    assert.equal(f.booking().customerPayableAmount, 140);
    await assert.rejects(f.call(proposer, 'approve'), {code: 'permission-denied'});
    await f.call(proposer === 'owner' ? 'customer' : 'owner', 'approve');
    const booking = f.booking();
    assert.equal(booking.customerPayableAmount, 290);
    assert.equal(booking.customerPayableBeforeProin, 310);
    assert.equal(booking.servicePrice, 350);
    assert.equal(booking.salonTotalEarning, 350);
    assert.equal(booking.discountAmount, 40);
    assert.equal(booking.proinReservedAmount, 20);
    assert.equal(booking.discountBaseAmount, 200);
    assert.equal(booking.durationMinutes, 55);
    assert.equal(booking.extraServiceRequest, null);
    assert.equal(booking.serviceName, 'Haircut, Beard trim, Hair wash');
    assert.equal(shouldAutoCompleteService(booking, f.now + 35 * 60000), false);
    const payer = proposer === 'owner' ? 'customer' : 'owner';
    await f.call(payer, 'approve');
    await f.call(proposer, 'propose');
    assert.equal(f.booking().customerPayableAmount, 290);
    assert.equal([...f.rows.keys()].filter((key) => key.startsWith('slotLocks/')).length, slotSegmentMillis(f.now, 55).length);
  });
}
test('unrelated accounts, guests and completed visits cannot request or approve', async () => {
  const f = fixture();
  await assert.rejects(f.call('', 'propose'), {code: 'unauthenticated'});
  await assert.rejects(f.call('intruder', 'propose'), {code: 'permission-denied'});
  await f.call('customer', 'propose');
  f.booking().status = 'completed';
  await assert.rejects(f.call('owner', 'approve'), {code: 'failed-precondition'});
  assert.equal(f.booking().customerPayableAmount, 140);
});
test('decline and cancel leave the original price unchanged', async () => {
  const f = fixture();
  await f.call('customer', 'propose');
  await assert.rejects(f.call('owner', 'cancel'), {code: 'permission-denied'});
  await f.call('owner', 'reject');
  assert.equal(f.booking().extraServiceRequest, null);
  await f.call('owner', 'propose', {requestId: 'second'});
  await f.call('owner', 'cancel', {requestId: 'second'});
  assert.equal(f.booking().customerPayableAmount, 140);
});
test('changed prices or service availability require a new proposal', async () => {
  const f = fixture();
  await assert.rejects(f.call('owner', 'propose', {expectedPrices: {beard: 1, wash: 50}}), {code: 'failed-precondition'});
  await f.call('owner', 'propose');
  const beard = f.rows.get('salons/salon').services[1];
  beard.price = 120;
  await assert.rejects(f.call('customer', 'approve'), {code: 'failed-precondition'});
  beard.price = 100; beard.isAvailable = false;
  await assert.rejects(f.call('customer', 'approve'), {code: 'failed-precondition'});
  assert.equal(f.booking().customerPayableAmount, 140);
});
test('overlap introduced after proposal prevents approval atomically', async () => {
  const f = fixture();
  await f.call('owner', 'propose');
  f.rows.set(`slotLocks/barber_${f.now + 30 * 60000}`, {active: true, bookingId: 'another'});
  await assert.rejects(f.call('customer', 'approve'), {code: 'failed-precondition'});
  assert.equal(f.booking().servicePrice, 200);
  assert.equal(f.booking().extraServiceRequest.id, 'addition1');
});
test('late start reserves additional time beyond the scheduled duration', async () => {
  const f = fixture();
  f.booking().startedAt = Timestamp.fromMillis(f.now + 10 * 60000);
  await f.call('owner', 'propose');
  await f.call('customer', 'approve');
  assert.ok(f.booking().extraSlotLockIds.length > 0);
  assert.equal(f.booking().autoCompleteAt.toMillis(), f.now + 70 * 60000);
});
test('barber skills, duplicate services and closing time are enforced', async () => {
  const f = fixture();
  await assert.rejects(f.call('owner', 'propose', {serviceIds: ['hair'], expectedPrices: {hair: 200}}), {code: 'failed-precondition'});
  f.rows.get('barbers/barber').serviceIds = ['hair'];
  await assert.rejects(f.call('owner', 'propose'), {code: 'failed-precondition'});
  f.rows.get('barbers/barber').serviceIds = ['hair', 'beard', 'wash'];
  f.rows.get('salons/salon').closeTime = '12:30 PM';
  await assert.rejects(f.call('owner', 'propose'), {code: 'failed-precondition'});
});
