import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/collection_prices.dart';
import 'package:the_collector/theme/components/collector_dock.dart';
import 'package:the_collector/pages/collection/collection_shops.dart';
import 'package:the_collector/pages/collection/price_history_plot.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/crud.dart';

import 'helpers/load_collector_fonts.dart';

const String _owner = 'prices-owner';

class _Printing extends Fake implements sf.MtgCard {
  _Printing(this.prices);
  @override
  final sf.Prices prices;
}

class _Catalog extends Fake implements CardCatalog {
  final Completer<Map<String, sf.MtgCard>> pending =
      Completer<Map<String, sf.MtgCard>>();
  bool closed = false;
  @override
  Future<Map<String, sf.MtgCard>> printings(Iterable<String> ids) =>
      pending.future;
  @override
  void close() => closed = true;
}

class _DelayedStore<T> extends Fake implements CollectionStore<T> {
  _DelayedStore(this.backing);

  final CollectionStore<T> backing;
  final StreamController<List<T>> updates =
      StreamController<List<T>>.broadcast();

  @override
  CollectionReference<T> get collection => backing.collection;

  @override
  Stream<List<T>> streamAll() => updates.stream;
}

CollectionStore<MTGCard> _cards(FakeFirebaseFirestore database) =>
    CollectionStore<MTGCard>(
      collection: database.collection('user/$_owner/cards'),
      toMap: (MTGCard card) => card.toMap(),
      fromMap: (String id, Map<String, Object?> data) =>
          MTGCardMapper.fromMap(data)..id = id,
    );

CollectionStore<MTGDeck> _groups(FakeFirebaseFirestore database) =>
    CollectionStore<MTGDeck>(
      collection: database.collection('user/$_owner/decks'),
      toMap: (MTGDeck group) => group.toMap(),
      fromMap: (String id, Map<String, Object?> data) =>
          MTGDeckMapper.fromMap(data)..id = id,
    );

MTGCard _card({
  String printing = 'printing',
  int quantity = 1,
  sf.Finish finish = sf.Finish.nonfoil,
}) => MTGCard(
  name: 'Saved card',
  setId: 'set',
  description: '',
  flavorText: '',
  cmc: 1,
  typeLine: 'Artifact',
  rarity: sf.Rarity.common,
  setType: sf.SetType.expansion,
  manaCost: null,
  scryfallId: printing,
  quantity: quantity,
  finish: finish,
  prices: const CardPrices(usd: 2, usdFoil: 5, eur: 3, eurFoil: 7, tix: 0.5),
  pricesUpdatedAt: DateTime.utc(2026, 10, 1),
);

