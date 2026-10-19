import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { after, before, beforeEach, test } from 'node:test';
import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { collection, deleteDoc, doc, getDoc, getDocFromServer, getDocs, runTransaction, serverTimestamp, setDoc, updateDoc, writeBatch } from 'firebase/firestore';

let environment;
const code = 'a123456789abcdef';
const operationId = 'a'.repeat(32);
const database = (uid) => uid ? environment.authenticatedContext(uid).firestore() : environment.unauthenticatedContext().firestore();
const session = (db) => doc(db, `gameSessions/${code}`);
const receipt = (db, uid, id = operationId) => doc(db, `user/${uid}/gameOperations/${id}`);
const game = () => ({ id: code, ownerId: 'alice', format: 'standard', names: ['Alice', 'Bob'], life: [20, 20], members: ['alice', 'bob'], createdAt: serverTimestamp(), updatedAt: serverTimestamp(), operationVersion: 1, revision: 0, lastOperationId: null });
const intent = (kind = 'delta', extra = {}) => ({ sessionId: code, kind, player: kind === 'delta' || kind === 'rename' ? 0 : null, delta: kind === 'delta' ? -1 : null, name: kind === 'rename' ? 'Alicia' : null, ...extra });
const operation = (kind = 'delta', extra = {}) => ({ ...intent(kind), revision: 1, createdAt: serverTimestamp(), ...extra });
const patch = (extra = {}) => ({ life: [19, 20], revision: 1, lastOperationId: operationId, updatedAt: serverTimestamp(), ...extra });

before(async () => {
  environment = await initializeTestEnvironment({ projectId: 'demo-collector-game-operations', firestore: { host: '127.0.0.1', port: 18080, rules: await readFile(new URL('../firestore.rules', import.meta.url), 'utf8') } });
});
beforeEach(async () => {
  await environment.clearFirestore();
  await environment.withSecurityRulesDisabled(async (context) => setDoc(session(context.firestore()), game()));
});
after(async () => environment?.cleanup());

async function commit(uid, data = operation(), changes = patch(), id = operationId) {
  const db = database(uid);
  const batch = writeBatch(db);
  batch.set(receipt(db, uid, id), data);
  batch.update(session(db), changes);
  return batch.commit();
}

async function applyDelta(db, uid, id, delta) {
  const target = receipt(db, uid, id);
  const acknowledge = (data) => {
    const expected = intent('delta', { delta });
    for (const [key, value] of Object.entries(expected)) assert.equal(data[key], value, `A retry must preserve ${key}.`);
    assert.ok(Number.isSafeInteger(data.revision) && data.revision > 0);
    return data.revision;
  };
  for (let attempt = 0; attempt < 5; attempt++) {
    let attemptedRevision;
    try {
      return await runTransaction(db, async (transaction) => {
        const previous = await transaction.get(target);
        if (previous.exists()) return acknowledge(previous.data());
        const snapshot = await transaction.get(session(db));
        const current = snapshot.data();
        assert.ok(current.members.includes(uid));
        attemptedRevision = current.revision;
        const life = [...current.life];
        life[0] += delta;
        const revision = current.revision + 1;
        transaction.set(target, operation('delta', { delta, revision }));
        transaction.update(session(db), patch({ life, revision, lastOperationId: id }));
        return revision;
      });
    } catch (error) {
      if (error.code !== 'permission-denied' || attemptedRevision === undefined) throw error;
      let current;
      try {
        const saved = await getDocFromServer(target);
        if (saved.exists()) return acknowledge(saved.data());
        if (attempt === 4) throw error;
        current = (await getDocFromServer(session(db))).data();
      } catch (readError) {
        if (readError.code) throw error;
        throw readError;
      }
      if (current?.operationVersion !== 1 || current.revision <= attemptedRevision || !current.members.includes(uid)) throw error;
    }
  }
  throw new Error('Shared game retry limit reached.');
}

