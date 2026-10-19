import 'package:arcane/arcane.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_collector/main.dart' as app;
import 'package:the_collector/pages/collection/card/price_history.dart';
import 'package:the_collector/pages/collection/collection_decks.dart'
    show DeckCard;
import 'package:the_collector/pages/collection/collection_prices.dart';
import 'package:the_collector/pages/collection/deck/deck.dart'
    show DeckFlyoutScreen;
import 'package:the_collector/pages/dock/hub_rules.dart' show HubRules;
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/firebase_environment.dart';

Future<void> _wait(WidgetTester tester, Finder target) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 45));
  while (target.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(target, findsWidgets);
  expect(tester.takeException(), isNull);
}

Future<void> _checkpoint(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 700));
  expect(tester.takeException(), isNull);
  if (const bool.fromEnvironment('APP_UI_SCREENSHOTS')) {
    void repaint(RenderObject object) {
      object.markNeedsPaint();
      object.visitChildren(repaint);
    }

    for (final RenderObject view in tester.binding.renderViews) {
      repaint(view);
    }
    await tester.pump();
    debugPrint('APP_UI_READY:$name');
    await Future<void>.delayed(const Duration(seconds: 4));
  }
}

Future<void> _waitGone(WidgetTester tester, Finder target) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 45));
  while (target.evaluate().isNotEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(target, findsNothing);
  expect(tester.takeException(), isNull);
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty &&
      find.byType(Scrollable).hitTestable().evaluate().isNotEmpty) {
    await _scrollTo(tester, target);
  } else {
    await _wait(tester, target);
  }
  if (target.hitTestable().evaluate().isEmpty) {
    await _scrollTo(tester, target);
  }
  await _wait(tester, target.hitTestable());
  await tester.tap(target.hitTestable().first);
  await tester.pump(const Duration(milliseconds: 500));
  expect(tester.takeException(), isNull);
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    final Finder scrollable = find.byType(Scrollable).hitTestable();
    expect(scrollable, findsWidgets);
    tester.state<ScrollableState>(scrollable.first).position.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 200));
  }
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    if (target.evaluate().isNotEmpty) {
      await tester.ensureVisible(target.first);
      break;
    }
    final Finder scrollable = find.byType(Scrollable).hitTestable();
    expect(scrollable, findsWidgets);
    await tester.drag(scrollable.first, const Offset(0, -160));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 200));
  if (target.evaluate().isEmpty) {
    for (final Element element in find.byType(Text).evaluate()) {
      final Text widget = element.widget as Text;
      debugPrint(
        'APP_UI_SCROLL_TEXT:${widget.data ?? widget.textSpan?.toPlainText()}',
      );
    }
    for (final Element element
        in find.byType(Scrollable).hitTestable().evaluate()) {
      final ScrollableState scrollable =
          (element as StatefulElement).state as ScrollableState;
      debugPrint(
        'APP_UI_SCROLL_POSITION:axis=${scrollable.position.axis.name} '
        'offset=${scrollable.position.pixels} '
        'max=${scrollable.position.maxScrollExtent}',
      );
    }
    await _checkpoint(tester, 'scroll_failure');
  }
  expect(target, findsWidgets);
  expect(tester.takeException(), isNull);
}

Future<void> _back(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  await tester.pump(const Duration(milliseconds: 300));
  final BuildContext surface = tester.element(find.byType(Scaffold).last);
  final ModalRoute<Object?> route = ModalRoute.of(surface)!;
  final Size size = MediaQuery.sizeOf(surface);
  expect(route.isCurrent, isTrue);
  await tester.dragFrom(Offset(1, size.height / 2), Offset(size.width * .8, 0));
  await tester.pump(const Duration(milliseconds: 700));
  expect(
    route.isCurrent,
    isFalse,
    reason: 'The native edge swipe must pop the route.',
  );
  expect(tester.takeException(), isNull);
}

