import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arcane/arcane.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/card/card.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/crud.dart';

import 'helpers/load_collector_fonts.dart';

const String _first = '11111111-1111-1111-1111-111111111111';
const String _second = '22222222-2222-2222-2222-222222222222';

sf.MtgCard _printing({
  String id = _first,
  String set = 'aaa',
  String number = '1',
  String rules = 'Fresh rules.',
  String usd = '5.00',
}) {
  final Map<String, Object?> json = jsonDecode(
    File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
  ) as Map<String, Object?>;
  json.addAll(<String, Object?>{
    'id': id,
    'name': 'Fixture card',
    'set': set,
    'set_name': 'Set $set',
    'collector_number': number,
    'layout': 'normal',
    'card_faces': null,
    'image_uris': null,
    'oracle_text': rules,
    'type_line': 'Instant',
    'mana_cost': '{U}',
    'cmc': 1,
    'finishes': <String>['nonfoil'],
    'prices': <String, Object?>{'usd': usd, 'eur': '3.00', 'tix': null},
  });
  return sf.MtgCard.fromJson(json);
}

class _Request {
  _Request(Iterable<String> ids) : ids = ids.toList();

  final List<String> ids;
  final Completer<Map<String, sf.MtgCard>> completion =
      Completer<Map<String, sf.MtgCard>>();

  void succeed(sf.MtgCard card) =>
      completion.complete(<String, sf.MtgCard>{card.id: card});
  void fail() => completion.completeError(StateError('Offline fixture'));
}

class _Catalog extends CardCatalog {
  final List<_Request> requests = <_Request>[];

  @override
  Future<Map<String, sf.MtgCard>> printings(Iterable<String> ids) {
    final _Request request = _Request(ids);
    requests.add(request);
    return request.completion.future;
  }
}

class _Cards extends CollectionStore<MTGCard> {
  _Cards(FakeFirebaseFirestore database, {this.failInventory = false})
    : super(
        collection: database.collection('user/drawer-owner/cards'),
        toMap: (MTGCard card) => card.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGCardMapper.fromMap(data)..id = id,
      );

  final bool failInventory;

  @override
  Stream<List<MTGCard>> streamAll() => failInventory
      ? Stream<List<MTGCard>>.error(StateError('Inventory unavailable'))
      : super.streamAll();
}

class _Fixture {
  _Fixture({this.failInventory = false}) : database = FakeFirebaseFirestore();

  final FakeFirebaseFirestore database;
  final bool failInventory;
  late final _Cards cards = _Cards(database, failInventory: failInventory);
  late final CollectionStore<MTGDeck> groups = CollectionStore<MTGDeck>(
    collection: database.collection('user/drawer-owner/decks'),
    toMap: (MTGDeck group) => group.toMap(),
    fromMap: (String id, Map<String, Object?> data) =>
        MTGDeckMapper.fromMap(data)..id = id,
  );
  final _Catalog catalog = _Catalog();
  late MTGCard selected;

  Future<void> seed({bool secondPrinting = false}) async {
    selected =
        cardFromScryfall(_printing(), finish: sf.Finish.nonfoil).copyWith(
          quantity: 7,
          oracleText: 'Cached rules.',
          prices: const CardPrices(usd: 2, eur: 3),
        )..id = _first;
    await cards.set(_first, selected);
    if (secondPrinting) {
      final MTGCard second = cardFromScryfall(
        _printing(id: _second, set: 'bbb', number: '2'),
        finish: sf.Finish.nonfoil,
      ).copyWith(quantity: 2, oracleText: 'Second cached rules.')..id = _second;
      await cards.set(_second, second);
    }
    await groups.set(
      'binder',
      MTGDeck(
        name: 'Binder',
        kind: CollectionGroupKind.binder,
        entries: const <DeckEntry>[
          DeckEntry(
            scryfallId: _first,
            quantity: 3,
            finish: sf.Finish.nonfoil,
            language: 'en',
          ),
        ],
      ),
    );
  }
}

Future<void> _show(
  WidgetTester tester,
  _Fixture fixture, {
  bool sheet = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(fixture.catalog.close);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.dark),
      home: sheet
          ? Builder(
              builder: (BuildContext context) => Scaffold(
                child: Center(
                  child: PrimaryButton(
                    key: const ValueKey<String>('underlying-collection'),
                    onPressed: () => openCardDetails(
                      context,
                      card: fixture.selected,
                      store: fixture.cards,
                      groups: fixture.groups,
                      catalog: fixture.catalog,
                    ),
                    child: const Text('Open card'),
                  ),
                ),
              ),
            )
          : CardFlyoutScreen(
              card: fixture.selected,
              store: fixture.cards,
              groups: fixture.groups,
              catalog: fixture.catalog,
            ),
    ),
  );
  await tester.pumpAndSettle();
  if (sheet) await _tap(tester, find.text('Open card'));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.hitTestable().first);
  await tester.pumpAndSettle();
}

Finder get _refresh =>
    find.byKey(const ValueKey<String>('card-market-refresh'));

