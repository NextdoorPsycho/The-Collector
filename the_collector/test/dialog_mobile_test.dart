import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/crud.dart';

import 'helpers/load_collector_fonts.dart';

Future<void> _phone(WidgetTester tester, ThemeMode mode, Widget home) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(mode),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: const Size(375, 667),
          textScaler: const TextScaler.linear(2.35),
          padding: const EdgeInsets.only(top: 20),
          viewPadding: const EdgeInsets.only(top: 20),
        ),
        child: child!,
      ),
      home: home,
    ),
  );
  await tester.pumpAndSettle();
}

void _expectActions(
  WidgetTester tester,
  String confirmation, {
  double bottom = 667,
  List<String> additionalActions = const <String>[],
}) {
  for (final String label in <String>[
    'Cancel',
    confirmation,
    ...additionalActions,
  ]) {
    final Finder action = find.text(label).hitTestable();
    expect(action, findsOneWidget);
    final Rect bounds = tester.getRect(action);
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(375));
    expect(bounds.top, greaterThanOrEqualTo(20));
    expect(bounds.bottom, lessThanOrEqualTo(bottom));
  }
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadCollectorFonts);

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'New Deck actions fit 375px at 2.35 text in ${mode.name} and create once',
      (WidgetTester tester) async {
        final FakeFirebaseFirestore database = FakeFirebaseFirestore();
        final CollectionStore<MTGDeck> store = CollectionStore<MTGDeck>(
          collection: database.collection('user/alice/decks'),
          toMap: (MTGDeck deck) => deck.toMap(),
          fromMap: (String id, Map<String, Object?> data) =>
              MTGDeckMapper.fromMap(data)..id = id,
        );
        await _phone(tester, mode, CollectionDecks(store: store));
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(find.text('Deck'), findsOneWidget);
        await tester.tap(find.text('Deck'));
        await tester.pumpAndSettle();
        final Finder nameField = find.byKey(
          const ValueKey<String>('group-name'),
        );
        final Finder nameInput = find.descendant(
          of: nameField,
          matching: find.byType(EditableText),
        );
        expect(nameInput, findsOneWidget);
        _expectActions(
          tester,
          'Create',
          additionalActions: <String>['Create and scan'],
        );
        await tester.enterText(nameInput.hitTestable(), '  Esper Control  ');
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        _expectActions(
          tester,
          'Create',
          bottom: 407,
          additionalActions: <String>['Create and scan'],
        );
        await tester.tap(find.text('Create').hitTestable().last);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(nameField, findsNothing);
        expect(
          find.byKey(const ValueKey<String>('container-search')),
          findsNothing,
        );
        expect(find.text('Esper Control'), findsOneWidget);
        final Finder search = find
            .bySemanticsLabel('Search containers')
            .hitTestable();
        expect(search, findsOneWidget);
        await tester.tap(search);
        await tester.pumpAndSettle();
        final Finder searchField = find.byKey(
          const ValueKey<String>('container-search'),
        );
        expect(searchField.hitTestable(), findsOneWidget);
        await tester.enterText(searchField, 'Esper');
        await tester.pumpAndSettle();
        expect(find.text('Esper Control'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('Close search').hitTestable());
        await tester.pumpAndSettle();
        expect(searchField, findsNothing);
        expect(search, findsOneWidget);
        final QuerySnapshot<MTGDeck> decks = await store.collection.get();
        expect(decks.docs, hasLength(1));
        expect(decks.docs.single.data().name, 'Esper Control');
        expect(decks.docs.single.data().kind, CollectionGroupKind.deck);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'Rename keeps its value and submits by keyboard in ${mode.name} at 2.35',
      (WidgetTester tester) async {
        final List<String> names = <String>[];
        await _phone(
          tester,
          mode,
          Builder(
            builder: (BuildContext context) => Scaffold(
              child: Center(
                child: SecondaryButton(
                  onPressed: () async {
                    final String? name = await promptGroupName(
                      context,
                      title: 'Rename Deck',
                      initialValue: 'Esper Control',
                    );
                    if (name != null) {
                      names.add(name);
                    }
                  },
                  child: const Text('Rename'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        _expectActions(tester, 'Save');
        final Finder input = find.byType(EditableText).hitTestable().first;
        expect(
          tester.widget<EditableText>(input).controller.text,
          'Esper Control',
        );
        await tester.enterText(input, 'Azorius Control');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(names, <String>['Azorius Control']);
        expect(find.byType(EditableText), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'Delete confirmation fits ${mode.name} at 2.35 and closes before async work',
      (WidgetTester tester) async {
        final Completer<void> write = Completer<void>();
        final List<bool?> results = <bool?>[];
        int confirmations = 0;
        bool writeFinished = false;
        await _phone(
          tester,
          mode,
          Builder(
            builder: (BuildContext context) => Scaffold(
              child: Center(
                child: SecondaryButton(
                  onPressed: () async {
                    final bool result = await confirmGroupDeletion(
                      context,
                      title: 'Delete Deck',
                      description: 'Delete Esper Control? Your collection quantities stay unchanged.',
                    );
                    results.add(result);
                    if (result) {
                      confirmations++;
                      await write.future;
                      writeFinished = true;
                    }
                  },
                  child: const Text('Delete deck'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Delete deck'));
        await tester.pumpAndSettle();
        _expectActions(tester, 'Delete');
        await tester.tap(find.text('Cancel').hitTestable());
        await tester.pumpAndSettle();
        expect(confirmations, 0);
        expect(results, <bool?>[false]);
        await tester.tap(find.text('Delete deck'));
        await tester.pumpAndSettle();
        _expectActions(tester, 'Delete');
        await tester.tap(find.text('Delete').hitTestable());
        await tester.pumpAndSettle();
        expect(find.text('Delete Deck'), findsNothing);
        expect(confirmations, 1);
        expect(results, <bool?>[false, true]);
        expect(writeFinished, isFalse);
        write.complete();
        await tester.pump();
        expect(writeFinished, isTrue);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
