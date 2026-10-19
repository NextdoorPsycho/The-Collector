import 'package:arcane/arcane.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/deck/deck.dart';
import 'package:the_collector/pages/collection/card/card_thumbnail.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';

void main() {
  testWidgets(
    'search owned printings adds to a container without changing inventory',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionStore<MTGDeck> groups = CollectionStore<MTGDeck>(
        collection: database.collection('user/alice/decks'),
        toMap: (MTGDeck group) => group.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGDeckMapper.fromMap(data)..id = id,
      );
      final CollectionStore<MTGCard> inventory = CollectionStore<MTGCard>(
        collection: database.collection('user/alice/cards'),
        toMap: (MTGCard card) => card.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGCardMapper.fromMap(data)..id = id,
      );
      final MTGDeck group = MTGDeck(
        name: 'Trade binder',
        kind: CollectionGroupKind.binder,
      )..id = 'binder';
      await groups.set('binder', group);
      final MTGCard card = MTGCard(
        name: 'Stored spell',
        setId: 'set',
        description: '',
        flavorText: '',
        cmc: 2,
        typeLine: 'Instant',
        rarity: sf.Rarity.common,
        setType: sf.SetType.expansion,
        manaCost: '{1}{U}',
        scryfallId: 'd88a8e2d-2577-4a67-af86-e33c0ba94114',
        finish: sf.Finish.foil,
        language: 'en',
        quantity: 7,
      )..id = 'printing-foil';
      await inventory.set(card.id!, card);
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: DeckFlyoutScreen(
            deck: group,
            store: groups,
            inventory: inventory,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('From Collection'));
      await tester.pumpAndSettle();
      final Finder ownedRow = find.byKey(
        ValueKey<String>('owned-printing-${card.id}'),
      );
      expect(
        find.descendant(of: ownedRow, matching: find.textContaining('7 owned')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: ownedRow,
          matching: find.textContaining('foil · EN'),
        ),
        findsOneWidget,
      );
      final Finder artwork = find.descendant(
        of: ownedRow,
        matching: find.byType(CardThumbnail),
      );
      expect(artwork, findsOneWidget);
      expect(tester.getSize(artwork).width, 42);
      expect(tester.getSize(ownedRow).height, greaterThanOrEqualTo(44));
      final Finder search = find.byKey(
        const ValueKey<String>('inventory-picker-search'),
      );
      await tester.enterText(search, 'absent');
      await tester.pumpAndSettle();
      expect(find.text('No owned cards match.'), findsOneWidget);
      expect((await groups.get('binder')).effectiveEntries, isEmpty);
      expect(find.text('Cancel').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Cancel').hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('inventory-picker-search')),
        findsNothing,
      );
      expect((await groups.get('binder')).effectiveEntries, isEmpty);
      expect((await inventory.get(card.id!)).quantity, 7);
      // The fake Firestore subject replays cached snapshots outside fake time.
      await tester.runAsync(() async {
        await tester.tap(find.text('From Collection').hitTestable());
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(
        find.text('Could not load collection printings. Retry.'),
        findsNothing,
      );
      expect(search.hitTestable(), findsOneWidget);
      await tester.enterText(search, 'Stored');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stored spell'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('inventory-picker-search')),
        findsNothing,
      );
      final DeckEntry entry = (await groups.get('binder'))
          .effectiveEntries
          .single;
      expect(entry.quantity, 1);
      expect(entry.scryfallId, card.scryfallId);
      expect(entry.finish, sf.Finish.foil);
      expect(entry.language, 'en');
      expect((await inventory.get(card.id!)).quantity, 7);
      expect(find.byType(CardThumbnail), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  Future<void> choose(WidgetTester tester, String label) async {
    await Scrollable.ensureVisible(
      tester.element(find.text(label).first),
      alignment: .5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).hitTestable());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a remotely deleted deck cannot remain as an editable saved board',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final MTGDeck deck = MTGDeck(name: 'Removed deck')..id = 'removed';
      final CollectionStore<MTGDeck> store = CollectionStore<MTGDeck>(
        collection: database.collection('user/alice/decks'),
        toMap: (MTGDeck deck) => deck.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGDeckMapper.fromMap(data)..id = id,
      );
      await store.set(deck.id!, deck);
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: DeckFlyoutScreen(deck: deck, store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Search Cards'), findsOneWidget);
      await store.delete(deck.id!);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This deck has been deleted. Return to your decks to choose another.',
        ),
        findsOneWidget,
      );
      expect(find.text('Search Cards'), findsNothing);
      expect(find.byIcon(Icons.trash), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('320px deck list retains full names at large text', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    const String name = 'My very long deck name for a multiplayer night';
    final CollectionStore<MTGDeck> store = CollectionStore<MTGDeck>(
      collection: database.collection('user/alice/decks'),
      toMap: (MTGDeck deck) => deck.toMap(),
      fromMap: (String id, Map<String, Object?> data) =>
          MTGDeckMapper.fromMap(data)..id = id,
    );
    await store.set('deck', MTGDeck(name: name));
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.light),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(1.8),
          ),
          child: CollectionDecks(store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(name), findsOneWidget);
    expect(tester.widget<Text>(find.text(name)).maxLines, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'changing deck copies and removing final entry preserves inventory and old references',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      const String printing = 'd88a8e2d-2577-4a67-af86-e33c0ba94114';
      final MTGDeck deck = MTGDeck(
        name: 'Existing deck',
        cards: <String>[printing],
      )..id = 'deck';
      await database.doc('user/alice/decks/deck').set(deck.toMap());
      await database.doc('user/alice/cards/$printing').set(<String, Object?>{
        'quantity': 7,
      });
      final CollectionStore<MTGDeck> store = CollectionStore<MTGDeck>(
        collection: database.collection('user/alice/decks'),
        toMap: (MTGDeck deck) => deck.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGDeckMapper.fromMap(data)..id = id,
      );
      final MTGCard metadata = MTGCard(
        name: 'Stored spell',
        setId: 'set',
        description: '',
        flavorText: '',
        cmc: 2,
        typeLine: 'Instant',
        rarity: sf.Rarity.common,
        setType: sf.SetType.expansion,
        manaCost: '{1}{U}',
      );
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.light),
          home: DeckFlyoutScreen(
            deck: deck,
            store: store,
            metadata: <String, MTGCard>{printing: metadata},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Add one Stored spell to mainboard'),
        findsNothing,
      );
      await tester.tap(find.text('Stored spell'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.bySemanticsLabel('Add one Stored spell to mainboard'),
      );
      await tester.pumpAndSettle();
      final DocumentSnapshot<Map<String, dynamic>> stored = await database
          .doc('user/alice/decks/deck')
          .get();
      expect(
        MTGDeckMapper.fromMap(stored.data()!).effectiveEntries.single.quantity,
        2,
      );
      expect(
        (await database.doc('user/alice/cards/$printing').get())
            .data()!['quantity'],
        7,
      );
      await tester.tap(
        find.bySemanticsLabel('Stored spell options in mainboard'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove').hitTestable());
      await tester.pumpAndSettle();
      final MTGDeck emptied = MTGDeckMapper.fromMap(
        (await database.doc('user/alice/decks/deck').get()).data()!,
      );
      expect(emptied.effectiveEntries, isEmpty);
      expect(emptied.cards, <String>[printing]);
      expect(
        find.text('No deck entries yet. Add a printing to start building.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'compact deck workflows remain usable at 320px and 2.35 text in ${mode.name}',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final FakeFirebaseFirestore database = FakeFirebaseFirestore();
        const String printing = 'd88a8e2d-2577-4a67-af86-e33c0ba94114';
        final MTGCard card = MTGCard(
          name: 'Stored spell',
          setId: 'set',
          description: '',
          flavorText: '',
          cmc: 2,
          typeLine: 'Instant',
          manaCost: '{1}{U}',
          rarity: sf.Rarity.common,
          setType: sf.SetType.expansion,
          scryfallId: printing,
          finish: sf.Finish.nonfoil,
          language: 'en',
          quantity: 7,
        )..id = 'printing';
        final CollectionStore<MTGDeck> store = CollectionStore<MTGDeck>(
          collection: database.collection('user/alice/decks'),
          toMap: (MTGDeck deck) => deck.toMap(),
          fromMap: (String id, Map<String, Object?> data) =>
              MTGDeckMapper.fromMap(data)..id = id,
        );
        final CollectionStore<MTGCard> inventory = CollectionStore<MTGCard>(
          collection: database.collection('user/alice/cards'),
          toMap: (MTGCard card) => card.toMap(),
          fromMap: (String id, Map<String, Object?> data) =>
              MTGCardMapper.fromMap(data)..id = id,
        );
        await inventory.set('printing', card);
        final MTGDeck deck = MTGDeck(name: 'My deck', cards: <String>[printing])
          ..id = 'deck';
        await store.set('deck', deck);
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(mode),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2.35),
              ),
              child: DeckFlyoutScreen(
                deck: deck,
                store: store,
                inventory: inventory,
                metadata: <String, MTGCard>{printing: card},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Mana curve & checks'), findsNothing);
        expect(find.textContaining('sideboard •'), findsNothing);
        await tester.tap(find.byKey(const ValueKey<String>('deck-options')));
        await tester.pumpAndSettle();
        await choose(tester, 'Format: casual');
        await choose(tester, 'standard');
        expect((await store.get('deck')).format, DeckFormat.standard);
        await tester.tap(find.byKey(const ValueKey<String>('deck-options')));
        await tester.pumpAndSettle();
        await choose(tester, 'Mana curve & checks');
        expect(find.text('Mainboard nonlands').hitTestable(), findsOneWidget);
        await choose(tester, 'Done');
        await tester.scrollUntilVisible(
          find.text('Stored spell'),
          100,
          scrollable: find
              .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await choose(tester, 'Stored spell');
        await tester.scrollUntilVisible(
          find.bySemanticsLabel('Stored spell options in mainboard'),
          100,
          scrollable: find
              .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await Scrollable.ensureVisible(
          tester.element(
            find.bySemanticsLabel('Stored spell options in mainboard'),
          ),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.bySemanticsLabel('Stored spell options in mainboard'),
        );
        await tester.pumpAndSettle();
        await choose(tester, 'Move to sideboard');
        expect(
          (await store.get('deck')).effectiveEntries.single.section,
          DeckSection.sideboard,
        );
        await tester.scrollUntilVisible(
          find.text('From Collection'),
          -120,
          scrollable: find
              .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await Scrollable.ensureVisible(
          tester.element(find.text('From Collection')),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('From Collection'));
        await tester.pumpAndSettle();
        await choose(tester, 'Stored spell');
        expect((await store.get('deck')).effectiveEntries, hasLength(2));
        expect((await inventory.get('printing')).quantity, 7);
        await tester.tap(find.byKey(const ValueKey<String>('deck-options')));
        await tester.pumpAndSettle();
        await choose(tester, 'Delete Deck');
        await choose(tester, 'Cancel');
        expect((await store.get('deck')).name, 'My deck');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
