import 'package:arcane/arcane.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/pages/collection/deck/deck.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/theme/components/collector_dock.dart';
import 'package:the_collector/utils/crud.dart';

import 'helpers/load_collector_fonts.dart';

CollectionStore<MTGDeck> _store(FakeFirebaseFirestore database) =>
    CollectionStore<MTGDeck>(
      collection: database.collection('user/alice/decks'),
      toMap: (MTGDeck group) => group.toMap(),
      fromMap: (String id, Map<String, Object?> data) =>
          MTGDeckMapper.fromMap(data)..id = id,
    );

void main() {
  setUpAll(loadCollectorFonts);
  for (final int count in <int>[0, 1]) {
    testWidgets('pulling down reveals search with $count containers', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final CollectionStore<MTGDeck> store = _store(FakeFirebaseFirestore());
      if (count == 1) {
        await store.set(
          'binder',
          MTGDeck(name: 'Trades', kind: CollectionGroupKind.binder),
        );
      }
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: CollectionDecks(store: store),
        ),
      );
      await tester.pumpAndSettle();
      final Finder search = find.byKey(
        const ValueKey<String>('container-search'),
      );
      expect(search, findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, 160));
      await tester.pumpAndSettle();
      expect(search.hitTestable(), findsOneWidget);
      if (count == 1) {
        await tester.enterText(search, 'missing');
        await tester.pumpAndSettle();
        expect(find.text('Trades'), findsNothing);
        await tester.enterText(search, 'Trades');
        await tester.pumpAndSettle();
        expect(find.text('Trades').last, findsOneWidget);
        expect((await store.get('binder')).name, 'Trades');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('created group opens once when Containers becomes active', (
    WidgetTester tester,
  ) async {
    final CollectionStore<MTGDeck> groups = _store(FakeFirebaseFirestore());
    await groups.set(
      'folder',
      MTGDeck(name: 'Archive', kind: CollectionGroupKind.folder),
    );
    await groups.set(
      'binder',
      MTGDeck(
        name: 'Imported binder',
        kind: CollectionGroupKind.binder,
        parentId: 'folder',
      ),
    );
    final ValueNotifier<(String?, bool)> request =
        ValueNotifier<(String?, bool)>(('binder', false));
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        home: ValueListenableBuilder<(String?, bool)>(
          valueListenable: request,
          builder:
              (BuildContext context, (String?, bool) value, Widget? child) =>
                  CollectionDecks(
                    store: groups,
                    openGroupId: value.$1,
                    active: value.$2,
                    onScan: (MTGDeck _) async {},
                  ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(DeckFlyoutScreen), findsNothing);
    request.value = ('binder', true);
    await tester.pumpAndSettle();
    final DeckFlyoutScreen detail = tester.widget<DeckFlyoutScreen>(
      find.byType(DeckFlyoutScreen),
    );
    expect(detail.deck.id, 'binder');
    Navigator.of(tester.element(find.byType(DeckFlyoutScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(DeckFlyoutScreen), findsNothing);
    request.value = ('folder', true);
    await tester.pumpAndSettle();
    expect(find.text('Imported binder'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('group-scan-cards')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    request.dispose();
  });
  testWidgets(
    'folder shows child containers and direct cards in one workspace',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionStore<MTGDeck> groups = _store(database);
      await groups.set(
        'folder',
        MTGDeck(
          name: 'Trade stock',
          kind: CollectionGroupKind.folder,
          entries: const <DeckEntry>[
            DeckEntry(scryfallId: 'folder-print', quantity: 3),
          ],
        ),
      );
      await groups.set(
        'box',
        MTGDeck(
          name: 'Commons box',
          kind: CollectionGroupKind.box,
          parentId: 'folder',
        ),
      );
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: CollectionDecks(store: groups, onScan: (MTGDeck _) async {}),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trade stock'));
      await tester.pumpAndSettle();
      expect(find.text('Commons box'), findsOneWidget);
      expect(find.text('folder-print'), findsOneWidget);
      expect(find.text('Cards in folder'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('group-scan-cards')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final ThemeMode theme in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'container creation keeps every action above the keyboard at 2.35 text ${theme.name}',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final CollectionStore<MTGDeck> store = _store(FakeFirebaseFirestore());
        final List<String> scanned = <String>[];
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(theme),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2.35)),
              child: child!,
            ),
            home: CollectionDecks(
              store: store,
              onScan: (MTGDeck group) async => scanned.add(group.id!),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create').hitTestable());
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('create-kind-binder')),
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('group-name')),
          'Keyboard binder',
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        for (final String action in <String>[
          'group-cancel',
          'group-create',
          'group-create-scan',
        ]) {
          final Finder button = find.byKey(ValueKey<String>(action));
          expect(button.hitTestable(), findsOneWidget);
          final Rect bounds = tester.getRect(button);
          expect(bounds.top, greaterThanOrEqualTo(0));
          expect(bounds.bottom, lessThanOrEqualTo(308));
          expect(bounds.height, greaterThanOrEqualTo(44));
        }
        expect((await store.collection.get()).docs, isEmpty);
        await tester.tap(
          find.byKey(const ValueKey<String>('group-create-scan')),
        );
        await tester.pumpAndSettle();
        final MTGDeck group = (await store.collection.get()).docs.single.data();
        expect(group.name, 'Keyboard binder');
        expect(group.kind, CollectionGroupKind.binder);
        expect(scanned, <String>[group.id!]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'single-sheet creation and direct scanning preserve destinations at 320px in $mode',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final CollectionStore<MTGDeck> store = _store(FakeFirebaseFirestore());
        final List<String> scanned = <String>[];
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(mode),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 568),
                textScaler: TextScaler.linear(2),
              ),
              child: CollectionDecks(
                store: store,
                onScan: (MTGDeck group) async {
                  scanned.add(group.id!);
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create').hitTestable());
        await tester.pumpAndSettle();
        expect(find.text('New container').hitTestable(), findsOneWidget);
        await tester.ensureVisible(
          find
              .byKey(const ValueKey<String>('create-kind-binder'))
              .hitTestable(),
        );
        await tester.tap(
          find
              .byKey(const ValueKey<String>('create-kind-binder'))
              .hitTestable(),
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('group-name')).hitTestable(),
          'Trades',
        );
        await tester.pumpAndSettle();
        final Finder confirm = find.text('Create and scan').last;
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        await tester.tap(confirm.hitTestable());
        await tester.pumpAndSettle();
        final MTGDeck group = (await store.collection.get()).docs.single.data();
        expect(group.kind, CollectionGroupKind.binder);
        expect(group.name, 'Trades');
        expect(scanned, <String>[group.id!]);
        final Finder scan = find.byKey(
          ValueKey<String>('scan-group-${group.id}'),
        );
        await tester.ensureVisible(scan);
        await tester.pumpAndSettle();
        await tester.tap(scan);
        await tester.pumpAndSettle();
        expect(scanned, <String>[group.id!, group.id!]);
        await tester.tap(
          find.bySemanticsLabel('Search containers').hitTestable(),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey<String>('container-search')),
          'no match',
        );
        await tester.pumpAndSettle();
        expect(find.text('Trades'), findsNothing);
        expect((await store.get(group.id!)).effectiveEntries, isEmpty);
        await tester.enterText(
          find.byKey(const ValueKey<String>('container-search')),
          'Trades',
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(DeckCard),
            matching: find.text('Trades'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  for (final CollectionGroupKind kind in CollectionGroupKind.values) {
    testWidgets(
      'existing ${kind.name} starts scanning with its saved destination',
      (WidgetTester tester) async {
        final CollectionStore<MTGDeck> store = _store(FakeFirebaseFirestore());
        final MTGDeck group = MTGDeck(name: 'Destination', kind: kind)
          ..id = 'saved';
        await store.set(group.id!, group);
        MTGDeck? scanDestination;
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(ThemeMode.dark),
            home: DeckFlyoutScreen(
              deck: group,
              store: store,
              onScan: (MTGDeck destination) async {
                scanDestination = destination;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('group-scan-cards')),
        );
        await tester.pumpAndSettle();
        expect(scanDestination?.id, 'saved');
        expect(scanDestination?.kind, kind);
        expect((await store.get('saved')).effectiveEntries, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('create and scan saves a nested box before opening its scanner', (
    WidgetTester tester,
  ) async {
    final CollectionStore<MTGDeck> store = _store(FakeFirebaseFirestore());
    await store.set(
      'folder',
      MTGDeck(name: 'Storage', kind: CollectionGroupKind.folder),
    );
    MTGDeck? scanDestination;
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        home: CollectionDecks(
          store: store,
          onScan: (MTGDeck destination) async {
            final MTGDeck saved = await store.get(destination.id!);
            expect(saved.name, destination.name);
            scanDestination = destination;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Storage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Box'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('group-name')).hitTestable(),
      'Bulk box',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create and scan'));
    await tester.pumpAndSettle();
    expect(scanDestination?.kind, CollectionGroupKind.box);
    expect(scanDestination?.parentId, 'folder');
    expect(scanDestination?.id, isNotEmpty);
    final MTGDeck saved = await store.get(scanDestination!.id!);
    expect(saved.parentId, 'folder');
    expect(saved.effectiveEntries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'import receives current folder but global filters and deleted folders use root',
    (WidgetTester tester) async {
      final CollectionStore<MTGDeck> store = _store(FakeFirebaseFirestore());
      await store.set(
        'folder',
        MTGDeck(name: 'Storage', kind: CollectionGroupKind.folder),
      );
      await store.set(
        'box',
        MTGDeck(name: 'Box', kind: CollectionGroupKind.box, parentId: 'folder'),
      );
      final List<String?> parents = <String?>[];
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: CollectionDecks(store: store, onImport: parents.add),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import'));
      await tester.tap(find.text('Storage'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import'));
      await tester.tap(find.text('All groups'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Boxes').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import'));
      await tester.tap(find.text('Boxes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All').hitTestable());
      await tester.pumpAndSettle();
      await store.delete('folder');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import'));
      expect(parents, <String?>[null, 'folder', null, null]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'five group kinds remain reachable by collection scrolling under the actual toolbar and root dock',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final CollectionStore<MTGDeck> store = _store(FakeFirebaseFirestore());
      for (final CollectionGroupKind kind in CollectionGroupKind.values) {
        await store.set(
          kind.name,
          MTGDeck(name: '${groupKindLabel(kind)} trades', kind: kind),
        );
      }
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: Scaffold(
            footers: <Widget>[
              CollectorDock(
                selectedIndex: 0,
                items: <CollectorDockItem>[
                  for (final String label in <String>[
                    'Cards',
                    'Containers',
                    'Scan',
                    'Tabletop',
                    'More',
                  ])
                    CollectorDockItem(
                      icon: Icons.square,
                      label: label,
                      onPressed: () {},
                    ),
                ],
              ),
            ],
            child: CollectionDecks(
              store: store,
              onImport: (String? parentId) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Rect dockBounds = tester.getRect(find.byType(CollectorDock));
      for (final CollectionGroupKind kind in CollectionGroupKind.values) {
        final Finder name = find.text('${groupKindLabel(kind)} trades');
        final Finder groupScroll = find.descendant(
          of: find.descendant(
            of: find.byType(CollectionDecks),
            matching: find.byType(ListView),
          ),
          matching: find.byType(Scrollable),
        );
        expect(groupScroll, findsOneWidget);
        tester.state<ScrollableState>(groupScroll).position.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(name, 100, scrollable: groupScroll);
        await tester.ensureVisible(name);
        await tester.pumpAndSettle();
        expect(name.hitTestable(), findsOneWidget);
        final Rect viewport = tester.getRect(
          find
              .descendant(
                of: find.byType(CollectionDecks),
                matching: find.byType(ListView),
              )
              .hitTestable(),
        );
        expect(tester.getRect(name).top, greaterThanOrEqualTo(viewport.top));
        expect(tester.getRect(name).bottom, lessThanOrEqualTo(viewport.bottom));
        final Size scanTarget = tester.getSize(
          find.byKey(ValueKey<String>('scan-group-${kind.name}')),
        );
        expect(scanTarget.width, greaterThanOrEqualTo(44));
        expect(scanTarget.height, greaterThanOrEqualTo(44));
        expect(
          tester
              .getSize(find.ancestor(of: name, matching: find.byType(DeckCard)))
              .height,
          inInclusiveRange(44, 72),
        );
        expect(tester.getRect(find.byType(CollectorDock)), dockBounds);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'folder browsing retains root navigation and direct card access, kind filter finds nested groups',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final CollectionStore<MTGDeck> store = _store(FakeFirebaseFirestore());
      await store.set(
        'folder',
        MTGDeck(name: 'Trade storage', kind: CollectionGroupKind.folder),
      );
      await store.set(
        'box',
        MTGDeck(
          name: 'Blue box',
          kind: CollectionGroupKind.box,
          parentId: 'folder',
        ),
      );
      await store.set('deck', MTGDeck(name: 'Root deck'));
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: CollectionDecks(store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Root deck'), findsOneWidget);
      expect(find.text('Blue box'), findsNothing);
      await tester.tap(find.text('Trade storage'));
      await tester.pumpAndSettle();
      expect(find.text('Blue box'), findsOneWidget);
      expect(find.byType(DeckFlyoutScreen), findsOneWidget);
      expect(find.text('Cards in folder'), findsNothing);
      expect(find.text('Root deck'), findsNothing);
      await tester.tap(find.text('Containers'));
      await tester.pumpAndSettle();
      expect(find.text('Root deck'), findsOneWidget);
      await tester.tap(find.text('All groups'));
      await tester.pumpAndSettle();
      expect(find.text('Boxes'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Boxes').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('Blue box'), findsOneWidget);
      expect(find.text('Root deck'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'create group renders one editable name and commits the chosen kind',
    (WidgetTester tester) async {
      final CollectionStore<MTGDeck> store = _store(FakeFirebaseFirestore());
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: CollectionDecks(store: store),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('Binder'), findsOneWidget);
      await tester.tap(find.text('Binder'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('group-name')).hitTestable(),
        findsOneWidget,
      );
      expect(find.text('Cancel'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey<String>('group-name')).hitTestable(),
        'Trades',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create').hitTestable().last);
      await tester.pumpAndSettle();
      final MTGDeck group = (await store.collection.get()).docs.single.data();
      expect(group.name, 'Trades');
      expect(group.kind, CollectionGroupKind.binder);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'binder actions omit deck rules and importing remains reachable',
    (WidgetTester tester) async {
      final CollectionStore<MTGDeck> store = _store(FakeFirebaseFirestore());
      final MTGDeck binder = MTGDeck(
        name: 'Trade binder',
        kind: CollectionGroupKind.binder,
      )..id = 'binder';
      await store.set('binder', binder);
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.light),
          home: DeckFlyoutScreen(deck: binder, store: store),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('deck-options')));
      await tester.pumpAndSettle();
      expect(find.text('Rename Binder'), findsOneWidget);
      expect(find.text('Move to folder'), findsOneWidget);
      expect(find.text('Delete Binder'), findsOneWidget);
      expect(find.text('Mana curve & checks'), findsNothing);
      expect(find.text('Format: casual'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      int imports = 0;
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.light),
          home: CollectionDecks(
            store: store,
            onImport: (String? parentId) => imports++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import'));
      expect(imports, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'imported format stays visible until a supported format is selected',
    (WidgetTester tester) async {
      final CollectionStore<MTGDeck> store = _store(FakeFirebaseFirestore());
      final MTGDeck deck = MTGDeck(
        name: 'Modern export',
        sourceFormat: 'modern',
      )..id = 'modern';
      await store.set(deck.id!, deck);
      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: DeckFlyoutScreen(deck: deck, store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('modern · 0 cards · 0 printings'), findsOneWidget);
      expect(find.text('casual'), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('deck-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Format: modern'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('standard'));
      await tester.pumpAndSettle();
      final MTGDeck saved = await store.get(deck.id!);
      expect(saved.format, DeckFormat.standard);
      expect(saved.sourceFormat, isNull);
      expect(find.text('standard · 0 cards · 0 printings'), findsOneWidget);
      expect(find.text('modern'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all imported sections are reachable entry destinations', (
    WidgetTester tester,
  ) async {
    final CollectionStore<MTGDeck> store = _store(FakeFirebaseFirestore());
    final MTGDeck deck = MTGDeck(
      name: 'Sections',
      entries: const <DeckEntry>[
        DeckEntry(scryfallId: 'printing', section: DeckSection.maybeboard),
      ],
    )..id = 'deck';
    await store.set('deck', deck);
    final MTGCard metadata = MTGCard(
      name: 'Stored spell',
      setId: 'set',
      description: '',
      flavorText: '',
      cmc: 1,
      typeLine: 'Instant',
      rarity: sf.Rarity.common,
      setType: sf.SetType.expansion,
      manaCost: '{U}',
    );
    await tester.pumpWidget(
      ArcaneApp(
        theme: MyThemeData.themeData(ThemeMode.dark),
        home: DeckFlyoutScreen(
          deck: deck,
          store: store,
          metadata: <String, MTGCard>{'printing': metadata},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stored spell'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.bySemanticsLabel('Stored spell options in maybeboard'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Move to companion'), findsOneWidget);
    expect(find.text('Move to commander'), findsOneWidget);
    await tester.tap(find.text('Move to companion'));
    await tester.pumpAndSettle();
    expect(
      (await store.get('deck')).effectiveEntries.single.section,
      DeckSection.companion,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
