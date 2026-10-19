import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { deleteApp, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { FieldValue, getFirestore, Timestamp } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';
import { performDeletion, requestDeletion } from '../src/account_deletion';
import { FirebaseDeletionStore } from '../src/firebase_deletion_store';

const enabled: boolean = process.env.RUN_ACCOUNT_DELETION_EMULATOR_TESTS === '1';
if (enabled && (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST || !process.env.FIREBASE_STORAGE_EMULATOR_HOST)) {
  throw new Error('All three emulator hosts must be set; this test never contacts production.');
}
const projectId = 'demo-collector-deletion-backend';
const app = enabled ? initializeApp({ projectId, storageBucket: `${projectId}.appspot.com` }, 'deletion-tests') : undefined;
after(async () => { if (app) await deleteApp(app); });

test('Admin worker erases >500 nested docs, paginates games/files, preserves concurrent joins, retries partial failure', { skip: !enabled, timeout: 120_000 }, async () => {
  const database = getFirestore(app!);
  const auth = getAuth(app!);
  const storage = getStorage(app!);
  const store = new FirebaseDeletionStore(database, auth, storage);
  const uid = `delete-${Date.now()}`;
  const other = `${uid}-other`;
  await auth.createUser({ uid });
  await auth.createUser({ uid: other });
  await database.doc(`user/${uid}`).set({ theme: false });
  await database.doc(`user/${other}/cards/keep`).set({ quantity: 9 });
  for (let start = 0; start < 610; start += 400) {
    const batch = database.batch();
    for (let index = start; index < Math.min(start + 400, 610); index++) {
      batch.set(database.doc(`user/${uid}/cards/card/priceObservations/${index}`), { price: index });
    }
    await batch.commit();
  }
  await database.doc(`user/${uid}/restricted/perms`).set({ admin: true });
  await database.doc(`user/${uid}/ingestionOperations/receipt`).set({ quantity: 1 });
  await database.doc(`user/${uid}/gameOperations/receipt`).set({ sessionId: 'ended-game', kind: 'delta', delta: -1 });
  const batch = database.batch();
  for (let index = 0; index < 105; index++) {
    batch.set(database.doc(`gameSessions/${uid}-owned-${index}`), { ownerId: uid, members: [uid, other] });
    batch.set(database.doc(`gameSessions/${uid}-joined-${index}`), { ownerId: other, members: [other, uid], life: [20, 20], names: ['A', 'B'] });
  }
  await batch.commit();
  const bucket = storage.bucket();
  for (let start = 0; start < 105; start += 5) {
    await Promise.all(Array.from({ length: Math.min(5, 105 - start) }, (_, offset) => bucket.file(`user/${uid}/private/${start + offset}.txt`).save('delete')));
  }
  await bucket.file(`user/${other}/private/keep.txt`).save('keep');
  await bucket.file(`user/${uid}suffix/private/keep.txt`).save('keep');
  await requestDeletion({ uid, authTime: Date.now() / 1000 }, { expectedUid: uid }, store, Date.now());
  const failingStore = new FirebaseDeletionStore(database, auth, storage);
  failingStore.deleteStorage = async (): Promise<boolean> => { throw new Error('Injected storage outage'); };
  await assert.rejects(performDeletion(uid, failingStore));
  assert.equal((await store.job(uid))!.state, 'pending');
  assert.equal((await auth.getUser(uid)).uid, uid);
  assert.equal((await database.collection(`user/${uid}/cards/card/priceObservations`).get()).size, 0);
  const concurrentGame = database.doc(`gameSessions/${uid}-joined-0`);
  await concurrentGame.update({ members: FieldValue.arrayUnion(uid) });
  const cleanup = store.deleteGames(uid, () => true);
  const join = concurrentGame.update({ members: FieldValue.arrayUnion('concurrent-new-member') });
  await Promise.all([cleanup, join]);
  assert.deepEqual((await concurrentGame.get()).get('members').sort(), [other, 'concurrent-new-member'].sort());
  const completionFailure = new FirebaseDeletionStore(database, auth, storage);
  completionFailure.complete = async (): Promise<void> => { throw new Error('Injected completion outage'); };
  await assert.rejects(performDeletion(uid, completionFailure));
  await assert.rejects(auth.getUser(uid), { code: 'auth/user-not-found' });
  assert.equal((await store.job(uid))!.state, 'pending');
  await performDeletion(uid, store);
  await performDeletion(uid, store);
  assert.equal((await store.job(uid))!.state, 'complete');
  assert.ok((await store.job(uid))!.completedAt);
  await assert.rejects(auth.getUser(uid), { code: 'auth/user-not-found' });
  assert.equal((await auth.getUser(other)).uid, other);
  assert.equal((await database.doc(`user/${uid}`).get()).exists, false);
  assert.equal((await database.doc(`user/${uid}/restricted/perms`).get()).exists, false);
  assert.equal((await database.doc(`user/${uid}/ingestionOperations/receipt`).get()).exists, false);
  assert.equal((await database.doc(`user/${uid}/gameOperations/receipt`).get()).exists, false);
  assert.equal((await database.doc(`user/${other}/cards/keep`).get()).get('quantity'), 9);
  assert.equal((await database.collection('gameSessions').where('ownerId', '==', uid).get()).empty, true);
  assert.equal((await database.collection('gameSessions').where('members', 'array-contains', uid).get()).empty, true);
  assert.equal((await bucket.getFiles({ prefix: `user/${uid}/`, autoPaginate: false }))[0].length, 0);
  assert.equal((await bucket.file(`user/${other}/private/keep.txt`).exists())[0], true);
  assert.equal((await bucket.file(`user/${uid}suffix/private/keep.txt`).exists())[0], true);
  assert.equal((await database.doc(`accountDeletions/${uid}`).get()).get('requestedAt') instanceof Timestamp, true);
  // Remove only this test's surviving fixtures, never clear a shared emulator database.
  await database.recursiveDelete(database.doc(`user/${other}`));
  for (let index = 0; index < 105; index++) await database.doc(`gameSessions/${uid}-joined-${index}`).delete();
  await bucket.file(`user/${other}/private/keep.txt`).delete();
  await bucket.file(`user/${uid}suffix/private/keep.txt`).delete();
  await auth.deleteUser(other);
  await database.doc(`accountDeletions/${uid}`).delete();
});
