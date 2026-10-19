import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arcane/arcane.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, TextInputAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/card/card.dart';
import 'package:the_collector/pages/collection/card/card_add_dialog.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/crud.dart';

import 'helpers/load_collector_fonts.dart';

sf.MtgCard _printing(
  String id,
  String number, {
  List<String> finishes = const <String>['nonfoil', 'foil'],
  String language = 'en',
  String name = 'Dusk // Dawn',
}) {
  final Map<String, Object?> json = jsonDecode(
    File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
  ) as Map<String, Object?>;
  json.addAll(<String, Object?>{
    'id': id,
    'name': name,
    'lang': language,
    'collector_number': number,
    'image_uris': null,
    'card_faces': null,
    'finishes': finishes,
  });
  return sf.MtgCard.fromJson(json);
}

class _Catalog extends CardCatalog {
  final List<sf.MtgCard> cards = <sf.MtgCard>[
    _printing('11111111-1111-1111-1111-111111111111', '1'),
    _printing('22222222-2222-2222-2222-222222222222', '2'),
  ];
  final List<String> queries = <String>[];

  @override
  Future<Map<String, sf.MtgCard>> printings(Iterable<String> ids) async =>
      <String, sf.MtgCard>{
        for (final sf.MtgCard card in cards)
          if (ids.contains(card.id)) card.id: card,
      };

  @override
  Future<sf.PaginableList<sf.MtgCard>> search(
    String query, {
    int page = 1,
    bool allPrintings = false,
  }) async {
    queries.add(query);
    return sf.PaginableList<sf.MtgCard>(data: cards, hasMore: false);
  }
}

class _DeferredCatalog extends CardCatalog {
  final List<(String, Completer<sf.PaginableList<sf.MtgCard>>)> requests =
      <(String, Completer<sf.PaginableList<sf.MtgCard>>)>[];

  @override
  Future<sf.PaginableList<sf.MtgCard>> search(
    String query, {
    int page = 1,
    bool allPrintings = false,
  }) {
    final Completer<sf.PaginableList<sf.MtgCard>> pending =
        Completer<sf.PaginableList<sf.MtgCard>>();
    requests.add((query, pending));
    return pending.future;
  }
}

class _PagedCatalog extends CardCatalog {
  final List<int> pages = <int>[];
  final List<String> queries = <String>[];
  bool failNext = true;

  @override
  Future<sf.PaginableList<sf.MtgCard>> search(
    String query, {
    int page = 1,
    bool allPrintings = false,
  }) async {
    pages.add(page);
    queries.add(query);
    if (page == 2 && failNext) {
      failNext = false;
      throw StateError('Offline');
    }
    return sf.PaginableList<sf.MtgCard>(
      data: <sf.MtgCard>[
        _printing(
          page == 1
              ? '11111111-1111-1111-1111-111111111111'
              : '22222222-2222-2222-2222-222222222222',
          '$page',
        ),
      ],
      hasMore: page == 1,
    );
  }
}

class _OwnedStore extends CollectionStore<MTGCard> {
  _OwnedStore(FakeFirebaseFirestore database)
    : super(
        collection: database.collection('user/test/cards'),
        toMap: (MTGCard card) => card.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGCardMapper.fromMap(data)..id = id,
      );

  bool failNextQuantity = false;

  @override
  Future<void> txn(String id, MTGCard Function(MTGCard) update) async {
    if (failNextQuantity) {
      failNextQuantity = false;
      throw StateError('Offline quantity update');
    }
    await super.txn(id, update);
  }
}

class _Fixture {
  final FakeFirebaseFirestore database = FakeFirebaseFirestore();
  final _Catalog catalog = _Catalog();
  late final _OwnedStore cards = _OwnedStore(database);
  late final CollectionStore<MTGDeck> groups = CollectionStore<MTGDeck>(
    collection: database.collection('user/test/decks'),
    toMap: (MTGDeck group) => group.toMap(),
    fromMap: (String id, Map<String, Object?> data) =>
        MTGDeckMapper.fromMap(data)..id = id,
  );

