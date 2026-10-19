import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:arcane/arcane.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/card/card_add_dialog.dart';
import 'package:the_collector/pages/collection/card/card_thumbnail.dart';
import 'package:the_collector/pages/collection/moxfield_import_screen.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/collection_organization.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/moxfield_import.dart';

import 'helpers/load_collector_fonts.dart';

class _Service extends MoxfieldImportService {
  _Service(this.preview);
  MoxfieldImportPreview preview;
  Completer<void>? waiting;
  MoxfieldImportException? failure;
  final List<String> inputs = <String>[];

  @override
  Future<MoxfieldImportPreview> prepare(
    String input, {
    String? sourceName,
    bool Function()? isCancelled,
    void Function(int resolved, int total)? onProgress,
  }) async {
    inputs.add(input);
    if (failure != null) throw failure!;
    onProgress?.call(0, preview.document.rows.length);
    if (waiting != null) await waiting!.future;
    if (isCancelled?.call() ?? false) throw const MoxfieldImportCancelled();
    return preview;
  }
}

class _LostAcknowledgment extends CollectionOrganization {
  _LostAcknowledgment({required super.groups});
  final List<String?> operations = <String?>[];

  @override
  Future<String> createGroup({
    required String name,
    CollectionGroupKind kind = CollectionGroupKind.deck,
    String? parentId,
    String? sourceUrl,
    String? sourceFormat,
    List<DeckEntry> entries = const <DeckEntry>[],
    DeckFormat format = DeckFormat.casual,
    String? operationId,
  }) async {
    operations.add(operationId);
    final String id = await super.createGroup(
      name: name,
      kind: kind,
      parentId: parentId,
      sourceUrl: sourceUrl,
      sourceFormat: sourceFormat,
      entries: entries,
      format: format,
      operationId: operationId,
    );
    if (operations.length == 1) {
      throw StateError('Import saved; response interrupted.');
    }
    return id;
  }
}

class _PrintingCatalog extends CardCatalog {
  final sf.MtgCard card = sf.MtgCard.fromJson(
    jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<String, Object?>,
  );
  final List<String> queries = <String>[];
  @override
  Future<sf.PaginableList<sf.MtgCard>> search(
    String query, {
    int page = 1,
    bool allPrintings = false,
  }) async {
    queries.add(query);
    return sf.PaginableList<sf.MtgCard>(
      data: <sf.MtgCard>[card],
      hasMore: false,
    );
  }
}

MoxfieldImportPreview _preview({bool exact = true, bool invalid = false}) {
  final sf.MtgCard printing = sf.MtgCard.fromJson(
    jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<String, Object?>,
  );
  final MTGCard card = cardFromScryfall(printing, finish: sf.Finish.nonfoil);
  final MoxfieldImportRow row = MoxfieldImportRow(
    line: 2,
    source: '3 ${card.name}',
    quantity: 3,
    name: card.name,
    section: DeckSection.sideboard,
    condition: 'Near Mint',
  );
  final MoxfieldImportDocument document = MoxfieldImportDocument(
    sourceName: 'Moxfield deck',
    sourceFormat: 'moxfield-csv',
    deckFormat: 'modern',
    rows: <MoxfieldImportRow>[row],
  );
  return MoxfieldImportPreview(
    document: document,
    entries: <MoxfieldResolvedEntry>[
      MoxfieldResolvedEntry(
        row: row,
        card: card,
        exactPrinting: exact,
        entry: DeckEntry(
          scryfallId: card.printingId!,
          quantity: 3,
          section: row.section,
          condition: row.condition,
          finish: card.finish,
          language: card.language,
        ),
      ),
    ],
    issues: invalid
        ? const <MoxfieldImportIssue>[
            MoxfieldImportIssue(
              line: 3,
              source: '0 Island',
              message: 'Quantity must be positive.',
            ),
          ]
        : const <MoxfieldImportIssue>[],
  );
}

