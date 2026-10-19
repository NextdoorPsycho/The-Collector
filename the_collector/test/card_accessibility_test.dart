import 'dart:convert';
import 'dart:io';

import 'package:arcane/arcane.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/card/card.dart';
import 'package:the_collector/pages/collection/card/card_item.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/crud.dart';

class _Catalog extends CardCatalog {
  @override
  Future<Map<String, sf.MtgCard>> printings(Iterable<String> ids) async =>
      <String, sf.MtgCard>{};
}

Future<({MTGCard card, CollectionStore<MTGCard> store})> _inventory({
  bool artwork = false,
}) async {
  final FakeFirebaseFirestore database = FakeFirebaseFirestore();
  final sf.MtgCard printing = sf.MtgCard.fromJson(
    jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<String, dynamic>,
  );
  final MTGCard card =
      cardFromScryfall(printing, finish: sf.Finish.nonfoil).copyWith(
        quantity: 7,
        imageUrl: artwork ? 'https://cards.scryfall.io/front/test.jpg' : null,
        backImageUrl: artwork
            ? 'https://cards.scryfall.io/back/test.jpg'
            : null,
      )..id = 'printing';
  final CollectionStore<MTGCard> store = CollectionStore<MTGCard>(
    collection: database.collection('user/alice/cards'),
    toMap: (MTGCard card) => card.toMap(),
    fromMap: (String id, Map<String, Object?> data) =>
        MTGCardMapper.fromMap(data)..id = id,
  );
  await store.set(card.id!, card);
  return (card: card, store: store);
}

void main() {
  Future<void> reveal(WidgetTester tester, String text) async {
    if ((text == 'Artwork' || text == 'Delete Printing') &&
        find.text(text).evaluate().isEmpty) {
      await reveal(tester, 'More');
      await tester.tap(find.text('More').hitTestable());
      await tester.pumpAndSettle();
    } else if (text != 'Artwork' &&
        text != 'Delete Printing' &&
        find.text('Actions').evaluate().isNotEmpty) {
      await tester.tap(find.text('Done').hitTestable());
      await tester.pumpAndSettle();
    }
    final Finder target = find.text(text);
    if (target.evaluate().isEmpty) {
      final Finder scrollable = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      final ScrollableState state = tester.state<ScrollableState>(scrollable);
      state.position.jumpTo(state.position.minScrollExtent);
      await tester.pump();
      await tester.scrollUntilVisible(target, 100, scrollable: scrollable);
    }
    await Scrollable.ensureVisible(tester.element(target.first), alignment: .5);
    await tester.pumpAndSettle();
  }

  testWidgets('card tile supports keyboard activation without a pointer', (
    WidgetTester tester,
  ) async {
    final ({MTGCard card, CollectionStore<MTGCard> store}) inventory =
        await _inventory();
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.light),
        home: Scaffold(
          child: Center(
            child: SizedBox(
              width: 220,
              height: 250,
              child: buildCardItem(inventory.card, store: inventory.store),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(Sheet), findsOneWidget);
    expect(find.text('Card Details'), findsNothing);
    expect(find.text('Quantity'), findsOneWidget);
    expect((await inventory.store.get('printing')).quantity, 7);
    Navigator.of(tester.element(find.byType(CardFlyoutScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(Sheet), findsNothing);
    expect(find.byType(CardButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'iOS card details hides route close and preserves quantity editing',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final TargetPlatform? previousPlatform =
          debugDefaultTargetPlatformOverride;
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final ({MTGCard card, CollectionStore<MTGCard> store}) inventory =
            await _inventory();
        final _Catalog catalog = _Catalog();
        addTearDown(catalog.close);
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(ThemeMode.dark),
            home: CardFlyoutScreen(
              card: inventory.card,
              store: inventory.store,
              catalog: catalog,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Card Details'), findsNothing);
        expect(find.bySemanticsLabel('Close card details'), findsNothing);
        expect(find.text('Organize'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('Remove one copy'));
        await tester.pumpAndSettle();
        expect((await inventory.store.get('printing')).quantity, 6);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );

  testWidgets(
    'visible delete requires confirmation and leaves deck references',
    (WidgetTester tester) async {
      final ({MTGCard card, CollectionStore<MTGCard> store}) inventory =
          await _inventory();
      final _Catalog catalog = _Catalog();
      addTearDown(catalog.close);
      final FakeFirebaseFirestore database =
          inventory.store.collection.firestore as FakeFirebaseFirestore;
      await database.doc('user/alice/decks/deck').set(<String, Object?>{
        'entries': <Object?>[
          <String, Object?>{
            'scryfallId': inventory.card.scryfallId,
            'quantity': 2,
          },
        ],
      });
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: CardFlyoutScreen(
            card: inventory.card,
            store: inventory.store,
            catalog: catalog,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, 'Delete Printing');
      await tester.tap(find.text('Delete Printing').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await inventory.store.get('printing')).quantity, 7);
      await reveal(tester, 'Delete Printing');
      await tester.tap(find.text('Delete Printing').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(
        (await inventory.store.collection.doc('printing').get()).exists,
        isFalse,
      );
      expect(
        (await database.doc('user/alice/decks/deck').get()).exists,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    for (final double scale in <double>[1, 2.35]) {
      testWidgets(
        'small phone card details preserve identity, zoom and deletion at text scale $scale in ${mode.name}',
        (WidgetTester tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final ({MTGCard card, CollectionStore<MTGCard> store}) inventory =
              await _inventory(artwork: true);
          final _Catalog catalog = _Catalog();
          addTearDown(catalog.close);
          await tester.pumpWidget(
            ArcaneApp(
              theme: MyThemeData.themeData(mode),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(320, 568),
                  textScaler: TextScaler.linear(scale),
                ),
                child: CardFlyoutScreen(
                  card: inventory.card,
                  store: inventory.store,
                  catalog: catalog,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final Finder name = find.byKey(
            const ValueKey<String>('card-detail-name'),
          );
          final Finder artwork = find.byKey(
            const ValueKey<String>('card-detail-artwork'),
          );
          expect(tester.getRect(name).top, greaterThanOrEqualTo(0));
          expect(tester.getRect(name).bottom, lessThan(568));
          if (artwork.evaluate().isNotEmpty) {
            expect(
              tester.getTopLeft(name).dy,
              lessThan(tester.getTopLeft(artwork).dy),
            );
          }
          expect(
            tester.takeException(),
            isNull,
            reason: 'initial details layout',
          );
          if (artwork.evaluate().isEmpty) {
            await tester.scrollUntilVisible(
              artwork,
              100,
              scrollable: find
                  .descendant(
                    of: find.byType(ListView).first,
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
          }
          await Scrollable.ensureVisible(
            tester.element(artwork),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          expect(tester.getSize(artwork).height, lessThan(240));

          await reveal(tester, 'Artwork');
          await tester.tap(find.text('Artwork').hitTestable());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'full artwork layout');
          expect(find.byType(InteractiveViewer), findsWidgets);
          await tester.tap(find.bySemanticsLabel('Back to card details'));
          await tester.pumpAndSettle();

          await reveal(tester, 'Show Back');
          await tester.tap(find.text('Show Back').hitTestable());
          await tester.pumpAndSettle();
          await reveal(tester, 'Show Front');
          expect(find.text('Show Front').hitTestable(), findsOneWidget);
          await reveal(tester, 'Delete Printing');
          await tester.tap(find.text('Delete Printing').hitTestable());
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'delete confirmation layout',
          );
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect((await inventory.store.get('printing')).quantity, 7);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
