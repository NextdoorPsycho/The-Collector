import 'package:arcane/arcane.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/card/price_history.dart';
import 'package:the_collector/pages/collection/card/card_thumbnail.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/crud.dart';

void main() {
  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'empty history is readable without inventing observations at large text ${mode.name}',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final FakeFirebaseFirestore database = FakeFirebaseFirestore();
        final CollectionStore<MTGCard> store = CollectionStore<MTGCard>(
          collection: database.collection('user/alice/cards'),
          toMap: (MTGCard card) => card.toMap(),
          fromMap: (String id, Map<String, Object?> data) =>
              MTGCardMapper.fromMap(data)..id = id,
        );
        final MTGCard card = MTGCard(
          name: 'Stored printing',
          setId: 'set',
          description: '',
          flavorText: '',
          cmc: 2,
          typeLine: 'Instant',
          manaCost: null,
          rarity: sf.Rarity.common,
          setType: sf.SetType.expansion,
          finish: sf.Finish.nonfoil,
          prices: const CardPrices(usd: 3),
          quantity: 7,
        )..id = 'printing';
        await store.set('printing', card);
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(mode),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 568),
                textScaler: TextScaler.linear(2.35),
              ),
              child: PriceHistoryScreen(card: card, store: store),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final Finder helper = find.text('Refresh Value to record a quote.');
        await tester.scrollUntilVisible(
          helper,
          80,
          scrollable: find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(helper);
        await tester.pumpAndSettle();
        expect(find.text('No recorded prices'), findsOneWidget);
        expect(helper.hitTestable(), findsOneWidget);
        expect(tester.getRect(helper).bottom, lessThanOrEqualTo(568));
        expect(find.textContaining('Change ('), findsNothing);
        expect(find.text('USD 3.00'), findsNothing);
        expect(
          (await store.collection
                  .doc('printing')
                  .collection('priceObservations')
                  .get())
              .docs,
          isEmpty,
        );
        expect((await store.get('printing')).quantity, 7);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
    for (final double scale in <double>[1, 2.35]) {
      testWidgets(
        'price history preserves per-copy quotes and currency at 320px/$scale ${mode.name}',
        (WidgetTester tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final FakeFirebaseFirestore database = FakeFirebaseFirestore();
          final CollectionStore<MTGCard> store = CollectionStore<MTGCard>(
            collection: database.collection('user/alice/cards'),
            toMap: (MTGCard card) => card.toMap(),
            fromMap: (String id, Map<String, Object?> data) =>
                MTGCardMapper.fromMap(data)..id = id,
          );
          final MTGCard card = MTGCard(
            name: 'A printing with a long name',
            setId: 'set',
            description: '',
            flavorText: '',
            cmc: 2,
            typeLine: 'Instant',
            manaCost: '{1}{U}',
            rarity: sf.Rarity.common,
            setType: sf.SetType.expansion,
            finish: sf.Finish.nonfoil,
            quantity: 7,
          )..id = 'printing';
          await store.set('printing', card);
          await store.collection
              .doc('printing')
              .collection('priceObservations')
              .doc('new')
              .set(<String, Object>{
                'observedAt': Timestamp.fromDate(
                  DateTime.utc(2026, 10, 10, 12),
                ),
                'prices': const CardPrices(
                  usd: 1000000,
                  usdFoil: 2,
                  eur: 10,
                ).toMap(),
              });
          await store.collection
              .doc('printing')
              .collection('priceObservations')
              .doc('old')
              .set(<String, Object>{
                'observedAt': Timestamp.fromDate(DateTime.utc(2026, 10, 9, 12)),
                'prices': const CardPrices(usd: 10, eur: 1, tix: 4).toMap(),
              });
          await tester.pumpWidget(
            ArcaneApp(
              theme: MyThemeData.themeData(mode),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(320, 640),
                  textScaler: TextScaler.linear(scale),
                ),
                child: PriceHistoryScreen(card: card, store: store),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(CardThumbnail), findsOneWidget);
          expect(find.textContaining('Normal'), findsOneWidget);
          final Finder scrollable = find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first;
          Future<void> reveal(Finder finder) async {
            await tester.scrollUntilVisible(
              finder,
              100,
              scrollable: scrollable,
            );
            await Scrollable.ensureVisible(
              tester.element(finder),
              alignment: .5,
            );
            await tester.pumpAndSettle();
          }

          await reveal(find.text('USD 1000000.00'));
          expect(find.text('2026-10-10'), findsOneWidget);
          expect(find.text('Change (2 dates): +USD 999990.00'), findsOneWidget);
          expect(find.text('USD 7000000.00'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey<String>('history-currency')),
            -100,
            scrollable: scrollable,
          );
          await Scrollable.ensureVisible(
            tester.element(
              find.byKey(const ValueKey<String>('history-currency')),
            ),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .getSize(find.byKey(const ValueKey<String>('history-currency')))
                .height,
            greaterThanOrEqualTo(44),
          );
          await tester.tap(find.text('USD').hitTestable());
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(find.text('EUR').hitTestable());
          await tester.pump(const Duration(milliseconds: 350));
          await reveal(find.text('EUR 10.00'));
          expect(find.text('Change (2 dates): +EUR 9.00'), findsOneWidget);
          expect(find.text('USD 1000000.00'), findsNothing);
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey<String>('history-currency')),
            -100,
            scrollable: scrollable,
          );
          await Scrollable.ensureVisible(
            tester.element(
              find.byKey(const ValueKey<String>('history-currency')),
            ),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('EUR').hitTestable());
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(find.text('TIX').hitTestable());
          await tester.pumpAndSettle();
          await reveal(find.text('No quote'));
          expect(find.text('TIX 4.00'), findsOneWidget);
          expect(find.textContaining('Change ('), findsNothing);
          await tester.scrollUntilVisible(
            find.text('Scryfall · Per copy'),
            -100,
            scrollable: scrollable,
          );
          await tester.pumpAndSettle();
          expect(
            find.text('Scryfall · Per copy').hitTestable(),
            findsOneWidget,
          );
          expect((await store.get('printing')).quantity, 7);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
