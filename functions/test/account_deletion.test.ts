import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DeletionError, DeletionJob, DeletionState, DeletionStore, performDeletion, requestDeletion } from '../src/account_deletion';

class Store implements DeletionStore {
  jobs = new Map<string, DeletionJob>();
  calls: string[] = [];
  failAt: string | undefined;
  authPresent = true;
  async accept(uid: string, now: number, allowNew: boolean): Promise<DeletionState> {
    const existing: DeletionJob | undefined = this.jobs.get(uid);
    if (existing) return existing.state;
    if (!allowNew) throw new DeletionError('failed-precondition', 'Sign in again.');
    this.jobs.set(uid, { state: 'pending', requestedAt: now });
    return 'pending';
  }
  async job(uid: string): Promise<DeletionJob | undefined> { return this.jobs.get(uid); }
  private operation(step: string): void {
    this.calls.push(step);
    if (this.failAt === step) throw new Error('Temporary service failure');
  }
  async deleteUserTree(uid: string): Promise<void> { this.operation(`tree:${uid}`); }
  async deleteGames(uid: string, canContinue: () => boolean): Promise<boolean> { this.operation(`games:${uid}`); return canContinue(); }
  async deleteStorage(uid: string, canContinue: () => boolean): Promise<boolean> { this.operation(`storage:${uid}`); return canContinue(); }
  async deleteAuth(uid: string): Promise<void> { this.operation(`auth:${uid}`); this.authPresent = false; }
  async complete(uid: string, now: number): Promise<void> {
    this.operation(`complete:${uid}`);
    this.jobs.set(uid, { state: 'complete', requestedAt: this.jobs.get(uid)!.requestedAt, completedAt: now });
  }
}
const now = 1_800_000_000_000;
const caller = { uid: 'alice', authTime: now / 1000 };
const confirmation = { expectedUid: 'alice' };

test('caller UID is authoritative, payloads cannot select another account', async () => {
  const store = new Store();
  await assert.rejects(requestDeletion(undefined, null, store, now), { code: 'unauthenticated' });
  for (const payload of [null, {}, { uid: 'bob' }, { path: 'user/bob' }, { expectedUid: 'alice', uid: 'bob' }, [], 'bob', 1]) {
    await assert.rejects(requestDeletion(caller, payload, store, now), { code: 'invalid-argument' });
  }
  await assert.rejects(requestDeletion(caller, { expectedUid: 'bob' }, store, now), { code: 'failed-precondition', reason: 'account-changed' });
  assert.equal(store.jobs.size, 0);
  assert.deepEqual(await requestDeletion(caller, confirmation, store, now), { accepted: true, state: 'pending' });
  assert.deepEqual([...store.jobs.keys()], ['alice']);
  assert.deepEqual(store.calls, []);
});

test('first request requires auth_time within five minutes; existing job can be resumed', async () => {
  for (const authTime of [undefined, 'fresh', now / 1000 - 301, now / 1000 + 1]) {
    await assert.rejects(requestDeletion({ uid: 'alice', authTime }, confirmation, new Store(), now), { code: 'failed-precondition' });
  }
  const store = new Store();
  await requestDeletion({ uid: 'alice', authTime: now / 1000 - 300 }, confirmation, store, now);
  assert.equal((await requestDeletion({ uid: 'alice', authTime: 0 }, confirmation, store, now)).state, 'pending');
  assert.equal(store.jobs.get('alice')!.requestedAt, now);
});

test('partial failure retains pending marker and Auth; retry cleans only caller then Auth last', async () => {
  const store = new Store();
  await requestDeletion(caller, confirmation, store, now);
  store.failAt = 'storage:alice';
  await assert.rejects(performDeletion('alice', store, () => now));
  assert.equal(store.authPresent, true);
  assert.equal(store.jobs.get('alice')!.state, 'pending');
  store.failAt = undefined;
  store.calls = [];
  assert.equal(await performDeletion('alice', store, () => now), true);
  assert.deepEqual(store.calls, ['tree:alice', 'games:alice', 'storage:alice', 'auth:alice', 'complete:alice']);
  store.calls = [];
  assert.equal(await performDeletion('alice', store, () => now), true);
  assert.deepEqual(store.calls, []);
});

test('completion failure after Auth deletion safely replays with protected pending job', async () => {
  const store = new Store();
  await requestDeletion(caller, confirmation, store, now);
  store.failAt = 'complete:alice';
  await assert.rejects(performDeletion('alice', store, () => now));
  assert.equal(store.authPresent, false);
  assert.equal(store.jobs.get('alice')!.state, 'pending');
  store.failAt = undefined;
  await performDeletion('alice', store, () => now);
  assert.equal(store.jobs.get('alice')!.state, 'complete');
});

test('expired work budget leaves a resumable job without starting Auth deletion', async () => {
  const store = new Store();
  await requestDeletion(caller, confirmation, store, now);
  let clock = now;
  assert.equal(await performDeletion('alice', store, () => { clock += 100; return clock; }, 50), false);
  assert.equal(store.jobs.get('alice')!.state, 'pending');
  assert.equal(store.authPresent, true);
  assert.deepEqual(store.calls, ['tree:alice']);
});