test('new protocol is opt-in; sessions start without a fabricated operation', async () => {
  await deleteDoc(session(database('alice')));
  for (const changes of [{ operationVersion: 2 }, { revision: 1 }, { lastOperationId: operationId }, { arbitrary: true }]) {
    await assertFails(setDoc(session(database('alice')), { ...game(), members: ['alice'], ...changes }));
  }
  await assertSucceeds(setDoc(session(database('alice')), { ...game(), members: ['alice'] }));
  await assertFails(updateDoc(session(database('alice')), { operationVersion: 2 }));
  await assertFails(updateDoc(session(database('alice')), { life: [19, 20], updatedAt: serverTimestamp() }));
});

test('member delta commits with a private immutable receipt', async () => {
  await assertSucceeds(commit('bob'));
  assert.deepEqual((await getDoc(session(database('bob')))).data().life, [19, 20]);
  assert.equal((await getDoc(receipt(database('bob'), 'bob'))).data().revision, 1);
  await assertFails(getDoc(receipt(database('alice'), 'bob')));
  await assertFails(getDocs(collection(database('alice'), 'user/bob/gameOperations')));
  await assertSucceeds(getDocs(collection(database('bob'), 'user/bob/gameOperations')));
  await assertFails(updateDoc(receipt(database('bob'), 'bob'), { delta: -10 }));
  await assertFails(deleteDoc(receipt(database('bob'), 'bob')));
});

test('operation and game mutation require each other in one atomic commit', async () => {
  await assertFails(setDoc(receipt(database('bob'), 'bob'), operation()));
  await assertFails(updateDoc(session(database('bob')), patch()));
  await assertSucceeds(commit('bob'));
  await assertFails(updateDoc(session(database('bob')), patch({ life: [18, 20], revision: 2 })));
  assert.deepEqual((await getDoc(session(database('bob')))).data().life, [19, 20]);
});

test('a client transaction uses the same atomic operation contract as a batch', async () => {
  assert.equal(await applyDelta(database('alice'), 'alice', '1'.repeat(32), -1), 1);
});

test('retries and concurrent clients account for every unique operation once', async () => {
  const first = database('alice');
  const second = database('bob');
  const results = await Promise.allSettled([
    applyDelta(first, 'alice', '1'.repeat(32), -1),
    applyDelta(second, 'bob', '2'.repeat(32), -10),
    applyDelta(first, 'alice', '1'.repeat(32), -1),
  ]);
  const current = (await getDoc(session(first))).data();
  assert.deepEqual(results.map((result) => result.status), ['fulfilled', 'fulfilled', 'fulfilled'], JSON.stringify({ results: results.map((result) => result.status === 'fulfilled' ? result.value : result.reason.message), current }));
  assert.deepEqual(current.life, [9, 20]);
  assert.equal(current.revision, 2);
  await assert.rejects(applyDelta(first, 'alice', '1'.repeat(32), 10));
  assert.equal((await getDocs(collection(first, 'user/alice/gameOperations'))).size, 1);
});

test('delta receipt cannot alter another player, names, ownership or membership', async () => {
  for (const changes of [{ life: [19, 19] }, { names: ['Other', 'Bob'] }, { ownerId: 'bob' }, { members: ['bob'] }, { revision: 3 }, { lastOperationId: 'b'.repeat(32) }, { updatedAt: new Date(0) }]) {
    await assertFails(commit('bob', operation(), patch(changes)));
  }
  for (const changes of [{ player: -1 }, { player: 2 }, { delta: 1.5 }, { delta: 0 }, { delta: -1000001 }, { name: 'hidden rename' }, { sessionId: 'b123456789abcdef' }, { revision: 2 }, { extra: true }, { createdAt: new Date(0) }]) {
    await assertFails(commit('bob', operation('delta', changes)));
  }
  await assertFails(commit('bob', operation(), patch({ lastOperationId: 'not-valid' }), 'not-valid'));
  await assertFails(commit('bob', operation('delta', { delta: 1000000 }), patch({ life: [1000020, 20] })));
  await assertSucceeds(commit('bob'));
});

