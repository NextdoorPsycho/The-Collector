import 'dart:async';

import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';

const String _printing = 'd88a8e2d-2577-4a67-af86-e33c0ba94114';

MTGCard _card() => MTGCard(
  name: 'Lightning Bolt',
  setId: 'set-id',
  description: '',
  flavorText: '',
  cmc: 1,
  typeLine: 'Instant',
  rarity: Rarity.common,
  setType: SetType.expansion,
  manaCost: '{R}',
  scryfallId: _printing,
  finish: Finish.foil,
  language: 'en',
);

class _Storage implements ScanQueueStorage {
  final Map<String, Map<String, ScanQueueEntry>> completed =
      <String, Map<String, ScanQueueEntry>>{};
  @override
  Future<List<ScanQueueEntry>> readCompletedEntries(String userId) async =>
      completed[userId]?.values.toList() ?? <ScanQueueEntry>[];
  @override
  Future<void> completeEntry(String userId, ScanQueueEntry entry) async {
    await removeEntries(userId, <String>[entry.operationId]);
    completed.putIfAbsent(
      userId,
      () => <String, ScanQueueEntry>{},
    )[entry.operationId] = entry;
  }

  @override
  Future<void> removeCompletedEntries(
    String userId,
    List<String> operationIds,
  ) async {
    if (failWrites || failRemovals) throw StateError('disk full');
    for (final String id in operationIds) {
      completed[userId]?.remove(id);
    }
  }

  final Map<String, Map<String, ScanQueueEntry>> values =
      <String, Map<String, ScanQueueEntry>>{};
  int batchWrites = 0;
  bool failWrites = false;
  bool failRemovals = false;
  @override
  Future<List<ScanQueueEntry>> readEntries(String userId) async =>
      values[userId]?.values.toList() ?? <ScanQueueEntry>[];
  @override
  Future<void> upsertEntries(
    String userId,
    List<ScanQueueEntry> entries,
  ) async {
    if (failWrites) {
      throw StateError('disk full');
    }
    batchWrites++;
    final Map<String, ScanQueueEntry> owner = values.putIfAbsent(
      userId,
      () => <String, ScanQueueEntry>{},
    );
    for (final ScanQueueEntry entry in entries) {
      owner[entry.operationId] = ScanQueueEntry.fromMap(entry.toMap());
    }
  }

  @override
  Future<void> removeEntries(String userId, List<String> operationIds) async {
    if (failWrites || failRemovals) {
      throw StateError('disk full');
    }
    for (final String id in operationIds) {
      values[userId]?.remove(id);
    }
  }
}

class _DeferredRemovalStorage extends _Storage {
  Completer<void>? removal;

  @override
  Future<void> removeEntries(String userId, List<String> operationIds) async {
    await removal?.future;
    await super.removeEntries(userId, operationIds);
  }
}

