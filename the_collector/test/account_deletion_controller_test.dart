import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/auth/account_deletion.dart';

class _Boundaries {
  _Boundaries({this.remote, this.mark, this.cancel, this.clean, this.read});

  final DeletionRequest? remote;
  final DeletionRequest? mark;
  final DeletionRequest? cancel;
  final DeletionRequest? clean;
  final Future<bool> Function(String uid)? read;
  final List<String> calls = <String>[];
  final Set<String> pending = <String>{};
  late final AccountDeletionController controller = AccountDeletionController(
    isPending: pending.contains,
    readRemote: read == null
        ? null
        : (String uid) async {
            calls.add('read:$uid');
            return read!(uid);
          },
    requestRemote: (String uid) async {
      calls.add('remote:$uid');
      await remote?.call(uid);
    },
    markPending: (String uid) async {
      calls.add('mark:$uid');
      pending.add(uid);
      await mark?.call(uid);
    },
    cancelPending: (String uid) async {
      calls.add('cancel:$uid');
      await cancel?.call(uid);
      pending.remove(uid);
    },
    cleanLocal: (String uid) async {
      calls.add('clean:$uid');
      await clean?.call(uid);
    },
  );
}

void main() {
  test(
    'concurrent requests bind to one UID and share exactly one submission',
    () async {
      final Completer<void> entered = Completer<void>();
      final Completer<void> response = Completer<void>();
      final _Boundaries boundaries = _Boundaries(
        remote: (String _) async {
          entered.complete();
          await response.future;
        },
      );
      final AccountDeletionController controller = boundaries.controller;
      addTearDown(controller.dispose);
      final Future<void> first = controller.request('alice');
      addTearDown(() async {
        if (!response.isCompleted) response.complete();
        await first;
      });
      await entered.future;
      expect(identical(first, controller.request('alice')), isTrue);
      await expectLater(controller.request('bob'), throwsStateError);
      await expectLater(
        controller.accept('bob').timeout(const Duration(seconds: 1)),
        throwsStateError,
      );
      expect(controller.uid, 'alice');
      expect(controller.stage, AccountDeletionStage.submitting);
      expect(boundaries.pending, <String>{'alice'});
      response.complete();
      await first;
      expect(boundaries.calls, <String>[
        'mark:alice',
        'remote:alice',
        'clean:alice',
      ]);
      expect(controller.stage, AccountDeletionStage.idle);
    },
  );

  test('accepting an existing server job deduplicates cleanup without issuing a remote request', () async {
    final Completer<void> entered = Completer<void>();
    final Completer<void> completed = Completer<void>();
    final _Boundaries boundaries = _Boundaries(
      clean: (String _) async {
        entered.complete();
        await completed.future;
      },
    );
    final AccountDeletionController controller = boundaries.controller;
    addTearDown(controller.dispose);
    final Future<void> first = controller.accept('alice');
    addTearDown(() async {
      if (!completed.isCompleted) completed.complete();
      await first;
    });
    await entered.future;
    expect(identical(first, controller.accept('alice')), isTrue);
    await expectLater(
      controller.accept('bob').timeout(const Duration(seconds: 1)),
      throwsStateError,
    );
    await expectLater(controller.request('bob'), throwsStateError);
    expect(controller.stage, AccountDeletionStage.cleaning);
    expect(controller.blocksAccount, isTrue);
    completed.complete();
    await first;
    expect(boundaries.calls, <String>['mark:alice', 'clean:alice']);
  });

  for (final String code in <String>[
    'unauthenticated',
    'invalid-argument',
    'failed-precondition',
    'not-found',
    'permission-denied',
    'unimplemented',
  ]) {
    test(
      'known $code rejection cancels only the local pending guard, without purging',
      () async {
        final FirebaseFunctionsException failure = FirebaseFunctionsException(
          code: code,
          message: 'Request rejected.',
        );
        final _Boundaries boundaries = _Boundaries(
          remote: (String _) async => throw failure,
        );
        final AccountDeletionController controller = boundaries.controller;
        addTearDown(controller.dispose);
        await expectLater(controller.request('alice'), throwsA(same(failure)));
        expect(boundaries.calls, <String>[
          'mark:alice',
          'remote:alice',
          'cancel:alice',
        ]);
        expect(boundaries.pending, isEmpty);
        expect(controller.stage, AccountDeletionStage.idle);
        expect(controller.blocksAccount, isFalse);
        expect(controller.error, isNull);
      },
    );
  }

  test(
    'unknown timeout retains the guard and does not purge or cancel',
    () async {
      final TimeoutException failure = TimeoutException('Response lost.');
      final _Boundaries boundaries = _Boundaries(
        remote: (String _) async => throw failure,
      );
      final AccountDeletionController controller = boundaries.controller;
      addTearDown(controller.dispose);
      await expectLater(controller.request('alice'), throwsA(same(failure)));
      expect(boundaries.calls, <String>['mark:alice', 'remote:alice']);
      expect(boundaries.pending, <String>{'alice'});
      expect(controller.stage, AccountDeletionStage.failed);
      expect(controller.blocksAccount, isTrue);
      expect(controller.error, contains('could not be confirmed'));
    },
  );

  test(
    'a later known rejection cannot cancel an earlier unconfirmed request',
    () async {
      int attempts = 0;
      final _Boundaries boundaries = _Boundaries(
        remote: (String _) async {
          if (++attempts == 1) throw TimeoutException('Response lost.');
          throw FirebaseFunctionsException(
            code: 'permission-denied',
            message: 'Retry rejected.',
          );
        },
      );
      final AccountDeletionController controller = boundaries.controller;
      addTearDown(controller.dispose);
      await expectLater(
        controller.request('alice'),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(
        controller.retry(),
        throwsA(isA<FirebaseFunctionsException>()),
      );
      expect(boundaries.pending, <String>{'alice'});
      expect(boundaries.calls, <String>[
        'mark:alice',
        'remote:alice',
        'mark:alice',
        'remote:alice',
      ]);
      expect(controller.accepted, isFalse);
      expect(controller.stage, AccountDeletionStage.failed);
      expect(controller.blocksAccount, isTrue);
    },
  );

  for (final bool accepted in <bool>[true, false]) {
    test(
      'resolving an unknown request cleans only an accepted own job, accepted=$accepted',
      () async {
        final _Boundaries boundaries = _Boundaries(
          remote: (String _) async => throw TimeoutException('Response lost.'),
          read: (String uid) async {
            expect(uid, 'alice');
            return accepted;
          },
        );
        final AccountDeletionController controller = boundaries.controller;
        addTearDown(controller.dispose);
        await expectLater(
          controller.request('alice'),
          throwsA(isA<TimeoutException>()),
        );
        expect(await controller.resolveRemote(), accepted);
        expect(controller.accepted, accepted);
        expect(boundaries.pending, <String>{'alice'});
        expect(
          boundaries.calls.where((String call) => call.startsWith('remote:')),
          hasLength(1),
        );
        expect(
          boundaries.calls.where((String call) => call.startsWith('clean:')),
          hasLength(accepted ? 1 : 0),
        );
        expect(
          boundaries.calls.where((String call) => call.startsWith('cancel:')),
          isEmpty,
        );
        expect(
          controller.stage,
          accepted ? AccountDeletionStage.idle : AccountDeletionStage.failed,
        );
      },
    );
  }

  for (final bool viaRetry in <bool>[true, false]) {
    test(
      'accepted cleanup failure retries locally without a second remote request, retry=$viaRetry',
      () async {
        int attempts = 0;
        final StateError failure = StateError('Local disk unavailable.');
        final _Boundaries boundaries = _Boundaries(
          clean: (String _) async {
            if (++attempts == 1) throw failure;
          },
        );
        final AccountDeletionController controller = boundaries.controller;
        addTearDown(controller.dispose);
        await expectLater(controller.request('alice'), throwsA(same(failure)));
        expect(controller.stage, AccountDeletionStage.failed);
        expect(controller.blocksAccount, isTrue);
        expect(controller.uid, 'alice');
        expect(boundaries.pending, <String>{'alice'});
        expect(boundaries.calls, <String>[
          'mark:alice',
          'remote:alice',
          'clean:alice',
        ]);
        if (viaRetry) {
          await controller.retry();
        } else {
          await controller.request('alice');
        }
        expect(
          boundaries.calls.where((String call) => call.startsWith('remote:')),
          hasLength(1),
        );
        expect(
          boundaries.calls.where((String call) => call.startsWith('clean:')),
          hasLength(2),
        );
        expect(
          boundaries.calls.where((String call) => call.startsWith('cancel:')),
          isEmpty,
        );
        expect(controller.stage, AccountDeletionStage.idle);
        expect(controller.error, isNull);
      },
    );
  }

  test(
    'a failed local mark prevents remote deletion and can be retried safely',
    () async {
      int attempts = 0;
      final StateError failure = StateError('Deletion marker flush failed.');
      final _Boundaries boundaries = _Boundaries(
        mark: (String _) async {
          if (++attempts == 1) throw failure;
        },
      );
      final AccountDeletionController controller = boundaries.controller;
      addTearDown(controller.dispose);
      await expectLater(controller.request('alice'), throwsA(same(failure)));
      expect(boundaries.calls, <String>['mark:alice']);
      expect(boundaries.pending, <String>{'alice'});
      expect(controller.stage, AccountDeletionStage.failed);
      expect(controller.blocksAccount, isTrue);
      await controller.retry();
      expect(boundaries.calls, <String>[
        'mark:alice',
        'mark:alice',
        'remote:alice',
        'clean:alice',
      ]);
      expect(controller.stage, AccountDeletionStage.idle);
    },
  );

  test('failed cancellation preserves the guard rather than claiming rejection recovered', () async {
    final StateError failure = StateError('Pending marker removal failed.');
    final _Boundaries boundaries = _Boundaries(
      remote: (String _) async => throw FirebaseFunctionsException(
        code: 'permission-denied',
        message: 'Request rejected.',
      ),
      cancel: (String _) async => throw failure,
    );
    final AccountDeletionController controller = boundaries.controller;
    addTearDown(controller.dispose);
    await expectLater(controller.request('alice'), throwsA(same(failure)));
    expect(boundaries.pending, <String>{'alice'});
    expect(boundaries.calls, <String>[
      'mark:alice',
      'remote:alice',
      'cancel:alice',
    ]);
    expect(controller.stage, AccountDeletionStage.failed);
    expect(controller.blocksAccount, isTrue);
  });

  test(
    'retry without a pending UID cannot invoke deletion boundaries',
    () async {
      final _Boundaries boundaries = _Boundaries();
      addTearDown(boundaries.controller.dispose);
      await expectLater(boundaries.controller.retry(), throwsStateError);
      expect(boundaries.calls, isEmpty);
    },
  );
}
