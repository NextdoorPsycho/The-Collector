import { applicationDefault, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';
import { onDocumentCreated } from 'firebase-functions/v2/firestore';
import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { error as logError } from 'firebase-functions/logger';
import { defineString } from 'firebase-functions/params';
import { DeletionError, performDeletion, requestDeletion, TOMBSTONE_MS } from './account_deletion';
import { FirebaseDeletionStore, PAGE_SIZE } from './firebase_deletion_store';
import { CardHintError, cardHintsStatus as recognitionStatus, suggestCardHints as inferCardHints } from './card_hints';

initializeApp();
const database = getFirestore();
const store = new FirebaseDeletionStore(database, getAuth(), getStorage());
const region = 'us-central1';
const recognitionModel = defineString('COLLECTOR_RECOGNITION_MODEL', { default: '' });
const recognitionLocation = defineString('COLLECTOR_RECOGNITION_LOCATION', { default: 'us-central1' });

export const cardHintsStatus = onCall({ region, enforceAppCheck: true, maxInstances: 2, timeoutSeconds: 15 }, async (request) => {
  try {
    if (request.auth && (await database.doc(`accountDeletions/${request.auth.uid}`).get()).exists) {
      throw new CardHintError('failed-precondition', 'Account deletion is pending.');
    }
    return recognitionStatus(request.auth ? { uid: request.auth.uid, appVerified: request.app !== undefined } : undefined,
      request.data as unknown, { project: process.env.GCLOUD_PROJECT ?? '', location: recognitionLocation.value(), model: recognitionModel.value() });
  } catch (error: unknown) {
    if (error instanceof CardHintError) throw new HttpsError(error.code, error.message, error.reason ? { reason: error.reason } : undefined);
    throw new HttpsError('unavailable', 'Cloud status unavailable.');
  }
});

export const suggestCardHints = onCall({
  region, enforceAppCheck: true, maxInstances: 2, concurrency: 4,
  timeoutSeconds: 30, memory: '512MiB', cpu: 1,
}, async (request) => {
  try {
    if (request.auth && (await database.doc(`accountDeletions/${request.auth.uid}`).get()).exists) {
      throw new CardHintError('failed-precondition', 'Account deletion is pending.');
    }
    return await inferCardHints(
      request.auth ? { uid: request.auth.uid, appVerified: request.app !== undefined } : undefined,
      request.data as unknown,
      {
        project: process.env.GCLOUD_PROJECT ?? '',
        location: recognitionLocation.value(),
        model: recognitionModel.value(),
      },
      {
        accessToken: async () => (await applicationDefault().getAccessToken()).access_token,
        fetch,
      },
    );
  } catch (error: unknown) {
    if (error instanceof CardHintError) throw new HttpsError(error.code, error.message, error.reason ? { reason: error.reason } : undefined);
    logError('Card hint request failed.');
    throw new HttpsError('unavailable', 'Card suggestions are temporarily unavailable.');
  }
});

export const requestAccountDeletion = onCall({ region, timeoutSeconds: 30 }, async (request) => {
  try {
    return await requestDeletion(request.auth ? { uid: request.auth.uid, authTime: request.auth.token.auth_time } : undefined,
      request.data as unknown, store, Date.now());
  } catch (error: unknown) {
    if (error instanceof DeletionError) {
      throw new HttpsError(error.code, error.message,
        error.code === 'failed-precondition' ? { reason: error.reason ?? 'requires-recent-login' } : undefined);
    }
    logError('Account deletion request could not be recorded.');
    throw new HttpsError('internal', 'Account deletion could not be started. Please retry.');
  }
});

export const deleteAccountData = onDocumentCreated({
  region, document: 'accountDeletions/{uid}', retry: true, timeoutSeconds: 540, memory: '512MiB',
}, async (event): Promise<void> => {
  if (!await performDeletion(event.params.uid, store)) throw new Error('Deletion will continue on retry.');
});

// Recover jobs after the event retry window, and expire completed markers after old JWTs expire.
export const maintainAccountDeletions = onSchedule({ region, schedule: 'every 60 minutes', timeoutSeconds: 540, memory: '512MiB' },
  async (): Promise<void> => {
    const pending = await database.collection('accountDeletions').where('state', '==', 'pending')
      .orderBy('requestedAt').limit(10).get();
    for (const job of pending.docs) {
      try { await performDeletion(job.id, store, Date.now, 40_000); }
      catch { logError('Pending account deletion will be retried.'); }
    }
    const cutoff = Timestamp.fromMillis(Date.now() - TOMBSTONE_MS);
    const expired = await database.collection('accountDeletions').where('state', '==', 'complete')
      .where('completedAt', '<', cutoff).limit(PAGE_SIZE).get();
    if (!expired.empty) {
      const batch = database.batch();
      for (const job of expired.docs) batch.delete(job.ref);
      await batch.commit();
    }
  });
