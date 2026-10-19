import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/scanning/scan_accounting.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';
import 'package:the_collector/utils/scanning/journaled_scan_queue_storage.dart';

class _Recognizer implements CardRecognizer {
  final Completer<void> admitted = Completer<void>();
  final Completer<ScanRecognition> result = Completer<ScanRecognition>();
  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) {
    admitted.complete();
    return result.future;
  }
}

class _FailingJournalStore extends ScanDraftStore {
  _FailingJournalStore() : super(userId: 'accounting');
  bool fail = true;
  @override
  Future<void> recordQueueEntries(
    List<ScanQueueEntry> entries, {
    required bool completed,
  }) {
    if (fail) throw const FileSystemException('Journal unavailable');
    return super.recordQueueEntries(entries, completed: completed);
  }
}

class _FailingUndoJournalStore extends ScanDraftStore {
  _FailingUndoJournalStore() : super(userId: 'accounting');
  bool fail = true;
  @override
  Future<void> finishQueueRemoval(List<String> ids) {
    if (fail) throw const FileSystemException('Undo receipt unavailable');
    return super.finishQueueRemoval(ids);
  }
}

class _InterruptedDiscardBox extends Fake implements Box<String> {
  _InterruptedDiscardBox(this.delegate);
  final Box<String> delegate;
  bool interrupt = false;
  @override
  String? get path => delegate.path;
  @override
  Iterable<String> get keys => delegate.keys.whereType<String>();
  @override
  bool containsKey(Object? key) => delegate.containsKey(key);
  @override
  String? get(Object? key, {String? defaultValue}) =>
      delegate.get(key, defaultValue: defaultValue);
  @override
  Future<void> put(Object? key, String value) => delegate.put(key, value);
  @override
  Future<void> putAll(Map<Object?, String> entries) => delegate.putAll(entries);
  @override
  Future<void> flush() => delegate.flush();
  @override
  Future<void> delete(Object? key) => delegate.delete(key);
  @override
  Future<void> deleteAll(Iterable<Object?> keys) async {
    final List<Object?> snapshot = keys.toList();
    if (interrupt &&
        snapshot.whereType<String>().any(
          (String key) => key.startsWith('photo:'),
        )) {
      interrupt = false;
      throw const FileSystemException(
        'Discard interrupted before photo removal',
      );
    }
    await delegate.deleteAll(snapshot);
  }
}

ScanCrop _crop([String path = '']) => ScanCrop(
  imagePath: path,
  width: 1000,
  height: 1400,
  rectified: true,
  sourceCorners: const <ScanPoint>[],
  lines: const <ScanTextLine>[],
);