void main() {
  test('failed completion pruning preserves restart protection', () async {
    final _Storage storage = _Storage();
    int uploads = 0;
    final ScanQueue queue = ScanQueue(
      userId: 'alice',
      storage: storage,
      writer: (ScanQueueEntry _) async {
        uploads++;
      },
    );
    await queue.load();
    final ScanQueueApproval approval = ScanQueueApproval(
      operationId: 'capture_0',
      card: _card(),
    );
    await queue.enqueueBatch(<ScanQueueApproval>[approval]);
    await queue.flush();
    storage.failRemovals = true;
    await expectLater(queue.pruneCompleted(<String>{}), throwsStateError);
    expect(queue.hasCompleted('capture_0'), isTrue);
    await queue.enqueueBatch(<ScanQueueApproval>[approval]);
    await queue.flush();
    expect(uploads, 1);
    queue.dispose();
    final ScanQueue resumed = ScanQueue(
      userId: 'alice',
      storage: storage,
      writer: (ScanQueueEntry _) async {
        uploads++;
      },
    );
    await resumed.load();
    expect(resumed.hasCompleted('capture_0'), isTrue);
    expect(resumed.count, 0);
    storage.failRemovals = false;
    await resumed.pruneCompleted(<String>{});
    expect(resumed.completedCount, 0);
    resumed.dispose();
  });

  testWidgets(
    'held additions survive restart while unrelated uploads continue',
    (WidgetTester tester) async {
      final _Storage storage = _Storage();
      DateTime now = DateTime.utc(2026, 10, 13);
      final List<String> uploads = <String>[];
      ScanQueue queue = ScanQueue(
        userId: 'alice',
        storage: storage,
        now: () => now,
        writer: (ScanQueueEntry entry) async {
          uploads.add(entry.operationId);
        },
      );
      await queue.load();
      await queue.enqueueBatch(<ScanQueueApproval>[
        ScanQueueApproval(
          operationId: 'held',
          card: _card(),
          quantity: 3,
          deckId: 'binder',
        ),
      ], undoWindow: const Duration(seconds: 10));
      final DateTime until = queue.entries.single.undoUntil!;
      now = now.add(const Duration(seconds: 2));
      await queue.enqueueBatch(<ScanQueueApproval>[
        ScanQueueApproval(
          operationId: 'held',
          card: _card(),
          quantity: 3,
          deckId: 'binder',
        ),
      ], undoWindow: const Duration(seconds: 10));
      expect(queue.entries.single.undoUntil, until);
      queue.dispose();
      queue = ScanQueue(
        userId: 'alice',
        storage: storage,
        now: () => now,
        writer: (ScanQueueEntry entry) async {
          uploads.add(entry.operationId);
        },
      );
      await queue.load();
      expect(queue.canUndo('held'), isTrue);
      final Future<void> flush = queue.flush();
      await tester.pump();
      await queue.enqueueBatch(<ScanQueueApproval>[
        ScanQueueApproval(operationId: 'immediate', card: _card()),
      ]);
      await tester.pump();
      expect(uploads, <String>['immediate']);
      expect(queue.canUndo('held'), isTrue);
      expect(await queue.undo('held'), isTrue);
      await flush;
      expect(uploads, <String>['immediate']);
      expect(queue.entries, isEmpty);
      expect(storage.values['alice'], isEmpty);
      queue.dispose();
    },
  );

  testWidgets('expiry uploads once and rejects undo at or after the boundary', (
    WidgetTester tester,
  ) async {
    final _Storage storage = _Storage();
    DateTime now = DateTime.utc(2026, 10, 13);
    final Completer<void> write = Completer<void>();
    int uploads = 0;
    final ScanQueue queue = ScanQueue(
      userId: 'alice',
      storage: storage,
      now: () => now,
      writer: (ScanQueueEntry entry) async {
        uploads++;
        await write.future;
      },
    );
    await queue.load();
    await queue.enqueueBatch(<ScanQueueApproval>[
      ScanQueueApproval(operationId: 'held', card: _card()),
    ], undoWindow: const Duration(seconds: 10));
    final Future<void> flush = queue.flush();
    await tester.pump();
    expect(uploads, 0);
    now = now.add(const Duration(seconds: 10));
    expect(queue.canUndo('held'), isFalse);
    expect(await queue.undo('held'), isFalse);
    await tester.pump(const Duration(seconds: 10));
    expect(uploads, 1);
    expect(queue.isSending('held'), isTrue);
    expect(await queue.undo('held'), isFalse);
    write.complete();
    await flush;
    await queue.flush();
    expect(uploads, 1);
    expect(queue.entries, isEmpty);
    queue.dispose();
  });

  testWidgets(
    'pending durable undo cannot race with expiry or send another copy',
    (WidgetTester tester) async {
      final _DeferredRemovalStorage storage = _DeferredRemovalStorage();
      DateTime now = DateTime.utc(2026, 10, 13);
      int uploads = 0;
      final ScanQueue queue = ScanQueue(
        userId: 'alice',
        storage: storage,
        now: () => now,
        writer: (ScanQueueEntry entry) async {
          uploads++;
        },
      );
      await queue.load();
      await queue.enqueueBatch(<ScanQueueApproval>[
        ScanQueueApproval(operationId: 'held', card: _card()),
      ], undoWindow: const Duration(seconds: 10));
      final Future<void> flush = queue.flush();
      storage.removal = Completer<void>();
      final Future<bool> undo = queue.undo('held');
      expect(queue.canUndo('held'), isFalse);
      now = now.add(const Duration(seconds: 11));
      await tester.pump(const Duration(seconds: 11));
      expect(uploads, 0);
      storage.removal!.complete();
      expect(await undo, isTrue);
      await flush;
      expect(uploads, 0);
      expect(queue.entries, isEmpty);
      queue.dispose();
    },
  );

  testWidgets('undo claims the operation while its draft choice is persisted', (
    WidgetTester tester,
  ) async {
    final _Storage storage = _Storage();
    final Completer<void> draftWrite = Completer<void>();
    DateTime now = DateTime.utc(2026, 10, 13);
    int uploads = 0;
    final ScanQueue queue = ScanQueue(
      userId: 'alice',
      storage: storage,
      now: () => now,
      writer: (ScanQueueEntry entry) async {
        uploads++;
      },
    );
    await queue.load();
    await queue.enqueueBatch(<ScanQueueApproval>[
      ScanQueueApproval(operationId: 'held', card: _card()),
    ], undoWindow: const Duration(seconds: 10));
    final Future<void> flush = queue.flush();
    now = now.add(const Duration(milliseconds: 9900));
    final Future<bool> undo = queue.undo(
      'held',
      beforeRemove: () => draftWrite.future,
    );
    expect(queue.canUndo('held'), isFalse);
    now = now.add(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 20));
    expect(uploads, 0);
    expect(storage.values['alice']!.keys, <String>['held']);
    draftWrite.complete();
    expect(await undo, isTrue);
    await flush;
    expect(uploads, 0);
    expect(storage.values['alice'], isEmpty);
    queue.dispose();
  });

  test(
    'failed undo draft persistence leaves the saved operation intact',
    () async {
      final _Storage storage = _Storage();
      final ScanQueue queue = ScanQueue(
        userId: 'alice',
        storage: storage,
        writer: (ScanQueueEntry entry) async {},
      );
      await queue.load();
      await queue.enqueueBatch(<ScanQueueApproval>[
        ScanQueueApproval(operationId: 'held', card: _card()),
      ], undoWindow: const Duration(seconds: 10));
      await expectLater(
        queue.undo(
          'held',
          beforeRemove: () async {
            throw StateError('draft write failed');
          },
        ),
        throwsStateError,
      );
      expect(queue.canUndo('held'), isTrue);
      expect(queue.entries.single.operationId, 'held');
      expect(storage.values['alice']!.keys, <String>['held']);
      queue.dispose();
    },
  );

  testWidgets(
    'failed undo remains durable and pause or disposal releases held flush',
    (WidgetTester tester) async {
      final _Storage storage = _Storage();
      DateTime now = DateTime.utc(2026, 10, 13);
      int uploads = 0;
      final ScanQueue queue = ScanQueue(
        userId: 'alice',
        storage: storage,
        now: () => now,
        writer: (ScanQueueEntry entry) async {
          uploads++;
        },
      );
      await queue.load();
      await queue.enqueueBatch(<ScanQueueApproval>[
        ScanQueueApproval(operationId: 'held', card: _card()),
      ], undoWindow: const Duration(seconds: 10));
      storage.failRemovals = true;
      await expectLater(queue.undo('held'), throwsStateError);
      expect(queue.canUndo('held'), isTrue);
      expect(storage.values['alice']!.keys, <String>['held']);
      Future<void> flush = queue.flush();
      await tester.pump();
      queue.pauseUploads();
      await flush;
      expect(uploads, 0);
      flush = queue.resumeUploads();
      await tester.pump();
      queue.dispose();
      await flush;
      now = now.add(const Duration(seconds: 20));
      await tester.pump(const Duration(seconds: 20));
      expect(uploads, 0);
      expect(storage.values['alice']!.keys, <String>['held']);
    },
  );

  test('automatic passes skip failed approvals and explicit retries remain bounded', () async {
    final _Storage storage = _Storage();
    final List<String> attempts = <String>[];
    bool allowFailed = false;
    final ScanQueue queue = ScanQueue(
      userId: 'alice',
      storage: storage,
      writer: (ScanQueueEntry entry) async {
        attempts.add(entry.operationId);
        if (entry.operationId == 'failed' && !allowFailed) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'unavailable',
          );
        }
      },
    );
    await queue.load();
    await queue.enqueueBatch(<ScanQueueApproval>[
      ScanQueueApproval(
        operationId: 'failed',
        card: _card(),
        quantity: 3,
        deckId: 'binder',
      ),
    ]);
    await queue.flush(retryFailures: false);
    final Map<String, Object?> failed = queue.entries.single.toMap();
    final int writes = storage.batchWrites;
    await queue.enqueueBatch(<ScanQueueApproval>[
      ScanQueueApproval(operationId: 'fresh', card: _card()),
    ]);
    await queue.flush(retryFailures: false);
    await queue.flush(retryFailures: false);
    expect(attempts, <String>['failed', 'fresh']);
    expect(queue.entries.single.toMap(), failed);
    expect(storage.values['alice']!['failed']!.toMap(), failed);
    expect(storage.batchWrites, writes + 1);
    expect(queue.failedCount, 1);
    await queue.flush();
    expect(attempts, <String>['failed', 'fresh', 'failed']);
    expect(queue.entries.single.toMap(), failed);
    expect(queue.failedCount, 1);
    queue.pauseUploads();
    allowFailed = true;
    await queue.flush(retryFailures: false);
    expect(queue.paused, isTrue);
    expect(attempts, hasLength(3));
    await queue.resumeUploads();
    expect(attempts, <String>['failed', 'fresh', 'failed', 'failed']);
    expect(queue.entries, isEmpty);
    expect(queue.failedCount, 0);
    queue.dispose();
  });

  final Map<Object, String> diagnosticCases = <Object, String>{
    FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'):
        'permission-denied',
    FirebaseException(plugin: 'cloud_firestore', code: 'unauthenticated'):
        'Sign in',
    FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'):
        'unavailable',
    FirebaseException(plugin: 'cloud_firestore', code: 'deadline-exceeded'):
        'deadline-exceeded',
    FirebaseException(
      plugin: 'cloud_firestore',
      code: 'network-request-failed',
    ): 'network-request-failed',
    FirebaseException(plugin: 'cloud_firestore', code: 'resource-exhausted'):
        'limit reached',
    FirebaseException(plugin: 'cloud_firestore', code: 'failed-precondition'):
        'failed-precondition',
    StateError('Destination group no longer exists.'): 'Restore it',
    StateError('Operation ID was already used for another addition.'):
        'receipt must be reconciled',
    StateError('Stored printing metadata does not match this addition.'):
        'conflicting metadata',
    StateError('Account changed.'): 'account that captured',
    StateError('private diagnostic must not appear'):
        'Check your connection and destination',
  };
  for (final MapEntry<Object, String> scenario in diagnosticCases.entries) {
    test(
      'upload diagnostic persists without changing approval: ${scenario.value}',
      () async {
        final _Storage storage = _Storage();
        final ScanQueue queue = ScanQueue(
          userId: 'alice',
          storage: storage,
          writer: (ScanQueueEntry _) async => throw scenario.key,
        );
        await queue.load();
        await queue.enqueueBatch(<ScanQueueApproval>[
          ScanQueueApproval(
            operationId: 'diagnostic',
            card: _card(),
            quantity: 3,
            deckId: 'deck',
            deckSection: DeckSection.sideboard,
          ),
        ]);
        final Map<String, Object?> original = queue.entries.single.toMap();
        await queue.flush();
        final ScanQueueEntry failed = queue.entries.single;
        expect(failed.error, contains(scenario.value));
        expect(failed.error, isNot(contains('private diagnostic')));
        expect(failed.withError(null).toMap(), original);
        final ScanQueue restored = ScanQueue(
          userId: 'alice',
          storage: storage,
          writer: (ScanQueueEntry _) async {},
        );
        await restored.load();
        expect(restored.entries.single.toMap(), failed.toMap());
        await restored.flush(retryFailures: false);
        expect(restored.entries.single.toMap(), failed.toMap());
        restored.dispose();
        queue.dispose();
      },
    );
  }

  test(
    'accepted addition with failed local cleanup retries the same receipt only',
    () async {
      final _Storage storage = _Storage();
      final FakeFirebaseFirestore firestore = FakeFirebaseFirestore();
      final CollectionIngestion ingestion = CollectionIngestion(
        firestore: firestore,
      );
      final List<String> attempts = <String>[];
      final ScanQueue queue = ScanQueue(
        userId: 'alice',
        storage: storage,
        writer: (ScanQueueEntry entry) async {
          attempts.add(entry.operationId);
          await ingestion.add(
            userId: 'alice',
            operationId: entry.operationId,
            card: entry.card,
            quantity: entry.quantity,
          );
        },
      );
      await queue.load();
      await queue.enqueueBatch(<ScanQueueApproval>[
        ScanQueueApproval(operationId: 'cleanup', card: _card(), quantity: 3),
      ]);
      final Map<String, Object?> original = queue.entries.single.toMap();
      storage.failRemovals = true;
      await queue.flush();
      expect(queue.entries.single.error, contains('Addition saved'));
      expect(queue.entries.single.withError(null).toMap(), original);
      expect(
        storage.values['alice']!['cleanup']!.error,
        contains('pending record'),
      );
      storage.failRemovals = false;
      await queue.flush(retryFailures: false);
      expect(attempts, <String>['cleanup']);
      await queue.resumeUploads();
      expect(attempts, <String>['cleanup', 'cleanup']);
      expect(queue.entries, isEmpty);
      expect(
        (await firestore.doc('user/alice/cards/${_printing}__foil').get())
            .data()!['quantity'],
        3,
      );
      queue.dispose();
    },
  );

  test(
    'restart after a lost acknowledgement replays one persisted operation',
    () async {
      final _Storage storage = _Storage();
      final FakeFirebaseFirestore firestore = FakeFirebaseFirestore();
      final CollectionIngestion ingestion = CollectionIngestion(
        firestore: firestore,
      );
      final List<String> attempts = <String>[];
      bool loseAcknowledgement = true;
      Future<void> send(ScanQueueEntry entry) async {
        expect(storage.values['alice']!.containsKey(entry.operationId), isTrue);
        attempts.add(entry.operationId);
        await ingestion.add(
          userId: 'alice',
          operationId: entry.operationId,
          card: entry.card,
          quantity: entry.quantity,
        );
        if (loseAcknowledgement) {
          throw StateError('connection lost after commit');
        }
      }

      final ScanQueue original = ScanQueue(
        userId: 'alice',
        storage: storage,
        writer: send,
      );
      await original.load();
      await original.enqueue(card: _card(), quantity: 3);
      final String operation = original.entries.single.operationId;
      await original.flush();
      expect(original.entries.single.error, contains('then retry'));
      original.dispose();
      loseAcknowledgement = false;
      final ScanQueue restored = ScanQueue(
        userId: 'alice',
        storage: storage,
        writer: send,
      );
      await restored.load();
      expect(restored.entries.single.operationId, operation);
      expect(restored.entries.single.card.finish, Finish.foil);
      await restored.flush();
      expect(restored.entries, isEmpty);
      expect(attempts, <String>[operation, operation]);
      expect(
        (await firestore.doc('user/alice/cards/${_printing}__foil').get())
            .data()!['quantity'],
        3,
      );
      restored.dispose();
    },
  );

  test('concurrent approvals persist all entries and preserve destination across restart', () async {
    final _Storage storage = _Storage();
    final ScanQueue queue = ScanQueue(
      userId: 'alice',
      storage: storage,
      writer: (ScanQueueEntry _) async {},
    );
    await queue.load();
    await Future.wait<void>(<Future<void>>[
      queue.enqueue(
        card: _card(),
        quantity: 2,
        deckId: 'deck-1',
        deckSection: DeckSection.sideboard,
      ),
      queue.enqueue(card: _card(), quantity: 4),
    ]);
    expect(queue.entries.length, 2);
    final ScanQueue restored = ScanQueue(
      userId: 'alice',
      storage: storage,
      writer: (ScanQueueEntry _) async {},
    );
    await restored.load();
    expect(restored.entries.first.deckId, 'deck-1');
    expect(restored.entries.first.deckSection, DeckSection.sideboard);
    expect(restored.entries.last.quantity, 4);
    expect(
      restored.entries
          .map((ScanQueueEntry entry) => entry.operationId)
          .toSet()
          .length,
      2,
    );
    final ScanQueue otherUser = ScanQueue(
      userId: 'bob',
      storage: storage,
      writer: (ScanQueueEntry _) async {},
    );
    await otherUser.load();
    expect(otherUser.entries, isEmpty);
    queue.dispose();
    restored.dispose();
    otherUser.dispose();
  });

  test(
    'disk failure cannot upload an approval that was not persisted',
    () async {
      final _Storage storage = _Storage()..failWrites = true;
      int uploads = 0;
      final ScanQueue queue = ScanQueue(
        userId: 'alice',
        storage: storage,
        writer: (ScanQueueEntry _) async {
          uploads++;
        },
      );
      await queue.load();
      await expectLater(
        queue.enqueue(card: _card(), quantity: 1),
        throwsStateError,
      );
      await queue.flush();
      expect(uploads, 0);
      expect(queue.entries, isEmpty);
      queue.dispose();
    },
  );

  test(
    'duplicate flush cannot overlap an upload or remove an in-flight entry',
    () async {
      final _Storage storage = _Storage();
      final Completer<void> pending = Completer<void>();
      int uploads = 0;
      final ScanQueue queue = ScanQueue(
        userId: 'alice',
        storage: storage,
        writer: (ScanQueueEntry _) {
          uploads++;
          return pending.future;
        },
      );
      await queue.load();
      await queue.enqueue(card: _card(), quantity: 1);
      final Future<void> first = queue.flush();
      await queue.flush();
      await expectLater(
        queue.remove(queue.entries.single.operationId),
        throwsStateError,
      );
      pending.complete();
      await first;
      expect(uploads, 1);
      expect(queue.entries, isEmpty);
      queue.dispose();
    },
  );
  test('bulk approvals have one durable write and one notification', () async {
    final _Storage storage = _Storage();
    final ScanQueue queue = ScanQueue(
      userId: 'alice',
      storage: storage,
      writer: (ScanQueueEntry _) async {},
    );
    await queue.load();
    int notifications = 0;
    queue.addListener(() => notifications++);
    await queue.enqueueBatch(
      List<ScanQueueApproval>.generate(
        1000,
        (int index) => ScanQueueApproval(card: _card(), quantity: index + 1),
      ),
    );
    expect(storage.batchWrites, 1);
    expect(notifications, 1);
    expect(queue.count, 1000);
    expect(queue.entryAt(999).quantity, 1000);
    expect(identical(queue.entries, queue.entries), isTrue);
    expect(() => queue.entries.clear(), throwsUnsupportedError);
    queue.dispose();
  });

  testWidgets(
    'upload deadlines retain actual writer slots and protect late acknowledgements',
    (WidgetTester tester) async {
      final _Storage storage = _Storage();
      final List<Completer<void>> pending = <Completer<void>>[];
      final List<String> attempts = <String>[];
      bool holdWrites = true;
      int active = 0;
      int peak = 0;
      final ScanQueue queue = ScanQueue(
        userId: 'alice',
        storage: storage,
        writer: (ScanQueueEntry entry) async {
          attempts.add(entry.operationId);
          active++;
          peak = active > peak ? active : peak;
          try {
            if (holdWrites) {
              final Completer<void> completion = Completer<void>();
              pending.add(completion);
              await completion.future;
            }
          } finally {
            active--;
          }
        },
      );
      await queue.load();
      await queue.enqueueBatch(
        List<ScanQueueApproval>.generate(
          1000,
          (int index) =>
              ScanQueueApproval(operationId: 'draft_$index', card: _card()),
        ),
      );
      final Future<void> flushing = queue.flush();
      expect(attempts, hasLength(4));
      await tester.pump(const Duration(seconds: 26));
      expect(queue.paused, isTrue);
      expect(queue.sending, isTrue);
      expect(queue.count, 1000);
      expect(queue.isSending('draft_0'), isTrue);
      await expectLater(queue.remove('draft_0'), throwsStateError);
      await queue.resumeUploads();
      await tester.pump(const Duration(minutes: 2));
      expect(attempts, hasLength(4));
      expect(active, 4);
      expect(queue.paused, isTrue);

      pending.first.complete();
      await tester.pump();
      expect(queue.count, 999);
      expect(queue.isSending('draft_0'), isFalse);
      expect(storage.values['alice']!.containsKey('draft_0'), isFalse);
      expect(attempts, hasLength(4));
      pending[1].completeError(StateError('late destination failure'));
      pending[2].complete();
      pending[3].complete();
      await flushing;
      expect(queue.count, 997);
      expect(queue.failedCount, 1);
      expect(
        queue.entries
            .firstWhere(
              (ScanQueueEntry entry) => entry.operationId == 'draft_1',
            )
            .error,
        isNotNull,
      );
      expect(active, 0);

      holdWrites = false;
      await queue.resumeUploads();
      expect(queue.count, 0);
      expect(peak, 4);
      expect(attempts.where((String id) => id == 'draft_0'), hasLength(1));
      expect(attempts.where((String id) => id == 'draft_1'), hasLength(2));
      queue.dispose();
    },
  );

  testWidgets(
    'a late successful write leaves its durable receipt retry after disposal without notifying UI',
    (WidgetTester tester) async {
      final _Storage storage = _Storage();
      final Completer<void> pending = Completer<void>();
      final FakeFirebaseFirestore firestore = FakeFirebaseFirestore();
      final CollectionIngestion ingestion = CollectionIngestion(
        firestore: firestore,
      );
      final ScanQueue queue = ScanQueue(
        userId: 'alice',
        storage: storage,
        writer: (ScanQueueEntry entry) async {
          await pending.future;
          await ingestion.add(
            userId: 'alice',
            operationId: entry.operationId,
            card: entry.card,
            quantity: entry.quantity,
          );
        },
      );
      await queue.load();
      await queue.enqueueBatch(<ScanQueueApproval>[
        ScanQueueApproval(
          operationId: 'draft_late',
          card: _card(),
          quantity: 3,
        ),
      ]);
      int notifications = 0;
      queue.addListener(() => notifications++);
      final Future<void> flushing = queue.flush();
      await tester.pump(const Duration(seconds: 26));
      expect(queue.isSending('draft_late'), isTrue);
      queue.dispose();
      final int before = notifications;
      pending.complete();
      await flushing;
      await tester.pump(const Duration(seconds: 26));
      expect(notifications, before);
      expect(queue.count, 1);
      expect(storage.values['alice']!.values.single.operationId, 'draft_late');
      expect(
        (await firestore.doc('user/alice/cards/${_printing}__foil').get())
            .data()!['quantity'],
        3,
      );
      await queue.resumeUploads();
      expect(notifications, before);
    },
  );

  test(
    'one invalid approval prevents writing any part of the bulk batch',
    () async {
      final _Storage storage = _Storage();
      final ScanQueue queue = ScanQueue(
        userId: 'alice',
        storage: storage,
        writer: (ScanQueueEntry _) async {},
      );
      await queue.load();
      await expectLater(
        queue.enqueueBatch(<ScanQueueApproval>[
          ScanQueueApproval(card: _card()),
          ScanQueueApproval(card: _card(), quantity: 0),
        ]),
        throwsArgumentError,
      );
      expect(storage.batchWrites, 0);
      expect(queue.count, 0);
      queue.dispose();
    },
  );

  test('bounded concurrent uploads continue past a failed addition', () async {
    final _Storage storage = _Storage();
    int active = 0;
    int peak = 0;
    int attempts = 0;
    final ScanQueue queue = ScanQueue(
      userId: 'alice',
      storage: storage,
      uploadConcurrency: 3,
      writer: (ScanQueueEntry entry) async {
        active++;
        peak = peak < active ? active : peak;
        attempts++;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        active--;
        if (entry.quantity == 2) {
          throw StateError('invalid destination');
        }
      },
    );
    await queue.load();
    await queue.enqueueBatch(
      List<ScanQueueApproval>.generate(
        10,
        (int index) => ScanQueueApproval(card: _card(), quantity: index + 1),
      ),
    );
    await queue.flush();
    expect(peak, 3);
    expect(attempts, 10);
    expect(queue.entries.single.quantity, 2);
    expect(queue.entries.single.error, isNotNull);
    expect(storage.values['alice']!.length, 1);
    queue.dispose();
  });

  test(
    'pause finishes in-flight writes and resume uploads remaining approvals',
    () async {
      final _Storage storage = _Storage();
      final Completer<void> submitted = Completer<void>();
      final Completer<void> finish = Completer<void>();
      int attempts = 0;
      final ScanQueue queue = ScanQueue(
        userId: 'alice',
        storage: storage,
        uploadConcurrency: 1,
        writer: (ScanQueueEntry entry) async {
          attempts++;
          if (attempts == 1) {
            submitted.complete();
            await finish.future;
          }
        },
      );
      await queue.load();
      await queue.enqueueBatch(
        List<ScanQueueApproval>.generate(
          3,
          (_) => ScanQueueApproval(card: _card()),
        ),
      );
      final Future<void> flushing = queue.flush();
      await submitted.future;
      queue.pauseUploads();
      finish.complete();
      await flushing;
      expect(attempts, 1);
      expect(queue.count, 2);
      expect(queue.paused, isTrue);
      await queue.resumeUploads();
      expect(attempts, 3);
      expect(queue.count, 0);
      queue.dispose();
    },
  );

  test('failed local acknowledgement leaves original operation durable for restart', () async {
    final _Storage storage = _Storage();
    final Set<String> applied = <String>{};
    int attempts = 0;
    final ScanQueue queue = ScanQueue(
      userId: 'alice',
      storage: storage,
      writer: (ScanQueueEntry entry) async {
        attempts++;
        applied.add(entry.operationId);
        storage.failWrites = true;
      },
    );
    await queue.load();
    await queue.enqueue(card: _card(), quantity: 1);
    await queue.flush();
    expect(queue.count, 1);
    final String operationId = queue.entries.single.operationId;
    expect(storage.values['alice']!.containsKey(operationId), isTrue);
    storage.failWrites = false;
    final ScanQueue resumed = ScanQueue(
      userId: 'alice',
      storage: storage,
      writer: (ScanQueueEntry entry) async {
        attempts++;
        applied.add(entry.operationId);
      },
    );
    await resumed.load();
    await resumed.flush();
    expect(attempts, 2);
    expect(applied, <String>{operationId});
    expect(resumed.count, 0);
    queue.dispose();
    resumed.dispose();
  });
  test('stable draft approval survives enqueue acknowledgement loss without duplicate inventory', () async {
    final _Storage storage = _Storage();
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final CollectionIngestion ingestion = CollectionIngestion(
      firestore: database,
    );
    final ScanQueue queue = ScanQueue(
      userId: 'alice',
      storage: storage,
      writer: (ScanQueueEntry entry) async {
        await ingestion.add(
          userId: 'alice',
          operationId: entry.operationId,
          card: entry.card,
          quantity: entry.quantity,
        );
      },
    );
    await queue.load();
    final ScanQueueApproval approval = ScanQueueApproval(
      operationId: 'draft_0',
      card: _card(),
      quantity: 5,
    );
    await queue.enqueueBatch(<ScanQueueApproval>[approval, approval]);
    await queue.enqueueBatch(<ScanQueueApproval>[approval]);
    expect(queue.count, 1);
    expect(storage.batchWrites, 1);
    await expectLater(
      queue.enqueueBatch(<ScanQueueApproval>[
        ScanQueueApproval(operationId: 'draft_0', card: _card(), quantity: 6),
      ]),
      throwsStateError,
    );
    await queue.flush();
    await queue.enqueueBatch(<ScanQueueApproval>[approval]);
    await queue.flush();
    expect(
      (await database.doc('user/alice/cards/${_printing}__foil').get())
          .data()!['quantity'],
      5,
    );
    expect(queue.count, 0);
    queue.dispose();
  });
}
