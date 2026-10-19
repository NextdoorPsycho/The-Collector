import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:scryfall_api/scryfall_api.dart' hide Color;
import 'package:the_collector/pages/scanning/scan_screen.dart';
import 'package:the_collector/pages/collection/collection_shops.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_accounting.dart';
import 'package:the_collector/utils/scanning/scan_queue.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

import 'helpers/load_collector_fonts.dart';

class _Storage implements ScanQueueStorage {
  @override
  Future<List<ScanQueueEntry>> readCompletedEntries(String userId) async =>
      <ScanQueueEntry>[];
  @override
  Future<void> completeEntry(String userId, ScanQueueEntry entry) async {}
  @override
  Future<void> removeCompletedEntries(
    String userId,
    List<String> operationIds,
  ) async {}
  _Storage([this.entries = const <ScanQueueEntry>[]]);
  final List<ScanQueueEntry> entries;
  @override
  Future<List<ScanQueueEntry>> readEntries(String userId) async =>
      entries.toList();
  @override
  Future<void> upsertEntries(
    String userId,
    List<ScanQueueEntry> entries,
  ) async {}
  @override
  Future<void> removeEntries(String userId, List<String> operationIds) async {}
}

MtgCard _printing([String name = 'Lightning Bolt']) =>
    MtgCard.fromJson(<String, Object?>{
      'id': 'd88a8e2d-2577-4a67-af86-e33c0ba94114',
      'oracle_id': '0ab3db25-3d2b-4a25-824f-794e95ab58a4',
      'lang': 'en',
      'prints_search_uri': 'https://api.scryfall.com/cards/search',
      'rulings_uri': 'https://api.scryfall.com/cards/test/rulings',
      'scryfall_uri': 'https://scryfall.com/card/m11/123',
      'uri': 'https://api.scryfall.com/cards/test',
      'cmc': 1,
      'color_identity': <String>['R'],
      'keywords': <String>[],
      'layout': 'normal',
      'legalities': <String, Object?>{},
      'name': name,
      'oversized': false,
      'reserved': false,
      'type_line': 'Instant',
      'booster': true,
      'border_color': 'black',
      'collector_number': '123a',
      'digital': false,
      'foil': true,
      'nonfoil': true,
      'finishes': <String>['nonfoil', 'foil'],
      'frame': '2015',
      'full_art': false,
      'games': <String>['paper'],
      'highres_image': true,
      'image_status': 'highres_scan',
      'prices': <String, Object?>{},
      'promo': false,
      'purchase_uris': <String, String>{},
      'related_uris': <String, String>{},
      'rarity': 'common',
      'released_at': '2010-07-16',
      'reprint': true,
      'scryfall_set_uri': 'https://scryfall.com/sets/m11',
      'set_name': 'Magic 2011',
      'set_search_uri': 'https://api.scryfall.com/cards/search',
      'set_type': 'core',
      'set_uri': 'https://api.scryfall.com/sets/m11',
      'set': 'm11',
      'set_id': 'set-id',
      'story_spotlight': false,
      'textless': false,
      'variation': false,
    });

class _Catalog implements ScanCatalog {
  int calls = 0;
  @override
  Future<PaginableList<MtgCard>> rulesKeywordCards(
    List<String> keywords, {
    String? phrase,
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);
  @override
  Future<PaginableList<MtgCard>> rulesTextPrintings(
    String phrase, {
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
    int page = 1,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);

  @override
  Future<MtgCard?> exactPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  }) async => null;
  @override
  Future<MtgCard?> fuzzyName(String name) async => null;
  @override
  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) async {
    calls++;
    return PaginableList<MtgCard>(data: <MtgCard>[_printing()], hasMore: false);
  }
}

Future<void> _show(
  WidgetTester tester,
  Widget screen,
  Brightness brightness, {
  double scale = 1,
  double keyboard = 0,
}) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(
        brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      ),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 568),
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: child!,
      ),
      home: screen,
    ),
  );
  await tester.pumpAndSettle();
}

class _Drafts extends ScanDraftStore {
  _Drafts(this.items) : super(userId: 'fixture');
  final List<ScanDraftItem> items;
  final List<String> removed = <String>[];
  ScanQueue? queue;

  @override
  Future<ScanAccounting> readAccounting() async => ScanAccounting(
    added: queue?.quantityCount ?? 0,
    pendingDelivery: queue?.quantityCount ?? 0,
  );