test('joined members can rename one player and reset all players with receipts', async () => {
  await assertFails(commit('bob', operation('rename'), patch({ names: ['Alicia', 'Intruder'], life: [20, 20] })));
  await assertSucceeds(commit('bob', operation('rename'), patch({ names: ['Alicia', 'Bob'], life: [20, 20] })));
  await assertSucceeds(commit('alice', operation('delta', { revision: 2, delta: -12 }), patch({ life: [8, 20], revision: 2, lastOperationId: 'b'.repeat(32) }), 'b'.repeat(32)));
  await assertFails(commit('bob', operation('reset', { revision: 3 }), patch({ life: [20, 19], revision: 3, lastOperationId: 'c'.repeat(32) }), 'c'.repeat(32)));
  await assertSucceeds(commit('bob', operation('reset', { revision: 3 }), patch({ life: [20, 20], revision: 3, lastOperationId: 'c'.repeat(32) }), 'c'.repeat(32)));
  assert.deepEqual((await getDoc(session(database('bob')))).data().names, ['Alicia', 'Bob']);
});

test('eight-player Commander accepts the final player and resets to forty', async () => {
  await environment.withSecurityRulesDisabled(async (context) => setDoc(session(context.firestore()), {
    ...game(), format: 'commander', names: Array.from({ length: 8 }, (_, index) => `Player ${index + 1}`), life: Array(8).fill(40),
  }));
  await assertSucceeds(commit('bob', operation('delta', { player: 7, delta: -43 }), patch({ life: [40, 40, 40, 40, 40, 40, 40, -3] })));
  await assertSucceeds(commit('bob', operation('rename', { player: 7, name: 'Pat', revision: 2 }), patch({ life: [40, 40, 40, 40, 40, 40, 40, -3], names: ['Player 1', 'Player 2', 'Player 3', 'Player 4', 'Player 5', 'Player 6', 'Player 7', 'Pat'], revision: 2, lastOperationId: 'b'.repeat(32) }), 'b'.repeat(32)));
  await assertFails(commit('bob', operation('reset', { revision: 3 }), patch({ life: Array(8).fill(20), revision: 3, lastOperationId: 'c'.repeat(32) }), 'c'.repeat(32)));
  await assertSucceeds(commit('bob', operation('reset', { revision: 3 }), patch({ life: Array(8).fill(40), revision: 3, lastOperationId: 'c'.repeat(32) }), 'c'.repeat(32)));
});

test('Leave removes only its actor; the owner must End instead', async () => {
  await assertFails(commit('alice', operation('leave'), patch({ life: [20, 20], members: ['bob'] })));
  await assertFails(commit('bob', operation('leave'), patch({ life: [20, 20], members: ['bob'] })));
  await assertSucceeds(commit('bob', operation('leave'), patch({ life: [20, 20], members: ['alice'] })));
  assert.deepEqual((await getDoc(session(database('alice')))).data().members, ['alice']);
  await assertSucceeds(getDoc(receipt(database('bob'), 'bob')));
  await assertFails(commit('bob', operation('delta', { revision: 2 }), patch({ revision: 2, lastOperationId: 'b'.repeat(32) }), 'b'.repeat(32)));
  await assertSucceeds(updateDoc(session(database('bob')), { members: ['alice', 'bob'] }));
  await assertFails(deleteDoc(session(database('bob'))));
  await assertSucceeds(deleteDoc(session(database('alice'))));
  await assertSucceeds(getDoc(receipt(database('bob'), 'bob')));
});

test('nonmembers, unauthenticated and deleting actors cannot create operation receipts', async () => {
  await assertFails(commit('mallory'));
  const db = database(null);
  const batch = writeBatch(db);
  batch.set(receipt(db, 'bob'), operation());
  batch.update(session(db), patch());
  await assertFails(batch.commit());
  await environment.withSecurityRulesDisabled(async (context) => setDoc(doc(context.firestore(), 'accountDeletions/bob'), { state: 'pending' }));
  await assertFails(commit('bob'));
  await assertSucceeds(commit('alice'));
});

test('legacy sessions keep existing writes and cannot attach protocol receipts', async () => {
  await environment.withSecurityRulesDisabled(async (context) => {
    const { operationVersion, revision, lastOperationId, ...legacy } = game();
    await setDoc(session(context.firestore()), legacy);
  });
  await assertFails(commit('bob'));
  await assertSucceeds(updateDoc(session(database('bob')), { life: [19, 20], updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(session(database('alice')), { operationVersion: 1, revision: 0, lastOperationId: null }));
});
