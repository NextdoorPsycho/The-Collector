import 'package:arcane/arcane.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/card/card_markets_panel.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/crud.dart';

import 'helpers/load_collector_fonts.dart';

class _Printing extends Fake implements sf.MtgCard {
  _Printing(this.purchaseUris);
  @override
  final Map<String, Uri>? purchaseUris;
}

MTGCard _card({
  String id = 'printing',
  sf.Finish? finish = sf.Finish.nonfoil,
  int quantity = 2,
  CardPrices? prices = const CardPrices(
    usd: 2,
    usdFoil: 5,
    usdEtched: 8,
    eur: 3,
    eurFoil: 7,
    tix: .5,
  ),
}) => MTGCard(
  name: 'Saved card',
  setId: 'set',
  description: '',
  flavorText: '',
  cmc: 2,
  typeLine: 'Creature',
  rarity: sf.Rarity.common,
  setType: sf.SetType.expansion,
  manaCost: '{1}{U}',
  scryfallId: id,
  oracleId: 'oracle',
  quantity: quantity,
  finish: finish,
  prices: prices,
  pricesUpdatedAt: DateTime.utc(2026, 10, 1),
)..id = id;

Future<void> _show(
  WidgetTester tester,
  CardMarketsPanel panel, {
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
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: panel,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadCollectorFonts);

  testWidgets('cash totals respect every owned finish and unknown quotes', (
    WidgetTester tester,
  ) async {
    final MTGCard card = _card();
    await _show(
      tester,
      CardMarketsPanel(
        card: card,
        holdings: <MTGCard>[
          card,
          _card(id: 'foil', finish: sf.Finish.foil, quantity: 3),
          _card(id: 'etched', finish: sf.Finish.etched, quantity: 1),
        ],
        onRefresh: () {},
      ),
    );
    final Finder usd = find.byKey(const ValueKey<String>('card-market-usd'));
    final Finder eur = find.byKey(const ValueKey<String>('card-market-eur'));
    expect(
      find.descendant(of: usd, matching: find.text('USD 2.00')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: usd, matching: find.text('USD 27.00')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: eur, matching: find.text('EUR 27.00')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: eur, matching: find.text('5 priced · 1 unpriced')),
      findsOneWidget,
    );
    final Finder digital = find.byKey(
      const ValueKey<String>('card-market-tix'),
    );
    expect(
      find.descendant(of: digital, matching: find.text('TIX 0.50')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: digital, matching: find.text('Digital reference')),
      findsOneWidget,
    );
    expect(find.text('TIX 3.00'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unavailable finish does not borrow a normal quote or show zero',
    (WidgetTester tester) async {
      final MTGCard card = _card(finish: sf.Finish.unknown);
      await _show(
        tester,
        CardMarketsPanel(
          card: card,
          holdings: <MTGCard>[card],
          onRefresh: () {},
        ),
      );
      expect(find.text('No quote'), findsNWidgets(2));
      expect(find.text('No total'), findsNWidgets(2));
      expect(find.text('USD 0.00'), findsNothing);
      expect(find.text('EUR 0.00'), findsNothing);
      expect(find.text('USD 2.00'), findsNothing);
      expect(find.text('TIX 0.50'), findsOneWidget);
    },
  );

  testWidgets(
    'zero is a real quote while invalid cached prices stay unavailable',
    (WidgetTester tester) async {
      final MTGCard card = _card(
        prices: const CardPrices(usd: 0, eur: double.nan, tix: double.infinity),
      );
      await _show(
        tester,
        CardMarketsPanel(
          card: card,
          holdings: <MTGCard>[card],
          onRefresh: () {},
        ),
      );
      expect(find.text('USD 0.00'), findsNWidgets(2));
      expect(find.text('No total'), findsOneWidget);
      expect(find.text('No quote'), findsNWidgets(2));
      expect(find.textContaining('NaN'), findsNothing);
      expect(find.textContaining('Infinity'), findsNothing);
    },
  );

  testWidgets('cash holdings cannot double count duplicated inventory rows', (
    WidgetTester tester,
  ) async {
    final MTGCard card = _card();
    await _show(
      tester,
      CardMarketsPanel(
        card: card,
        holdings: <MTGCard>[card, card],
        onRefresh: () {},
      ),
    );
    expect(find.text('USD 4.00'), findsOneWidget);
    expect(find.text('USD 8.00'), findsNothing);
  });

  testWidgets(
    'cached date survives a failed refresh and refresh is disabled in flight',
    (WidgetTester tester) async {
      final MTGCard card = _card();
      int refreshes = 0;
      await _show(
        tester,
        CardMarketsPanel(
          card: card,
          holdings: <MTGCard>[card],
          error: 'Prices unavailable',
          onRefresh: () => refreshes++,
        ),
      );
      expect(find.textContaining('Cached'), findsOneWidget);
      expect(find.text('Prices unavailable'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('card-market-refresh')),
      );
      expect(refreshes, 1);
      await _show(
        tester,
        CardMarketsPanel(
          card: card,
          holdings: <MTGCard>[card],
          refreshing: true,
          fetchedAt: DateTime.utc(2026, 10, 15),
          onRefresh: () => refreshes++,
        ),
      );
      final IconButton refresh = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('card-market-refresh')),
      );
      expect(refresh.onPressed, isNull);
      expect(find.textContaining('Fetched'), findsOneWidget);
      expect(refreshes, 1);
    },
  );

  testWidgets('market links only open actual allowed market web addresses', (
    WidgetTester tester,
  ) async {
    final MTGCard card = _card();
    final List<Uri> opened = <Uri>[];
    final Uri good = Uri.parse('https://www.tcgplayer.com/product/123');
    await _show(
      tester,
      CardMarketsPanel(
        card: card,
        holdings: <MTGCard>[card],
        printing: _Printing(<String, Uri>{
          'tcgplayer': good,
          'cardmarket': Uri.parse('https://cardmarket.com.bad.example/item'),
          'cardhoarder': Uri.parse('javascript:alert(1)'),
        }),
        onRefresh: () {},
        openLink: (Uri uri) async => opened.add(uri),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('card-market-link-tcgplayer')),
    );
    await tester.pumpAndSettle();
    expect(opened, <Uri>[good]);
    expect(
      find.byKey(const ValueKey<String>('card-market-link-cardmarket')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('card-market-link-cardhoarder')),
      findsNothing,
    );
  });

  testWidgets(
    'history displays only saved valid observations for the chosen finish',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionStore<MTGCard> store = CollectionStore<MTGCard>(
        collection: database.collection('user/alice/cards'),
        toMap: (MTGCard card) => card.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGCardMapper.fromMap(data)..id = id,
      );
      final MTGCard card = _card(finish: sf.Finish.foil);
      await store.set(card.id!, card);
      for (final (String, Object?, CardPrices) row
          in <(String, Object?, CardPrices)>[
            (
              'first',
              Timestamp.fromDate(DateTime.utc(2026, 10, 1)),
              const CardPrices(usd: 2, usdFoil: 5),
            ),
            (
              'last',
              Timestamp.fromDate(DateTime.utc(2026, 10, 2)),
              const CardPrices(usd: 3, usdFoil: 7),
            ),
            (
              'bad',
              Timestamp.fromDate(DateTime.utc(2026, 10, 3)),
              const CardPrices(usdFoil: double.nan),
            ),
          ]) {
        await store.collection
            .doc(card.id)
            .collection('priceObservations')
            .doc(row.$1)
            .set(<String, Object?>{
              'observedAt': row.$2,
              'prices': row.$3.toMap(),
            });
      }
      await _show(
        tester,
        CardMarketsPanel(
          card: card,
          holdings: <MTGCard>[card],
          onRefresh: () {},
          store: store,
        ),
      );
      final Finder toggle = find.byKey(
        const ValueKey<String>('card-market-history-toggle'),
      );
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('2 observations · Per copy'), findsOneWidget);
      expect(find.text('+USD 2.00'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('card-market-history-plot')),
        findsOneWidget,
      );
      expect(find.textContaining('NaN'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty history stays empty and viewing it writes no observations',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionStore<MTGCard> store = CollectionStore<MTGCard>(
        collection: database.collection('user/alice/cards'),
        toMap: (MTGCard card) => card.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGCardMapper.fromMap(data)..id = id,
      );
      final MTGCard card = _card();
      await store.set(card.id!, card);
      await _show(
        tester,
        CardMarketsPanel(
          card: card,
          holdings: <MTGCard>[card],
          onRefresh: () {},
          store: store,
        ),
      );
      final Finder toggle = find.byKey(
        const ValueKey<String>('card-market-history-toggle'),
      );
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('No recorded prices'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('card-market-history-plot')),
        findsNothing,
      );
      expect(
        (await store.collection
                .doc(card.id)
                .collection('priceObservations')
                .get())
            .docs,
        isEmpty,
      );
      expect((await store.get(card.id!)).quantity, 2);
    },
  );

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets('market rows reflow at 320px and large text in ${mode.name}', (
      WidgetTester tester,
    ) async {
      final MTGCard card = _card(finish: sf.Finish.etched);
      await _show(
        tester,
        CardMarketsPanel(
          card: card,
          holdings: <MTGCard>[card],
          onRefresh: () {},
        ),
        mode: mode,
        scale: 2.35,
      );
      expect(tester.takeException(), isNull);
      for (final String market in <String>['usd', 'eur', 'tix']) {
        final Finder row = find.byKey(ValueKey<String>('card-market-$market'));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        expect(tester.getRect(row).right, lessThanOrEqualTo(320));
        expect(tester.takeException(), isNull);
      }
    });
  }
}