  @override
  Future<List<ScanDraftItem>> readItems() async => items.toList();
  @override
  Future<List<ScanDraftPhoto>> readPhotos() async => <ScanDraftPhoto>[];
  @override
  Future<List<ScanDraftRescan>> readRescans() async => <ScanDraftRescan>[];
  @override
  Future<List<List<ScanPoint>>> readReplacedRegions(String photoId) async =>
      <List<ScanPoint>>[];
  @override
  Future<List<ScanDraftDetail>> readDetails() async => <ScanDraftDetail>[];
  @override
  Future<List<ScanDraftRecovery>> readRecoveries() async =>
      <ScanDraftRecovery>[];
  @override
  Future<ScanDraftRecovery?> scheduleRecovery(
    String itemId, {
    bool manual = false,
  }) async => null;
  @override
  Future<void> completeRecovery(ScanDraftRecovery job) async {}
  @override
  Future<List<ScanDraftItem>> upsertItems(List<ScanDraftItem> values) async {
    for (final ScanDraftItem value in values) {
      items.removeWhere((ScanDraftItem item) => item.id == value.id);
      items.add(value);
    }
    return values;
  }

  @override
  Future<void> removeItems(List<String> ids) async {
    removed.addAll(ids);
    items.removeWhere((ScanDraftItem item) => ids.contains(item.id));
  }
}

ScanDraftItem _draft(
  String id, {
  String name = 'Lightning Bolt',
  String path = '',
  bool reviewed = false,
  bool selected = false,
  bool exact = false,
}) {
  final MtgCard card = _printing(name);
  final ScanCrop crop = ScanCrop(
    imagePath: path,
    width: 640,
    height: 900,
    rectified: true,
    sourceCorners: const <ScanPoint>[],
    lines: <ScanTextLine>[
      ScanTextLine(
        text: name,
        confidence: .99,
        bounds: const ScanBounds(.1, .05, .7, .02),
      ),
      const ScanTextLine(
        text: '123a',
        confidence: .99,
        bounds: ScanBounds(.05, .85, .2, .02),
      ),
      const ScanTextLine(
        text: 'M11 EN',
        confidence: .99,
        bounds: ScanBounds(.05, .9, .2, .02),
      ),
    ],
  );
  return ScanDraftItem(
    id: id,
    photoId: '',
    crop: crop,
    resolution: ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(card, <ScanEvidence>{ScanEvidence.nameMatch}),
      ],
      hints: ScanHints.fromCrop(crop),
      status: exact
          ? ScanResolutionStatus.exactPrinting
          : ScanResolutionStatus.needsReview,
    ),
    approval: reviewed
        ? ScanQueueApproval(
            operationId: id,
            card: cardFromScryfall(card, finish: Finish.nonfoil),
            quantity: 2,
            deckSection: DeckSection.mainboard,
          )
        : null,
    selected: selected,
  );
}

ScanScreen _screen(
  ScanQueue queue, {
  _Drafts? drafts,
  List<MTGDeck> decks = const <MTGDeck>[],
}) => ScanScreen(
  userId: 'fixture',
  queue: queue,
  draftStore: drafts,
  resolver: ScanResolver(catalog: _Catalog()),
  decks: Stream<List<MTGDeck>>.value(decks),
);

