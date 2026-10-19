import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arcane/arcane.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/collection_cards.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/crud.dart';

class _Catalog extends CardCatalog {
  int calls = 0;
  @override
  Future<Map<String, sf.MtgCard>> printings(Iterable<String> ids) async {
    calls++;
    return <String, sf.MtgCard>{};
  }
}

class _ObservedStore extends CollectionStore<MTGCard> {
  _ObservedStore(FakeFirebaseFirestore database)
    : super(
        collection: database.collection('user/alice/cards'),
        toMap: (MTGCard card) => card.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGCardMapper.fromMap(data)..id = id,
      );
  int subscriptions = 0;
  int cancellations = 0;
  @override
  Stream<List<MTGCard>> streamAll() {
    final Stream<List<MTGCard>> source = super.streamAll();
    return Stream<List<MTGCard>>.multi((
      MultiStreamController<List<MTGCard>> controller,
    ) {
      subscriptions++;
      final StreamSubscription<List<MTGCard>> subscription = source.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = () {
        cancellations++;
        return subscription.cancel();
      };
    }, isBroadcast: true);
  }
}

MTGCard _completeCard() {
  final sf.MtgCard printing = sf.MtgCard.fromJson(
    jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<String, dynamic>,
  );
  return cardFromScryfall(
    printing,
    finish: sf.Finish.nonfoil,
  ).copyWith(quantity: 7, imageUrl: 'https://cards.scryfall.io/test.jpg');
}

void main() {
  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      '320px large-text filters and complete card names remain reachable in $mode',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final FakeFirebaseFirestore database = FakeFirebaseFirestore();
        const String name =
            'A long card name that needs more than three lines on a small phone';
        await database
            .doc('user/alice/cards/spell')
            .set(_completeCard().copyWith(name: name, imageUrl: null).toMap());
        final _Catalog catalog = _Catalog();
        addTearDown(catalog.close);
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(mode),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(1.8),
              ),
              child: CollectionCards(
                store: _ObservedStore(database),
                catalog: catalog,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.funnel));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Reset'),
          -150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Reset'));
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text(name),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        final Text title = tester.widget<Text>(find.text(name));
        expect(title.maxLines, isNull);
        expect(tester.takeException(), isNull);
        expect(
          (await database.doc('user/alice/cards/spell').get())
              .data()!['quantity'],
          7,
        );
      },
    );
  }
  testWidgets('mobile name and type filters retain saved inventory', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final sf.MtgCard printing = sf.MtgCard.fromJson(
      jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    final MTGCard spell = cardFromScryfall(
      printing,
      finish: sf.Finish.nonfoil,
    ).copyWith(quantity: 7, imageUrl: null);
    final MTGCard creature = spell.copyWith(
      name: 'Another Creature',
      typeLine: 'Creature',
      quantity: 3,
    );
    await database.doc('user/alice/cards/spell').set(spell.toMap());
    await database.doc('user/alice/cards/creature').set(creature.toMap());
    final CollectionStore<MTGCard> store = CollectionStore<MTGCard>(
      collection: database.collection('user/alice/cards'),
      toMap: (MTGCard card) => card.toMap(),
      fromMap: (String id, Map<String, Object?> data) =>
          MTGCardMapper.fromMap(data)..id = id,
    );
    final _Catalog catalog = _Catalog();
    addTearDown(catalog.close);
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.light),
        home: CollectionCards(store: store, catalog: catalog),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 printings • 10 cards'), findsOneWidget);
    expect(find.text('Normal · EN'), findsNWidgets(2));
    expect(find.textContaining('nonfoil'), findsNothing);
    final Text title = tester.widget<Text>(find.text(spell.name));
    expect(title.style!.fontWeight, FontWeight.w600);
    for (final Text detail in <Text>[
      tester.widget<Text>(find.text('Normal · EN').first),
      tester.widget<Text>(find.text('7 copies')),
    ]) {
      expect(detail.style!.fontSize, lessThan(title.style!.fontSize!));
    }
    await tester.tap(find.byIcon(Icons.magnifying_glass));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'another');
    await tester.pumpAndSettle();
    expect(find.text('1 printing • 3 cards'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.tap(find.byIcon(Icons.funnel));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'sorcery');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('1 printing • 7 cards'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.funnel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('2 printings • 10 cards'), findsOneWidget);
    final DocumentSnapshot<Map<String, dynamic>> saved = await database
        .doc('user/alice/cards/spell')
        .get();
    expect(saved.data()!['quantity'], 7);
    expect(saved.data()!['finish'], 'nonfoil');
    expect(tester.takeException(), isNull);
  });
  testWidgets('complete printing metadata needs no additional catalog lookup', (
    WidgetTester tester,
  ) async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final MTGCard card = _completeCard().copyWith(
      colors: <sf.Color>[],
      colorIdentity: <sf.Color>[],
    );
    await database.doc('user/alice/cards/spell').set(card.toMap());
    final _Catalog catalog = _Catalog();
    addTearDown(catalog.close);
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.light),
        home: CollectionCards(
          store: _ObservedStore(database),
          catalog: catalog,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 printing • 7 cards'), findsOneWidget);
    expect(catalog.calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inactive cards detach inventory and retain filters before resubscribing',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      await database.doc('user/alice/cards/spell').set(_completeCard().toMap());
      final _ObservedStore store = _ObservedStore(database);
      final _Catalog catalog = _Catalog();
      addTearDown(catalog.close);
      final ValueNotifier<bool> active = ValueNotifier<bool>(true);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.light),
          home: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (BuildContext context, bool value, Widget? child) =>
                CollectionCards(
                  key: const ValueKey<String>('cards'),
                  store: store,
                  catalog: catalog,
                  active: value,
                ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(store.subscriptions, 1);
      await tester.tap(find.byIcon(Icons.magnifying_glass));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'dusk');
      await tester.pumpAndSettle();
      active.value = false;
      await tester.pumpAndSettle();
      expect(store.cancellations, 1);
      expect(find.text('1 printing • 7 cards'), findsOneWidget);
      await database.doc('user/alice/cards/spell').update(<String, Object?>{
        'quantity': 12,
      });
      await tester.pumpAndSettle();
      expect(find.text('1 printing • 7 cards'), findsOneWidget);
      active.value = true;
      await tester.pumpAndSettle();
      expect(store.subscriptions, 2);
      expect(find.text('1 printing • 12 cards'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'dusk',
      );
      expect(catalog.calls, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
