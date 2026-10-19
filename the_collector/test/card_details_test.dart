import 'dart:convert';
import 'dart:io';

import 'package:arcane/arcane.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/card/card.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/crud.dart';

import 'helpers/load_collector_fonts.dart';

class _Catalog extends CardCatalog {
  @override
  Future<Map<String, sf.MtgCard>> printings(Iterable<String> ids) async =>
      <String, sf.MtgCard>{};
}

class _CommitThenThrowFirestore extends FakeFirebaseFirestore {
  bool failGroupCommit = false;
  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    final T result = await super.runTransaction<T>(
      transactionHandler,
      timeout: timeout,
      maxAttempts: maxAttempts,
    );
    if (failGroupCommit) {
      failGroupCommit = false;
      throw StateError('Test committed transaction with lost acknowledgment');
    }
    return result;
  }
}

class _Groups extends CollectionStore<MTGDeck> {
  bool failMembership = false;
  int attempts = 0;
  _Groups(FakeFirebaseFirestore database)
    : super(
        collection: database.collection('user/alice/decks'),
        toMap: (MTGDeck group) => group.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGDeckMapper.fromMap(data)..id = id,
      );
  @override
  Future<void> txn(String id, MTGDeck Function(MTGDeck group) update) async {
    attempts++;
    if (failMembership) {
      failMembership = false;
      throw StateError('Test offline membership write');
    }
    await super.txn(id, update);
  }
}

Future<({MTGCard card, CollectionStore<MTGCard> cards, _Groups groups})>
_stores({int quantity = 7}) async {
  final FakeFirebaseFirestore database = _CommitThenThrowFirestore();
  final sf.MtgCard printing = sf.MtgCard.fromJson(
    jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<String, Object?>,
  );
  final MTGCard card =
      cardFromScryfall(printing, finish: sf.Finish.nonfoil).copyWith(
        quantity: quantity,
        imageUrl: null,
        backImageUrl: null,
      )..id = printing.id;
  final CollectionStore<MTGCard> cards = CollectionStore<MTGCard>(
    collection: database.collection('user/alice/cards'),
    toMap: (MTGCard card) => card.toMap(),
    fromMap: (String id, Map<String, Object?> data) =>
        MTGCardMapper.fromMap(data)..id = id,
  );
  await cards.set(card.id!, card);
  return (card: card, cards: cards, groups: _Groups(database));
}

