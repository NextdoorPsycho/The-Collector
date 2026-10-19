import { readFile } from 'node:fs/promises';
import { after, before, beforeEach, test } from 'node:test';
import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { arrayUnion, collection, deleteDoc, doc, getDoc, getDocs, query, serverTimestamp, setDoc, updateDoc, where } from 'firebase/firestore';

let environment;
const code = 'a123456789abcdef';
const game = () => ({ id: code, ownerId: 'alice', format: 'standard', names: ['Alice', 'Bob'], life: [20, 20], members: ['alice'], createdAt: serverTimestamp(), updatedAt: serverTimestamp() });
const database = (uid) => uid ? environment.authenticatedContext(uid).firestore() : environment.unauthenticatedContext().firestore();
const session = (uid) => doc(database(uid), `gameSessions/${code}`);

before(async () => {
  environment = await initializeTestEnvironment({ projectId: 'demo-collector-games', firestore: { host: '127.0.0.1', port: 18080, rules: await readFile(new URL('../firestore.rules', import.meta.url), 'utf8') } });
});
beforeEach(async () => {
  await environment.clearFirestore();
  await environment.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'user/alice'), { theme: false });
    await setDoc(doc(context.firestore(), 'user/bob'), { theme: false });
    await setDoc(doc(context.firestore(), 'user/alice/restricted/perms'), { admin: true });
  });
});
after(async () => environment?.cleanup());

async function create() { await assertSucceeds(setDoc(session('alice'), game())); }

test('admins can list profiles and manage other roles without reading their private cards', async () => {
  await assertSucceeds(getDocs(collection(database('alice'), 'user')));
  await assertFails(getDocs(collection(database('bob'), 'user')));
  await assertSucceeds(setDoc(doc(database('alice'), 'user/bob/restricted/perms'), { admin: true }));
  await assertFails(setDoc(doc(database('alice'), 'user/alice/restricted/perms'), { admin: false }));
  await assertFails(setDoc(doc(database('alice'), 'user/bob/restricted/perms'), { admin: false, other: true }));
  await assertFails(getDoc(doc(database('alice'), 'user/bob/cards/card')));
});

test('anonymous users cannot read or create games; nonmembers cannot enumerate them', async () => {
  await create();
  await assertFails(getDoc(session(null)));
  await assertFails(setDoc(session(null), game()));
  await assertFails(getDocs(collection(database('bob'), 'gameSessions')));
  await assertSucceeds(getDoc(session('bob')));
  await assertSucceeds(getDocs(query(collection(database('alice'), 'gameSessions'), where('members', 'array-contains', 'alice'))));
});

test('join by code adds only the authenticated user and cannot mutate life or permissions', async () => {
  await create();
  await assertFails(updateDoc(session('bob'), { life: [1, 1], updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(session('bob'), { members: arrayUnion('mallory') }));
  await assertFails(updateDoc(session('bob'), { members: ['bob'] }));
  await assertFails(updateDoc(session('bob'), { members: ['alice', 'bob', 'mallory'] }));
  await assertSucceeds(updateDoc(session('bob'), { members: arrayUnion('bob') }));
  await assertSucceeds(updateDoc(session('bob'), { life: [19, 20], updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(session('bob'), { ownerId: 'bob' }));
  await assertFails(updateDoc(session('bob'), { members: ['bob'] }));
});

test('session writes validate player data and preserve immutable setup', async () => {
  for (const change of [{ ownerId: 'bob' }, { members: ['alice', 'bob'] }, { names: ['One'], life: [20] }, { names: ['One', 'Two'], life: [20, 'bad'] }, { format: 'unknown' }, { extra: true }]) {
    await assertFails(setDoc(session('alice'), { ...game(), ...change }));
  }
  await create();
  await assertFails(updateDoc(session('alice'), { format: 'commander', updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(session('alice'), { names: ['One', 'Two', 'Three'], life: [20, 20, 20], updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(session('alice'), { life: [1.5, 20], updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(session('alice'), { updatedAt: new Date(0) }));
  await assertFails(deleteDoc(session('bob')));
  await assertSucceeds(deleteDoc(session('alice')));
});

test('price history stays private to its owner', async () => {
  const observation = doc(database('bob'), 'user/bob/priceHistory/2026-10-09_usd');
  await assertSucceeds(setDoc(observation, { total: 12.34, currency: 'usd' }));
  await assertSucceeds(getDoc(observation));
  await assertFails(getDoc(doc(database('alice'), 'user/bob/priceHistory/2026-10-09_usd')));
});