  Future<MTGCard> seed({bool owned = true}) async {
    final MTGCard card = cardFromScryfall(
      catalog.cards.first,
      finish: sf.Finish.nonfoil,
    );
    if (owned) {
      card.id = card.printingId;
      await cards.set(card.id!, card);
    }
    await groups.set(
      'binder',
      MTGDeck(name: 'Trades', kind: CollectionGroupKind.binder),
    );
    return card;
  }
}

Future<void> _show(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  ThemeMode theme = ThemeMode.dark,
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(theme),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final Finder scrollable = find
        .descendant(
          of: find.byType(ListView).last,
          matching: find.byType(Scrollable),
        )
        .first;
    final ScrollableState scroll = tester.state<ScrollableState>(scrollable);
    scroll.position.jumpTo(scroll.position.minScrollExtent);
    await tester.pump();
    await tester.scrollUntilVisible(finder, 100, scrollable: scrollable);
  }
  if (finder.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(finder.first);
    await tester.pumpAndSettle();
  }
  await tester.tap(finder.hitTestable().first);
  await tester.pumpAndSettle();
}

Finder _ownedQuantity() => find.byWidgetPredicate(
  (Widget widget) =>
      widget is Semantics && widget.properties.label == 'Edit owned quantity',
);

void main() {
  setUpAll(loadCollectorFonts);

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
    testWidgets(
      'phone dossier covers parent search and safe-area in ${mode.name} while keeping close and swipe',
      (WidgetTester tester) async {
        final _Fixture fixture = _Fixture();
        addTearDown(fixture.catalog.close);
        final MTGCard card = await fixture.seed();
        tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
        addTearDown(tester.view.resetPadding);
        await _show(
          tester,
          Builder(
            builder: (BuildContext context) => Scaffold(
              child: SafeArea(
                child: Column(
                  children: <Widget>[
                    const TextField(placeholder: Text('Search owned cards')),
                    PrimaryButton(
                      onPressed: () => openCardDetails(
                        context,
                        card: card,
                        store: fixture.cards,
                        groups: fixture.groups,
                        catalog: fixture.catalog,
                      ),
                      child: const Text('Open dossier'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          theme: mode,
        );
        await _tapVisible(tester, find.text('Open dossier'));
        final Rect sheet = tester.getRect(find.byType(CardFlyoutScreen));
        expect(sheet.top, lessThanOrEqualTo(54));
        final Color surface = Theme.of(
          tester.element(find.byType(CardFlyoutScreen)),
        ).colorScheme.background;
        final Finder opaqueBacking = find.byWidgetPredicate(
          (Widget widget) => widget is ModalBarrier && widget.color == surface,
        );
        expect(opaqueBacking, findsOneWidget);
        final Rect backing = tester.getRect(opaqueBacking);
        expect(backing.top, 0);
        expect(backing.bottom, greaterThanOrEqualTo(sheet.top));
        expect(backing.width, 390);
        final Finder close = find.byKey(
          const ValueKey<String>('card-detail-close'),
        );
        expect(close.hitTestable(), findsOneWidget);
        expect(tester.getRect(close).top, greaterThanOrEqualTo(44));
        expect(tester.getSize(close), const Size(44, 44));
        await _tapVisible(tester, close);
        expect(find.byType(CardFlyoutScreen), findsNothing);
        await _tapVisible(tester, find.text('Open dossier'));
        await tester.fling(
          find.byKey(const ValueKey<String>('card-detail-name')),
          const Offset(0, 650),
          1800,
        );
        await tester.pumpAndSettle();
        expect(find.byType(CardFlyoutScreen), findsNothing);
        expect((await fixture.cards.get(card.id!)).quantity, 1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  for (final (Size, TargetPlatform, ThemeMode, double) config
      in <(Size, TargetPlatform, ThemeMode, double)>[
        (const Size(834, 1194), TargetPlatform.iOS, ThemeMode.light, 1),
        (const Size(834, 1194), TargetPlatform.iOS, ThemeMode.dark, 2),
        (const Size(1280, 800), TargetPlatform.macOS, ThemeMode.dark, 1),
        (const Size(1280, 800), TargetPlatform.macOS, ThemeMode.light, 2.35),
      ]) {
    testWidgets(
      'regular dossier and missing-art printings ${config.$2.name} ${config.$3.name} ${config.$4}x',
      (WidgetTester tester) async {
        final _Fixture fixture = _Fixture();
        addTearDown(fixture.catalog.close);
        fixture.catalog.cards[0] = _printing(
          fixture.catalog.cards.first.id,
          '123b',
          language: 'ja',
          name: 'The Underworld Cookbook of the Academy of Unusual Inventions',
        );
        final MTGCard card = await fixture.seed();
        await _show(
          tester,
          Builder(
            builder: (BuildContext context) => PrimaryButton(
              onPressed: () => openCardDetails(
                context,
                card: card,
                store: fixture.cards,
                groups: fixture.groups,
                catalog: fixture.catalog,
              ),
              child: const Text('Open dossier'),
            ),
          ),
          size: config.$1,
          theme: config.$3,
          scale: config.$4,
        );
        await _tapVisible(tester, find.text('Open dossier'));
        expect(
          tester.getSize(find.byType(CardFlyoutScreen)).height,
          closeTo(config.$1.height * .88, 1),
        );
        expect(
          find.byWidgetPredicate(
            (Widget widget) => widget is ModalBarrier && widget.color?.a == 1,
          ),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('card-detail-name')).hitTestable(),
          findsOneWidget,
        );
        expect(find.text('JA · Normal'), findsOneWidget);
        expect(find.text('Artwork unavailable'), findsOneWidget);
        await _tapVisible(tester, find.text('Printings'));
        expect(find.byType(CardPrintingSelector), findsOneWidget);
        final Finder edition = find.byKey(
          ValueKey<String>('printing-choice-${card.printingId}'),
        );
        await _tapVisible(tester, edition);
        expect(
          find.byKey(const ValueKey<String>('printing-metadata')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey<String>('printing-metadata')),
              )
              .data,
          contains('#123b · JA'),
        );
        expect(
          find.byKey(const ValueKey<String>('printing-copies')),
          findsNothing,
        );
        await _tapVisible(
          tester,
          find.byKey(const ValueKey<String>('printing-cancel')),
        );
        await _tapVisible(
          tester,
          find.byKey(const ValueKey<String>('card-detail-close')),
        );
        expect(find.byType(CardFlyoutScreen), findsNothing);
        expect((await fixture.cards.get(card.id!)).language, 'ja');
        expect((await fixture.cards.get(card.id!)).quantity, 1);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(config.$2),
    );
  }

  testWidgets(
    'absolute owned quantity validates, cancels and retries without changing memberships',
    (WidgetTester tester) async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.catalog.close);
      final MTGCard card = await fixture.seed();
      await fixture.groups.set(
        'binder',
        MTGDeck(
          name: 'Trades',
          kind: CollectionGroupKind.binder,
          entries: <DeckEntry>[
            DeckEntry(
              scryfallId: card.printingId!,
              quantity: 2,
              finish: card.finish,
              language: card.language,
            ),
          ],
        ),
      );
      await _show(
        tester,
        Builder(
          builder: (BuildContext context) => PrimaryButton(
            onPressed: () => openCardDetails(
              context,
              card: card,
              store: fixture.cards,
              groups: fixture.groups,
              catalog: fixture.catalog,
            ),
            child: const Text('Open dossier'),
          ),
        ),
        size: const Size(1280, 800),
      );
      await _tapVisible(tester, find.text('Open dossier'));
      await _tapVisible(tester, _ownedQuantity());
      final Finder quantity = find.byKey(
        const ValueKey<String>('owned-quantity'),
      );
      for (final String invalid in <String>['-1', '1.5', '1000001']) {
        await tester.enterText(quantity, invalid);
        await _tapVisible(tester, find.text('Save quantity'));
        expect(find.text('Enter 0 to 1000000 copies'), findsWidgets);
        expect((await fixture.cards.get(card.id!)).quantity, 1);
      }
      await tester.enterText(quantity, '123');
      await _tapVisible(tester, find.text('Done'));
      expect((await fixture.cards.get(card.id!)).quantity, 1);
      await _tapVisible(tester, _ownedQuantity());
      expect(tester.widget<TextField>(quantity).controller!.text, '1');
      await tester.enterText(quantity, '3200');
      fixture.cards.failNextQuantity = true;
      await _tapVisible(tester, find.text('Save quantity'));
      expect(find.text('Could not update quantity. Retry.'), findsWidgets);
      expect((await fixture.cards.get(card.id!)).quantity, 1);
      await _tapVisible(tester, find.text('Save quantity'));
      expect((await fixture.cards.get(card.id!)).quantity, 3200);
      expect(
        (await fixture.groups.get('binder')).effectiveEntries.single.quantity,
        2,
      );
      await _tapVisible(tester, _ownedQuantity());
      await tester.enterText(quantity, '0');
      await _tapVisible(tester, find.text('Save quantity'));
      await _tapVisible(tester, find.text('Cancel'));
      expect((await fixture.cards.get(card.id!)).quantity, 3200);
      await _tapVisible(tester, find.text('Save quantity'));
      await _tapVisible(tester, find.text('Delete'));
      expect(await fixture.cards.exists(card.id!), isFalse);
      expect(
        (await fixture.groups.get('binder')).effectiveEntries.single.quantity,
        2,
      );
      expect(find.byType(CardFlyoutScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'catalog dossier add copies returns to an owned record and selected container',
    (WidgetTester tester) async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.catalog.close);
      final MTGCard card = await fixture.seed(owned: false);
      await _show(
        tester,
        CardFlyoutScreen(
          card: card,
          store: fixture.cards,
          groups: fixture.groups,
          catalog: fixture.catalog,
        ),
      );
      await _tapVisible(tester, find.text('Add copies'));
      expect(find.byType(CardPrintingSelector), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey<String>('printing-copies')),
        '4',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('printing-destination')),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await _tapVisible(tester, find.text('Binder: Trades'));
      await _tapVisible(
        tester,
        find.byKey(const ValueKey<String>('printing-confirm')),
      );
      expect(find.byType(CardPrintingSelector), findsNothing);
      final MTGCard owned = await fixture.cards.get(
        CollectionIngestion.inventoryId(card),
      );
      expect(owned.quantity, 4);
      expect(owned.finish, sf.Finish.nonfoil);
      expect(
        (await fixture.groups.get('binder')).effectiveEntries.single.quantity,
        4,
      );
      await tester.pumpAndSettle();
      expect(
        _ownedQuantity(),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((Text text) => text.data)
            .whereType<String>()
            .join(' | '),
      );
      expect(find.text('In Trades'), findsOneWidget);
      await _tapVisible(tester, find.text('More'));
      expect(find.text('Delete Printing').hitTestable(), findsOneWidget);
      await _tapVisible(tester, find.text('Done'));
      await _tapVisible(tester, _ownedQuantity());
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('owned-quantity')),
            )
            .controller!
            .text,
        '4',
      );
      await _tapVisible(tester, find.text('Done'));
      expect((await fixture.cards.get(owned.id!)).quantity, 4);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'printing-only selection preserves caller quantity and destination',
    (WidgetTester tester) async {
      final _Catalog catalog = _Catalog();
      addTearDown(catalog.close);
      PrintingSelection? selected;
      await _show(
        tester,
        CardPrintingSelector(
          printingOnly: true,
          catalog: catalog,
          initialPrintings: catalog.cards,
          initialPrinting: catalog.cards.first,
          initialQuantity: 3200,
          initialDestinationId: 'source-owned-destination',
          initialDeckSection: DeckSection.sideboard,
          onCancel: () {},
          onSelected: (PrintingSelection value) => selected = value,
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('printing-copies')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('printing-destination')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('printing-deck-section')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(
          ValueKey<String>('printing-choice-${catalog.cards.last.id}'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      expect(selected?.card.printingId, catalog.cards.last.id);
      expect(selected?.quantity, 3200);
      expect(selected?.destinationId, 'source-owned-destination');
      expect(selected?.deckSection, DeckSection.sideboard);
    },
  );

  testWidgets(
    'candidate selection preserves destination without adding inventory',
    (WidgetTester tester) async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.catalog.close);
      await fixture.seed(owned: false);
      PrintingSelection? selected;
      await _show(
        tester,
        CardPrintingSelector(
          catalog: fixture.catalog,
          initialPrintings: fixture.catalog.cards,
          initialPrinting: fixture.catalog.cards.first,
          initialDestinationId: 'binder',
          initialQuantity: 7,
          groups: fixture.groups.streamAll(),
          onCancel: () {},
          onSelected: (PrintingSelection value) => selected = value,
        ),
      );
      expect(
        find.byKey(
          ValueKey<String>('printing-choice-${fixture.catalog.cards.last.id}'),
        ),
        findsOneWidget,
      );
      expect(find.text('Binder: Trades'), findsOneWidget);
      await tester.tap(
        find.byKey(
          ValueKey<String>('printing-choice-${fixture.catalog.cards.last.id}'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      expect(selected?.card.printingId, fixture.catalog.cards.last.id);
      expect(selected?.quantity, 7);
      expect(selected?.destinationId, 'binder');
      expect((await fixture.cards.collection.get()).docs, isEmpty);
      expect((await fixture.groups.get('binder')).effectiveEntries, isEmpty);
      expect(fixture.catalog.queries, isEmpty);
    },
  );

  testWidgets(
    'selection preserves a deck section and artwork evidence does not change the printing',
    (WidgetTester tester) async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.catalog.close);
      await fixture.groups.set(
        'deck',
        MTGDeck(name: 'League', kind: CollectionGroupKind.deck),
      );
      PrintingSelection? selected;
      sf.MtgCard? evidence;
      await _show(
        tester,
        CardPrintingSelector(
          catalog: fixture.catalog,
          initialPrintings: fixture.catalog.cards,
          initialPrinting: fixture.catalog.cards.first,
          initialDestinationId: 'deck',
          initialDeckSection: DeckSection.sideboard,
          groups: fixture.groups.streamAll(),
          onPrintingArtworkTap: (sf.MtgCard card) => evidence = card,
          onCancel: () {},
          onSelected: (PrintingSelection value) => selected = value,
        ),
      );
      expect(find.text('Sideboard'), findsOneWidget);
      await tester.tap(
        find.byKey(
          ValueKey<String>('printing-artwork-${fixture.catalog.cards.last.id}'),
        ),
      );
      await tester.pumpAndSettle();
      expect(evidence?.id, fixture.catalog.cards.last.id);
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      expect(selected?.card.printingId, fixture.catalog.cards.first.id);
      expect(selected?.deckSection, DeckSection.sideboard);
      expect((await fixture.groups.get('deck')).effectiveEntries, isEmpty);
    },
  );

  testWidgets('catalog dossier has no owned mutation controls', (
    WidgetTester tester,
  ) async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.catalog.close);
    final MTGCard card = await fixture.seed(owned: false);
    await _show(
      tester,
      CardFlyoutScreen(
        card: card,
        store: fixture.cards,
        groups: fixture.groups,
        catalog: fixture.catalog,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('0 owned'), findsOneWidget);
    expect(find.text('Add copies').hitTestable(), findsOneWidget);
    expect(find.bySemanticsLabel('Remove one copy'), findsNothing);
    expect(find.text('Delete Printing'), findsNothing);
    expect((await fixture.cards.collection.get()).docs, isEmpty);
  });

  testWidgets('dossier organization replaces its body without another modal', (
    WidgetTester tester,
  ) async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.catalog.close);
    final MTGCard card = await fixture.seed();
    await _show(
      tester,
      CardFlyoutScreen(
        card: card,
        store: fixture.cards,
        groups: fixture.groups,
        catalog: fixture.catalog,
      ),
    );
    expect(find.text('Delete Printing'), findsNothing);
    expect(find.text('Card').hitTestable(), findsOneWidget);
    expect(find.text('Value').hitTestable(), findsOneWidget);
    expect(find.text('Locations').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Organize'));
    await tester.pumpAndSettle();
    expect(find.byType(ArcaneDialog), findsNothing);
    expect(find.text('Trades').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Trades'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('group-copies')),
      '2',
    );
    await tester.tap(find.byKey(const ValueKey<String>('organization-save')));
    await tester.pumpAndSettle();
    expect(find.text('Card').hitTestable(), findsOneWidget);
    expect(
      (await fixture.groups.get('binder')).effectiveEntries.single.quantity,
      2,
    );
    expect((await fixture.cards.get(card.id!)).quantity, 1);
  });

  testWidgets(
    'dossier printing browser cancels in place without changing inventory',
    (WidgetTester tester) async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.catalog.close);
      final MTGCard card = await fixture.seed();
      await _show(
        tester,
        CardFlyoutScreen(
          card: card,
          store: fixture.cards,
          groups: fixture.groups,
          catalog: fixture.catalog,
        ),
      );
      await tester.tap(find.text('Printings'));
      await tester.pumpAndSettle();
      expect(find.byType(ArcaneDialog), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('printing-copies')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('printing-destination')),
        findsNothing,
      );
      expect(
        find.byKey(
          ValueKey<String>('printing-choice-${fixture.catalog.cards.last.id}'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('printing-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('Card').hitTestable(), findsOneWidget);
      expect((await fixture.cards.collection.get()).docs.length, 1);
    },
  );

  testWidgets('dossier Escape closes after returning from a printing editor', (
    WidgetTester tester,
  ) async {
    final _Fixture fixture = _Fixture();
    addTearDown(fixture.catalog.close);
    final MTGCard card = await fixture.seed();
    await _show(
      tester,
      Builder(
        builder: (BuildContext context) => PrimaryButton(
          onPressed: () => openCardDetails(
            context,
            card: card,
            store: fixture.cards,
            groups: fixture.groups,
            catalog: fixture.catalog,
          ),
          child: const Text('Open dossier'),
        ),
      ),
    );
    await tester.tap(find.text('Open dossier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Printings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('printing-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Locations'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(CardFlyoutScreen), findsNothing);
    expect(find.text('Open dossier').hitTestable(), findsOneWidget);
  });

  for (final double scale in <double>[1, 2.35]) {
    testWidgets('owned quantity stays on one line at ${scale}x', (
      WidgetTester tester,
    ) async {
      final _Fixture fixture = _Fixture();
      addTearDown(fixture.catalog.close);
      final MTGCard card = (await fixture.seed()).copyWith(quantity: 3200);
      card.id = card.printingId;
      await fixture.cards.set(card.id!, card);
      await _show(
        tester,
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: CardFlyoutScreen(
            card: card,
            store: fixture.cards,
            groups: fixture.groups,
            catalog: fixture.catalog,
          ),
        ),
      );
      final Finder count = find.descendant(
        of: find.byWidgetPredicate(
          (Widget widget) =>
              widget is Semantics &&
              widget.properties.label == 'Edit owned quantity',
        ),
        matching: find.text('3200'),
      );
      final Rect countBounds = tester.getRect(count);
      final TextStyle style = DefaultTextStyle.of(tester.element(count)).style
          .merge(tester.widget<Text>(count).style);
      final TextPainter expected = TextPainter(
        text: TextSpan(text: '3200', style: style),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.linear(scale),
      )..layout();
      expect(countBounds.width, greaterThanOrEqualTo(expected.width));
      expect(countBounds.height, lessThanOrEqualTo(expected.height + 1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('printing choices remain visible after selecting an edition', (
    WidgetTester tester,
  ) async {
    final _Catalog catalog = _Catalog();
    addTearDown(catalog.close);
    await _show(
      tester,
      Builder(
        builder: (BuildContext context) => PrimaryButton(
          onPressed: () => CardPrintingDialog(
            addToCollection: false,
            catalog: catalog,
          ).open(context),
          child: const Text('Open'),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'name:dusk lang:en');
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('printing-choice-${catalog.cards.first.id}')),
    );
    await tester.pumpAndSettle();
    expect(
      find
          .byKey(ValueKey<String>('printing-choice-${catalog.cards.last.id}'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('printing-next')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('printing-previous')),
      findsNothing,
    );
    expect(catalog.queries.single, 'name:dusk lang:en');
    expect(
      find.byKey(const ValueKey<String>('printing-copies')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('printing-finish')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a newer printing search is not overwritten by an earlier response',
    (WidgetTester tester) async {
      final _DeferredCatalog catalog = _DeferredCatalog();
      addTearDown(catalog.close);
      await _show(
        tester,
        Builder(
          builder: (BuildContext context) => PrimaryButton(
            onPressed: () => CardPrintingDialog(
              addToCollection: false,
              catalog: catalog,
            ).open(context),
            child: const Text('Open'),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'first');
      await tester.tap(find.text('Search'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'second');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(catalog.requests.length, 2);
      catalog.requests.last.$2.complete(
        sf.PaginableList<sf.MtgCard>(
          data: <sf.MtgCard>[
            _printing('22222222-2222-2222-2222-222222222222', '2'),
          ],
          hasMore: false,
        ),
      );
      await tester.pumpAndSettle();
      catalog.requests.first.$2.complete(
        sf.PaginableList<sf.MtgCard>(
          data: <sf.MtgCard>[
            _printing('11111111-1111-1111-1111-111111111111', '1'),
          ],
          hasMore: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>(
            'printing-choice-22222222-2222-2222-2222-222222222222',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'printing-choice-11111111-1111-1111-1111-111111111111',
          ),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'printing pagination retries its failed page and keeps selection',
    (WidgetTester tester) async {
      final _PagedCatalog catalog = _PagedCatalog();
      addTearDown(catalog.close);
      PrintingSelection? selected;
      await _show(
        tester,
        CardPrintingSelector(
          catalog: catalog,
          initialQuery: 'name:dusk or name:dawn',
          onSelected: (PrintingSelection result) => selected = result,
          onCancel: () {},
        ),
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'printing-choice-11111111-1111-1111-1111-111111111111',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('printing-copies')),
        '4',
      );
      await tester.tap(find.text('More Printings'));
      await tester.pumpAndSettle();
      expect(find.text('Search unavailable'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(catalog.pages, <int>[1, 2, 2]);
      expect(
        find.byKey(
          const ValueKey<String>(
            'printing-choice-22222222-2222-2222-2222-222222222222',
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      expect(selected?.card.printingId, '11111111-1111-1111-1111-111111111111');
      expect(selected?.quantity, 4);
      expect(selected?.card.finish, sf.Finish.nonfoil);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('set and collector filters retain the advanced identity query', (
    WidgetTester tester,
  ) async {
    final _Catalog catalog = _Catalog();
    addTearDown(catalog.close);
    await _show(
      tester,
      CardPrintingSelector(
        catalog: catalog,
        initialQuery: 'name:dusk or name:dawn',
        onSelected: (PrintingSelection result) {},
        onCancel: () {},
      ),
    );
    await tester.tap(find.text('Filter'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('printing-set-filter')),
      'ice',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('printing-number-filter')),
      '67',
    );
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(catalog.queries.last, '(name:dusk or name:dawn) set:"ice" cn:"67"');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unsupported Normal waits for an explicit foil or etched finish',
    (WidgetTester tester) async {
      final _Catalog catalog = _Catalog();
      addTearDown(catalog.close);
      PrintingSelection? selected;
      await _show(
        tester,
        CardPrintingSelector(
          catalog: catalog,
          initialPrinting: _printing(
            '11111111-1111-1111-1111-111111111111',
            '1',
            finishes: <String>['foil', 'etched'],
          ),
          onSelected: (PrintingSelection result) => selected = result,
          onCancel: () {},
        ),
      );
      expect(find.text('Choose a finish'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.tap(find.byKey(const ValueKey<String>('printing-finish')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('Etched').hitTestable().last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      expect(selected?.card.finish, sf.Finish.etched);
      expect(tester.takeException(), isNull);
    },
  );
}
