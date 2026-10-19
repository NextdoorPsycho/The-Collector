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
import 'package:the_collector/pages/collection/card/card_add_dialog.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/collection_ingestion.dart';

class _Catalog extends CardCatalog {
  final List<sf.MtgCard> cards;
  int calls = 0;
  _Catalog(sf.MtgCard card) : cards = <sf.MtgCard>[card];
  _Catalog.printings(this.cards);
  @override
  Future<sf.PaginableList<sf.MtgCard>> search(
    String query, {
    int page = 1,
    bool allPrintings = false,
  }) async {
    expect(allPrintings, isTrue);
    calls++;
    return sf.PaginableList<sf.MtgCard>(data: cards, hasMore: false);
  }
}

class _Ingestion extends CollectionIngestion {
  _Ingestion() : super(firestore: FakeFirebaseFirestore());
  final List<String> operations = <String>[];
  final List<int> quantities = <int>[];
  @override
  Future<IngestionResult> add({
    required String userId,
    required String operationId,
    required MTGCard card,
    int quantity = 1,
    String? deckId,
    DeckSection deckSection = DeckSection.mainboard,
  }) async {
    operations.add(operationId);
    quantities.add(quantity);
    expect(userId, 'alice');
    expect(card.finish, sf.Finish.foil);
    expect(card.language, 'en');
    if (operations.length == 1) {
      throw StateError('Simulated unavailable network');
    }
    return IngestionResult(
      cardId: card.scryfallId!,
      status: IngestionStatus.previouslyApplied,
    );
  }
}

sf.MtgCard _withoutArtwork(String id, String number) {
  final Map<String, Object?> json = Map<String, Object?>.from(
    jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<Object?, Object?>,
  );
  json['id'] = id;
  json['collector_number'] = number;
  json['finishes'] = <String>['nonfoil', 'foil'];
  json.remove('image_uris');
  json['card_faces'] = (json['card_faces'] as List<Object?>).map((
    Object? value,
  ) {
    final Map<String, Object?> face = Map<String, Object?>.from(
      value as Map<Object?, Object?>,
    );
    face.remove('image_uris');
    return face;
  }).toList();
  return sf.MtgCard.fromJson(json);
}

