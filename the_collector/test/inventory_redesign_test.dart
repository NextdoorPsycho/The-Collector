import 'dart:convert';
import 'dart:io';

import 'package:arcane/arcane.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/collection_cards.dart';
import 'package:the_collector/pages/collection/card/card_add_dialog.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/crud.dart';

class _Catalog extends CardCatalog {
  sf.MtgCard? hydration;

  @override
  Future<Map<String, sf.MtgCard>> printings(Iterable<String> ids) async =>
      <String, sf.MtgCard>{?hydration?.id: hydration!};

  @override
  Future<sf.PaginableList<sf.MtgCard>> search(
    String query, {
    int page = 1,
    bool allPrintings = false,
  }) async => sf.PaginableList<sf.MtgCard>(
    data: <sf.MtgCard>[?hydration],
    hasMore: false,
  );
}

class _Store extends CollectionStore<MTGCard> {
  _Store(FakeFirebaseFirestore database)
    : super(
        collection: database.collection('user/alice/cards'),
        toMap: (MTGCard card) => card.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGCardMapper.fromMap(data)..id = id,
      );

  final Map<String, int> deleteCalls = <String, int>{};
  String? failNextDelete;

  @override
  Future<void> delete(String id) async {
    deleteCalls.update(id, (int calls) => calls + 1, ifAbsent: () => 1);
    if (id == failNextDelete) {
      failNextDelete = null;
      throw StateError('Offline');
    }
    await super.delete(id);
  }
}

MTGCard _card(String name, int quantity, {double? usd, double? foil}) {
  final sf.MtgCard printing = sf.MtgCard.fromJson(
    jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<String, dynamic>,
  );
  return cardFromScryfall(printing, finish: sf.Finish.nonfoil).copyWith(
    name: name,
    quantity: quantity,
    finish: foil == null ? sf.Finish.nonfoil : sf.Finish.foil,
    imageUrl: null,
    prices: CardPrices(usd: usd, usdFoil: foil),
  );
}

