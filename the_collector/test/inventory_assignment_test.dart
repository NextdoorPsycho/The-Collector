import 'package:arcane/arcane.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/collection_cards.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/card_catalog.dart';

import 'helpers/assignment_fixture.dart';
import 'helpers/load_collector_fonts.dart';

class _Catalog extends Fake implements CardCatalog {
  @override
  Future<Map<String, sf.MtgCard>> printings(Iterable<String> ids) async =>
      <String, sf.MtgCard>{};
}

Future<void> _show(WidgetTester tester, AssignmentDatabase database) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await assignmentCards(database).set(
    'alpha',
    assignmentCard(
      'alpha',
      quantity: 3,
      finish: sf.Finish.foil,
      language: 'ja',
    ),
  );
  await assignmentCards(database)
      .set('beta', assignmentCard('beta', name: 'Beta', quantity: 2));
  await assignmentGroups(database).set(
    'binder',
    MTGDeck(name: 'Trade binder', kind: CollectionGroupKind.binder),
  );
  await assignmentGroups(database)
      .set('box', MTGDeck(name: 'Storage', kind: CollectionGroupKind.box));
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.dark),
      home: CollectionCards(
        store: assignmentCards(database),
        catalog: _Catalog(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.longPress(find.text('Alpha'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Beta'));
  await tester.pumpAndSettle();
  expect(find.text('2 selected · 5 copies'), findsOneWidget);
  await tester.tap(find.text('Assign'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadCollectorFonts);
  testWidgets(
    'selected owned copies assign to a binder and exit selection after acknowledgement',
    (WidgetTester tester) async {
      final AssignmentDatabase database = AssignmentDatabase();
      await _show(tester, database);
      await tester.tap(
        find.byKey(const ValueKey<String>('assign-owned-binder')),
      );
      await tester.pumpAndSettle();
      final List<DeckEntry> entries = (await assignmentGroups(
        database,
      ).get('binder')).effectiveEntries;
      expect(entries, hasLength(2));
      final DeckEntry alpha = entries.singleWhere(
        (DeckEntry entry) => entry.scryfallId == 'alpha',
      );
      expect(alpha.quantity, 3);
      expect(alpha.finish, sf.Finish.foil);
      expect(alpha.language, 'ja');
      expect(
        (await assignmentGroups(database).get('box')).effectiveEntries,
        isEmpty,
      );
      expect((await assignmentCards(database).get('alpha')).quantity, 3);
      expect((await assignmentCards(database).get('beta')).quantity, 2);
      expect(find.text('2 selected · 5 copies'), findsNothing);
      expect(find.text('Assign owned'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed assignment keeps the selected copies and retries once without duplication',
    (WidgetTester tester) async {
      final AssignmentDatabase database = AssignmentDatabase();
      await _show(tester, database);
      database.failNextTransaction = true;
      await tester.tap(
        find.byKey(const ValueKey<String>('assign-owned-binder')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Offline').hitTestable(), findsOneWidget);
      expect(
        (await assignmentGroups(database).get('binder')).effectiveEntries,
        isEmpty,
      );
      expect(
        find.byKey(const ValueKey<String>('assign-owned-binder')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('assign-owned-binder')),
      );
      await tester.pumpAndSettle();
      expect(database.transactions, 2);
      expect(database.committedWrites, 1);
      expect(
        (await assignmentGroups(database).get('binder')).effectiveEntries
            .fold<int>(
              0,
              (int count, DeckEntry entry) => count + entry.quantity,
            ),
        5,
      );
      expect(find.text('Assign owned'), findsNothing);
      expect((await assignmentCards(database).get('alpha')).quantity, 3);
      expect(tester.takeException(), isNull);
    },
  );
}