void main() {
  late Directory directory;
  late MtgCard printing;
  late DateTime now;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('scan-accounting-');
    Hive.init(directory.path);
    final Map<String, Object?> fixture = Map<String, Object?>.from(
      jsonDecode(
        await File('test/fixtures/scryfall_split_card.json').readAsString(),
      ) as Map<Object?, Object?>,
    );
    printing = MtgCard.fromJson(fixture);
    now = DateTime.utc(2026, 10, 15);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  ScanQueueEntry entry(String id, {int quantity = 1}) => ScanQueueEntry(
    operationId: id,
    card: cardFromScryfall(printing, finish: Finish.nonfoil),
    quantity: quantity,
    createdAt: now,
    undoUntil: now.add(const Duration(seconds: 10)),
  );

  ScanDraftItem draft(String id, {bool approved = false}) => ScanDraftItem(
    id: id,
    photoId: '',
    crop: _crop(),
    approval: approved
        ? ScanQueueApproval(
            operationId: id,
            card: cardFromScryfall(printing, finish: Finish.nonfoil),
          )
        : null,
  );

  test(
    'discard removes staged choices while retaining submitted operations',
    () async {
      final ScanDraftStore drafts = ScanDraftStore(userId: 'accounting');
      await drafts.upsertItems(<ScanDraftItem>[
        draft('staged', approved: true),
        draft('submitted'),
      ]);
      await drafts.recordQueueEntries(<ScanQueueEntry>[
        entry('submitted'),
      ], completed: false);
      await drafts.discardRemaining();
      expect(
        (await drafts.readItems()).map((ScanDraftItem item) => item.id),
        <String>['submitted'],
      );
      expect((await drafts.readAccounting()).added, 1);
      expect((await drafts.readAccounting()).discarded, 1);
    },
  );

  test(
    'discard protects explicit queue IDs even before journal recovery',
    () async {
      final ScanDraftStore drafts = ScanDraftStore(userId: 'accounting');
      await drafts.upsertItems(<ScanDraftItem>[
        draft('staged', approved: true),
        draft('submitted'),
      ]);
      await drafts.discardRemaining(protectedIds: <String>{'submitted'});
      expect(
        (await drafts.readItems()).map((ScanDraftItem item) => item.id),
        <String>['submitted'],
      );
    },
  );

  test(
    'a session without persistence protects only explicitly submitted IDs',
    () async {
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: ScanResolver(),
      );
      addTearDown(session.dispose);
      session.add(ScanSessionItem.fromDraft(draft('staged', approved: true)));
      session.add(ScanSessionItem.fromDraft(draft('submitted')));
      await session.discardRemaining(protectedIds: <String>{'submitted'});
      expect(session.items.map((ScanSessionItem item) => item.id), <String>[
        'submitted',
      ]);
    },
  );

  test(
    'queue totals survive retirement without inventing captured evidence',
    () async {
      final ScanDraftStore drafts = ScanDraftStore(userId: 'accounting');
      final JournaledScanQueueStorage storage = JournaledScanQueueStorage(
        drafts: drafts,
      );
      await drafts.upsertItems(<ScanDraftItem>[draft('one', approved: true)]);
      await storage.upsertEntries('accounting', <ScanQueueEntry>[
        entry('one', quantity: 4),
      ]);
      await storage.completeEntry('accounting', entry('one', quantity: 4));
      await drafts.removeItems(<String>['one']);
      await storage.removeCompletedEntries('accounting', <String>['one']);
      await Hive.close();
      final ScanAccounting totals = await ScanDraftStore(userId: 'accounting')
          .readAccounting();
      expect(totals.captured, 0);
      expect(totals.added, 4);
      expect(totals.pendingDelivery, 0);
      expect(totals.discarded, 0);
    },
  );

  test(
    'replayed enqueue and completion count copies once without a capture',
    () async {
      final ScanDraftStore drafts = ScanDraftStore(userId: 'accounting');
      final JournaledScanQueueStorage storage = JournaledScanQueueStorage(
        drafts: drafts,
      );
      await drafts.upsertItems(<ScanDraftItem>[draft('one')]);
      for (int replay = 0; replay < 3; replay++) {
        await storage.upsertEntries('accounting', <ScanQueueEntry>[
          entry('one', quantity: 3),
        ]);
        await storage.completeEntry('accounting', entry('one', quantity: 3));
      }
      final ScanAccounting totals = await drafts.readAccounting();
      expect(totals.captured, 0);
      expect(totals.added, 3);
      expect(totals.pendingDelivery, 0);
    },
  );

  test(
    'undo retains the draft and reduces net added copies after restart',
    () async {
      final ScanDraftStore drafts = ScanDraftStore(userId: 'accounting');
      final ScanQueue queue = ScanQueue(
        userId: 'accounting',
        now: () => now,
        storage: JournaledScanQueueStorage(drafts: drafts),
        writer: (ScanQueueEntry _) async {},
      );
      addTearDown(queue.dispose);
      await drafts.upsertItems(<ScanDraftItem>[draft('one', approved: true)]);
      await queue.load();
      await queue.enqueueBatch(<ScanQueueApproval>[
        ScanQueueApproval(
          operationId: 'one',
          card: entry('one').card,
          quantity: 5,
        ),
      ], undoWindow: const Duration(seconds: 10));
      expect((await drafts.readAccounting()).added, 5);
      expect(await queue.undo('one'), isTrue);
      final ScanAccounting totals = await ScanDraftStore(userId: 'accounting')
          .readAccounting();
      expect(totals.captured, 0);
      expect(totals.added, 0);
      expect(totals.pendingDelivery, 0);
      expect(totals.undone, 1);
      expect(await drafts.readItems(), hasLength(1));
    },
  );

  test(
    'clear completed preserves totals, pending work and undo evidence',
    () async {
      final ScanDraftStore drafts = ScanDraftStore(userId: 'accounting');
      final JournaledScanQueueStorage storage = JournaledScanQueueStorage(
        drafts: drafts,
      );
      await drafts.upsertItems(<ScanDraftItem>[
        draft('complete', approved: true),
        draft('undo', approved: true),
        draft('unread'),
      ]);
      await storage.upsertEntries('accounting', <ScanQueueEntry>[
        entry('complete'),
        entry('undo'),
      ]);
      await storage.completeEntry('accounting', entry('complete'));
      await drafts.clearCompleted(now: now);
      expect(
        (await drafts.readItems()).map((ScanDraftItem item) => item.id),
        containsAll(<String>['undo', 'unread', 'complete']),
      );
      await drafts.clearCompleted(now: now.add(const Duration(seconds: 11)));
      expect(
        (await drafts.readItems()).map((ScanDraftItem item) => item.id),
        unorderedEquals(<String>['undo', 'unread']),
      );
      final ScanAccounting totals = await drafts.readAccounting();
      expect(totals.captured, 0);
      expect(totals.added, 2);
      expect(totals.pendingDelivery, 1);
      expect(totals.processing, 1);
      expect(
        await drafts.readRecentReceipts(),
        isNot(
          contains(
            predicate<ScanCaptureReceipt>(
              (ScanCaptureReceipt receipt) => receipt.id == 'complete',
            ),
          ),
        ),
      );
    },
  );

  test(
    'journal failure retains queue completion until replay before prune',
    () async {
      final _FailingJournalStore drafts = _FailingJournalStore();
      final HiveScanQueueStorage underlying = HiveScanQueueStorage();
      final JournaledScanQueueStorage storage = JournaledScanQueueStorage(
        drafts: drafts,
        storage: underlying,
      );
      await underlying.completeEntry(
        'accounting',
        entry('complete', quantity: 2),
      );
      await expectLater(
        storage.removeCompletedEntries('accounting', <String>['complete']),
        throwsA(isA<FileSystemException>()),
      );
      expect(await underlying.readCompletedEntries('accounting'), hasLength(1));
      drafts.fail = false;
      await storage.readCompletedEntries('accounting');
      await storage.removeCompletedEntries('accounting', <String>['complete']);
      final ScanAccounting totals = await drafts.readAccounting();
      expect(totals.captured, 0);
      expect(totals.added, 2);
    },
  );

  test(
    'enqueue interrupted before journal is reconciled on reopening',
    () async {
      final _FailingJournalStore drafts = _FailingJournalStore();
      final HiveScanQueueStorage underlying = HiveScanQueueStorage();
      final JournaledScanQueueStorage storage = JournaledScanQueueStorage(
        drafts: drafts,
        storage: underlying,
      );
      await expectLater(
        storage.upsertEntries('accounting', <ScanQueueEntry>[
          entry('pending', quantity: 6),
        ]),
        throwsA(isA<FileSystemException>()),
      );
      expect(await underlying.readEntries('accounting'), hasLength(1));
      drafts.fail = false;
      await storage.readEntries('accounting');
      await storage.readEntries('accounting');
      final ScanAccounting totals = await drafts.readAccounting();
      expect(totals.captured, 0);
      expect(totals.added, 6);
      expect(totals.pendingDelivery, 6);
    },
  );

  test(
    'accounts have isolated totals and reject cross-account queue writes',
    () async {
      final ScanDraftStore drafts = ScanDraftStore(userId: 'accounting');
      final JournaledScanQueueStorage storage = JournaledScanQueueStorage(
        drafts: drafts,
      );
      await storage.upsertEntries('accounting', <ScanQueueEntry>[entry('one')]);
      expect(
        (await ScanDraftStore(userId: 'other').readAccounting()).captured,
        0,
      );
      await expectLater(
        storage.upsertEntries('other', <ScanQueueEntry>[entry('one')]),
        throwsArgumentError,
      );
      expect((await drafts.readAccounting()).captured, 0);
    },
  );

  test(
    'undo interrupted after queue deletion is recovered exactly once',
    () async {
      final _FailingUndoJournalStore drafts = _FailingUndoJournalStore();
      final JournaledScanQueueStorage storage = JournaledScanQueueStorage(
        drafts: drafts,
      );
      await drafts.upsertItems(<ScanDraftItem>[draft('one', approved: true)]);
      await storage.upsertEntries('accounting', <ScanQueueEntry>[
        entry('one', quantity: 2),
      ]);
      await expectLater(
        storage.removeEntries('accounting', <String>['one']),
        throwsA(isA<FileSystemException>()),
      );
      final JournaledScanQueueStorage reopened = JournaledScanQueueStorage(
        drafts: ScanDraftStore(userId: 'accounting'),
      );
      expect(await reopened.readEntries('accounting'), isEmpty);
      expect(await reopened.readEntries('accounting'), isEmpty);
      final ScanAccounting totals = await ScanDraftStore(userId: 'accounting')
          .readAccounting();
      expect(totals.captured, 0);
      expect(totals.added, 0);
      expect(totals.undone, 1);
    },
  );

  test('unresolved counts move from processing to needs check and disappear on discard', () async {
    final ScanDraftStore drafts = ScanDraftStore(userId: 'accounting');
    await drafts.upsertItems(<ScanDraftItem>[draft('one')]);
    expect((await drafts.readAccounting()).processing, 1);
    await drafts.upsertItems(<ScanDraftItem>[
      ScanDraftItem(
        id: 'one',
        photoId: '',
        crop: _crop(),
        error: 'Lookup unavailable',
      ),
    ]);
    final ScanAccounting failed = await drafts.readAccounting();
    expect(failed.processing, 0);
    expect(failed.needsCheck, 1);
    await drafts.discardRemaining();
    final ScanAccounting discarded = await drafts.readAccounting();
    expect(discarded.captured, 0);
    expect(discarded.processing, 0);
    expect(discarded.needsCheck, 0);
    expect(discarded.discarded, 1);
  });

  test(
    'interrupted discard is replayed before a saved photo can resume',
    () async {
      final File photo = await File('${directory.path}/gallery.jpg')
          .writeAsBytes(<int>[1, 2, 3]);
      late _InterruptedDiscardBox box;
      final ScanDraftStore drafts = ScanDraftStore(
        userId: 'accounting',
        openBox: (String name) async {
          box = _InterruptedDiscardBox(await Hive.openBox<String>(name));
          return box;
        },
      );
      await drafts.importPhotos(<String>[photo.path], multipleCards: true);
      await drafts.upsertItems(<ScanDraftItem>[draft('one')]);
      box.interrupt = true;
      await expectLater(
        drafts.discardRemaining(),
        throwsA(isA<FileSystemException>()),
      );
      final ScanDraftStore restarted = ScanDraftStore(userId: 'accounting');
      expect(await restarted.readPhotos(), isEmpty);
      expect(await restarted.readItems(), isEmpty);
      final ScanAccounting totals = await restarted.readAccounting();
      expect(totals.captured, 0);
      expect(totals.discarded, 1);
    },
  );

  test(
    'clear completed leaves a capture awaiting its first durable write alone',
    () async {
      final ScanDraftStore drafts = ScanDraftStore(userId: 'accounting');
      final ScanSession session = ScanSession(
        recognizer: _Recognizer(),
        resolver: ScanResolver(),
        store: drafts,
      );
      addTearDown(session.dispose);
      await session.load();
      final ScanSessionItem pending = ScanSessionItem(
        _crop(),
        id: 'not-yet-written',
      );
      session.add(pending);
      await session.clearCompleted(now: now);
      expect(session.items, contains(same(pending)));
    },
  );

  test(
    'large completed batches retain totals with bounded recent receipts',
    () async {
      final ScanDraftStore drafts = ScanDraftStore(userId: 'accounting');
      await drafts.recordQueueEntries(<ScanQueueEntry>[
        for (int index = 0; index < 3200; index++) entry('capture-$index'),
      ], completed: true);
      final ScanAccounting totals = await drafts.readAccounting();
      expect(totals.captured, 0);
      expect(totals.added, 3200);
      expect(await drafts.readRecentReceipts(), hasLength(24));
      await drafts.clearCompleted(now: now.add(const Duration(seconds: 11)));
      expect(await drafts.readRecentReceipts(), isEmpty);
      expect((await drafts.readAccounting()).added, 3200);
    },
  );

  test('discard remaining cancels late recognition but preserves approved additions', () async {
    final File photo = await File('${directory.path}/gallery.jpg')
        .writeAsBytes(<int>[1, 2, 3]);
    final ScanDraftStore drafts = ScanDraftStore(userId: 'accounting');
    final _Recognizer recognizer = _Recognizer();
    final ScanSession session = ScanSession(
      recognizer: recognizer,
      resolver: ScanResolver(),
      store: drafts,
    );
    addTearDown(session.dispose);
    await session.load();
    final ScanSessionItem approved = ScanSessionItem(_crop(), id: 'approved')
      ..approval = draft('approved', approved: true).approval;
    final ScanSessionItem rejected = ScanSessionItem(_crop(), id: 'rejected');
    session.add(approved);
    session.add(rejected);
    await session.persist(<ScanSessionItem>[approved, rejected]);
    final JournaledScanQueueStorage storage = JournaledScanQueueStorage(
      drafts: drafts,
    );
    await storage.upsertEntries('accounting', <ScanQueueEntry>[
      entry('approved'),
    ]);
    await session.addPhotos(<String>[photo.path], multipleCards: true);
    await recognizer.admitted.future;
    await session.discardRemaining();
    recognizer.result.complete(
      ScanRecognition(
        imagePath: photo.path,
        width: 1000,
        height: 1400,
        crops: <ScanCrop>[_crop()],
      ),
    );
    while (session.running) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(session.items.map((ScanSessionItem item) => item.id), <String>[
      'approved',
    ]);
    expect(await drafts.readPhotos(), isEmpty);
    expect(
      (await drafts.readItems()).map((ScanDraftItem item) => item.id),
      <String>['approved'],
    );
    expect(await storage.readEntries('accounting'), hasLength(1));
    final ScanAccounting totals = await drafts.readAccounting();
    expect(totals.captured, 0);
    expect(totals.added, 1);
    expect(totals.discarded, 1);
  });
}