Future<_Store> _mount(
  WidgetTester tester,
  FakeFirebaseFirestore database,
) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final _Store store = _Store(database);
  final _Catalog catalog = _Catalog();
  addTearDown(catalog.close);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.dark),
      home: CollectionCards(store: store, catalog: catalog),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('Value remains reachable and passes an explicit filtered scope', (
    WidgetTester tester,
  ) async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final _Catalog catalog = _Catalog();
    addTearDown(catalog.close);
    final List<List<MTGCard>?> requests = <List<MTGCard>?>[];
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        home: CollectionCards(
          store: _Store(database),
          catalog: catalog,
          onValue: requests.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('collection-value')));
    expect(requests, <List<MTGCard>?>[null]);
    await database.doc('user/alice/cards/alpha').set(_card('Alpha', 3).toMap());
    await database.doc('user/alice/cards/beta').set(_card('Beta', 2).toMap());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.magnifying_glass));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Alpha');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('collection-value')));
    expect(requests.last!.map((MTGCard card) => card.id), <String>['alpha']);
    await tester.enterText(find.byType(TextField).first, 'unmatched');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('collection-value')));
    expect(requests.last, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual Add writes through the injected account database', (
    WidgetTester tester,
  ) async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final sf.MtgCard printing = sf.MtgCard.fromJson(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    final _Catalog catalog = _Catalog()..hydration = printing;
    addTearDown(catalog.close);
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        home: CollectionCards(store: _Store(database), catalog: catalog),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.plus));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final Finder dialog = find.byType(CardPrintingDialog);
    expect(dialog, findsOneWidget);
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)).first,
      'Dusk',
    );
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('printing-choice-${printing.id}')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add to Collection'));
    await tester.tap(find.text('Add to Collection').hitTestable());
    await tester.pumpAndSettle();
    final MTGCard saved = await _Store(database).get(printing.id);
    expect(saved.quantity, 1);
    expect(saved.finish, sf.Finish.nonfoil);
    expect((await database.collection('user/alice/decks').get()).docs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('metadata hydration keeps the saved finish and quote', (
    WidgetTester tester,
  ) async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final sf.MtgCard printing = sf.MtgCard.fromJson(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    final MTGCard saved = _card(
      'Dusk // Dawn',
      2,
      usd: 1,
      foil: 12,
    ).copyWith(oracleText: null, imageUrl: null);
    await database.doc('user/alice/cards/saved-foil').set(saved.toMap());
    final _Catalog catalog = _Catalog()..hydration = printing;
    addTearDown(catalog.close);
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        home: CollectionCards(store: _Store(database), catalog: catalog),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('USD 24.00'), findsWidgets);
    expect(find.text('Foil · EN'), findsOneWidget);
    await tester.longPress(find.text('Dusk // Dawn'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected · 2 copies'), findsOneWidget);
    expect(
      (await database.doc('user/alice/cards/saved-foil').get())
          .data()!['prices'],
      containsPair('usdFoil', 12.0),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('long press selects owned copies without opening deletion', (
    WidgetTester tester,
  ) async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    await database.doc('user/alice/cards/alpha').set(_card('Alpha', 3).toMap());
    await database.doc('user/alice/cards/beta').set(_card('Beta', 2).toMap());
    await database.doc('user/alice/decks/box').set(<String, Object?>{
      'name': 'Box',
      'cards': <String>['alpha', 'beta'],
    });
    await _mount(tester, database);

    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected · 3 copies'), findsOneWidget);
    expect(find.text('Delete Printing'), findsNothing);
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected · 5 copies'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(
      (await database.collection('user/alice/cards').get()).docs,
      hasLength(2),
    );
    await tester.tap(find.text('Remove copies'));
    await tester.pumpAndSettle();
    expect((await database.collection('user/alice/cards').get()).docs, isEmpty);
    expect(
      (await database.doc('user/alice/decks/box').get()).data()!['cards'],
      <String>['alpha', 'beta'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('bulk removal retains failed rows and retries only those rows', (
    WidgetTester tester,
  ) async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    await database.doc('user/alice/cards/alpha').set(_card('Alpha', 3).toMap());
    await database.doc('user/alice/cards/beta').set(_card('Beta', 2).toMap());
    final _Store store = await _mount(tester, database);
    store.failNextDelete = 'beta';

    await tester.tap(find.byKey(const ValueKey<String>('collection-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All shown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove copies'));
    await tester.pumpAndSettle();
    expect(
      (await database.doc('user/alice/cards/alpha').get()).exists,
      isFalse,
    );
    expect((await database.doc('user/alice/cards/beta').get()).exists, isTrue);
    expect(find.text('1 selected · 2 copies'), findsOneWidget);
    await tester.tap(find.text('Retry removal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove copies'));
    await tester.pumpAndSettle();
    expect((await database.collection('user/alice/cards').get()).docs, isEmpty);
    expect(store.deleteCalls, <String, int>{'alpha': 1, 'beta': 2});
    expect(tester.takeException(), isNull);
  });

  testWidgets('sorting uses copy counts and the owned finish value', (
    WidgetTester tester,
  ) async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    await database
        .doc('user/alice/cards/alpha')
        .set(_card('Alpha', 3, usd: 2).toMap());
    await database
        .doc('user/alice/cards/beta')
        .set(_card('Beta', 1, usd: 1, foil: 20).toMap());
    await database
        .doc('user/alice/cards/gamma')
        .set(_card('Gamma', 7, usd: 1).toMap());
    await _mount(tester, database);

    await tester.tap(find.byIcon(Icons.funnel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Most copies'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Gamma')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Alpha')).dy,
      lessThan(tester.getTopLeft(find.text('Beta')).dy),
    );

    await tester.tap(find.byIcon(Icons.funnel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Highest value'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Beta')).dy,
      lessThan(tester.getTopLeft(find.text('Gamma')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Gamma')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha')).dy),
    );
    expect(find.text('USD 20.00'), findsOneWidget);
    expect(
      (await database.doc('user/alice/cards/beta').get()).data()!['quantity'],
      1,
    );
    expect(tester.takeException(), isNull);
  });
}
