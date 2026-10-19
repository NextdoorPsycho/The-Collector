import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:the_collector/utils/auth/local_account_data.dart';
import 'package:the_collector/utils/auth/collector_auth.dart';
import 'package:the_collector/utils/auth/restart_after_deletion.dart'
    if (dart.library.js_interop) 'package:the_collector/utils/auth/restart_after_deletion_web.dart';

const bool accountDeletionEnabled =
    bool.fromEnvironment('ACCOUNT_DELETION_ENABLED') ||
    bool.fromEnvironment('USE_FIREBASE_EMULATORS');

enum AccountDeletionStage { idle, submitting, cleaning, failed }

typedef DeletionRequest = Future<void> Function(String uid);

class AccountDeletionController extends ChangeNotifier {
  AccountDeletionController({
    required this.requestRemote,
    required this.markPending,
    required this.cancelPending,
    required this.cleanLocal,
    this.readRemote,
    bool Function(String)? isPending,
  }) : isPending = isPending ?? LocalAccountData.isDeleting;

  final DeletionRequest requestRemote;
  final DeletionRequest markPending;
  final DeletionRequest cancelPending;
  final DeletionRequest cleanLocal;
  final Future<bool> Function(String uid)? readRemote;
  final bool Function(String uid) isPending;
  AccountDeletionStage stage = AccountDeletionStage.idle;
  String? uid;
  String? error;
  bool _accepted = false;
  Future<void>? _running;

  static final AccountDeletionController instance = AccountDeletionController(
    requestRemote: (String uid) async {
      if (FirebaseAuth.instance.currentUser?.uid != uid) {
        throw FirebaseFunctionsException(
          code: 'failed-precondition',
          message: 'The signed-in account changed.',
          details: const <String, String>{'reason': 'account-changed'},
        );
      }
      final HttpsCallableResult<Object?> response =
          await FirebaseFunctions.instanceFor(region: 'us-central1')
              .httpsCallable('requestAccountDeletion')
              .call<Object?>(<String, String>{'expectedUid': uid})
              .timeout(const Duration(seconds: 25));
      final Object? data = response.data;
      if (data is! Map<Object?, Object?> ||
          data['accepted'] != true ||
          (data['state'] != 'pending' && data['state'] != 'complete')) {
        throw const FormatException('Invalid account deletion response.');
      }
    },
    readRemote: (String uid) async {
      if (FirebaseAuth.instance.currentUser?.uid != uid) return false;
      final DocumentSnapshot<Map<String, dynamic>> job = await FirebaseFirestore
          .instance
          .doc('accountDeletions/$uid')
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      if (!job.exists) return false;
      validateDeletionJob(job.data());
      return true;
    },
    markPending: LocalAccountData.markDeleting,
    cancelPending: LocalAccountData.cancelDeleting,
    cleanLocal: (String uid) async {
      await LocalAccountData.acceptDeletion(uid);
      await WidgetsBinding.instance.endOfFrame;
      await LocalAccountData.purge(uid);
      final String? currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null || currentUid == uid) {
        await FirebaseCollectorAuth.instance.signOut();
      }
      final FirebaseFirestore database = FirebaseFirestore.instance;
      await database.terminate();
      await database.clearPersistence();
      await LocalAccountData.finishDeletionCleanup(uid);
      restartAfterDeletion();
    },
  );

  bool get blocksAccount =>
      stage == AccountDeletionStage.cleaning ||
      stage == AccountDeletionStage.failed;

  void _change(AccountDeletionStage next, {String? message}) {
    stage = next;
    error = message;
    notifyListeners();
  }

  bool get accepted => _accepted;

  Future<bool> resolveRemote() async {
    final String? owner = uid;
    if (owner == null || readRemote == null) return false;
    final bool found = await readRemote!(owner);
    if (found) await accept(owner);
    return found;
  }

  void leavePending() {
    if (_running != null || _accepted) return;
    _change(AccountDeletionStage.idle);
  }

  Future<void> request(String owner) {
    if (_accepted && uid == owner) return accept(owner);
    final bool previouslyPending = isPending(owner);
    if (_running != null) {
      if (uid != owner) {
        return Future<void>.error(StateError('Account changed.'));
      }
      return _running!;
    }
    uid = owner;
    _accepted = false;
    return _run(() async {
      _change(AccountDeletionStage.submitting);
      await markPending(owner);
      try {
        await requestRemote(owner);
      } catch (failure) {
        if (!previouslyPending && _definitelyRejected(failure)) {
          await cancelPending(owner);
          _change(AccountDeletionStage.idle);
        } else {
          _change(
            AccountDeletionStage.failed,
            message:
                'The request could not be confirmed. Reconnect and retry. '
                'Account changes are paused until its status is known.',
          );
        }
        rethrow;
      }
      _accepted = true;
      await _clean(owner);
    });
  }

  Future<void> accept(String owner) {
    if (_running != null) {
      if (uid != owner) {
        return Future<void>.error(StateError('Account changed.'));
      }
      return _running!;
    }
    uid = owner;
    _accepted = true;
    return _run(() async {
      _change(AccountDeletionStage.cleaning);
      await markPending(owner);
      await _clean(owner);
    });
  }

  Future<void> _run(Future<void> Function() action) {
    final Future<void> work = Future<void>.sync(action)
        .catchError((Object error) {
          if (stage != AccountDeletionStage.idle &&
              stage != AccountDeletionStage.failed) {
            _change(
              AccountDeletionStage.failed,
              message:
                  'Account cleanup could not finish. Retry to remove its '
                  'remaining local data.',
            );
          }
          throw error;
        });
    _running = work.whenComplete(() => _running = null);
    return _running!;
  }

  Future<void> _clean(String owner) async {
    _change(AccountDeletionStage.cleaning);
    await cleanLocal(owner);
    _change(AccountDeletionStage.idle);
  }

  Future<void> retry() {
    final String? owner = uid;
    if (owner == null) {
      return Future<void>.error(StateError('No deletion pending.'));
    }
    return _accepted ? accept(owner) : request(owner);
  }

  static bool _definitelyRejected(Object failure) =>
      failure is FirebaseFunctionsException &&
      <String>{
        'unauthenticated',
        'invalid-argument',
        'failed-precondition',
        'not-found',
        'permission-denied',
        'unimplemented',
      }.contains(failure.code);
}