Future<void> _choose<T>(WidgetTester tester, String label) async {
  final Finder destination = find.byKey(
    const ValueKey<String>('printing-destination'),
  );
  final Finder selector = T == String && destination.evaluate().isNotEmpty
      ? destination
      : find.byType(Selector<T>).first;
  await tester.ensureVisible(selector);
  await tester.pumpAndSettle();
  await tester.tap(selector);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.ensureVisible(find.text(label).last);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(find.text(label).last);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadCollectorFonts);
  testWidgets(
    'manual correction keeps destination and section without saving before confirmation',
    (WidgetTester tester) async {
      DateTime now = DateTime.utc(2026, 10, 13);
      final List<ScanQueueEntry> writes = <ScanQueueEntry>[];
      final ScanQueue queue = ScanQueue(
        userId: 'fixture',
        now: () => now,
        storage: _Storage(),
        writer: (ScanQueueEntry entry) async => writes.add(entry),
      );
      addTearDown(queue.dispose);
      final _Drafts drafts = _Drafts(<ScanDraftItem>[_draft('manual')])
        ..queue = queue;
      final MTGDeck deck = MTGDeck(name: 'Batch deck')..id = 'batch-deck';
      await _show(
        tester,
        _screen(queue, drafts: drafts, decks: <MTGDeck>[deck]),
        Brightness.dark,
      );
      expect(drafts.items.single.approval, isNull);
      expect(queue.count, 0);
      expect(writes, isEmpty);
      await tester.tap(find.text('Check (1)'));
      await tester.pumpAndSettle();
      await _choose<Finish>(tester, 'Foil');
      await _choose<String>(tester, 'Deck: Batch deck');
      await _choose<DeckSection>(tester, 'Sideboard');
      expect(find.text('Confirm').hitTestable(), findsOneWidget);
      expect(drafts.items.single.approval, isNull);
      expect(writes, isEmpty);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(queue.count, 1);
      expect(queue.canUndo('manual'), isTrue);
      expect(writes, isEmpty);
      expect(drafts.items, hasLength(1));
      now = now.add(const Duration(seconds: 11));
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(queue.count, 0);
      expect(writes, hasLength(1));
      expect(drafts.items, isEmpty);
      expect(writes.single.deckId, deck.id);
      expect(writes.single.deckSection, DeckSection.sideboard);
      expect(writes.single.card.finish, Finish.foil);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
  for (final Brightness brightness in Brightness.values) {
    testWidgets(
      'retained scan ${brightness.name} AX2.35 keeps capture, error and uploads reachable',
      (WidgetTester tester) async {
        final ScanQueueEntry pending = ScanQueueEntry(
          operationId: 'pending',
          card: cardFromScryfall(_printing(), finish: Finish.foil),
          quantity: 2,
          createdAt: DateTime.utc(2026),
          error: 'Upload unavailable. Retry.',
        );
        final ScanQueue queue = ScanQueue(
          userId: 'fixture',
          storage: _Storage(<ScanQueueEntry>[pending]),
          writer: (ScanQueueEntry _) async {},
        );
        addTearDown(queue.dispose);
        final StreamController<List<MTGDeck>> decks =
            StreamController<List<MTGDeck>>();
        addTearDown(decks.close);
        final _Drafts drafts = _Drafts(<ScanDraftItem>[
          _draft('retained', name: 'Go for the Throat'),
        ])..queue = queue;
        await _show(
          tester,
          ScanScreen(
            userId: 'fixture',
            queue: queue,
            draftStore: drafts,
            resolver: ScanResolver(catalog: _Catalog()),
            decks: decks.stream,
          ),
          brightness,
          scale: 2.35,
        );
        decks.addError(StateError('local fixture deck stream failed'));
        await tester.pumpAndSettle();
        expect(find.text('Continue scanning').hitTestable(), findsOneWidget);
        expect(find.text('Check (1)').hitTestable(), findsOneWidget);
        expect(find.text('Attention').hitTestable(), findsOneWidget);
        expect(find.text('Added 2').hitTestable(), findsOneWidget);
        expect(find.text('Pending 2').hitTestable(), findsOneWidget);
        final SemanticsHandle semantics = tester.ensureSemantics();
        try {
          await tester.pump();
          final Finder addition = find.ancestor(
            of: find.byKey(const ValueKey<String>('scan-added')),
            matching: find.byType(GhostButton),
          );
          expect(
            tester.getSemantics(addition).getSemanticsData().label,
            'Added 2',
          );
          expect(
            find.bySemanticsLabel(
              RegExp(r'^Needs attention: Decks are unavailable'),
            ),
            findsOneWidget,
          );
          expect(
            tester
                .getSemantics(addition)
                .getSemanticsData()
                .hasAction(SemanticsAction.tap),
            isTrue,
          );
        } finally {
          semantics.dispose();
        }
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Attention'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Decks are unavailable').hitTestable(),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('Done'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Done').hitTestable());
        await tester.pumpAndSettle();
        await tester.tap(find.text('Added 2'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Upload unavailable. Retry.').first,
          80,
          scrollable: find.byType(Scrollable).hitTestable().last,
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Upload unavailable. Retry.').hitTestable(),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('Done'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Done').hitTestable());
        await tester.pumpAndSettle();
        final Finder retained = find.text('Go for the Throat');
        await tester.ensureVisible(retained);
        await tester.pumpAndSettle();
        expect(retained.hitTestable(), findsOneWidget);
        expect(find.text('Continue scanning').hitTestable(), findsOneWidget);
        expect(queue.count, 1);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
    testWidgets(
      'Shops ${brightness.name} AX2.35 with keyboard keeps location and both actions reachable',
      (WidgetTester tester) async {
        await _show(
          tester,
          const CollectionShops(),
          brightness,
          scale: 2.35,
          keyboard: 260,
        );
        await tester.showKeyboard(find.byType(TextField));
        await tester.enterText(find.byType(TextField), 'Portland');
        for (final String text in <String>[
          'Find card shops',
          'Wizards Store & Event Locator',
        ]) {
          await tester.ensureVisible(find.text(text));
          await tester.pumpAndSettle();
          expect(find.text(text).hitTestable(), findsOneWidget);
        }
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          'Portland',
        );
        expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .maxScrollExtent,
          greaterThan(0),
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