Future<void> _show(
  WidgetTester tester,
  Widget child, {
  ThemeMode mode = ThemeMode.dark,
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(mode),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 568),
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _visible(WidgetTester tester, Finder target) async {
  final Finder scrollable = find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(target, 120, scrollable: scrollable);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _refresh(WidgetTester tester) async {
  await _visible(tester, find.text('Refresh prices'));
  await tester.tap(find.text('Refresh prices').hitTestable());
  await tester.pump();
}

void main() {
  testWidgets(
    'Value separates cards, containers and history into bounded views',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      await _cards(database).set('owned', _card(quantity: 2));
      for (int index = 0; index < 6; index++) {
        await _groups(database).set(
          'box$index',
          MTGDeck(
            name: 'Box $index',
            kind: CollectionGroupKind.box,
            entries: const <DeckEntry>[
              DeckEntry(scryfallId: 'printing', quantity: 1),
            ],
          ),
        );
      }
      await _show(
        tester,
        CollectionPrices(
          cardsStore: _cards(database),
          groupsStore: _groups(database),
        ),
      );
      expect(find.text('Saved card'), findsOneWidget);
      expect(find.text('Box · Box 0'), findsNothing);
      final List<Rect> tabs = <Rect>[
        for (final String key in <String>[
          'value-view-cards',
          'value-view-containers',
          'collection-value-history-toggle',
        ])
          tester.getRect(find.byKey(ValueKey<String>(key))),
      ];
      for (final Rect tab in tabs) {
        expect(tab.height, greaterThanOrEqualTo(44));
        expect(tab.top, closeTo(tabs.first.top, .01));
        expect(tab.width, closeTo(tabs.first.width, .01));
      }
      expect(tabs.first.left, 12);
      expect(tabs.last.right, 308);
      expect(tabs[1].left - tabs[0].right, closeTo(8, .01));
      await tester.tap(find.text('Containers'));
      await tester.pumpAndSettle();
      expect(find.text('Saved card'), findsNothing);
      expect(find.text('Box · Box 0'), findsOneWidget);
      expect(find.text('Box · Box 4'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('value-next-page')),
      );
      await tester.tap(find.byKey(const ValueKey<String>('value-next-page')));
      await tester.pumpAndSettle();
      expect(find.text('Box · Box 4'), findsOneWidget);
      expect(find.text('Box · Box 0'), findsNothing);
      expect(find.text('4.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'filtered Value excludes other owned cards and collection history',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      await _cards(database).set('chosen', _card(quantity: 3));
      await _cards(database)
          .set('excluded', _card(printing: 'other', quantity: 20));
      await _show(
        tester,
        CollectionPrices(
          cardsStore: _cards(database),
          groupsStore: _groups(database),
          cardIds: const <String>{'chosen'},
        ),
      );
      expect(find.text('6.00'), findsOneWidget);
      expect(find.text('3 priced · 0 missing'), findsOneWidget);
      expect(find.text('History'), findsNothing);
      final Selector<CardCurrency> currency = tester
          .widget<Selector<CardCurrency>>(
            find.byKey(const ValueKey<String>('collection-value-currency')),
          );
      expect(currency.values, <CardCurrency>[
        CardCurrency.usd,
        CardCurrency.eur,
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      await _show(
        tester,
        CollectionPrices(
          cardsStore: _cards(database),
          groupsStore: _groups(database),
          cardIds: const <String>{},
        ),
      );
      expect(find.text('0.00'), findsOneWidget);
      expect(find.text('0 priced · 0 missing'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadCollectorFonts);

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
    for (final double scale in <double>[1, 2.35]) {
      testWidgets(
        'Value is glanceable and disclosure remains reachable under the actual dock $mode scale $scale',
        (WidgetTester tester) async {
          final FakeFirebaseFirestore database = FakeFirebaseFirestore();
          await _cards(database).set('printing', _card());
          await _show(
            tester,
            Scaffold(
              footers: <Widget>[
                CollectorDock(
                  selectedIndex: 0,
                  items: <CollectorDockItem>[
                    for (final String label in <String>[
                      'Cards',
                      'Containers',
                      'Scan',
                      'Tabletop',
                      'More',
                    ])
                      CollectorDockItem(
                        icon: Icons.square,
                        label: label,
                        onPressed: () {},
                      ),
                  ],
                ),
              ],
              child: CollectionPrices(
                cardsStore: _cards(database),
                groupsStore: _groups(database),
              ),
            ),
            mode: mode,
            scale: scale,
          );
          expect(find.text('2.00'), findsOneWidget);
          await _visible(tester, find.text('1 priced · 0 missing'));
          expect(
            find.text('1 priced · 0 missing').hitTestable(),
            findsOneWidget,
          );
          expect(find.text('Printing and finish'), findsNothing);
          expect(
            find.descendant(
              of: find.byType(CollectionPrices),
              matching: find.text('Containers'),
            ),
            findsNothing,
          );
          final Finder list = find.descendant(
            of: find.byType(CollectionPrices),
            matching: find.byType(ListView),
          );
          final Finder scroll = find
              .descendant(of: list, matching: find.byType(Scrollable))
              .first;
          if (scale == 1) {
            expect(
              tester.state<ScrollableState>(scroll).position.maxScrollExtent,
              0,
            );
            expect(find.text('Refresh prices').hitTestable(), findsOneWidget);
            expect(find.text('Price details').hitTestable(), findsOneWidget);
            expect(find.text('History').hitTestable(), findsOneWidget);
            expect(
              tester
                  .getSize(
                    find.ancestor(
                      of: find.text('Refresh prices'),
                      matching: find.byType(PrimaryButton),
                    ),
                  )
                  .height,
              greaterThanOrEqualTo(44),
            );
          }
          final Finder details = find.text('Price details');
          await _visible(tester, details);
          final Finder detailsButton = find.ancestor(
            of: details,
            matching: find.byType(TextButton),
          );
          expect(
            tester.getSize(detailsButton).height,
            greaterThanOrEqualTo(44),
          );
          await tester.tap(details.hitTestable());
          await tester.pumpAndSettle();
          final Finder close = find.text('Close').hitTestable();
          expect(close, findsOneWidget);
          final Rect closeBounds = tester.getRect(close);
          expect(closeBounds.bottom, lessThanOrEqualTo(568));
          final Finder disclosureScroll = find
              .descendant(
                of: find.byType(ArcaneDialog),
                matching: find.byType(Scrollable),
              )
              .hitTestable()
              .last;
          final Finder basis = find.descendant(
            of: disclosureScroll,
            matching: find.text('Printing and finish'),
          );
          expect(basis, findsOneWidget);
          await tester.ensureVisible(basis);
          await tester.pumpAndSettle();
          final Rect proseViewport = tester.getRect(disclosureScroll);
          final Rect basisBounds = tester.getRect(basis);
          expect(basisBounds.overlaps(proseViewport), isTrue);
          expect(
            basisBounds.intersect(proseViewport).height,
            greaterThanOrEqualTo(
              basisBounds.height < 20 ? basisBounds.height : 20,
            ),
            reason: 'The pricing basis remains visible inside the facts pane',
          );
          final Finder historyBasis = find.descendant(
            of: disclosureScroll,
            matching: find.text(
              'Daily snapshots after refresh, including cards added or removed.',
            ),
          );
          final ScrollPosition disclosurePosition = tester
              .state<ScrollableState>(disclosureScroll)
              .position;
          disclosurePosition.jumpTo(disclosurePosition.maxScrollExtent);
          await tester.pumpAndSettle();
          expect(historyBasis, findsOneWidget);
          final Rect lastBounds = tester.getRect(historyBasis);
          expect(
            lastBounds.bottom,
            lessThanOrEqualTo(proseViewport.bottom + 1),
          );
          expect(
            lastBounds.intersect(proseViewport).height,
            greaterThanOrEqualTo(20),
          );
          expect(
            tester.getRect(close),
            closeBounds,
            reason: 'Close stays fixed while valuation disclosures scroll',
          );
          await tester.tap(close);
          await tester.pumpAndSettle();
          final Finder history = find.byKey(
            const ValueKey<String>('collection-value-history-toggle'),
          );
          await tester.scrollUntilVisible(history, 100, scrollable: scroll);
          await tester.ensureVisible(history);
          await tester.pumpAndSettle();
          await tester.tap(history);
          await tester.pumpAndSettle();
          expect(
            find.text('Refresh prices to record your first observation.'),
            findsOneWidget,
          );
          expect((await _cards(database).get('printing')).quantity, 1);
          expect(
            (await database.collection('user/$_owner/priceHistory').get()).docs,
            isEmpty,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'loaded history keeps its subscription state when delayed collections arrive',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final _DelayedStore<MTGCard> cards = _DelayedStore<MTGCard>(
        _cards(database),
      );
      final _DelayedStore<MTGDeck> groups = _DelayedStore<MTGDeck>(
        _groups(database),
      );
      await database.collection('user/$_owner/priceHistory').doc('saved').set(
        <String, Object?>{
          'currency': 'usd',
          'observedAt': Timestamp.fromDate(DateTime.utc(2026, 10, 2)),
          'total': 12,
          'pricedCopies': 3,
          'unpricedCopies': 1,
        },
      );
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(ThemeMode.dark),
            home: CollectionPrices(cardsStore: cards, groupsStore: groups),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey<String>('collection-value-history-toggle')),
        );
        await tester.pump();
        expect(find.text('3 priced · 1 unpriced'), findsOneWidget);
        final Finder history = find.byWidgetPredicate(
          (Widget widget) =>
              widget is StreamBuilder<QuerySnapshot<Map<String, dynamic>>>,
        );
        expect(history, findsOneWidget);
        final State<StatefulWidget> historyState = tester
            .state<State<StatefulWidget>>(history);

        cards.updates.add(<MTGCard>[_card()]);
        await tester.pump();
        await tester.pump();
        expect(find.text('1 priced · 0 missing'), findsOneWidget);
        expect(
          tester.state<State<StatefulWidget>>(history),
          same(historyState),
        );
        expect(find.text('3 priced · 1 unpriced'), findsOneWidget);

        groups.updates.add(<MTGDeck>[
          MTGDeck(name: 'Arriving deck', entries: const <DeckEntry>[]),
        ]);
        await tester.pump();
        await tester.pump();
        expect(find.text('Deck · Arriving deck'), findsNothing);
        expect(
          tester.state<State<StatefulWidget>>(history),
          same(historyState),
        );
        expect(find.text('3 priced · 1 unpriced'), findsOneWidget);
        expect(find.text('Loading price history…'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await cards.updates.close();
        await groups.updates.close();
      }
    },
  );

  testWidgets(
    'filtered refresh updates only selected variants without a whole collection observation',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionStore<MTGCard> cards = _cards(database);
      await cards.set('chosen', _card(quantity: 3));
      await cards.set('unselected-foil', _card(finish: sf.Finish.foil));
      final _Catalog catalog = _Catalog();
      await _show(
        tester,
        CollectionPrices(
          cardsStore: cards,
          groupsStore: _groups(database),
          currentUserId: () => _owner,
          catalogFactory: () => catalog,
          cardIds: const <String>{'chosen'},
        ),
      );
      await _refresh(tester);
      catalog.pending.complete(<String, sf.MtgCard>{
        'printing': _Printing(
          const sf.Prices(usd: '3', usdFoil: '7', eur: '2', eurFoil: '5'),
        ),
      });
      await tester.pumpAndSettle();
      expect((await cards.get('chosen')).prices!.usd, 3);
      expect((await cards.get('unselected-foil')).prices!.usdFoil, 5);
      expect(
        (await database.collection('user/$_owner/priceHistory').get()).docs,
        isEmpty,
      );
      expect(
        (await cards.collection
                .doc('chosen')
                .collection('priceObservations')
                .get())
            .docs,
        hasLength(1),
      );
      expect(
        (await cards.collection
                .doc('unselected-foil')
                .collection('priceObservations')
                .get())
            .docs,
        isEmpty,
      );
      expect(find.text('9.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'refresh uses current cards and quantities after catalogue lookup',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionStore<MTGCard> cards = _cards(database);
      await cards.set('printing', _card());
      await cards.set('removed', _card(printing: 'removed', quantity: 8));
      final _Catalog catalog = _Catalog();
      await _show(
        tester,
        CollectionPrices(
          cardsStore: cards,
          groupsStore: _groups(database),
          currentUserId: () => _owner,
          catalogFactory: () => catalog,
        ),
      );
      await _refresh(tester);
      await cards.set('printing', _card(quantity: 5));
      await cards.delete('removed');
      await cards.set(
        'printing__foil',
        _card(quantity: 4, finish: sf.Finish.foil),
      );
      catalog.pending.complete(<String, sf.MtgCard>{
        'printing': _Printing(
          const sf.Prices(
            usd: '3',
            usdFoil: '7',
            eur: '2',
            eurFoil: '5',
            tix: '0.25',
          ),
        ),
      });
      await tester.pumpAndSettle();
      expect((await cards.get('printing')).quantity, 5);
      expect((await cards.get('printing')).prices!.usd, 3);
      expect((await cards.get('printing__foil')).quantity, 4);
      expect((await cards.get('printing__foil')).prices!.usdFoil, 7);
      expect(await cards.exists('removed'), isFalse);
      final QuerySnapshot<Map<String, dynamic>> history = await database
          .collection('user/$_owner/priceHistory')
          .get();
      expect(history.docs, hasLength(2));
      final Map<String, Map<String, dynamic>> observations =
          <String, Map<String, dynamic>>{
            for (final QueryDocumentSnapshot<Map<String, dynamic>> record
                in history.docs)
              record.data()['currency'] as String: record.data(),
          };
      expect(observations['usd']!['total'], 43);
      expect(observations['eur']!['total'], 30);
      expect(observations.containsKey('tix'), isFalse);
      expect(observations['usd']!['pricedCopies'], 9);
      expect(observations['usd']!['unpricedCopies'], 0);
      expect(catalog.closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account change during catalogue lookup prevents quote and history writes',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionStore<MTGCard> cards = _cards(database);
      await cards.set('printing', _card(quantity: 2));
      final _Catalog catalog = _Catalog();
      String? currentUser = _owner;
      await _show(
        tester,
        CollectionPrices(
          cardsStore: cards,
          groupsStore: _groups(database),
          currentUserId: () => currentUser,
          catalogFactory: () => catalog,
        ),
      );
      await _refresh(tester);
      currentUser = 'other-owner';
      catalog.pending.complete(<String, sf.MtgCard>{
        'printing': _Printing(const sf.Prices(usd: '99')),
      });
      await tester.pumpAndSettle();
      expect((await cards.get('printing')).prices!.usd, 2);
      expect(
        (await database.collection('user/$_owner/priceHistory').get()).docs,
        isEmpty,
      );
      expect(
        (await database
                .collection('user/$_owner/cards/printing/priceObservations')
                .get())
            .docs,
        isEmpty,
      );
      expect(catalog.closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
    testWidgets(
      'empty Prices ${mode.name} at large text disables empty refresh',
      (WidgetTester tester) async {
        final FakeFirebaseFirestore database = FakeFirebaseFirestore();
        await _show(
          tester,
          CollectionPrices(
            cardsStore: _cards(database),
            groupsStore: _groups(database),
          ),
          mode: mode,
          scale: 2,
        );
        expect(
          find.text('Add cards to see collection and container estimates.'),
          findsOneWidget,
        );
        await _visible(tester, find.text('Refresh prices'));
        final PrimaryButton button = tester.widget<PrimaryButton>(
          find.ancestor(
            of: find.text('Refresh prices'),
            matching: find.byType(PrimaryButton),
          ),
        );
        expect(button.onPressed, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'container labels and valid observations remain readable beside corrupt history',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      await _cards(database).set('printing', _card());
      await _groups(database).set(
        'binder',
        MTGDeck(
          name: 'Trades',
          kind: CollectionGroupKind.binder,
          entries: const <DeckEntry>[
            DeckEntry(scryfallId: 'printing', finish: sf.Finish.nonfoil),
          ],
        ),
      );
      final CollectionReference<Map<String, dynamic>> history = database
          .collection('user/$_owner/priceHistory');
      await history.doc('valid').set(<String, Object?>{
        'currency': 'usd',
        'observedAt': Timestamp.fromDate(DateTime.utc(2026, 10, 2)),
        'total': 12,
        'pricedCopies': 3,
        'unpricedCopies': 1,
      });
      for (final (String, Object) invalid in <(String, Object)>[
        ('text', 'bad'),
        ('nan', double.nan),
        ('infinity', double.infinity),
        ('negative', -1),
      ]) {
        await history.doc(invalid.$1).set(<String, Object?>{
          'currency': 'usd',
          'observedAt': Timestamp.fromDate(DateTime.utc(2026, 10, 3)),
          'total': invalid.$2,
          'pricedCopies': 3,
          'unpricedCopies': 1,
        });
      }
      await _show(
        tester,
        CollectionPrices(
          cardsStore: _cards(database),
          groupsStore: _groups(database),
        ),
      );
      await _visible(tester, find.text('Containers'));
      expect(find.text('Containers'), findsOneWidget);
      await tester.tap(find.text('Containers'));
      await tester.pumpAndSettle();
      await _visible(tester, find.text('Binder · Trades'));
      expect(find.text('Binder · Trades'), findsOneWidget);
      await _visible(
        tester,
        find.byKey(const ValueKey<String>('collection-value-history-toggle')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('collection-value-history-toggle')),
      );
      await tester.pumpAndSettle();
      await _visible(
        tester,
        find.text('Some saved observations could not be read.'),
      );
      await _visible(tester, find.text('USD 12.00'));
      expect(find.text('3 priced · 1 unpriced'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('filled shop location retains its accessible name', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await _show(tester, const CollectionShops());
      await tester.enterText(find.byType(EditableText), 'Portland');
      await tester.pumpAndSettle();
      final SemanticsNode field = tester.getSemantics(
        find.bySemanticsLabel('City or postal code').first,
      );
      expect(field.label, 'City or postal code');
      expect(field.value, 'Portland');
      expect(field.getSemanticsData().flagsCollection.isTextField, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'history plots only recorded observations and ranks the owned finish and quantity',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      await _cards(database)
          .set('normal', _card(quantity: 2).copyWith(name: 'Normal copies'));
      await _cards(
        database,
      ).set('foil', _card(finish: sf.Finish.foil).copyWith(name: 'Foil copy'));
      final CollectionReference<Map<String, dynamic>> history = database
          .collection('user/$_owner/priceHistory');
      for (final (String, double) point in <(String, double)>[
        ('2026-10-01', 4),
        ('2026-10-03', 9),
      ]) {
        await history.doc(point.$1).set(<String, Object?>{
          'currency': 'usd',
          'observedAt': Timestamp.fromDate(DateTime.parse(point.$1)),
          'total': point.$2,
          'pricedCopies': 3,
          'unpricedCopies': 0,
        });
      }
      await _show(
        tester,
        CollectionPrices(
          cardsStore: _cards(database),
          groupsStore: _groups(database),
        ),
      );
      await _visible(tester, find.text('Normal copies'));
      expect(
        tester.getTopLeft(find.text('Foil copy')).dy,
        lessThan(tester.getTopLeft(find.text('Normal copies')).dy),
      );
      expect(find.text('USD 5.00'), findsOneWidget);
      expect(find.text('USD 4.00'), findsOneWidget);
      final Finder toggle = find.byKey(
        const ValueKey<String>('collection-value-history-toggle'),
      );
      await _visible(tester, toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await _visible(tester, find.byType(PriceHistoryPlot));
      final PriceHistoryPlot plot = tester.widget<PriceHistoryPlot>(
        find.byType(PriceHistoryPlot),
      );
      expect(
        plot.points.map((PriceHistoryPoint point) => point.total),
        <double>[9, 4],
      );
      expect(find.text('Includes cards added or removed.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