Future<void> _showPrintings(
  WidgetTester tester,
  _Catalog catalog,
  ThemeMode mode,
  double scale,
) async {
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
      home: Builder(
        builder: (BuildContext context) => PrimaryButton(
          onPressed: () => CardPrintingDialog(
            addToCollection: false,
            catalog: catalog,
          ).open<PrintingSelection>(context),
          child: const Text('Open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).hitTestable().first, 'dusk');
  await tester.ensureVisible(find.text('Search'));
  await tester.pumpAndSettle();
  expect(find.text('Search').hitTestable(), findsOneWidget);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
  final Finder choice = find
      .byKey(ValueKey<String>('printing-choice-${catalog.cards.first.id}'))
      .hitTestable();
  await tester.scrollUntilVisible(
    choice,
    80,
    scrollable: find
        .descendant(
          of: find.byType(ListView).hitTestable().first,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.ensureVisible(choice);
  await tester.tap(choice.hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    for (final double scale in <double>[1, 2.35]) {
      testWidgets(
        'missing artwork keeps editions searchable in ${mode.name} $scale',
        (WidgetTester tester) async {
          final _Catalog catalog = _Catalog.printings(<sf.MtgCard>[
            _withoutArtwork('first', '1'),
            _withoutArtwork('second', '2'),
          ]);
          addTearDown(catalog.close);
          await _showPrintings(tester, catalog, mode, scale);
          final Finder finish = find.byKey(
            const ValueKey<String>('printing-finish'),
          );
          await tester.ensureVisible(finish);
          await tester.pumpAndSettle();
          expect(finish.hitTestable(), findsOneWidget);
          expect(tester.getSize(finish).height, greaterThanOrEqualTo(44));
          await tester.tap(finish.hitTestable());
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(find.text('Foil').hitTestable().last);
          await tester.pumpAndSettle();
          final Finder second = find.byKey(
            const ValueKey<String>('printing-choice-second'),
          );
          await tester.scrollUntilVisible(
            second,
            80,
            scrollable: find
                .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          await tester.tap(second.hitTestable());
          await tester.pumpAndSettle();
          final Finder metadata = find.byKey(
            const ValueKey<String>('printing-metadata'),
          );
          await tester.scrollUntilVisible(
            metadata,
            -80,
            scrollable: find
                .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('#2').hitTestable(), findsWidgets);
          expect(catalog.calls, 1);
          await tester.ensureVisible(finish);
          await tester.pumpAndSettle();
          expect(find.text('Foil').hitTestable(), findsOneWidget);
          expect(
            find.byKey(const ValueKey<String>('printing-next')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey<String>('printing-previous')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey<String>('printing-cancel')).hitTestable(),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const ValueKey<String>('printing-cancel')).hitTestable(),
          );
          await tester.pumpAndSettle();
          expect(find.byType(CardPrintingDialog), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'large-text printing validation remains visible before confirming',
    (WidgetTester tester) async {
      final _Catalog catalog = _Catalog(_withoutArtwork('first', '1'));
      addTearDown(catalog.close);
      await _showPrintings(tester, catalog, ThemeMode.light, 2.35);
      final Finder copies = find.byKey(
        const ValueKey<String>('printing-copies'),
      );
      final Finder detailsScroll = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(copies, 80, scrollable: detailsScroll);
      await tester.pumpAndSettle();
      await tester.enterText(copies, '0');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add printing').hitTestable());
      await tester.pumpAndSettle();
      final Finder error = find.text('Enter a quantity from 1 to 1000000.');
      expect(error.hitTestable(), findsOneWidget);
      expect(find.byType(CardPrintingDialog), findsOneWidget);
      await tester.scrollUntilVisible(copies, 80, scrollable: detailsScroll);
      await tester.pumpAndSettle();
      await tester.enterText(copies, '2');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add printing').hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(CardPrintingDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Escape cancels printing selection without adding a card', (
    WidgetTester tester,
  ) async {
    final _Catalog catalog = _Catalog(_withoutArtwork('first', '1'));
    addTearDown(catalog.close);
    await _showPrintings(tester, catalog, ThemeMode.dark, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(CardPrintingDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reviewed manual addition validates quantity and retries with unchanged operation ID',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final Map<String, dynamic> fixture = jsonDecode(
        File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      fixture['finishes'] = <String>['nonfoil', 'foil'];
      final sf.MtgCard card = sf.MtgCard.fromJson(fixture);
      final _Catalog catalog = _Catalog(card);
      final _Ingestion ingestion = _Ingestion();
      addTearDown(catalog.close);
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.light),
          home: Builder(
            builder: (BuildContext context) => PrimaryButton(
              onPressed: () => CardPrintingDialog(
                catalog: catalog,
                ingestion: ingestion,
                userId: 'alice',
                groups: Stream<List<MTGDeck>>.value(const <MTGDeck>[]),
              ).open(context),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).hitTestable().first,
        'dusk',
      );
      await tester.tap(find.text('Search').hitTestable().first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(card.name).hitTestable().first);
      await tester.pumpAndSettle();
      expect(find.textContaining('EN'), findsWidgets);
      await tester.ensureVisible(find.byType(Selector<sf.Finish>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Normal').hitTestable().first);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('Foil').hitTestable().first);
      await tester.pumpAndSettle();
      final Finder quantity = find.byWidgetPredicate(
        (Widget widget) =>
            widget is TextField &&
            widget.placeholder is Text &&
            (widget.placeholder! as Text).data == 'Quantity',
      );
      await tester.ensureVisible(quantity);
      await tester.pumpAndSettle();
      await tester.enterText(quantity, '0');
      await tester.ensureVisible(find.text('Add to Collection'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to Collection').hitTestable().first);
      await tester.pumpAndSettle();
      expect(ingestion.operations, isEmpty);
      expect(find.text('Enter a quantity from 1 to 1000000.'), findsWidgets);
      final Finder selectedPane = find.byKey(
        const ValueKey<String>('printing-selected-details'),
      );
      if (find
          .descendant(of: selectedPane, matching: find.byType(Scrollable))
          .evaluate()
          .isNotEmpty) {
        await tester.scrollUntilVisible(
          quantity,
          80,
          scrollable: find
              .descendant(of: selectedPane, matching: find.byType(Scrollable))
              .first,
        );
      }
      await tester.ensureVisible(quantity);
      await tester.pumpAndSettle();
      await tester.enterText(quantity, '2');
      await tester.ensureVisible(find.text('Add to Collection'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to Collection').hitTestable().first);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Could not add this printing. Retry to finish the same addition.',
        ),
        findsWidgets,
      );
      await tester.ensureVisible(find.text('Add to Collection'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to Collection').hitTestable().first);
      await tester.pumpAndSettle();
      expect(ingestion.operations, hasLength(2));
      expect(ingestion.operations.first, ingestion.operations.last);
      expect(ingestion.quantities, <int>[2, 2]);
      expect(find.text('Open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'manual additions offer every container and preserve collection ownership',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionIngestion ingestion = CollectionIngestion(
        firestore: database,
      );
      final Map<String, Object?> fixture = Map<String, Object?>.from(
        jsonDecode(
          File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
        ) as Map<Object?, Object?>,
      );
      fixture['finishes'] = <String>['nonfoil'];
      final sf.MtgCard card = sf.MtgCard.fromJson(fixture);
      final _Catalog catalog = _Catalog(card);
      addTearDown(catalog.close);
      final List<MTGDeck> groups = <MTGDeck>[];
      for (final CollectionGroupKind kind in CollectionGroupKind.values) {
        final MTGDeck group = MTGDeck(name: 'Saved ${kind.name}', kind: kind)
          ..id = kind.name;
        groups.add(group);
        await database.doc('user/alice/decks/${kind.name}').set(group.toMap());
      }
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: Builder(
            builder: (BuildContext context) => PrimaryButton(
              onPressed: () => CardPrintingDialog(
                catalog: catalog,
                ingestion: ingestion,
                userId: 'alice',
                groups: Stream<List<MTGDeck>>.value(groups),
              ).open(context),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      for (final MTGDeck group in groups) {
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'dusk');
        await tester.tap(find.text('Search'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(ValueKey<String>('printing-choice-${card.id}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('printing-destination')),
        );
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(
          find.textContaining(': ${group.name}').hitTestable().last,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add to group'));
        await tester.pumpAndSettle();
        final MTGDeck saved = MTGDeckMapper.fromMap(
          (await database.doc('user/alice/decks/${group.id}').get()).data()!,
        );
        expect(saved.effectiveEntries.single.quantity, 1);
        expect(saved.effectiveEntries.single.section, DeckSection.mainboard);
        expect(find.byType(CardPrintingDialog), findsNothing);
      }
      expect(
        (await database.doc('user/alice/cards/${card.id}').get())
            .data()!['quantity'],
        CollectionGroupKind.values.length,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
