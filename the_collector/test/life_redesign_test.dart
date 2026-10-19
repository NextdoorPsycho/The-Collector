import 'dart:convert';

import 'package:arcane/arcane.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_collector/pages/dice/game_session_screen.dart';
import 'package:the_collector/pages/dock/hub.dart';
import 'package:the_collector/pages/dock/hub_dice.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/games/game_session.dart';

import 'helpers/load_collector_fonts.dart';

Future<void> _show(
  WidgetTester tester,
  Widget child, {
  double scale = 1,
  Size size = const Size(375, 667),
  EdgeInsets padding = EdgeInsets.zero,
  ThemeMode mode = ThemeMode.dark,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(mode),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: padding,
          viewPadding: padding,
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

void _expectFittedBoard(WidgetTester tester, int players, Rect safeBounds) {
  final Finder grid = find.byType(GridView);
  final Rect boardBounds = tester.getRect(grid);
  expect(boardBounds.left, greaterThanOrEqualTo(safeBounds.left));
  expect(boardBounds.top, greaterThanOrEqualTo(safeBounds.top));
  expect(boardBounds.right, lessThanOrEqualTo(safeBounds.right));
  expect(boardBounds.bottom, lessThanOrEqualTo(safeBounds.bottom));
  final ScrollableState scrollable = tester.state<ScrollableState>(
    find.descendant(of: grid, matching: find.byType(Scrollable)),
  );
  expect(scrollable.position.maxScrollExtent, lessThanOrEqualTo(1));
  for (int index = 0; index < players; index++) {
    final List<Rect> bounds = <Rect>[];
    for (final String control in <String>['name', 'lose', 'gain']) {
      final Finder target = find.byKey(
        ValueKey<String>('game-player-$control-$index'),
      );
      expect(target.hitTestable(), findsOneWidget);
      final Rect targetBounds = tester.getRect(target);
      expect(targetBounds.width, greaterThanOrEqualTo(44));
      expect(targetBounds.height, greaterThanOrEqualTo(44));
      expect(targetBounds.left, greaterThanOrEqualTo(boardBounds.left));
      expect(targetBounds.top, greaterThanOrEqualTo(boardBounds.top));
      expect(targetBounds.right, lessThanOrEqualTo(boardBounds.right));
      expect(targetBounds.bottom, lessThanOrEqualTo(boardBounds.bottom));
      bounds.add(targetBounds);
    }
    expect(bounds[0].overlaps(bounds[1]), isFalse);
    expect(bounds[0].overlaps(bounds[2]), isFalse);
    expect(bounds[1].overlaps(bounds[2]), isFalse);
  }
}

void main() {
  setUpAll(loadCollectorFonts);
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final int count in <int>[3, 6, 8]) {
    testWidgets('$count player board fits every zone without scrolling', (
      WidgetTester tester,
    ) async {
      await _show(
        tester,
        GameSessionScreen(
          format: count == 3 ? GameFormat.standard : GameFormat.commander,
          players: count,
          userId: 'alice',
          store: SharedGameStore(firestore: FakeFirebaseFirestore()),
        ),
      );
      for (int index = 0; index < count; index++) {
        final Finder name = find.byKey(
          ValueKey<String>('game-player-name-$index'),
        );
        expect(name.hitTestable(), findsOneWidget);
        final Rect bounds = tester.getRect(name);
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.bottom, lessThanOrEqualTo(667));
      }
      for (final Element element in find.byType(Scrollable).evaluate()) {
        expect(
          tester
              .state<ScrollableState>(
                find.byElementPredicate(
                  (Element candidate) => candidate == element,
                ),
              )
              .position
              .maxScrollExtent,
          lessThanOrEqualTo(1),
        );
      }
      if (count == 3) {
        final Rect first = tester.getRect(
          find.byKey(const ValueKey<String>('game-player-panel-0')),
        );
        final Rect second = tester.getRect(
          find.byKey(const ValueKey<String>('game-player-panel-1')),
        );
        expect(first.left, second.left);
        expect(first.width, greaterThan(350));
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final (Size, EdgeInsets) viewport in <(Size, EdgeInsets)>[
    (
      const Size(844, 390),
      const EdgeInsets.only(left: 47, right: 47, bottom: 21),
    ),
    (const Size(568, 320), EdgeInsets.zero),
  ]) {
    final Size size = viewport.$1;
    final EdgeInsets padding = viewport.$2;
    for (final int players in <int>[6, 8]) {
      for (final ThemeMode mode in <ThemeMode>[
        ThemeMode.light,
        ThemeMode.dark,
      ]) {
        testWidgets(
          '$players player ${mode.name} landscape board fits at $size',
          (WidgetTester tester) async {
            await _show(
              tester,
              GameSessionScreen(
                format: GameFormat.commander,
                players: players,
                userId: 'alice',
                store: SharedGameStore(firestore: FakeFirebaseFirestore()),
              ),
              size: size,
              padding: padding,
              mode: mode,
            );
            _expectFittedBoard(
              tester,
              players,
              Rect.fromLTRB(
                padding.left,
                padding.top,
                size.width - padding.right,
                size.height - padding.bottom,
              ),
            );
            await tester.tap(
              find.byKey(ValueKey<String>('game-player-gain-${players - 1}')),
            );
            await tester.pumpAndSettle();
            expect(find.text('41'), findsOneWidget);
            expect(find.text('40'), findsNWidgets(players - 1));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('landscape Life opens above the dock and fits every player', (
    WidgetTester tester,
  ) async {
    const Size size = Size(568, 320);
    await _show(
      tester,
      CollectorHub(
        initialWorkspace: CollectorWorkspace.tabletop,
        tabletop: Builder(
          builder: (BuildContext context) => Center(
            child: PrimaryButton(
              onPressed: () => Arcane.push<void>(
                context,
                GameSessionScreen(
                  format: GameFormat.commander,
                  players: 8,
                  userId: 'alice',
                  store: SharedGameStore(firestore: FakeFirebaseFirestore()),
                ),
              ),
              child: const Text('Open Life'),
            ),
          ),
        ),
      ),
      size: size,
    );
    expect(
      find.byKey(const ValueKey<String>('dock-Tabletop')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.text('Open Life'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('dock-Tabletop')).hitTestable(),
      findsNothing,
    );
    _expectFittedBoard(tester, 8, Offset.zero & size);
    await tester.tap(find.byKey(const ValueKey<String>('game-done')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('dock-Tabletop')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape accessibility text keeps scrollable player zones', (
    WidgetTester tester,
  ) async {
    await _show(
      tester,
      GameSessionScreen(
        format: GameFormat.commander,
        players: 8,
        userId: 'alice',
        store: SharedGameStore(firestore: FakeFirebaseFirestore()),
      ),
      size: const Size(568, 320),
      scale: 2.35,
    );
    final GridView grid = tester.widget<GridView>(find.byType(GridView));
    final SliverGridDelegateWithFixedCrossAxisCount delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 1);
    final Finder scrollable = find.descendant(
      of: find.byType(GridView),
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
      greaterThan(0),
    );
    final Finder lastGain = find.byKey(
      const ValueKey<String>('game-player-gain-7'),
    );
    await tester.scrollUntilVisible(lastGain, 250, scrollable: scrollable);
    await tester.pumpAndSettle();
    expect(lastGain.hitTestable(), findsOneWidget);
    final Size target = tester.getSize(lastGain);
    expect(target.width, greaterThanOrEqualTo(44));
    expect(target.height, greaterThanOrEqualTo(44));
    await tester.tap(lastGain);
    await tester.pumpAndSettle();
    expect(find.text('41'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'board shows direct one-life controls and player editor exposes larger changes',
    (WidgetTester tester) async {
      await _show(
        tester,
        GameSessionScreen(
          format: GameFormat.standard,
          players: 2,
          userId: 'alice',
          store: SharedGameStore(firestore: FakeFirebaseFirestore()),
        ),
      );
      expect(find.text('+10'), findsNothing);
      expect(find.text('-10'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey<String>('game-player-name-0')),
      );
      await tester.pumpAndSettle();
      expect(find.text('+10').hitTestable(), findsOneWidget);
      await tester.tap(find.text('+10').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('30').hitTestable(), findsOneWidget);
      expect(
        find
            .byKey(const ValueKey<String>('game-player-name-input'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Life resumes the last local game and New game starts fresh', (
    WidgetTester tester,
  ) async {
    const GameSession saved = GameSession(
      id: '',
      ownerId: 'alice',
      format: GameFormat.standard,
      names: <String>['Alice', 'Bob'],
      life: <int>[29, 18],
      members: <String>['alice'],
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'game.alice.standard.2': jsonEncode(saved.toMap()),
    });
    await _show(
      tester,
      Provider<AppUser?>.value(
        value: AppUser(),
        child: HubDice(
          userId: 'alice',
          store: SharedGameStore(firestore: FakeFirebaseFirestore()),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('games-mode-life')));
    await tester.pumpAndSettle();
    expect(find.byType(GameSessionScreen), findsOneWidget);
    expect(find.text('29'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('game-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New game').hitTestable());
    await tester.pumpAndSettle();
    expect(find.byType(GameSessionScreen), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('game-new')));
    await tester.pumpAndSettle();
    expect(find.text('29'), findsNothing);
    expect(find.text('20'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
