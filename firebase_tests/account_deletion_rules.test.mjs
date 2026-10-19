import { readFile } from 'node:fs/promises';
import { after, before, beforeEach, test } from 'node:test';
import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { collection, deleteDoc, doc, getDoc, getDocs, serverTimestamp, setDoc, updateDoc } from 'firebase/firestore';
import { getMetadata, ref, uploadString } from 'firebase/storage';

let environment;
const gameId = 'a123456789abcdef';
const context = (uid) => uid ? environment.authenticatedContext(uid) : environment.unauthenticatedContext();
const database = (uid) => context(uid).firestore();
const game = () => ({ id: gameId, ownerId: 'alice', format: 'standard', names: ['A', 'B'], life: [20, 20], members: ['alice'], createdAt: serverTimestamp(), updatedAt: serverTimestamp() });

before(async () => {
  environment = await initializeTestEnvironment({
    projectId: 'demo-the-collector',
    firestore: { host: '127.0.0.1', port: 18080, rules: await readFile(new URL('../firestore.rules', import.meta.url), 'utf8') },
    storage: { host: '127.0.0.1', port: 19199, rules: await readFile(new URL('../storage.rules', import.meta.url), 'utf8') },
  });
});
beforeEach(async () => {
  await environment.clearFirestore();
  await environment.clearStorage();
  await environment.withSecurityRulesDisabled(async (admin) => {
    await setDoc(doc(admin.firestore(), 'user/alice'), { theme: false });
    await setDoc(doc(admin.firestore(), 'user/alice/restricted/perms'), { admin: true });
    await setDoc(doc(admin.firestore(), `gameSessions/${gameId}`), game());
    for (const uid of ['alice', 'bob']) {
      await uploadString(ref(admin.storage(), `user/${uid}/public/card.jpg`), 'image');
      await uploadString(ref(admin.storage(), `user/${uid}/private/card.jpg`), 'image');
    }
  });
});
after(async () => environment?.cleanup());

async function mark(uid, state = 'pending') {
  await environment.withSecurityRulesDisabled(async (admin) => {
    await setDoc(doc(admin.firestore(), `accountDeletions/${uid}`), { state, requestedAt: serverTimestamp(), ...(state === 'complete' ? { completedAt: serverTimestamp() } : {}) });
  });
}

test('deletion jobs are own get only, including after deletion begins; never client write or enumerate', async () => {
  await mark('alice');
  await assertSucceeds(getDoc(doc(database('alice'), 'accountDeletions/alice')));
  await assertFails(getDoc(doc(database('bob'), 'accountDeletions/alice')));
  await assertFails(getDoc(doc(database(null), 'accountDeletions/alice')));
  await assertFails(getDocs(collection(database('alice'), 'accountDeletions')));
  for (const uid of ['alice', 'bob']) {
    await assertFails(setDoc(doc(database(uid), `accountDeletions/${uid}`), { state: 'pending' }));
  }
  await assertFails(updateDoc(doc(database('alice'), 'accountDeletions/alice'), { state: 'complete' }));
  await assertFails(deleteDoc(doc(database('alice'), 'accountDeletions/alice')));
});

test('pending and completed markers block stale-token profile, nested, receipt, game and admin writes', async () => {
  for (const state of ['pending', 'complete']) {
    await mark('alice', state);
    for (const path of ['user/alice', 'user/alice/cards/card', 'user/alice/cards/card/priceObservations/today', 'user/alice/decks/deck', 'user/alice/priceHistory/today']) {
      await assertFails(setDoc(doc(database('alice'), path), { value: 1 }));
    }
    await assertFails(setDoc(doc(database('alice'), 'user/alice/ingestionOperations/receipt'), { cardId: 'card', quantity: 1, language: 'en', finish: 'nonfoil', createdAt: serverTimestamp() }));
    await assertFails(setDoc(doc(database('alice'), 'user/bob/restricted/perms'), { admin: true }));
    await assertFails(setDoc(doc(database('alice'), 'gameSessions/b123456789abcdef'), { ...game(), id: 'b123456789abcdef' }));
    await assertFails(updateDoc(doc(database('alice'), `gameSessions/${gameId}`), { life: [19, 20], updatedAt: serverTimestamp() }));
    await assertFails(deleteDoc(doc(database('alice'), `gameSessions/${gameId}`)));
  }
});

test('deleting actors cannot join other games or recreate Storage; active owners retain access', async () => {
  await mark('bob');
  await assertFails(updateDoc(doc(database('bob'), `gameSessions/${gameId}`), { members: ['alice', 'bob'] }));
  await assertSucceeds(updateDoc(doc(database('carol'), `gameSessions/${gameId}`), { members: ['alice', 'carol'] }));
  await assertSucceeds(setDoc(doc(database('alice'), 'user/alice/cards/new'), { quantity: 1 }));
  for (const folder of ['public', 'decks', 'private', 'collection']) {
    await assertFails(uploadString(ref(context('bob').storage(), `user/bob/${folder}/new.jpg`), 'image'));
    await assertSucceeds(uploadString(ref(context('alice').storage(), `user/alice/${folder}/new.jpg`), 'image'));
  }
  await assertFails(getMetadata(ref(context(null).storage(), 'user/bob/public/card.jpg')));
  await assertSucceeds(getMetadata(ref(context(null).storage(), 'user/alice/public/card.jpg')));
  await assertFails(uploadString(ref(context('alice').storage(), 'prefix/user/alice/public/new.jpg'), 'image'));
});

test('active admin cannot grant permissions to a deleting target', async () => {
  await mark('bob');
  await assertFails(setDoc(doc(database('alice'), 'user/bob/restricted/perms'), { admin: true }));
  await assertSucceeds(setDoc(doc(database('alice'), 'user/carol/restricted/perms'), { admin: true }));
});