void main() {
  setUpAll(loadCollectorFonts);

  testWidgets(
    'inventory failure keeps selected quantity without claiming aggregate holdings',
    (WidgetTester tester) async {
      final _Fixture fixture = _Fixture(failInventory: true);
      await fixture.seed();
      await _show(tester, fixture);
      fixture.catalog.requests.single.completion.complete(
        <String, sf.MtgCard>{},
      );
      await tester.pumpAndSettle();

      expect(find.text('7'), findsOneWidget);
      expect(find.text('7 owned'), findsNothing);
      expect(find.textContaining('· 7 owned'), findsNothing);
      expect(find.text('USD 14.00'), findsNothing);
      await _tap(tester, find.text('Value'));
      final Finder usd = find.byKey(const ValueKey<String>('card-market-usd'));
      expect(
        find.descendant(of: usd, matching: find.text('USD 2.00')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: usd, matching: find.text('USD 14.00')),
        findsNothing,
      );
      expect(
        find.descendant(of: usd, matching: find.text('7 owned')),
        findsNothing,
      );
      expect((await fixture.cards.get(_first)).quantity, 7);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'successful metadata retry replaces saved rules and clears offline status',
    (WidgetTester tester) async {
      final _Fixture fixture = _Fixture();
      await fixture.seed();
      await _show(tester, fixture);
      fixture.catalog.requests.single.fail();
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Value'));
      expect(find.textContaining('Offline'), findsOneWidget);
      await _tap(tester, find.text('Card'));
      await _tap(tester, find.text('More'));
      await _tap(tester, find.text('Artwork'));
      fixture.catalog.requests.last.succeed(_printing(rules: 'Retried rules.'));
      await tester.pumpAndSettle();

      expect(find.text('Retried rules.'), findsOneWidget);
      expect(find.text('Cached rules.'), findsNothing);
      await _tap(tester, find.text('Value'));
      expect(find.textContaining('Offline'), findsNothing);
      expect(find.text('USD 5.00'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'market refresh recovers metadata without writing inventory memberships or history',
    (WidgetTester tester) async {
      final _Fixture fixture = _Fixture();
      await fixture.seed();
      final Map<String, Object?>? cardBefore =
          (await fixture.database.doc('user/drawer-owner/cards/$_first').get())
              .data();
      final Map<String, Object?>? groupBefore =
          (await fixture.database.doc('user/drawer-owner/decks/binder').get())
              .data();
      await _show(tester, fixture);
      fixture.catalog.requests.single.fail();
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Value'));
      expect(find.textContaining('Offline'), findsOneWidget);
      await _tap(tester, _refresh);
      fixture.catalog.requests.last.succeed(
        _printing(rules: 'Refreshed rules.', usd: '9.00'),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Offline'), findsNothing);
      expect(find.text('USD 63.00'), findsOneWidget);
      await _tap(tester, find.text('Card'));
      expect(find.text('Refreshed rules.'), findsOneWidget);
      expect(find.text('Cached rules.'), findsNothing);
      expect(
        (await fixture.database.doc('user/drawer-owner/cards/$_first').get())
            .data(),
        cardBefore,
      );
      expect(
        (await fixture.database.doc('user/drawer-owner/decks/binder').get())
            .data(),
        groupBefore,
      );
      expect(
        (await fixture.cards.collection
                .doc(_first)
                .collection('priceObservations')
                .get())
            .docs,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dismiss and delete pop only the card sheet while preserving group memberships',
    (WidgetTester tester) async {
      final _Fixture fixture = _Fixture();
      await fixture.seed();
      await _show(tester, fixture, sheet: true);
      fixture.catalog.requests.single.completion.complete(
        <String, sf.MtgCard>{},
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(CardFlyoutScreen), findsNothing);
      expect(
        find
            .byKey(const ValueKey<String>('underlying-collection'))
            .hitTestable(),
        findsOneWidget,
      );
      expect((await fixture.cards.get(_first)).quantity, 7);
      await _tap(tester, find.text('Open card'));
      fixture.catalog.requests.last.completion.complete(<String, sf.MtgCard>{});
      await tester.pumpAndSettle();
      await _tap(tester, find.text('More'));
      await _tap(tester, find.text('Delete Printing'));
      await _tap(tester, find.text('Delete'));

      expect(find.byType(CardFlyoutScreen), findsNothing);
      expect(
        find
            .byKey(const ValueKey<String>('underlying-collection'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(await fixture.cards.exists(_first), isFalse);
      expect(
        (await fixture.groups.get('binder')).effectiveEntries.single.quantity,
        3,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late metadata for previous owned printing cannot replace selected variant',
    (WidgetTester tester) async {
      final _Fixture fixture = _Fixture();
      await fixture.seed(secondPrinting: true);
      await _show(tester, fixture);
      final _Request firstRequest = fixture.catalog.requests.single;
      await _tap(tester, find.text('Locations'));
      await _tap(tester, find.text('BBB #2'));
      final _Request secondRequest = fixture.catalog.requests.last;
      expect(secondRequest.ids, <String>[_second]);
      secondRequest.succeed(
        _printing(
          id: _second,
          set: 'bbb',
          number: '2',
          rules: 'Selected printing rules.',
          usd: '11.00',
        ),
      );
      await tester.pumpAndSettle();
      firstRequest.succeed(
        _printing(rules: 'Stale printing rules.', usd: '1.00'),
      );
      await tester.pumpAndSettle();

      expect(find.text('BBB #2'), findsOneWidget);
      expect(find.text('Selected printing rules.'), findsOneWidget);
      expect(find.text('Stale printing rules.'), findsNothing);
      expect(find.text('USD 11.00'), findsOneWidget);
      expect(find.text('USD 1.00'), findsNothing);
      expect(find.text('2'), findsOneWidget);
      expect((await fixture.cards.get(_first)).quantity, 7);
      expect((await fixture.cards.get(_second)).quantity, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
