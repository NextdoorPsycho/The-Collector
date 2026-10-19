export type DeletionState = 'pending' | 'complete';
export interface DeletionJob {
  readonly state: DeletionState;
  readonly requestedAt: number;
  readonly completedAt?: number;
}
export interface Caller {
  readonly uid: string;
  readonly authTime: unknown;
}
export class DeletionError extends Error {
  constructor(readonly code: 'unauthenticated' | 'invalid-argument' | 'failed-precondition', message: string, readonly reason?: 'requires-recent-login' | 'account-changed') {
    super(message);
  }
}
export interface DeletionStore {
  accept(uid: string, now: number, allowNew: boolean): Promise<DeletionState>;
  job(uid: string): Promise<DeletionJob | undefined>;
  deleteUserTree(uid: string): Promise<void>;
  deleteGames(uid: string, canContinue: () => boolean): Promise<boolean>;
  deleteStorage(uid: string, canContinue: () => boolean): Promise<boolean>;
  deleteAuth(uid: string): Promise<void>;
  complete(uid: string, now: number): Promise<void>;
}
export const RECENT_LOGIN_MS = 5 * 60 * 1000;
export const TOMBSTONE_MS = 24 * 60 * 60 * 1000;

export async function requestDeletion(
  caller: Caller | undefined,
  data: unknown,
  store: DeletionStore,
  now: number,
): Promise<{ accepted: true; state: DeletionState }> {
  if (!caller) throw new DeletionError('unauthenticated', 'Sign in before deleting your account.');
  if (typeof data !== 'object' || data === null || Array.isArray(data) ||
      Object.keys(data).length !== 1 || !('expectedUid' in data) || typeof data.expectedUid !== 'string') {
    throw new DeletionError('invalid-argument', 'Confirm the signed-in account before deleting it.');
  }
  if (data.expectedUid !== caller.uid) {
    throw new DeletionError('failed-precondition', 'The signed-in account has changed.', 'account-changed');
  }
  if (!caller.uid || caller.uid.includes('/') || caller.uid.length > 128) {
    throw new DeletionError('unauthenticated', 'A valid signed-in account is required.');
  }
  const loginMs: number = typeof caller.authTime === 'number' ? caller.authTime * 1000 : NaN;
  const allowNew: boolean = Number.isFinite(loginMs) && loginMs <= now && now - loginMs <= RECENT_LOGIN_MS;
  const state: DeletionState = await store.accept(caller.uid, now, allowNew);
  return { accepted: true, state };
}

export async function performDeletion(
  uid: string,
  store: DeletionStore,
  now: () => number = Date.now,
  budgetMs: number = 8 * 60 * 1000,
): Promise<boolean> {
  if (!uid || uid.includes('/') || uid.length > 128) throw new Error('Invalid deletion job ID.');
  const job: DeletionJob | undefined = await store.job(uid);
  if (!job || job.state === 'complete') return true;
  const deadline: number = now() + budgetMs;
  const canContinue: () => boolean = () => now() < deadline;
  await store.deleteUserTree(uid);
  if (!canContinue() || !await store.deleteGames(uid, canContinue)) return false;
  if (!canContinue() || !await store.deleteStorage(uid, canContinue)) return false;
  if (!canContinue()) return false;
  await store.deleteAuth(uid);
  await store.complete(uid, now());
  return true;
}
