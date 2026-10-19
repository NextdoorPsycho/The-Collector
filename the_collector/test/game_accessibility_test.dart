import 'dart:convert';

import 'package:arcane/arcane.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_collector/pages/dice/game_session_screen.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/games/game_session.dart';

import 'helpers/load_collector_fonts.dart';

class _CountingStore extends SharedGameStore {
  _CountingStore(FakeFirebaseFirestore firestore) : super(firestore: firestore);

  int renames = 0;

  @override
  Future<void> rename(String id, int player, String name) async {
    renames++;
    await super.rename(id, player, name);
  }
}

Future<void> _show(
  WidgetTester tester,
  SharedGameStore store, {
  ThemeMode mode = ThemeMode.dark,
  double scale = 1,
  String? sharedId,
}) async {
  const Size size = Size(320, 568);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(mode),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: GameSessionScreen(
        format: GameFormat.standard,
        players: 2,
        sharedId: sharedId,
        userId: 'alice',
        store: store,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openName(WidgetTester tester) async {
  final Finder name = find.byKey(const ValueKey<String>('game-player-name-0'));
  await tester.ensureVisible(name);
  await tester.pumpAndSettle();
  await tester.tap(name.hitTestable());
  await tester.pumpAndSettle();
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('game-actions')));
  await tester.pumpAndSettle();
}

Finder _field() => find
    .descendant(
      of: find.byKey(const ValueKey<String>('game-player-name-input')),
      matching: find.byType(EditableText),
    )
    .hitTestable();

void main() {
  setUpAll(loadCollectorFonts);

  testWidgets('iOS game has compact actions and accessible exit after ending', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final TargetPlatform? previousPlatform = debugDefaultTargetPlatformOverride;
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final SharedGameStore store = SharedGameStore(firestore: database);
      final GameSession game = await store.create(
        'alice',
        GameFormat.standard,
        2,
      );
      await store.rename(game.id, 0, 'Alice');
      await _show(tester, store, sharedId: game.id);
      expect(find.byType(AppBar), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('game-done')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.bySemanticsLabel('Gain 1 life for Alice'));
      await tester.pumpAndSettle();
      expect(
        (await database.doc('gameSessions/${game.id}').get()).data()!['life'],
        <int>[21, 20],
      );
      await store.end(game.id);
      await tester.pumpAndSettle();
      expect(find.text('This session has ended.'), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Return to games').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });

  for (final double scale in <double>[1, 2.35]) {
    testWidgets(
      'iOS Game menu keeps its code and owner actions reachable at 320px scale $scale',
      (WidgetTester tester) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        final TargetPlatform? previousPlatform =
            debugDefaultTargetPlatformOverride;
        try {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          SharedPreferences.setMockInitialValues(<String, Object>{});
          final SharedGameStore store = SharedGameStore(
            firestore: FakeFirebaseFirestore(),
          );
          final GameSession game = await store.create(
            'alice',
            GameFormat.standard,
            2,
          );
          await _show(tester, store, sharedId: game.id, scale: scale);
          expect(find.byType(AppBar), findsNothing);
          await _openMenu(tester);
          expect(
            find
                .byWidgetPredicate(
                  (Widget widget) =>
                      widget is SelectableText && widget.data == game.id,
                )
                .hitTestable(),
            findsOneWidget,
          );
          for (final Finder control in <Finder>[
            find.text('Copy code'),
            find.text('Reset life totals'),
            find.text('End session'),
          ]) {
            await tester.ensureVisible(control.first);
            await tester.pumpAndSettle();
            expect(control.hitTestable(), findsOneWidget);
            final Rect bounds = tester.getRect(control.hitTestable());
            expect(bounds.left, greaterThanOrEqualTo(0));
            expect(bounds.right, lessThanOrEqualTo(320));
          }
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
          debugDefaultTargetPlatformOverride = previousPlatform;
        }
      },
    );
  }

  testWidgets('board and player editor life changes announce their purpose', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final SharedGameStore store = SharedGameStore(firestore: database);
      final GameSession game = await store.create(
        'alice',
        GameFormat.standard,
        2,
      );
      await store.rename(game.id, 0, 'Alice');
      await store.rename(game.id, 1, 'Bob');
      await _show(tester, store, sharedId: game.id);
      for (final String label in <String>[
        'Gain 1 life for Alice',
        'Lose 1 life for Alice',
      ]) {
        final SemanticsNode node = tester.getSemantics(
          find.bySemanticsLabel(label).first,
        );
        expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      }
      await tester.tap(find.bySemanticsLabel('Gain 1 life for Alice'));
      await tester.pumpAndSettle();
      expect(
        (await database.doc('gameSessions/${game.id}').get()).data()!['life'],
        <int>[21, 20],
      );
      await _openName(tester);
      final SemanticsNode editor = tester.getSemantics(
        find.bySemanticsLabel(RegExp('Lose 10 life for Alice')).first,
      );
      expect(editor.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(editor.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets('320px ${mode.name} large-text invalid rename stays editable', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedGameStore store = SharedGameStore(
        firestore: FakeFirebaseFirestore(),
      );
      await _show(tester, store, mode: mode, scale: 2.35);
      await _openName(tester);
      expect(tester.widget<EditableText>(_field()).controller.text, 'Player 1');
      await tester.enterText(_field(), '   ');
      await tester.tap(find.text('Save').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('Enter a player name.').hitTestable(), findsOneWidget);
      expect(_field(), findsOneWidget);
      await tester.enterText(_field(), List<String>.filled(41, 'a').join());
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        find.text('Use at most 40 characters.').hitTestable(),
        findsOneWidget,
      );
      expect(_field(), findsOneWidget);
      await tester.enterText(_field(), '  Alice  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('game-player-name-input')),
        findsNothing,
      );
      expect(find.text('Alice'), findsOneWidget);
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      final Map<String, Object?> saved = Map<String, Object?>.from(
        jsonDecode(preferences.getString('game.alice.standard.2')!)
            as Map<Object?, Object?>,
      );
      expect((saved['names']! as List<Object?>).first, 'Alice');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancel does not rename; keyboard and button confirm only once', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final _CountingStore store = _CountingStore(database);
    final GameSession game = await store.create(
      'alice',
      GameFormat.standard,
      2,
    );
    await _show(tester, store, sharedId: game.id);
    await _openName(tester);
    await tester.enterText(_field(), 'Unsaved');
    await tester.tap(find.text('Cancel').hitTestable());
    await tester.pumpAndSettle();
    expect(store.renames, 0);
    expect(find.text('Player 1'), findsOneWidget);
    await _openName(tester);
    await tester.enterText(_field(), 'Saved');
    final PrimaryButton save = tester.widget<PrimaryButton>(
      find.widgetWithText(PrimaryButton, 'Save').hitTestable(),
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    save.onPressed!();
    await tester.pumpAndSettle();
    expect(store.renames, 1);
    expect(
      (await database.doc('gameSessions/${game.id}').get()).data()!['names'],
      <String>['Saved', 'Player 2'],
    );
    expect(tester.takeException(), isNull);
  });
}
