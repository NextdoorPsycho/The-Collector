import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arcane/arcane.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' hide Color;
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:the_collector/pages/scanning/scan_screen.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/scanning/scan_accounting.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

class _Storage implements ScanQueueStorage {
  final Map<String, ScanQueueEntry> pending = <String, ScanQueueEntry>{};
  final Map<String, ScanQueueEntry> completed = <String, ScanQueueEntry>{};
  @override
  Future<List<ScanQueueEntry>> readEntries(String userId) async =>
      pending.values.toList();
  @override
  Future<List<ScanQueueEntry>> readCompletedEntries(String userId) async =>
      completed.values.toList();
  @override
  Future<void> upsertEntries(
    String userId,
    List<ScanQueueEntry> entries,
  ) async {
    for (final ScanQueueEntry entry in entries) {
      pending[entry.operationId] = entry;
    }
  }

  @override
  Future<void> completeEntry(String userId, ScanQueueEntry entry) async {
    completed[entry.operationId] = entry;
    pending.remove(entry.operationId);
  }

  @override
  Future<void> removeEntries(String userId, List<String> ids) async {
    ids.forEach(pending.remove);
  }

  @override
  Future<void> removeCompletedEntries(String userId, List<String> ids) async {
    ids.forEach(completed.remove);
  }
}

class _Drafts extends ScanDraftStore {
  _Drafts() : super(userId: 'accounting-ui');
  final ValueNotifier<int> changes = ValueNotifier<int>(0);
  final Map<String, ScanCaptureReceipt> receipts =
      <String, ScanCaptureReceipt>{};
  final List<ScanDraftItem> items = <ScanDraftItem>[];
  Completer<ScanAccounting>? heldRead;
  int reads = 0;
  int clearCalls = 0;
  int discardCalls = 0;
  @override
  ValueListenable<int> get accountingChanges => changes;
  @override
  Future<ScanAccounting> readAccounting() async {
    reads++;
    final Completer<ScanAccounting>? held = heldRead;
    heldRead = null;
    return held == null
        ? ScanAccounting.fromReceipts(receipts.values)
        : held.future;
  }

  @override
  Future<void> recordQueueEntries(
    List<ScanQueueEntry> entries, {
    required bool completed,
  }) async {
    for (final ScanQueueEntry entry in entries) {
      final ScanCaptureReceipt previous =
          receipts[entry.operationId] ??
          ScanCaptureReceipt(
            id: entry.operationId,
            capturedAt: entry.createdAt,
          );
      receipts[entry.operationId] = previous.copyWith(
        state: completed ? ScanReceiptState.delivered : ScanReceiptState.queued,
        quantity: entry.quantity,
      );
    }
    if (entries.isNotEmpty) changes.value++;
  }

  @override
  Future<void> reconcileQueueRemovals(Set<String> presentIds) async {}
  @override
  Future<List<ScanDraftItem>> readItems() async => items.toList();
  @override
  Future<List<ScanDraftPhoto>> readPhotos() async => <ScanDraftPhoto>[];
  @override
  Future<List<ScanDraftDetail>> readDetails() async => <ScanDraftDetail>[];
  @override
  Future<List<ScanDraftRecovery>> readRecoveries() async =>
      <ScanDraftRecovery>[];
  @override
  Future<List<ScanDraftRescan>> readRescans() async => <ScanDraftRescan>[];
  @override
  Future<void> removeItems(List<String> ids) async =>
      items.removeWhere((ScanDraftItem item) => ids.contains(item.id));
  @override
  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> values) async {
    for (final ScanDraftItem item in values) {
      items.removeWhere((ScanDraftItem old) => old.id == item.id);
      items.add(item);
    }
    return values;
  }

  @override
  Future<List<String>> clearCompleted({DateTime? now}) async {
    clearCalls++;
    for (final String id in receipts.keys.toList()) {
      if (receipts[id]!.state == ScanReceiptState.delivered) {
        receipts[id] = receipts[id]!.copyWith(archived: true);
      }
    }
    changes.value++;
    return <String>[];
  }

  @override
  Future<void> discardRemaining({
    Set<String> protectedIds = const <String>{},
  }) async {
    discardCalls++;
    items.removeWhere(
      (ScanDraftItem item) =>
          !protectedIds.contains(item.id) &&
          !(receipts[item.id]?.added ?? false),
    );
    changes.value++;
  }

  @override
  Future<void> clearCaptures() async =>
      throw StateError('A scope-free reset is forbidden.');
}

class _Recognizer implements CardRecognizer {
  @override
  Future<ScanRecognition> recognize(
    String path, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) => throw UnimplementedError();
}

