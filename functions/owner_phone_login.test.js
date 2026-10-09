const test = require('node:test');
const assert = require('node:assert/strict');
const {linkOwnerPhoneLogin} = require('./owner_phone_login');
const {memoryFirestore} = require('./test_support/memory_firestore');
function fixture() {
  const phone = '+919876543210';
  const now = Date.now();
  const {rows, firestore} = memoryFirestore({
    'users/owner': {role: 'owner', profilePhone: phone},
    'salons/salon': {ownerUid: 'owner', phone},
  });
  const accounts = new Map([
    ['owner', {uid: 'owner', email: 'owner@example.com', providerData: [{providerId: 'password'}]}],
    ['orphan', {uid: 'orphan', phoneNumber: phone, providerData: [{providerId: 'phone'}]}],
  ]);
  const proof = {uid: 'orphan', phone_number: phone, auth_time: now / 1000, firebase: {sign_in_provider: 'phone'}};
  const revoked = [];
  const auth = {
    verifyIdToken: async (token, checkRevoked) => {assert.equal(token, 'verified-token'); assert.equal(checkRevoked, true); return proof;},
    getUser: async (uid) => accounts.get(uid),
    updateUser: async (uid, data) => accounts.set(uid, {...accounts.get(uid), ...data}),
    revokeRefreshTokens: async (uid) => revoked.push(uid),
  };
  return {phone, rows, accounts, proof, auth, revoked,
    call: () => linkOwnerPhoneLogin({uid: 'owner', phoneIdToken: 'verified-token', firestore, auth, now})};
}
test('verified phone links to original owner UID without changing email or salon', async () => {
  const f = fixture(); await f.call();
  assert.equal(f.accounts.get('owner').phoneNumber, f.phone);
  assert.equal(f.accounts.get('owner').email, 'owner@example.com');
  assert.equal(f.rows.get('salons/salon').ownerUid, 'owner');
  assert.equal(f.accounts.get('orphan').phoneNumber, null);
  assert.deepEqual(f.revoked, ['orphan']);
  await f.call(); // safe retry if client lost the first result
  assert.deepEqual(f.revoked, ['orphan']);
});
test('stale or non-phone proof cannot link credentials', async () => {
  const f = fixture(); f.proof.auth_time -= 301;
  await assert.rejects(f.call(), {code: 'failed-precondition'});
  f.proof.auth_time += 301; f.proof.firebase.sign_in_provider = 'password';
  await assert.rejects(f.call(), {code: 'failed-precondition'});
});
test('cannot move a phone from a registered customer or owner account', async () => {
  for (const role of ['customer', 'owner']) {
    const f = fixture(); f.rows.set('users/orphan', {role});
    await assert.rejects(f.call(), {code: 'already-exists'});
    assert.equal(f.accounts.get('orphan').phoneNumber, f.phone);
    assert.equal(f.accounts.get('owner').phoneNumber, undefined);
  }
});
test('cannot link a phone different from the saved salon contact', async () => {
  const f = fixture(); f.rows.get('salons/salon').phone = '+919876543211';
  await assert.rejects(f.call(), {code: 'failed-precondition'});
});
test('failed target binding restores the original phone credential', async () => {
  const f = fixture(); const update = f.auth.updateUser;
  f.auth.updateUser = async (uid, data) => {if (uid === 'owner') throw new Error('transient auth error'); return update(uid, data);};
  await assert.rejects(f.call(), /transient auth error/);
  assert.equal(f.accounts.get('orphan').phoneNumber, f.phone);
});
