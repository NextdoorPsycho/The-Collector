import { Auth } from 'firebase-admin/auth';
import { BulkWriter, FieldValue, Firestore, GrpcStatus, Timestamp } from 'firebase-admin/firestore';
import { Storage } from 'firebase-admin/storage';
import { DeletionError, DeletionJob, DeletionState, DeletionStore } from './account_deletion';

export const PAGE_SIZE = 100;
type BulkWriteError = Parameters<Parameters<BulkWriter['onWriteError']>[0]>[0];

export function shouldRetryRecursiveDelete(
  error: Pick<BulkWriteError, 'code' | 'operationType' | 'failedAttempts'>,
): boolean {
  // Firestore 9.3.1 defaults also retry RESOURCE_EXHAUSTED and delete-only INTERNAL.
  const defaultRetry: boolean = error.code === GrpcStatus.RESOURCE_EXHAUSTED ||
    error.code === GrpcStatus.ABORTED || error.code === GrpcStatus.UNAVAILABLE ||
    (error.operationType === 'delete' && error.code === GrpcStatus.INTERNAL);
  const cancelledDelete: boolean = error.operationType === 'delete' && error.code === GrpcStatus.CANCELLED;
  return (defaultRetry || cancelledDelete) && error.failedAttempts < 10;
}
export class FirebaseDeletionStore implements DeletionStore {
  constructor(private readonly database: Firestore, private readonly auth: Auth, private readonly storage: Storage) {}

  async accept(uid: string, now: number, allowNew: boolean): Promise<DeletionState> {
    const reference = this.database.doc(`accountDeletions/${uid}`);
    return this.database.runTransaction(async (transaction): Promise<DeletionState> => {
      const snapshot = await transaction.get(reference);
      if (snapshot.exists) return snapshot.get('state') as DeletionState;
      if (!allowNew) throw new DeletionError('failed-precondition', 'Sign in again before deleting your account.');
      transaction.create(reference, { state: 'pending', requestedAt: Timestamp.fromMillis(now) });
      return 'pending';
    });
  }

  async job(uid: string): Promise<DeletionJob | undefined> {
    const snapshot = await this.database.doc(`accountDeletions/${uid}`).get();
    if (!snapshot.exists) return undefined;
    const state: unknown = snapshot.get('state');
    const requestedAt: unknown = snapshot.get('requestedAt');
    const completedAt: unknown = snapshot.get('completedAt');
    if ((state !== 'pending' && state !== 'complete') || !(requestedAt instanceof Timestamp)) {
      throw new Error('Invalid deletion job.');
    }
    return { state, requestedAt: requestedAt.toMillis(),
      ...(completedAt instanceof Timestamp ? { completedAt: completedAt.toMillis() } : {}) };
  }

  async deleteUserTree(uid: string): Promise<void> {
    const writer: BulkWriter = this.database.bulkWriter();
    writer.onWriteError(shouldRetryRecursiveDelete);
    try {
      await this.database.recursiveDelete(this.database.doc(`user/${uid}`), writer);
    } finally {
      await writer.close();
    }
  }

  async deleteGames(uid: string, canContinue: () => boolean): Promise<boolean> {
    for (const field of ['ownerId', 'members'] as const) {
      while (canContinue()) {
        const page = await this.database.collection('gameSessions')
          .where(field, field === 'ownerId' ? '==' : 'array-contains', uid).limit(PAGE_SIZE).get();
        if (page.empty) break;
        for (const document of page.docs) {
          if (!canContinue()) return false;
          await this.database.runTransaction(async (transaction): Promise<void> => {
            const current = await transaction.get(document.ref);
            if (!current.exists) return;
            if (current.get('ownerId') === uid) {
              transaction.delete(document.ref);
            } else {
              // Transform the latest membership atomically; never replace a stale array.
              transaction.update(document.ref, { members: FieldValue.arrayRemove(uid) });
            }
          });
        }
      }
      if (!canContinue()) return false;
    }
    return true;
  }

  async deleteStorage(uid: string, canContinue: () => boolean): Promise<boolean> {
    const bucket = this.storage.bucket();
    while (canContinue()) {
      const [files] = await bucket.getFiles({ prefix: `user/${uid}/`, maxResults: PAGE_SIZE, autoPaginate: false, versions: true });
      if (files.length === 0) return true;
      for (const file of files) {
        if (!canContinue()) return false;
        await file.delete({ ignoreNotFound: true });
      }
    }
    return false;
  }

  async deleteAuth(uid: string): Promise<void> {
    try {
      await this.auth.deleteUser(uid);
    } catch (error: unknown) {
      if (typeof error !== 'object' || error === null || !('code' in error) || error.code !== 'auth/user-not-found') throw error;
    }
  }

  async complete(uid: string, now: number): Promise<void> {
    const reference = this.database.doc(`accountDeletions/${uid}`);
    await this.database.runTransaction(async (transaction): Promise<void> => {
      const snapshot = await transaction.get(reference);
      if (snapshot.exists && snapshot.get('state') === 'pending') {
        transaction.update(reference, { state: 'complete', completedAt: Timestamp.fromMillis(now) });
      }
    });
  }
}