CollectionStore<MTGDeck> _groups(FakeFirebaseFirestore database) =>
    CollectionStore<MTGDeck>(
      collection: database.collection('user/alice/decks'),
      toMap: (MTGDeck group) => group.toMap(),
      fromMap: (String id, Map<String, Object?> data) =>
          MTGDeckMapper.fromMap(data)..id = id,
    );

Future<void> _show(
  WidgetTester tester,
  CollectionStore<MTGDeck> groups,
  _Service service, {
  ThemeMode theme = ThemeMode.dark,
  double scale = 1,
  Future<XFile?> Function()? pickFile,
  Future<PrintingSelection?> Function(BuildContext)? pickPrinting,
  String? parentId,
  CardCatalog? catalog,
  CollectionOrganization? organization,
}) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(theme),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (BuildContext context) => PrimaryButton(
          onPressed: () => Arcane.push(
            context,
            MoxfieldImportScreen(
              groups: groups,
              service: service,
              pickFile: pickFile,
              pickPrinting: pickPrinting,
              parentId: parentId,
              catalog: catalog,
              organization: organization,
            ),
          ),
          child: const Text('Open import'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open import'));
  await tester.pumpAndSettle();
}

Future<void> _read(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey<String>('moxfield-source')),
    'https://moxfield.com/decks/test',
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey<String>('moxfield-submit')));
  await tester.pumpAndSettle();
}

