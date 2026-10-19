# Account deletion

This backend is local source until an operator deploys it. Building the app does not deploy these functions or rules.

## Optional card hint inference

`suggestCardHints` is an opt-in image transcription pilot, not a trained classifier covering every card or printing. It accepts exactly `{imageBase64: string}` containing a JPEG or PNG crop up to 2 MiB, with sides between 64 and 4096 pixels. It accepts no image URL, user ID, model selector or storage path.

`cardHintsStatus` accepts only `{}` and requires the same Authentication and App Check verification. It returns `{configured, mode: "text-transcription", model}` without accepting an image, obtaining Vertex credentials, or running inference. `configured` checks runtime configuration; it does not prove model access, card accuracy, or live inference health. Settings checks this endpoint before allowing opt-in and shows deployment, configuration, authentication, timeout, or response failures. A granted preference can always be switched off. Failed crop requests remain retryable; cloud suggestions still require printing review.

The callable requires Firebase Authentication and App Check. Accounts pending deletion are rejected. Configure `COLLECTOR_RECOGNITION_MODEL` explicitly with a Vertex image-capable model that supports structured JSON output; the empty default disables inference. `COLLECTOR_RECOGNITION_LOCATION` defaults to `us-central1` and can be set to `global` for a compatible model. The runtime project comes from `GCLOUD_PROJECT`. Application Default Credentials supply the Vertex access token; no API key is stored in source. The runtime service account needs permission to invoke the configured model, and the app needs an active App Check provider before enabling this feature.

