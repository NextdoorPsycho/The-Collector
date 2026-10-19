import { readFile } from 'node:fs/promises';
import { after, before, beforeEach, test } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  setDoc,
  serverTimestamp,
  updateDoc,
} from 'firebase/firestore';
import { deleteObject, getMetadata, ref, uploadString } from 'firebase/storage';

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment} */
let environment;

before(async () => {
  environment = await initializeTestEnvironment({
    projectId: 'demo-the-collector',
    firestore: {
      host: '127.0.0.1',
      port: 18080,
      rules: await readFile(new URL('../firestore.rules', import.meta.url), 'utf8'),
    },
    storage: {
      host: '127.0.0.1',
      port: 19199,
      rules: await readFile(new URL('../storage.rules', import.meta.url), 'utf8'),
    },
  });
});

beforeEach(async () => {
  await environment.clearFirestore();
  await environment.clearStorage();
  await environment.withSecurityRulesDisabled(async (context) => {
    const database = context.firestore();
    await setDoc(doc(database, 'user/alice'), { theme: false });
    await setDoc(doc(database, 'user/alice/cards/card'), { quantity: 1 });
    await setDoc(doc(database, 'user/alice/decks/deck'), { name: 'Test deck' });
    await setDoc(doc(database, 'user/alice/restricted/perms'), { admin: true });
    for (const folder of ['public', 'decks', 'private', 'collection']) {
      await uploadString(ref(context.storage(), `user/alice/${folder}/file`), 'test');
    }
  });
});

after(async () => {
  await environment?.cleanup();
});

test('owners can create, read, update, and delete their profiles', async () => {
  const database = environment.authenticatedContext('bob').firestore();
  const profile = doc(database, 'user/bob');
  await assertSucceeds(setDoc(profile, { theme: false }));
  await assertSucceeds(getDoc(profile));
  await assertSucceeds(updateDoc(profile, { theme: true }));
  await assertSucceeds(deleteDoc(profile));
});

test('owners can manage and query their cards and decks', async () => {
  const database = environment.authenticatedContext('alice').firestore();
  for (const folder of ['cards', 'decks']) {
    const document = doc(database, `user/alice/${folder}/new`);
    await assertSucceeds(setDoc(document, { name: 'Test' }));
    await assertSucceeds(getDoc(document));
    await assertSucceeds(getDocs(collection(database, `user/alice/${folder}`)));
    await assertSucceeds(updateDoc(document, { name: 'Updated' }));
    await assertSucceeds(deleteDoc(document));
  }
});

test('anonymous clients cannot access profiles, collections, or permissions', async () => {
  const database = environment.unauthenticatedContext().firestore();
  for (const path of ['user/alice', 'user/alice/cards/card', 'user/alice/decks/deck', 'user/alice/restricted/perms']) {
    await assertFails(getDoc(doc(database, path)));
    await assertFails(setDoc(doc(database, path), { admin: true }));
  }
});

test('users cannot read, modify, delete, or query another user’s data', async () => {
  const database = environment.authenticatedContext('bob').firestore();
  for (const path of ['user/alice', 'user/alice/cards/card', 'user/alice/decks/deck', 'user/alice/restricted/perms']) {
    await assertFails(getDoc(doc(database, path)));
    await assertFails(setDoc(doc(database, path), { admin: true }));
    await assertFails(deleteDoc(doc(database, path)));
  }
  await assertFails(getDocs(collection(database, 'user/alice/cards')));
  await assertFails(getDocs(collection(database, 'user')));
});

test('owners can read permissions but cannot grant or revoke admin access', async () => {
  const database = environment.authenticatedContext('alice').firestore();
  const permissions = doc(database, 'user/alice/restricted/perms');
  await assertSucceeds(getDoc(permissions));
  await assertFails(setDoc(permissions, { admin: true }));
  await assertFails(updateDoc(permissions, { admin: false }));
  await assertFails(deleteDoc(permissions));
  const absent = doc(environment.authenticatedContext('bob').firestore(), 'user/bob/restricted/perms');
  await assertSucceeds(getDoc(absent));
  await assertFails(setDoc(absent, { admin: true }));
});