void _test(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(
      name,
      body,
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

void main() {
  setUpAll(loadCollectorFonts);

  _test('one source accepts a link or export without switching modes', (
    WidgetTester tester,
  ) async {
    final CollectionStore<MTGDeck> groups = _groups(FakeFirebaseFirestore());
    await _show(tester, groups, _Service(_preview()));
    final Finder source = find.byKey(const ValueKey<String>('moxfield-source'));
    expect(
      tester.widget<TextField>(source).semanticLabel,
      'Moxfield link or export',
    );
    await tester.enterText(source, '2 Lightning Bolt');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('moxfield-input-link')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('moxfield-input-export')),
      findsNothing,
    );
    expect(
      tester.widget<TextField>(source).controller!.text,
      '2 Lightning Bolt',
    );
    expect((await groups.collection.get()).docs, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  _test('preview separates ready printings from corrections', (
    WidgetTester tester,
  ) async {
    final MoxfieldImportPreview exact = _preview();
    final MoxfieldResolvedEntry first = exact.entries.single;
    final MoxfieldImportRow row = MoxfieldImportRow(
      line: 3,
      source: '2 Island',
      quantity: 2,
      name: 'Island',
    );
    final _Service service = _Service(
      MoxfieldImportPreview(
        document: MoxfieldImportDocument(
          sourceName: 'Mixed list',
          sourceFormat: 'text',
          rows: <MoxfieldImportRow>[first.row, row],
        ),
        entries: <MoxfieldResolvedEntry>[
          first,
          MoxfieldResolvedEntry(
            row: row,
            entry: first.entry.copyWith(quantity: 2),
            card: first.card.copyWith(name: 'Island'),
            exactPrinting: false,
          ),
        ],
      ),
    );
    addTearDown(service.close);
    await _show(tester, _groups(FakeFirebaseFirestore()), service);
    await _read(tester);
    expect(find.text('Needs attention · 1'), findsOneWidget);
    expect(find.text('Ready · 1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('moxfield-entry-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('moxfield-entry-0')),
      findsNothing,
    );
    await tester.tap(find.text('Ready · 1'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('moxfield-entry-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('moxfield-entry-1')),
      findsNothing,
    );
    expect(find.text('Create deck'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _test('a failed lookup can be corrected without reimporting the source', (
    WidgetTester tester,
  ) async {
    final MoxfieldImportPreview exact = _preview();
    final MoxfieldImportRow row = exact.document.rows.single;
    final _Service service = _Service(
      MoxfieldImportPreview(
        document: exact.document,
        entries: const <MoxfieldResolvedEntry>[],
        issues: <MoxfieldImportIssue>[
          MoxfieldImportIssue(
            line: row.line,
            source: row.source,
            message: 'Printing not found.',
            kind: MoxfieldImportIssueKind.lookup,
          ),
        ],
      ),
    );
    addTearDown(service.close);
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final CollectionStore<MTGDeck> groups = _groups(database);
    await _show(
      tester,
      groups,
      service,
      pickPrinting: (BuildContext _) async => PrintingSelection(
        card: exact.entries.single.card.copyWith(finish: sf.Finish.foil),
        quantity: 1,
      ),
    );
    await _read(tester);
    await tester.tap(find.byKey(const ValueKey<String>('moxfield-issue-2')));
    await tester.pumpAndSettle();
    expect(find.text('Ready · 1'), findsOneWidget);
    expect(find.textContaining('Printing not found.'), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('moxfield-submit')));
    await tester.pumpAndSettle();
    final DeckEntry saved =
        (await groups.streamAll().first).single.effectiveEntries.single;
    expect(saved.quantity, 3);
    expect(saved.section, DeckSection.sideboard);
    expect(saved.condition, 'Near Mint');
    expect(saved.finish, sf.Finish.foil);
    expect((await database.collection('user/alice/cards').get()).docs, isEmpty);
  });

  _test(
    'import creates one group preserving entries and never creates owned cards',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionStore<MTGDeck> groups = _groups(database);
      final _Service service = _Service(_preview());
      addTearDown(service.close);
      await _show(tester, groups, service);
      await _read(tester);
      await tester.tap(find.byKey(const ValueKey<String>('moxfield-submit')));
      await tester.pumpAndSettle();
      final List<MTGDeck> stored = await groups.streamAll().first;
      expect(stored, hasLength(1));
      expect(stored.single.name, 'Moxfield deck');
      expect(stored.single.sourceFormat, 'modern');
      expect(stored.single.effectiveEntries.single.quantity, 3);
      expect(
        stored.single.effectiveEntries.single.section,
        DeckSection.sideboard,
      );
      expect(stored.single.effectiveEntries.single.condition, 'Near Mint');
      expect(
        (await database.collection('user/alice/cards').get()).docs,
        isEmpty,
      );
      expect(find.text('Open import'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  _test(
    'name-only printings require approval or a correction that preserves exported copies',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionStore<MTGDeck> groups = _groups(database);
      final _Service service = _Service(_preview(exact: false));
      addTearDown(service.close);
      await _show(
        tester,
        groups,
        service,
        pickPrinting: (BuildContext _) async => PrintingSelection(
          card: service.preview.entries.single.card.copyWith(
            finish: sf.Finish.foil,
          ),
          quantity: 1,
        ),
      );
      await _read(tester);
      expect(find.text('3 cards · 1 printing'), findsOneWidget);
      expect(find.text('Needs attention · 1'), findsOneWidget);
      expect(find.text('Approve 1 suggested printing'), findsOneWidget);
      final Finder row = find.byKey(const ValueKey<String>('moxfield-entry-0'));
      expect(
        find.descendant(of: row, matching: find.byType(CardThumbnail)),
        findsOneWidget,
      );
      expect(
        tester
            .widget<PrimaryButton>(
              find.byKey(const ValueKey<String>('moxfield-submit')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey<String>('moxfield-entry-0')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('moxfield-approve-printings')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey<String>('moxfield-submit')));
      await tester.pumpAndSettle();
      final DeckEntry entry =
          (await groups.streamAll().first).single.effectiveEntries.single;
      expect(entry.finish, sf.Finish.foil);
      expect(entry.quantity, 3);
      expect(entry.condition, 'Near Mint');
      expect(entry.section, DeckSection.sideboard);
    },
  );

  _test('invalid rows block saving and Edit returns to input', (
    WidgetTester tester,
  ) async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final CollectionStore<MTGDeck> groups = _groups(database);
    final _Service service = _Service(_preview(invalid: true));
    addTearDown(service.close);
    await _show(tester, groups, service);
    await _read(tester);
    expect(find.text('Line 3: Quantity must be positive.'), findsOneWidget);
    expect(
      tester
          .widget<PrimaryButton>(
            find.byKey(const ValueKey<String>('moxfield-submit')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('moxfield-source')),
      findsOneWidget,
    );
    expect((await groups.streamAll().first), isEmpty);
  });

  _test(
    'syntax corrections edit the source and reparse instead of opening printings',
    (WidgetTester tester) async {
      final _Service service = _Service(_preview(invalid: true));
      addTearDown(service.close);
      int printingCalls = 0;
      final CollectionStore<MTGDeck> groups = _groups(FakeFirebaseFirestore());
      await _show(
        tester,
        groups,
        service,
        pickPrinting: (BuildContext _) async {
          printingCalls++;
          return null;
        },
      );
      await _read(tester);
      await tester.tap(find.byKey(const ValueKey<String>('moxfield-issue-3')));
      await tester.pumpAndSettle();
      expect(find.byType(CardPrintingSelector), findsNothing);
      expect(printingCalls, 0);
      final Finder source = find.byKey(
        const ValueKey<String>('moxfield-source'),
      );
      expect(
        tester.widget<TextField>(source).controller!.text,
        'https://moxfield.com/decks/test',
      );
      service.preview = _preview();
      await tester.enterText(source, '3 Dusk // Dawn');
      await tester.tap(find.byKey(const ValueKey<String>('moxfield-submit')));
      await tester.pumpAndSettle();
      expect(service.inputs.last, '3 Dusk // Dawn');
      expect(find.text('Needs attention · 0'), findsOneWidget);
      expect((await groups.collection.get()).docs, isEmpty);
    },
  );

  _test(
    'shared printing correction replaces the import body and cancellation preserves preview',
    (WidgetTester tester) async {
      final _Service service = _Service(_preview(exact: false));
      final _PrintingCatalog catalog = _PrintingCatalog();
      addTearDown(service.close);
      addTearDown(catalog.close);
      final CollectionStore<MTGDeck> groups = _groups(FakeFirebaseFirestore());
      await _show(tester, groups, service, catalog: catalog);
      await _read(tester);
      await tester.tap(find.byKey(const ValueKey<String>('moxfield-entry-0')));
      await tester.pumpAndSettle();
      expect(find.byType(CardPrintingSelector), findsOneWidget);
      expect(find.byType(CardPrintingDialog), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('moxfield-preview')),
        findsNothing,
      );
      expect(catalog.queries.single, '!"Dusk // Dawn"');
      await tester.tap(find.byKey(const ValueKey<String>('printing-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('Needs attention · 1'), findsOneWidget);
      expect((await groups.collection.get()).docs, isEmpty);
      await tester.tap(find.byKey(const ValueKey<String>('moxfield-entry-0')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<String>('printing-choice-${catalog.card.id}')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('printing-copies')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('printing-destination')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey<String>('printing-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Ready · 1'), findsOneWidget);
      expect(find.text('Needs attention · 0'), findsOneWidget);
      expect((await groups.collection.get()).docs, isEmpty);
    },
  );

  for (final CollectionGroupKind kind in CollectionGroupKind.values) {
    _test(
      'Create ${kind.name} preserves the selected parent and imported fields',
      (WidgetTester tester) async {
        final FakeFirebaseFirestore database = FakeFirebaseFirestore();
        final CollectionStore<MTGDeck> groups = _groups(database);
        await groups.set(
          'folder',
          MTGDeck(name: 'Archive', kind: CollectionGroupKind.folder),
        );
        final _Service service = _Service(_preview());
        addTearDown(service.close);
        await _show(tester, groups, service, parentId: 'folder');
        await _read(tester);
        await tester.tap(
          find.byKey(const ValueKey<String>('moxfield-destination')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Archive'), findsOneWidget);
        final Finder kindControl = find.byKey(
          const ValueKey<String>('moxfield-kind'),
        );
        await tester.tap(kindControl);
        await tester.pump(const Duration(milliseconds: 350));
        final String label =
            '${kind.name[0].toUpperCase()}${kind.name.substring(1)}';
        await tester.tap(find.text(label).hitTestable().last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.text('Create ${kind.name}'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey<String>('moxfield-submit')));
        await tester.pumpAndSettle();
        final Map<String, Object?> dump =
            jsonDecode(database.dump()) as Map<String, Object?>;
        final Map<String, Object?> users =
            dump['user']! as Map<String, Object?>;
        final Map<String, Object?> account =
            users['alice']! as Map<String, Object?>;
        final Map<String, Object?> containers =
            account['decks']! as Map<String, Object?>;
        final MapEntry<String, Object?> saved = containers.entries.singleWhere(
          (MapEntry<String, Object?> entry) =>
              entry.key != 'folder' &&
              (entry.value! as Map<String, Object?>).isNotEmpty,
        );
        final MTGDeck created = MTGDeckMapper.fromMap(
          saved.value! as Map<String, Object?>,
        )..id = saved.key;
        expect(created.kind, kind);
        expect(created.parentId, 'folder');
        expect(created.effectiveEntries.single.quantity, 3);
        expect(created.effectiveEntries.single.section, DeckSection.sideboard);
        expect(created.effectiveEntries.single.condition, 'Near Mint');
        expect(created.effectiveEntries.single.language, 'en');
        expect(account['cards'], anyOf(isNull, isEmpty));
      },
    );
  }

  _test(
    'retry after a lost save response reuses the operation and creates one container',
    (WidgetTester tester) async {
      final CollectionStore<MTGDeck> groups = _groups(FakeFirebaseFirestore());
      final _LostAcknowledgment organization = _LostAcknowledgment(
        groups: groups,
      );
      final _Service service = _Service(_preview());
      addTearDown(service.close);
      await _show(tester, groups, service, organization: organization);
      await _read(tester);
      await tester.tap(find.byKey(const ValueKey<String>('moxfield-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Import saved; response interrupted.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('moxfield-preview')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('moxfield-submit')));
      await tester.pumpAndSettle();
      expect(organization.operations, hasLength(2));
      expect(organization.operations.first, isNotNull);
      expect(organization.operations.first, organization.operations.last);
      expect((await groups.collection.get()).docs, hasLength(1));
      expect(find.text('Open import'), findsOneWidget);
    },
  );

  _test('private URL offers an export fallback and file limits retain source', (
    WidgetTester tester,
  ) async {
    final _Service service = _Service(_preview())
      ..failure = const MoxfieldImportException(
        'This deck is private. Export TXT or CSV.',
      );
    addTearDown(service.close);
    final CollectionStore<MTGDeck> groups = _groups(FakeFirebaseFirestore());
    await _show(
      tester,
      groups,
      service,
      pickFile: () async =>
          XFile.fromData(Uint8List(2 * 1024 * 1024 + 1), name: 'oversized.txt'),
    );
    await _read(tester);
    expect(find.text('Use TXT / CSV').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Use TXT / CSV'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an export no larger than 2 MiB.'), findsOneWidget);
    expect(service.inputs, hasLength(1));
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('moxfield-source')),
          )
          .controller!
          .text,
      'https://moxfield.com/decks/test',
    );
    expect((await groups.collection.get()).docs, isEmpty);
  });

  _test('cancelled matching cannot reopen preview or write a group', (
    WidgetTester tester,
  ) async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final CollectionStore<MTGDeck> groups = _groups(database);
    final _Service service = _Service(_preview())..waiting = Completer<void>();
    addTearDown(service.close);
    await _show(tester, groups, service);
    await tester.enterText(
      find.byKey(const ValueKey<String>('moxfield-source')),
      'https://moxfield.com/decks/test',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('moxfield-submit')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('moxfield-cancel')));
    service.waiting!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Open import'), findsOneWidget);
    expect((await groups.streamAll().first), isEmpty);
    expect(tester.takeException(), isNull);
  });

  _test(
    'file import reads chosen CSV and cancel discards a late picker result',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final _Service service = _Service(_preview());
      addTearDown(service.close);
      final Completer<XFile?> chosen = Completer<XFile?>();
      await _show(
        tester,
        _groups(database),
        service,
        pickFile: () => chosen.future,
      );
      await tester.tap(find.byKey(const ValueKey<String>('moxfield-file')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('moxfield-cancel')));
      chosen.complete(
        XFile.fromData(
          utf8.encode('Quantity,Name\n3 Fire // Ice'),
          name: 'Trades.csv',
          mimeType: 'text/csv',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Open import'), findsOneWidget);
      expect((await _groups(database).streamAll().first), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  _test('chosen export enters preview and saves through same group-only path', (
    WidgetTester tester,
  ) async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final _Service service = _Service(_preview());
    addTearDown(service.close);
    await _show(
      tester,
      _groups(database),
      service,
      pickFile: () async => XFile.fromData(
        utf8.encode('Quantity,Name\n3 Fire // Ice'),
        name: 'Trades.csv',
        mimeType: 'text/csv',
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('moxfield-file')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('moxfield-preview')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('moxfield-submit')));
    await tester.pumpAndSettle();
    expect((await _groups(database).streamAll().first), hasLength(1));
    expect((await database.collection('user/alice/cards').get()).docs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  _test(
    'unspecified-printing approval is reachable without scrolling a bulk import',
    (WidgetTester tester) async {
      final MoxfieldImportPreview one = _preview(exact: false);
      final List<MoxfieldImportRow> rows = List<MoxfieldImportRow>.filled(
        1000,
        one.document.rows.single,
      );
      final _Service service = _Service(
        MoxfieldImportPreview(
          document: MoxfieldImportDocument(
            sourceName: 'Bulk list',
            sourceFormat: 'moxfield-csv',
            rows: rows,
          ),
          entries: List<MoxfieldResolvedEntry>.filled(1000, one.entries.single),
        ),
      );
      addTearDown(service.close);
      await _show(tester, _groups(FakeFirebaseFirestore()), service);
      await _read(tester);
      final Finder approval = find
          .byKey(const ValueKey<String>('moxfield-approve-printings'))
          .hitTestable();
      expect(approval, findsOneWidget);
      expect(
        tester.getRect(approval).top,
        lessThan(
          tester
              .getRect(find.byKey(const ValueKey<String>('moxfield-entry-0')))
              .top,
        ),
      );
      await tester.tap(approval);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PrimaryButton>(
              find.byKey(const ValueKey<String>('moxfield-submit')),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final ThemeMode theme in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    for (final double scale in <double>[1, 2.35]) {
      _test(
        'input and preview remain usable at 320px ${theme.name} scale $scale',
        (WidgetTester tester) async {
          final _Service service = _Service(_preview(exact: false));
          addTearDown(service.close);
          await _show(
            tester,
            _groups(FakeFirebaseFirestore()),
            service,
            theme: theme,
            scale: scale,
          );
          expect(find.byType(AppBar), findsNothing);
          expect(tester.takeException(), isNull, reason: 'input');
          await _read(tester);
          expect(tester.takeException(), isNull, reason: 'preview');
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          addTearDown(tester.view.resetViewInsets);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'preview keyboard');
          expect(
            find.byKey(const ValueKey<String>('moxfield-submit')).hitTestable(),
            findsOneWidget,
          );
          expect(
            tester
                .getRect(find.byKey(const ValueKey<String>('moxfield-cancel')))
                .bottom,
            lessThanOrEqualTo(308),
          );
          final Finder cancel = find
              .byKey(const ValueKey<String>('moxfield-cancel'))
              .hitTestable();
          expect(cancel, findsOneWidget);
          expect(tester.getRect(cancel).bottom, lessThanOrEqualTo(568));
          await tester.tap(cancel);
          await tester.pumpAndSettle();
          expect(find.text('Open import'), findsOneWidget);
        },
      );
    }
  }
}
