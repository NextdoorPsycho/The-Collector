import assert from 'node:assert/strict';
import { MockTracker, test } from 'node:test';
import { Auth } from 'firebase-admin/auth';
import { BulkWriter, DocumentReference, Firestore, GrpcStatus } from 'firebase-admin/firestore';
import { Storage } from 'firebase-admin/storage';
import { FirebaseDeletionStore, shouldRetryRecursiveDelete } from '../src/firebase_deletion_store';

type WriteError = Parameters<Parameters<BulkWriter['onWriteError']>[0]>[0];
type RetryError = Pick<WriteError, 'code' | 'operationType' | 'failedAttempts'>;

test('effective installed SDK default policy stays intact, only cancelled deletes gain retries', async () => {
  const database = new Firestore({ projectId: 'demo-deletion-retry-policy' });
  const writer: BulkWriter = database.bulkWriter();
  const sdkPolicy: (error: RetryError) => boolean =
    (writer as unknown as { _errorFn: (error: RetryError) => boolean })._errorFn;
  try {
    for (let code = 0; code <= 16; code++) {
      for (const operationType of ['delete', 'create', 'set', 'update'] as const) {
        for (const failedAttempts of [1, 9, 10, 11]) {
          const error: RetryError = { code, operationType, failedAttempts };
          const expected: boolean = sdkPolicy(error) ||
            (code === GrpcStatus.CANCELLED && operationType === 'delete' && failedAttempts < 10);
          assert.equal(shouldRetryRecursiveDelete(error), expected, JSON.stringify(error));
        }
      }
    }
  } finally { await writer.close(); await database.terminate(); }
});

interface DeleteRequest { readonly writes: ReadonlyArray<{ readonly delete?: string }> }
interface Transport {
  initializeIfNeeded(): Promise<void>;
  request(method: string, request: DeleteRequest): Promise<{ status: Array<{ code: number }>; writeResults: Array<Record<string, never>> }>;
  recursiveDelete(reference: DocumentReference, writer: BulkWriter): Promise<void>;
}

async function exerciseDelete(
  failureCode: GrpcStatus,
  failures: number,
  mock: MockTracker,
): Promise<{ attempts: Map<string, number>; progress: string[]; remaining: Set<string>; failure: unknown }> {
  const database = new Firestore({ projectId: 'demo-deletion-retry-transport' });
  const internal = database as unknown as Transport;
  const attempts = new Map<string, number>();
  const progress: string[] = [];
  const remaining = new Set<string>(['cancelled', 'healthy']);
  const bulkStatic = BulkWriter as unknown as { _applyJitter: (delay: number) => number };
  // Remove only backoff delay; exercise the real SDK operation retry/callback path.
  const timing = mock.method(bulkStatic, '_applyJitter', () => 0);
  internal.initializeIfNeeded = async (): Promise<void> => {};
  internal.request = async (method: string, request: DeleteRequest) => {
    assert.equal(method, 'batchWrite');
    const status: Array<{ code: number }> = request.writes.map((write) => {
      const id: string = write.delete!.split('/').at(-1)!;
      const attempt: number = (attempts.get(id) ?? 0) + 1;
      attempts.set(id, attempt);
      if (id === 'cancelled' && failureCode === GrpcStatus.CANCELLED) remaining.delete(id);
      if (id === 'cancelled' && attempt <= failures) return { code: failureCode };
      remaining.delete(id);
      return { code: GrpcStatus.OK };
    });
    return { status, writeResults: status.map(() => ({})) };
  };
  internal.recursiveDelete = async (reference: DocumentReference, writer: BulkWriter): Promise<void> => {
    assert.equal(reference.path, 'user/alice');
    writer.onWriteResult((document: DocumentReference) => { progress.push(document.id); });
    const operations = ['cancelled', 'healthy'].map((id) => writer.delete(database.doc(`user/alice/cards/${id}`)));
    // Observe rejection before flush can settle it; never produce an unhandled promise.
    const results = Promise.allSettled(operations);
    await writer.flush();
    for (const result of await results) if (result.status === 'rejected') throw result.reason;
  };
  let failure: unknown;
  try {
    await new FirebaseDeletionStore(database, {} as Auth, {} as Storage).deleteUserTree('alice');
  } catch (error: unknown) { failure = error; }
  finally { timing.mock.restore(); await database.terminate(); }
  return { attempts, progress, remaining, failure };
}

test('transient cancelled delete repeats idempotently while healthy deletions progress', async (context) => {
  const result = await exerciseDelete(GrpcStatus.CANCELLED, 2, context.mock);
  assert.equal(result.failure, undefined);
  assert.equal(result.attempts.get('cancelled'), 3);
  assert.equal(result.attempts.get('healthy'), 1);
  assert.equal(result.remaining.size, 0);
  assert.deepEqual(result.progress, ['healthy', 'cancelled']);
});

test('persistent cancellation stops at ten failures and rejects cleanup', async (context) => {
  const result = await exerciseDelete(GrpcStatus.CANCELLED, 100, context.mock);
  assert.equal(result.attempts.get('cancelled'), 10);
  assert.equal(result.attempts.get('healthy'), 1);
  assert.ok(result.failure);
  assert.deepEqual(result.progress, ['healthy']);
});

test('permission denied fails immediately without retry or false acknowledgement', async (context) => {
  const result = await exerciseDelete(GrpcStatus.PERMISSION_DENIED, 100, context.mock);
  assert.equal(result.attempts.get('cancelled'), 1);
  assert.ok(result.failure);
  assert.equal(result.remaining.has('cancelled'), true);
  assert.deepEqual(result.progress, ['healthy']);
});