test('ingestion receipts are owner scoped and immutable after creation', async () => {
  const database = environment.authenticatedContext('alice').firestore();
  const receipt = doc(database, 'user/alice/ingestionOperations/scan-item-1');
  const data = {
    cardId: 'd88a8e2d-2577-4a67-af86-e33c0ba94114',
    quantity: 2,
    language: 'en',
    finish: 'nonfoil',
    createdAt: serverTimestamp(),
  };
  await assertSucceeds(setDoc(receipt, data));
  await assertSucceeds(getDoc(receipt));
  await assertFails(updateDoc(receipt, { quantity: 3 }));
  await assertFails(deleteDoc(receipt));
  for (const context of [environment.unauthenticatedContext(), environment.authenticatedContext('bob')]) {
    const other = doc(context.firestore(), 'user/alice/ingestionOperations/scan-item-1');
    await assertFails(getDoc(other));
    await assertFails(setDoc(doc(context.firestore(), 'user/alice/ingestionOperations/new'), data));
  }
});

test('ingestion receipts reject invalid quantities, finish and unexpected fields', async () => {
  const database = environment.authenticatedContext('alice').firestore();
  const data = { cardId: 'printing', quantity: 1, language: 'en', finish: 'foil', createdAt: serverTimestamp() };
  for (const change of [{ quantity: 0 }, { quantity: -1 }, { quantity: 1.5 }, { quantity: 1000001 }, { finish: 'unknown' }, { admin: true }, { createdAt: new Date(0) }]) {
    await assertFails(setDoc(doc(collection(database, 'user/alice/ingestionOperations')), { ...data, ...change }));
  }
});

test('unrecognized Firestore paths deny access even to authenticated users', async () => {
  const database = environment.authenticatedContext('alice').firestore();
  for (const path of ['unknown/document', 'user/alice/unknown/document', 'user/alice/restricted/other']) {
    await assertFails(getDoc(doc(database, path)));
    await assertFails(setDoc(doc(database, path), { value: true }));
  }
});

test('owners can manage all existing Storage folders', async () => {
  const storage = environment.authenticatedContext('alice').storage();
  for (const folder of ['public', 'decks', 'private', 'collection']) {
    const file = ref(storage, `user/alice/${folder}/new`);
    await assertSucceeds(uploadString(file, 'test'));
    await assertSucceeds(getMetadata(file));
    await assertSucceeds(deleteObject(file));
  }
});

test('existing public files remain readable without authentication but not writable', async () => {
  const storage = environment.unauthenticatedContext().storage();
  for (const folder of ['public', 'decks']) {
    const file = ref(storage, `user/alice/${folder}/file`);
    await assertSucceeds(getMetadata(file));
    await assertFails(uploadString(file, 'changed'));
    await assertFails(deleteObject(file));
  }
});

test('private Storage files are isolated from anonymous and other users', async () => {
  for (const context of [environment.unauthenticatedContext(), environment.authenticatedContext('bob')]) {
    for (const folder of ['private', 'collection']) {
      const file = ref(context.storage(), `user/alice/${folder}/file`);
      await assertFails(getMetadata(file));
      await assertFails(uploadString(file, 'changed'));
      await assertFails(deleteObject(file));
    }
  }
});

test('unrecognized Storage folders cannot receive files', async () => {
  const storage = environment.authenticatedContext('alice').storage();
  await assertFails(uploadString(ref(storage, 'unknown/file'), 'test'));
  await assertFails(uploadString(ref(storage, 'user/alice/unknown/file'), 'test'));
});

test('allowed Storage folder names do not grant access beneath arbitrary prefixes', async () => {
  const paths = ['archive/user/alice/public/file', 'user/bob/private/user/alice/decks/file',
    'archive/user/alice/private/file', 'user/bob/collection/user/alice/collection/file'];
  await environment.withSecurityRulesDisabled(async (context) => {
    for (const path of paths) {
      await uploadString(ref(context.storage(), path), 'private fixture');
    }
  });
  for (const context of [environment.unauthenticatedContext(),
    environment.authenticatedContext('alice'), environment.authenticatedContext('bob')]) {
    for (const path of paths) {
      const file = ref(context.storage(), path);
      await assertFails(getMetadata(file));
      await assertFails(uploadString(file, 'changed'));
      await assertFails(deleteObject(file));
    }
  }
});