const ScanCrop _crop = ScanCrop(
  imagePath: '',
  width: 1000,
  height: 1400,
  rectified: true,
  sourceCorners: <ScanPoint>[],
  lines: <ScanTextLine>[],
);

void main() {
  late MtgCard printing;
  setUp(() {
    printing = MtgCard.fromJson(
      Map<String, Object?>.from(
        jsonDecode(
          File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
        ) as Map<Object?, Object?>,
      ),
    );
  });
  ScanQueueEntry entry(String id, int quantity) => ScanQueueEntry(
    operationId: id,
    card: cardFromScryfall(printing, finish: Finish.nonfoil),
    quantity: quantity,
    createdAt: DateTime.utc(2026, 10, 15),
    undoUntil: DateTime.utc(2100),
    error: 'Offline',
  );
  Future<void> show(
    WidgetTester tester,
    _Drafts drafts,
    _Storage storage,
  ) async {
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        home: ScanScreen(
          userId: 'accounting-ui',
          draftStore: drafts,
          queueStorage: storage,
          queueWriter: (ScanQueueEntry _) async => throw StateError('Offline'),
          decks: const Stream<List<MTGDeck>>.empty(),
          recognizer: _Recognizer(),
          resolver: ScanResolver(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets(
    'default scanner journals queue recovery and preserves totals after retirement and reopening',
    (WidgetTester tester) async {
      final _Drafts drafts = _Drafts();
      final _Storage storage = _Storage()
        ..pending['pending'] = entry('pending', 4)
        ..completed['delivered'] = entry('delivered', 2);
      drafts.receipts['delivered'] = ScanCaptureReceipt(
        id: 'delivered',
        capturedAt: DateTime.utc(2026),
        acceptedAt: DateTime.utc(2026),
      );
      await show(tester, drafts, storage);
      expect(find.text('Captured 1'), findsOneWidget);
      expect(find.text('Added 6'), findsOneWidget);
      expect(find.text('Pending 4'), findsOneWidget);
      expect(storage.completed, isEmpty);
      await close(tester);
      await show(tester, drafts, storage);
      expect(find.text('Captured 1'), findsOneWidget);
      expect(find.text('Added 6'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'clear completed archives receipts while discard preserves approved drafts and queued additions',
    (WidgetTester tester) async {
      final _Drafts drafts = _Drafts();
      final _Storage storage = _Storage()
        ..pending['approved'] = entry('approved', 3);
      drafts.receipts['delivered'] = ScanCaptureReceipt(
        id: 'delivered',
        capturedAt: DateTime.utc(2026),
        acceptedAt: DateTime.utc(2026),
        state: ScanReceiptState.delivered,
        quantity: 2,
      );
      drafts.items.addAll(<ScanDraftItem>[
        ScanDraftItem(
          id: 'approved',
          photoId: '',
          crop: _crop,
          approval: ScanQueueApproval(
            operationId: 'approved',
            card: entry('approved', 3).card,
            quantity: 3,
          ),
        ),
        const ScanDraftItem(
          id: 'unresolved',
          photoId: '',
          crop: _crop,
          error: 'Needs review',
        ),
      ]);
      await show(tester, drafts, storage);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.dots_three));
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .byKey(const ValueKey<String>('scan-clear-completed'))
            .hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(drafts.clearCalls, 1);
      expect(drafts.items, hasLength(2));
      expect(find.text('Added 5'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('scan-discard-remaining')),
      );
      await tester.pumpAndSettle();
      expect(drafts.discardCalls, 1);
      expect(drafts.items.map((ScanDraftItem item) => item.id), <String>[
        'approved',
      ]);
      expect(storage.pending.keys, <String>['approved']);
      expect(find.text('Added 5'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'accounting invalidations coalesce and late reads cannot replace newer counts',
    (WidgetTester tester) async {
      final _Drafts drafts = _Drafts();
      final Completer<ScanAccounting> held = Completer<ScanAccounting>();
      drafts.heldRead = held;
      await show(tester, drafts, _Storage());
      drafts.receipts['current'] = ScanCaptureReceipt(
        id: 'current',
        capturedAt: DateTime.utc(2026),
        acceptedAt: DateTime.utc(2026),
        state: ScanReceiptState.delivered,
        quantity: 9,
      );
      for (int index = 0; index < 20; index++) {
        drafts.changes.value++;
      }
      held.complete(const ScanAccounting(added: 1));
      await tester.pumpAndSettle();
      expect(find.text('Added 9'), findsOneWidget);
      expect(find.text('Added 1'), findsNothing);
      expect(drafts.reads, lessThanOrEqualTo(3));
      await close(tester);
      drafts.changes.value++;
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