Future<void> _tabletopMode(WidgetTester tester, String mode) async {
  await _tap(tester, find.byKey(ValueKey<String>('games-mode-$mode')));
}

Future<void> _historyCurrency(
  WidgetTester tester,
  CardCurrency currency,
) async {
  await _tap(tester, find.byKey(const ValueKey<String>('history-currency')));
  await _tap(
    tester,
    find.widgetWithText(
      SelectItemButton<CardCurrency>,
      currency.name.toUpperCase(),
    ),
  );
}

Finder _tab(String name) => find.bySemanticsLabel(name).hitTestable();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'normal mobile app supports collection, decks, games, rules and preferences',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        expect(
          const bool.fromEnvironment('USE_FIREBASE_EMULATORS'),
          isTrue,
          reason: 'This fixture may write only to local Firebase emulators.',
        );
        await initializeCollectorFirebase();
        final FirebaseAuth auth = FirebaseAuth.instance;
        final FirebaseFirestore database = FirebaseFirestore.instance;
        expect(
          auth.currentUser,
          isNull,
          reason: 'Preserve any pre-existing signed-in account.',
        );
        final User user = (await auth.signInAnonymously()).user!;
        final String uid = user.uid;
        final DocumentReference<Map<String, dynamic>> profile = database.doc(
          'user/$uid',
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await database.enableNetwork();
          for (final String folder in <String>[
            'cards',
            'decks',
            'priceHistory',
          ]) {
            final QuerySnapshot<Map<String, dynamic>> records = await profile
                .collection(folder)
                .get();
            final WriteBatch batch = database.batch();
            for (final QueryDocumentSnapshot<Map<String, dynamic>> record
                in records.docs) {
              if (folder == 'cards') {
                final QuerySnapshot<Map<String, dynamic>> observations =
                    await record.reference
                        .collection('priceObservations')
                        .get();
                for (final QueryDocumentSnapshot<Map<String, dynamic>>
                    observation
                    in observations.docs) {
                  batch.delete(observation.reference);
                }
              }
              batch.delete(record.reference);
            }
            await batch.commit();
          }
          await profile.delete();
          await user.delete();
          await auth.signOut();
          final SharedPreferences preferences =
              await SharedPreferences.getInstance();
          for (final String key in preferences.getKeys().where(
            (String key) => key.startsWith('game.$uid.'),
          )) {
            await preferences.remove(key);
          }
        });

        // Exercise account setup Retry after a native offline read.
        await database.disableNetwork();
        await app.main();
        await _wait(tester, find.text('Could not load your account.'));
        await database.enableNetwork();
        await _tap(tester, find.text('Retry'));
        await _wait(
          tester,
          find.byKey(const ValueKey<String>('collection-mode-0')),
        );
        await _checkpoint(tester, 'home_dark');

        const String printing = 'f29ba16f-c8fb-42fe-aabf-87089cb214a7';
        final MTGCard bolt = MTGCard(
          name: 'Lightning Bolt',
          setId: '2x2',
          description: '',
          flavorText: '',
          cmc: 1,
          typeLine: 'Instant',
          rarity: sf.Rarity.common,
          setType: sf.SetType.masters,
          manaCost: '{R}',
          quantity: 7,
          scryfallId: printing,
          setCode: '2x2',
          setName: 'Double Masters 2022',
          collectorNumber: '117',
          language: 'en',
          finish: sf.Finish.nonfoil,
          colors: <sf.Color>[sf.Color.red],
          colorIdentity: <sf.Color>[sf.Color.red],
          oracleText: 'Lightning Bolt deals 3 damage to any target.',
          imageUrl: 'https://cards.scryfall.io/normal/front/f/2/$printing.jpg',
          prices: const CardPrices(usd: 1, eur: 2, tix: .5),
          pricesUpdatedAt: DateTime.utc(2026, 10, 1),
        );
        await Crud.card(uid).set(printing, bolt);
        final CollectionReference<Map<String, dynamic>> printingHistory =
            profile
                .collection('cards')
                .doc(printing)
                .collection('priceObservations');
        await printingHistory.doc('fixture-latest').set(<String, Object?>{
          'prices': const CardPrices(usd: 1, eur: 2, tix: .5).toMap(),
          'observedAt': Timestamp.fromDate(DateTime.utc(2026, 10, 1)),
          'source': 'Scryfall',
        });
        await printingHistory.doc('fixture-previous').set(<String, Object?>{
          'prices': const CardPrices(usd: .75, eur: 1.5, tix: .25).toMap(),
          'observedAt': Timestamp.fromDate(DateTime.utc(2026, 9, 30)),
          'source': 'Scryfall',
        });
        for (final (CardCurrency currency, double total)
            in <(CardCurrency, double)>[
              (CardCurrency.usd, 7),
              (CardCurrency.eur, 14),
              (CardCurrency.tix, 3.5),
            ]) {
          await profile
              .collection('priceHistory')
              .doc('fixture-${currency.name}')
              .set(<String, Object?>{
                'observedAt': Timestamp.fromDate(DateTime.utc(2026, 10, 1)),
                'currency': currency.name,
                'total': total,
                'pricedCopies': 7,
                'unpricedCopies': 0,
                'source': 'Scryfall',
              });
        }
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('collection-mode-0')),
        );
        await _wait(tester, find.text('Lightning Bolt'));
        await _checkpoint(tester, 'collection_dark');
        await tester.enterText(
          find.byType(TextField).hitTestable().first,
          'absent',
        );
        await _wait(tester, find.text('No cards match your filters.'));
        await tester.enterText(find.byType(TextField).hitTestable().first, '');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump(const Duration(milliseconds: 300));
        await _tap(tester, find.byIcon(Icons.funnel));
        await _scrollTo(tester, find.text('Clear Filters'));
        await _tap(tester, find.text('Clear Filters'));
        await _tap(tester, find.byIcon(Icons.funnel));
        await _scrollTo(tester, find.text('Lightning Bolt'));
        await _tap(tester, find.text('Lightning Bolt'));
        await _wait(
          tester,
          find.byKey(const ValueKey<String>('card-detail-name')),
        );
        await _checkpoint(tester, 'card_details');
        await _tap(tester, find.text('Artwork'));
        await _checkpoint(tester, 'card_artwork');
        await _back(tester);
        await _wait(
          tester,
          find.byKey(const ValueKey<String>('card-detail-name')),
        );
        await _tap(tester, find.text('Delete Printing'));
        await _wait(tester, find.text('Delete').hitTestable());
        await _tap(tester, find.text('Cancel'));
        await _tap(tester, find.text('Prices'));
        await _wait(tester, find.byType(PriceHistoryScreen));
        await _wait(tester, find.text('Change (2 dates): +USD 0.25'));
        await _checkpoint(tester, 'printing_history_usd');
        await database.disableNetwork();
        await _historyCurrency(tester, CardCurrency.eur);
        await _wait(tester, find.text('Change (2 dates): +EUR 0.50'));
        await _historyCurrency(tester, CardCurrency.tix);
        await _wait(tester, find.text('Change (2 dates): +TIX 0.25'));
        await _checkpoint(tester, 'printing_history_cached_tix');
        await database.enableNetwork();
        await _back(tester);
        await _wait(
          tester,
          find.byKey(const ValueKey<String>('card-detail-name')),
        );
        await _back(tester);

        await _tap(
          tester,
          find.byKey(const ValueKey<String>('collection-mode-1')),
        );
        await _wait(
          tester,
          find.text(
            'No groups here. Create a deck, binder, box, folder or list.',
          ),
        );
        await _tap(tester, find.text('Create'));
        await _wait(tester, find.text('New container'));
        await _tap(tester, find.text('Deck'));
        await _wait(tester, find.text('New container'));
        final Finder nameDialog = find.widgetWithText(
          ArcaneDialog,
          'New container',
        );
        expect(nameDialog, findsOneWidget);
        await tester.enterText(
          find
              .descendant(of: nameDialog, matching: find.byType(TextField))
              .hitTestable(),
          'Simulator deck',
        );
        await tester.pump();
        final Finder createDeck = find.descendant(
          of: nameDialog,
          matching: find.widgetWithText(SecondaryButton, 'Create'),
        );
        expect(createDeck, findsOneWidget);
        expect(tester.widget<SecondaryButton>(createDeck).onPressed, isNotNull);
        await _tap(tester, createDeck);
        await _waitGone(tester, nameDialog);
        final Finder createdDeck = find.widgetWithText(
          DeckCard,
          'Simulator deck',
        );
        await _wait(tester, createdDeck);
        expect(createdDeck, findsOneWidget);
        await _tap(tester, createdDeck);
        await _wait(tester, find.byType(DeckFlyoutScreen));
        expect(find.byType(DeckFlyoutScreen), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey<String>('deck-options')));
        await _wait(tester, find.text('Deck options').hitTestable());
        expect(find.text('Rename Deck'), findsWidgets);
        expect(find.text('Mana curve & checks'), findsWidgets);
        await _tap(tester, find.text('Cancel'));
        await _tap(tester, find.text('From Collection'));
        await _wait(tester, find.text('Choose From Collection'));
        await _tap(tester, find.text('Lightning Bolt'));
        final Finder addDeckCopy = find.bySemanticsLabel(
          RegExp(r'^Add one (Lightning Bolt|card) to mainboard$'),
        );
        await _scrollTo(tester, addDeckCopy);
        await _tap(tester, addDeckCopy);
        final QuerySnapshot<MTGDeck> decks = await Crud.deck(uid).collection
            .get();
        expect(decks.docs.single.data().effectiveEntries.single.quantity, 2);
        expect((await Crud.card(uid).get(printing)).quantity, 7);
        await _checkpoint(tester, 'deck_editing');
        await _back(tester);
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('collection-mode-2')),
        );
        await _wait(tester, find.text('Collection estimate · 7 priced copies'));
        await _scrollTo(tester, find.text('2 priced · 0 unpriced copies'));
        await _wait(tester, find.text('USD 2.00'));
        final CollectionPrices prices = tester.widget<CollectionPrices>(
          find.byType(CollectionPrices),
        );
        debugPrint('APP_UI_PRICES_ACTIVE:${prices.active}');
        expect(prices.active, isTrue);
        for (final Element element
            in find
                .byWidgetPredicate(
                  (Widget widget) =>
                      widget
                          is StreamBuilder<QuerySnapshot<Map<String, dynamic>>>,
                )
                .evaluate()) {
          final StreamBuilder<QuerySnapshot<Map<String, dynamic>>> builder =
              element.widget
                  as StreamBuilder<QuerySnapshot<Map<String, dynamic>>>;
          debugPrint('APP_UI_QUERY_STREAM:null=${builder.stream == null}');
        }
        try {
          final QuerySnapshot<Map<String, dynamic>> orderedHistory =
              await profile
                  .collection('priceHistory')
                  .orderBy('observedAt', descending: true)
                  .limit(90)
                  .snapshots()
                  .first
                  .timeout(const Duration(seconds: 10));
          debugPrint(
            'APP_UI_ORDERED_HISTORY:count=${orderedHistory.docs.length}',
          );
        } catch (error) {
          debugPrint('APP_UI_ORDERED_HISTORY:failed=${error.runtimeType}');
        }
        final QuerySnapshot<Map<String, dynamic>> seededHistory = await profile
            .collection('priceHistory')
            .get();
        for (final QueryDocumentSnapshot<Map<String, dynamic>> observation
            in seededHistory.docs) {
          final Map<String, Object?> fields = observation.data();
          debugPrint(
            'APP_UI_PRICE_HISTORY:${observation.id}:'
            '${fields.entries.map<String>((MapEntry<String, Object?> field) => '${field.key}:${field.value.runtimeType}').join(',')}',
          );
        }
        await _checkpoint(tester, 'prices_before_history');
        await _scrollTo(tester, find.text('7 priced · 0 unpriced'));
        await _checkpoint(tester, 'prices_dark');
        await database.disableNetwork();
        for (final (String currency, String collectionValue, String deckValue)
            in <(String, String, String)>[
              ('EUR', 'EUR 14.00', 'EUR 4.00'),
              ('TIX', 'TIX 3.50', 'TIX 1.00'),
              ('USD', 'USD 7.00', 'USD 2.00'),
            ]) {
          await _tap(tester, find.text(currency));
          await _wait(tester, find.text(collectionValue));
          await _scrollTo(tester, find.text(deckValue));
          await _scrollTo(tester, find.text('7 priced · 0 unpriced'));
          await _checkpoint(tester, 'prices_cached_${currency.toLowerCase()}');
        }
        await database.enableNetwork();
        final DocumentReference<Map<String, dynamic>> unreadableObservation =
            profile.collection('priceHistory').doc('fixture-unreadable');
        await unreadableObservation.set(<String, Object?>{
          'observedAt': Timestamp.fromDate(DateTime.utc(2026, 10, 2)),
          'currency': 'usd',
          'total': 'invalid',
          'pricedCopies': 7,
          'unpricedCopies': 0,
        });
        await _scrollTo(
          tester,
          find.text('Some saved observations could not be read.'),
        );
        await _wait(
          tester,
          find.text('Some saved observations could not be read.'),
        );
        await _checkpoint(tester, 'prices_unreadable_observation');
        await unreadableObservation.delete();
        await _tap(tester, find.text('EUR'));
        await _tap(tester, find.text('USD'));
        await _scrollTo(tester, find.text('7 priced · 0 unpriced'));
        await _waitGone(
          tester,
          find.text('Some saved observations could not be read.'),
        );
        await _tap(tester, _tab('Collection'));

        await _tap(tester, _tab('Tabletop'));
        await _tap(tester, find.byKey(const ValueKey<String>('die-d20')));
        await _tap(tester, find.bySemanticsLabel('Add one die'));
        await _tap(tester, find.text('Roll 2d20'));
        await _wait(tester, find.text('Last roll · 2d20'));
        await _wait(
          tester,
          find.byWidgetPredicate(
            (Widget widget) =>
                widget is Text &&
                widget.key == const ValueKey<String>('dice-total') &&
                int.tryParse(widget.data ?? '') != null,
          ),
        );
        final Text total = tester.widget<Text>(
          find.byKey(const ValueKey<String>('dice-total')),
        );
        expect(int.parse(total.data!), inInclusiveRange(2, 40));
        await _checkpoint(tester, 'dice_result');
        await _tap(tester, find.text('Roll 2d20'));
        await _scrollTo(tester, find.text('History (1)'));
        await _tap(tester, find.text('History (1)'));
        await _wait(tester, find.text('Recent rolls'));
        await _tabletopMode(tester, 'number');
        await tester.enterText(
          find.byKey(const ValueKey<String>('number-minimum')),
          '3',
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('number-maximum')),
          '3',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        await _tap(tester, find.byKey(const ValueKey<String>('number-pick')));
        await _wait(
          tester,
          find.byWidgetPredicate(
            (Widget widget) =>
                widget is Text &&
                widget.key == const ValueKey<String>('number-result') &&
                widget.data == '3',
          ),
        );
        await _checkpoint(tester, 'number_result');
        await _tabletopMode(tester, 'life');
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('game-players-2')),
        );
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('game-new')),
        );
        await _wait(tester, find.text('Player 1'));
        await _tap(tester, find.text('+1'));
        await _wait(tester, find.text('21'));
        await _checkpoint(tester, 'life_counter');
        await _back(tester);
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('game-resume')),
        );
        await _wait(tester, find.text('21'));
        await _back(tester);

        await _tap(tester, _tab('Settings'));
        await _wait(tester, find.text('Commander'));
        await _tap(tester, find.widgetWithText(Tile, 'Commander'));
        await _wait(
          tester,
          find.descendant(
            of: find.widgetWithText(Tile, 'Commander'),
            matching: find.byWidgetPredicate(
              (Widget widget) => widget is Switch && widget.value,
            ),
          ),
        );
        expect((await Crud.user().get(uid)).showCommander, isTrue);
        await _tap(tester, find.widgetWithText(Tile, 'Light theme'));
        await _wait(
          tester,
          find.descendant(
            of: find.widgetWithText(Tile, 'Light theme'),
            matching: find.byWidgetPredicate(
              (Widget widget) => widget is Switch && widget.value,
            ),
          ),
        );
        expect((await Crud.user().get(uid)).theme, isTrue);
        await _checkpoint(tester, 'settings_light');
        await _tap(tester, _tab('Tabletop'));
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('game-format-commander')),
        );
        await _scrollTo(tester, find.text('Commander · 40 life'));
        await _wait(tester, find.text('Commander · 40 life'));
        await _checkpoint(tester, 'commander_enabled');

        await _tap(tester, _tab('Rules'));
        await tester.enterText(
          find.byKey(const ValueKey<String>('rules-card-query')),
          'Lightning Bolt',
        );
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('rules-card-search')),
        );
        await _wait(tester, find.text('Lightning Bolt').hitTestable());
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('rules-read-current')),
        );
        await _wait(
          tester,
          find.text('Lightning Bolt deals 3 damage to any target.'),
        );
        await _checkpoint(tester, 'card_rulings');
        await _back(tester);
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('rules-mode-game')),
        );
        await _scrollTo(
          tester,
          find.byKey(const ValueKey<String>('rules-rule-query')),
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('rules-rule-query')),
          '702.2a',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        await tester.pump();
        final Finder ruleNumber = find.byWidgetPredicate(
          (Widget widget) => widget is Text && widget.data == '702.2a',
        );
        await _wait(tester, ruleNumber.hitTestable());
        expect(ruleNumber, findsOneWidget);
        final ModalRoute<Object?> rulesRoute = ModalRoute.of(
          tester.element(find.byType(HubRules)),
        )!;
        expect(rulesRoute.isCurrent, isTrue);
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('rules-read-current')),
        );
        final Finder ruleBody = find.byWidgetPredicate(
          (Widget widget) =>
              widget is SelectableText &&
              widget.data?.toLowerCase().contains('deathtouch') == true,
        );
        await _wait(tester, ruleBody.hitTestable());
        expect(ruleBody, findsOneWidget);
        expect(ruleNumber.hitTestable(), findsOneWidget);
        final ModalRoute<Object?> detailRoute = ModalRoute.of(
          tester.element(ruleBody),
        )!;
        expect(detailRoute, isNot(same(rulesRoute)));
        expect(detailRoute.isCurrent, isTrue);
        expect(rulesRoute.isCurrent, isFalse);
        await _checkpoint(tester, 'game_rules');
        await _back(tester);
        await _tap(tester, _tab('Collection'));
        await _wait(
          tester,
          find.byKey(const ValueKey<String>('collection-mode-0')),
        );
        await _checkpoint(tester, 'home_light');
        await profile.delete();
        await _wait(tester, find.text('Could not load your account.'));
        await _tap(tester, find.text('Retry'));
        await _wait(
          tester,
          find.byKey(const ValueKey<String>('collection-mode-0')),
        );
        expect((await profile.get()).exists, isTrue);
        expect((await Crud.card(uid).get(printing)).quantity, 7);
        debugPrint(
          'APP_UI_VERIFIED: native offline and missing-profile retries, collection filters/details/artwork, Organize deck edit, inventory invariant, USD/EUR/TIX cached collection and printing history, malformed-history recovery, dice and Number, persisted life, theme, Commander, card and game rules, Cupertino edge return gestures',
        );
      } finally {
        semantics.dispose();
      }
    },
  );
}