The status callable and client changes are local source until deployed. Rollout requires authorization for the target project and functions, an authenticated project operator, explicit model/location parameters, Vertex access for the runtime identity, and a successful App Check plus inference smoke test. Deploy only the reviewed `cardHintsStatus` and `suggestCardHints` functions for this feature. Parameter values are configured through the [Firebase parameter workflow](https://firebase.google.com/docs/functions/config-env); callable failures use [structured SDK errors](https://firebase.google.com/docs/functions/callable#handle_errors).

The app activates App Check only with `CLOUD_CARD_HINTS_ENABLED=true`, on iOS or Android. Production uses App Attest with Device Check fallback on iOS and Play Integrity on Android. For simulator or Personal Team testing, also set `CLOUD_APP_CHECK_DEBUG=true` in a debug or profile build and manually register the SDK-generated debug token in Firebase App Check. App code does not print, persist or register debug tokens. Release builds reject the debug-provider flag; cloud hints also reject emulator and unsupported-platform configurations before Firebase initialization. Default builds leave the feature and App Check activation disabled.

Backend publication, provider registration, debug-token registration, API enablement and service-account permissions require explicit operator approval. The local implementation does not perform these remote actions.

The response is `{model, elapsedMs, confidence: "uncalibrated", hints}`. `hints` has exactly seven nullable string fields: `name`, `setCode`, `collectorNumber`, `rulesText`, `typeLine`, `artist` and `language`. Unreadable fields stay null. The prompt requests literal visible text and forbids inferring a printing or set code from memory or artwork. Model output remains untrusted; the client must check suggestions against the catalog and keep them separate from primary camera OCR and exact-printing evidence. No confidence percentage, card ID or confirmation flag is returned.

Requests have an eight-second inference deadline, a 64 KiB response limit, two maximum function instances and four concurrent calls per instance. The callable stores no image or recognition result. It does not write to inventory, use Scryfall from the server, train a model or build an all-card artwork index.

A later visual retrieval stage would need a versioned Scryfall reference index and image embeddings, then combine retrieved candidates with observed names, rules, symbols and collector numbers. Artwork shared by multiple printings cannot establish the exact print on its own. That stage is not implemented or evaluated by this OCR pilot.

`npm test` includes injected inference and fetch fixtures. They verify authentication, App Check, image bounds, configuration validation, structured output, invalid replies and deadline cancellation without credentials, paid inference or network requests. Publication, model configuration and hardware recognition validation remain separate work; do not deploy the account-deletion functions when publishing only this pilot.

The implementation follows [Vertex generateContent](https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference), [App Check callable enforcement](https://firebase.google.com/docs/app-check/cloud-functions), and [Admin SDK credentials](https://firebase.google.com/docs/reference/admin/node/firebase-admin.app.credential).

## Client API

Call `requestAccountDeletion` in `us-central1` with exactly `{expectedUid: confirmedUser.uid}`.
The server uses the authenticated UID for every path. `expectedUid` binds the confirmation to the current account.
The first request requires an ID token with `auth_time` within five minutes.
Reauthenticate the same user, then refresh their ID token before calling.

The response is `{accepted: true, state: 'pending' | 'complete'}`.
An accepted request starts irreversible deletion. The client must stop account writes and remove that account's local drafts and queue.
A transport timeout does not prove rejection. Read the own job before resuming account writes or retrying.

Errors:

- `unauthenticated`: no authenticated caller.
- `invalid-argument`: missing confirmation or extra payload fields.
- `failed-precondition`, `details.reason = account-changed`: the confirmed UID differs from the authenticated UID.
- `failed-precondition`, `details.reason = requires-recent-login`: reauthentication is required for a new job.
- `internal`: the request could not be recorded. Retry or read the own job.

Clients can get only `accountDeletions/{theirUid}`. They cannot list, create, edit, or delete jobs.
Fields are `state`, `requestedAt`, and `completedAt` after completion. Timestamps use Firestore `Timestamp`.
Jobs contain no email address, IP address, or provider credentials.

## Cleanup and retries

`deleteAccountData` handles new jobs with event retries enabled.
It recursively deletes `user/{uid}`, including documents below missing parent documents.
It deletes owned games and removes the UID from other games with transactional array transforms.
Other players' names, life values, and concurrent joins remain intact.
Storage cleanup deletes only `user/{uid}/`, including object generations, in pages of 100.
Auth deletion follows all data cleanup. Missing Auth users count as an idempotent success.

Failures leave the protected job pending. Retries repeat cleanup safely.
Recursive deletion preserves the SDK retry policy and retries cancelled deletes up to ten failed attempts.
Persistent cancellation and permission errors still reject cleanup.
Hourly maintenance also retries pending jobs after the event retry window.
Completed jobs remain for at least 24 hours. Rules block old sessions while the marker exists.
Hourly maintenance deletes at most 100 expired markers per run.

## Local checks

Use Node.js 22, the configured Cloud Functions runtime.
From the repository root:

```sh
npm --prefix functions ci
npm --prefix functions test
```

The compiled output lives in ignored `functions/lib/`.
Unit tests require no credentials, emulators, or network backend.

The following commands start local emulators. Run them only when the shared emulator ports are free.

```sh
firebase emulators:exec --only auth,firestore,storage --project demo-the-collector \
  'npm --prefix firebase_tests test && RUN_ACCOUNT_DELETION_EMULATOR_TESTS=1 FIRESTORE_EMULATOR_HOST=127.0.0.1:18080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:19099 FIREBASE_STORAGE_EMULATOR_HOST=127.0.0.1:19199 npm --prefix functions run test:emulator'
```

Backend tests use the isolated `demo-collector-deletion-backend` project.
Rules tests use `demo-the-collector`, matching the Storage emulator launch project.
Test files run serially because Storage cross-service lookups use that launch project.
They cover nested cleanup above 500 documents, multiple pages, another owner's data, partial failure, concurrent joins, and marker denial.
The direct worker test excludes the Functions emulator to control injected failure timing.

For an app callable test, start `auth,firestore,storage,functions` with the same demo project as the app.
The Functions emulator listens on `127.0.0.1:15001`.
The callable requires a real emulator Auth ID token. Authentication claims cannot come from the request body.

## Production deployment

Deployment requires separate authorization. These commands publish destructive account-deletion behavior.

Read-only production checks on October 10, 2026 confirmed that `the-collector-app` has Blaze billing enabled.
Cloud Functions, Cloud Run, Eventarc, and Cloud Scheduler APIs were not enabled.
The deployed Firestore and Storage rules lacked the account-deletion guards, and neither deletion index existed.
Deploy and verify the complete rollout before enabling `ACCOUNT_DELETION_ENABLED` in a released app.

1. Select the intended Firebase project and confirm its default Storage bucket.
2. Confirm Blaze billing and enable the Cloud Functions, Cloud Run, Eventarc, and Cloud Scheduler APIs.
3. Grant the runtime service account Firestore read/write, Firebase Auth deletion, and Storage object deletion permissions.
4. Build and run all local tests with Node.js 22.
5. Deploy the rules and indexes before enabling account deletion in a released client.
6. Enable Storage-to-Firestore Rules permissions when the Firebase CLI requests them.
7. Deploy all three backend functions.
8. Verify deletion with a disposable account in a staging project.

Use `roles/datastore.user` and `roles/firebaseauth.admin` on the project.
Use `roles/storage.objectAdmin` on only the configured Storage bucket.
The deployment account also needs function deployment and service-account impersonation permissions.
Firebase manages the trigger and scheduler service identities during deployment.
No service-account key or production credential belongs in this repository.

After authorization, from the repository root:

```sh
firebase deploy --project the-collector-app --only firestore:rules,firestore:indexes,storage
firebase deploy --project the-collector-app --only functions:collector
```

Do not deploy Hosting as part of this backend change.
Verify the job indexes finish building and Storage's cross-service rules permission succeeds.
Monitor pending jobs and function failures. A persistent permission error leaves the account locked pending operator repair.
Cloud Storage retention policies can delay file deletion. Do not mark the job complete before deletion succeeds.
This worker deletes live app data. Cloud-provider backups and soft-delete retention follow the project's configured retention policies.

## Primary references

- [Callable authentication and errors](https://firebase.google.com/docs/functions/callable)
- [Node.js runtime configuration](https://firebase.google.com/docs/functions/manage-functions)
- [Event retries](https://firebase.google.com/docs/functions/retries)
- [Firestore event delivery](https://firebase.google.com/docs/functions/firestore-events)
- [Firestore recursive deletion](https://docs.cloud.google.com/nodejs/docs/reference/firestore/latest/firestore/firestore)
- [Storage rules and Firestore permissions](https://firebase.google.com/docs/storage/security/rules-conditions)
- [Scheduled functions](https://firebase.google.com/docs/functions/schedule-functions)