Future<bool> prepareAccount(String uid) async {
  if (LocalAccountData.isDeletionAccepted(uid)) {
    if (LocalAccountData.needsDeletionCleanup(uid)) {
      await AccountDeletionController.instance.accept(uid);
    } else if (FirebaseAuth.instance.currentUser?.uid == uid) {
      await FirebaseAuth.instance.signOut();
    }
    return false;
  }
  if (!accountDeletionEnabled) return !LocalAccountData.isDeleting(uid);
  final FirebaseFirestore database = FirebaseFirestore.instance;
  final DocumentReference<Map<String, dynamic>> reference = database.doc(
    'accountDeletions/$uid',
  );
  DocumentSnapshot<Map<String, dynamic>> job;
  try {
    job = await reference
        .get(
          GetOptions(
            source: LocalAccountData.isDeleting(uid)
                ? Source.server
                : Source.serverAndCache,
          ),
        )
        .timeout(const Duration(seconds: 20));
  } catch (failure) {
    final bool disconnected =
        failure is TimeoutException ||
        (failure is FirebaseException && failure.code == 'unavailable');
    if (!disconnected || LocalAccountData.isDeleting(uid)) rethrow;
    final DocumentSnapshot<Map<String, dynamic>> profile = await database
        .doc('user/$uid')
        .get(const GetOptions(source: Source.cache));
    if (!profile.exists) rethrow;
    // Cached accounts can work offline; server markers still deny cloud writes.
    job = await reference.get(const GetOptions(source: Source.cache));
  }
  if (job.exists) {
    validateDeletionJob(job.data());
    await AccountDeletionController.instance.accept(uid);
    return false;
  }
  return !LocalAccountData.isDeleting(uid);
}

void validateDeletionJob(Map<String, dynamic>? job) {
  if (job == null ||
      (job['state'] != 'pending' && job['state'] != 'complete') ||
      job['requestedAt'] is! Timestamp) {
    throw const FormatException('Invalid account deletion state.');
  }
}