Future<void> _show(
  WidgetTester tester,
  ({MTGCard card, CollectionStore<MTGCard> cards, _Groups groups}) stores, {
  ThemeMode theme = ThemeMode.dark,
  double scale = 1,
  bool injectGroups = true,
}) async {
  final _Catalog catalog = _Catalog();
  addTearDown(catalog.close);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(theme),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: CardFlyoutScreen(
        card: stores.card,
        store: stores.cards,
        groups: injectGroups ? stores.groups : null,
        catalog: catalog,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      100,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await Scrollable.ensureVisible(tester.element(finder.first), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(finder.hitTestable().first);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadCollectorFonts);
  testWidgets(
    'card summary offers markets and owned copies without a route change',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ({MTGCard card, CollectionStore<MTGCard> cards, _Groups groups})
      stores = await _stores();
      await _show(tester, stores);
      expect(find.text('Card').hitTestable(), findsOneWidget);
      expect(find.text('Value').hitTestable(), findsOneWidget);
      expect(find.text('Locations').hitTestable(), findsOneWidget);
      expect(find.text('7 owned'), findsOneWidget);
      await tester.tap(find.text('Value'));
      await tester.pumpAndSettle();
      expect(find.text('TCGplayer'), findsOneWidget);
      expect(find.text('Cardmarket'), findsOneWidget);
      expect(find.byType(CardFlyoutScreen), findsOneWidget);
      await tester.tap(find.text('Locations'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('card-owned-printings')),
        findsOneWidget,
      );
      expect((await stores.cards.get(stores.card.id!)).quantity, 7);
      expect(tester.takeException(), isNull);
    },
  );
  for (final ThemeMode theme in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'membership retains destination and save above number keyboard in ${theme.name}',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final ({MTGCard card, CollectionStore<MTGCard> cards, _Groups groups})
        stores = await _stores();
        await stores.groups.set(
          'binder',
          MTGDeck(name: 'Binder trades', kind: CollectionGroupKind.binder),
        );
        await _show(tester, stores, theme: theme, scale: 2.35);
        await _tap(tester, find.text('Organize'));
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('organize-group-binder')),
        );
        final Finder copies = find.byKey(
          const ValueKey<String>('group-copies'),
        );
        await tester.enterText(copies, '2');
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        for (final Finder control in <Finder>[
          find.byKey(const ValueKey<String>('organization-destination')),
          find.byKey(const ValueKey<String>('organization-save')),
          find.text('Cancel'),
        ]) {
          final Rect bounds = tester.getRect(control);
          expect(bounds.top, greaterThanOrEqualTo(0));
          expect(bounds.bottom, lessThanOrEqualTo(308));
        }
        expect(find.text('Binder trades').hitTestable(), findsOneWidget);
        expect(stores.groups.attempts, 0);
        await tester.tap(
          find.byKey(const ValueKey<String>('organization-save')),
        );
        await tester.pumpAndSettle();
        expect(
          (await stores.groups.get('binder')).effectiveEntries.single.quantity,
          2,
        );
        expect(stores.groups.attempts, 1);
        expect((await stores.cards.get(stores.card.id!)).quantity, 7);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
    testWidgets(
      'existing container opens its saved section directly in ${theme.name}',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final ({MTGCard card, CollectionStore<MTGCard> cards, _Groups groups})
        stores = await _stores();
        await stores.groups.set(
          'friday',
          MTGDeck(
            name: 'Friday deck',
            entries: <DeckEntry>[
              DeckEntry(
                scryfallId: stores.card.printingId!,
                finish: stores.card.finish,
                language: stores.card.language,
                quantity: 2,
                section: DeckSection.sideboard,
              ),
            ],
          ),
        );
        await _show(tester, stores, theme: theme, scale: 2);
        await _tap(tester, find.text('Locations'));
        final Finder membership = find.byKey(
          const ValueKey<String>('card-membership-friday'),
        );
        await _tap(tester, membership);
        expect(
          find.byKey(const ValueKey<String>('organize-group-friday')),
          findsNothing,
          reason: 'A known destination does not require a second selection.',
        );
        final Finder copies = find.byKey(
          const ValueKey<String>('group-copies'),
        );
        expect(tester.widget<TextField>(copies).controller!.text, '2');
        expect(
          tester
              .widget<Selector<DeckSection>>(
                find
                    .byWidgetPredicate(
                      (Widget widget) => widget is Selector<DeckSection>,
                    )
                    .first,
              )
              .value,
          DeckSection.sideboard,
        );
        await tester.enterText(copies, '4');
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('organization-save')),
        );
        final DeckEntry entry = (await stores.groups.get('friday'))
            .effectiveEntries
            .single;
        expect(entry.quantity, 4);
        expect(entry.section, DeckSection.sideboard);
        expect(stores.groups.attempts, 1);
        expect((await stores.cards.get(stores.card.id!)).quantity, 7);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  for (final double scale in <double>[1, 2]) {
    testWidgets(
      'organization offers compact named rows at 320px scale $scale',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final ({MTGCard card, CollectionStore<MTGCard> cards, _Groups groups})
        stores = await _stores();
        for (final CollectionGroupKind kind in CollectionGroupKind.values) {
          await stores.groups.set(
            kind.name,
            MTGDeck(name: '${kind.name} cards', kind: kind),
          );
        }
        await _show(tester, stores, scale: scale);
        await _tap(tester, find.text('Organize'));
        final Finder binder = find.byKey(
          const ValueKey<String>('organize-group-binder'),
        );
        await tester.ensureVisible(binder);
        await tester.pumpAndSettle();
        expect(tester.widget(binder), isA<Tile>());
        expect(
          find.descendant(of: binder, matching: find.byType(OutlineButton)),
          findsNothing,
        );
        expect(find.text('binder cards'), findsOneWidget);
        expect(tester.getSize(binder).height, greaterThanOrEqualTo(44));
        await _tap(tester, binder);
        expect(
          find.byKey(const ValueKey<String>('group-copies')),
          findsOneWidget,
        );
        await _tap(tester, find.text('Cancel'));
        expect((await stores.groups.get('binder')).effectiveEntries, isEmpty);
        expect((await stores.cards.get(stores.card.id!)).quantity, 7);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'organization replaces membership and never increments owned copies',
    (WidgetTester tester) async {
      final ({MTGCard card, CollectionStore<MTGCard> cards, _Groups groups})
      stores = await _stores();
      await stores.groups.set(
        'binder',
        MTGDeck(name: 'Blue binder', kind: CollectionGroupKind.binder),
      );
      await _show(tester, stores, injectGroups: false);
      for (final String copies in <String>['2', '2', '0']) {
        await _tap(tester, find.text('Organize'));
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('organize-group-binder')),
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('group-copies')),
          copies,
        );
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('organization-save')),
        );
        final MTGDeck binder = await stores.groups.get('binder');
        expect(binder.effectiveEntries.length, copies == '0' ? 0 : 1);
        if (copies != '0') expect(binder.effectiveEntries.single.quantity, 2);
        expect((await stores.cards.get(stores.card.id!)).quantity, 7);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'create membership retry reuses created group and cancellation writes nothing',
    (WidgetTester tester) async {
      final ({MTGCard card, CollectionStore<MTGCard> cards, _Groups groups})
      stores = await _stores();
      await _show(tester, stores);
      await _tap(tester, find.text('Organize'));
      await _tap(tester, find.text('New group'));
      await tester.enterText(find.byType(TextField).first, 'Friday cards');
      await _tap(tester, find.text('Cancel'));
      expect((await stores.groups.collection.get()).docs, isEmpty);
      await _tap(tester, find.text('Organize'));
      await _tap(tester, find.text('New group'));
      await tester.enterText(find.byType(TextField).first, 'Friday cards');
      stores.groups.failMembership = true;
      await _tap(
        tester,
        find.byKey(const ValueKey<String>('organization-save')),
      );
      expect(
        find.text(
          'Could not save organization. Retry. Your owned count is unchanged.',
        ),
        findsOneWidget,
      );
      expect((await stores.groups.collection.get()).docs.length, 1);
      await _tap(
        tester,
        find.byKey(const ValueKey<String>('organization-save')),
      );
      final List<MTGDeck> groups = (await stores.groups.collection.get()).docs
          .map((QueryDocumentSnapshot<MTGDeck> document) => document.data())
          .toList();
      expect(groups.length, 1);
      expect(groups.single.effectiveEntries.single.quantity, 1);
      expect(stores.groups.attempts, 2);
      expect((await stores.cards.get(stores.card.id!)).quantity, 7);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'group creation retry is idempotent after committed write loses acknowledgment',
    (WidgetTester tester) async {
      final ({MTGCard card, CollectionStore<MTGCard> cards, _Groups groups})
      stores = await _stores();
      await _show(tester, stores);
      await _tap(tester, find.text('Organize'));
      await _tap(tester, find.text('New group'));
      await tester.enterText(find.byType(TextField).first, 'Committed group');
      final _CommitThenThrowFirestore database =
          stores.groups.collection.firestore as _CommitThenThrowFirestore;
      database.failGroupCommit = true;
      await _tap(
        tester,
        find.byKey(const ValueKey<String>('organization-save')),
      );
      expect((await stores.groups.collection.get()).docs.length, 1);
      expect(
        (await stores.groups.collection.get()).docs.single
            .data()
            .effectiveEntries,
        isEmpty,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).first).enabled,
        isFalse,
      );
      await _tap(
        tester,
        find.byKey(const ValueKey<String>('organization-save')),
      );
      final List<QueryDocumentSnapshot<MTGDeck>> groups =
          (await stores.groups.collection.get()).docs;
      expect(groups.length, 1);
      expect(groups.single.data().name, 'Committed group');
      expect(groups.single.data().effectiveEntries.single.quantity, 1);
      expect((await stores.cards.get(stores.card.id!)).quantity, 7);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'organization Escape closes after choosing a group without writing',
    (WidgetTester tester) async {
      final ({MTGCard card, CollectionStore<MTGCard> cards, _Groups groups})
      stores = await _stores();
      await stores.groups.set(
        'list',
        MTGDeck(name: 'Trade list', kind: CollectionGroupKind.list),
      );
      await _show(tester, stores);
      await _tap(tester, find.text('Organize'));
      await _tap(
        tester,
        find.byKey(const ValueKey<String>('organize-group-list')),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('organization-save')),
        findsNothing,
      );
      expect((await stores.groups.get('list')).effectiveEntries, isEmpty);
      expect((await stores.cards.get(stores.card.id!)).quantity, 7);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'removing last owned copy requires deliberate delete confirmation',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        final ({MTGCard card, CollectionStore<MTGCard> cards, _Groups groups})
        stores = await _stores(quantity: 1);
        await _show(tester, stores);
        await _tap(tester, find.bySemanticsLabel('Remove one copy'));
        expect(find.text('Delete Printing'), findsWidgets);
        await _tap(tester, find.text('Cancel'));
        expect((await stores.cards.get(stores.card.id!)).quantity, 1);
        await _tap(tester, find.bySemanticsLabel('Add one copy'));
        expect((await stores.cards.get(stores.card.id!)).quantity, 2);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final ThemeMode theme in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    for (final double scale in <double>[1, 2.0]) {
      testWidgets(
        'compact card and group keyboard controls at 320px $scale ${theme.name}',
        (WidgetTester tester) async {
          final TargetPlatform? previous = debugDefaultTargetPlatformOverride;
          try {
            debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
            tester.view.physicalSize = const Size(320, 568);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetViewInsets);
            final ({
              MTGCard card,
              CollectionStore<MTGCard> cards,
              _Groups groups,
            })
            stores = await _stores();
            await _show(tester, stores, theme: theme, scale: scale);
            expect(find.text('Card Details'), findsNothing);
            expect(find.text('Artwork unavailable'), findsOneWidget);
            expect(find.text('EN · Normal'), findsOneWidget);
            expect(
              find.byType(ListView),
              scale == 1 ? findsNothing : findsOneWidget,
            );
            for (final String label in <String>[
              'Organize',
              'Value',
              'Printings',
            ]) {
              if (scale > 1) {
                final ScrollableState list = tester.state<ScrollableState>(
                  find
                      .descendant(
                        of: find.byType(ListView),
                        matching: find.byType(Scrollable),
                      )
                      .first,
                );
                list.position.jumpTo(list.position.minScrollExtent);
                await tester.pumpAndSettle();
              }
              if (find.text(label).evaluate().isEmpty) {
                await tester.scrollUntilVisible(
                  find.text(label),
                  100,
                  scrollable: find
                      .descendant(
                        of: find.byType(ListView),
                        matching: find.byType(Scrollable),
                      )
                      .first,
                );
              }
              await tester.ensureVisible(find.text(label));
              await tester.pumpAndSettle();
              final RenderParagraph text = tester.renderObject<RenderParagraph>(
                find.text(label),
              );
              expect(
                text.getBoxesForSelection(
                  TextSelection(baseOffset: 0, extentOffset: label.length),
                ),
                hasLength(1),
                reason: '$label stays on one line at text scale $scale',
              );
            }
            if (scale > 1) {
              final ScrollableState list = tester.state<ScrollableState>(
                find
                    .descendant(
                      of: find.byType(ListView),
                      matching: find.byType(Scrollable),
                    )
                    .first,
              );
              list.position.jumpTo(list.position.minScrollExtent);
              await tester.pumpAndSettle();
            }
            await _tap(tester, find.text('Organize'));
            await _tap(tester, find.text('New group'));
            await tester.enterText(find.byType(TextField).first, 'Shelf');
            tester.view.viewInsets = const FakeViewPadding(bottom: 220);
            await tester.pumpAndSettle();
            await _tap(tester, find.text('Cancel'));
            tester.view.resetViewInsets();
            await tester.pumpAndSettle();
            expect((await stores.groups.collection.get()).docs, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            debugDefaultTargetPlatformOverride = previous;
          }
        },
      );
    }
  }
}
