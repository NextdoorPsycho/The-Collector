import 'dart:async';
import 'dart:convert';

import 'package:arcane/arcane.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:the_collector/pages/dice/game_session_screen.dart';
import 'package:the_collector/pages/dock/hub_dice.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/games/game_session.dart';

import 'helpers/load_collector_fonts.dart';

class _RetryStore extends SharedGameStore {
  _RetryStore(this.game) : super(firestore: FakeFirebaseFirestore());
  final GameSession game;
  bool _fail = true;
  @override
  Stream<GameSession?> stream(String id) {
    if (_fail) {
      _fail = false;
      return Stream<GameSession?>.error(StateError('Unavailable'));
    }
    return Stream<GameSession?>.value(game);
  }
}

class _DelayedPreferences extends InMemorySharedPreferencesStore {
  _DelayedPreferences() : super.empty();
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  int writes = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes++;
    if (writes == 1) {
      entered.complete();
      await release.future;
    }
    return super.setValue(valueType, key, value);
  }
}

Future<void> _show(
  WidgetTester tester,
  Widget screen, {
  Size size = const Size(320, 640),
  double textScale = 1,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.dark),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: screen,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  setUpAll(loadCollectorFonts);
  testWidgets('four-player life controls fill the two halves of each zone', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _show(
      tester,
      GameSessionScreen(
        format: GameFormat.standard,
        players: 4,
        userId: 'alice',
        store: SharedGameStore(firestore: FakeFirebaseFirestore()),
      ),
      size: const Size(393, 852),
    );
    final Rect decrease = tester.getRect(
      find.byKey(const ValueKey<String>('game-player-lose-0')),
    );
    final Rect increase = tester.getRect(
      find.byKey(const ValueKey<String>('game-player-gain-0')),
    );
    expect(decrease.top, increase.top);
    expect(decrease.height, increase.height);
    expect(decrease.right, increase.left);
    expect(decrease.width, greaterThanOrEqualTo(90));
    expect(decrease.height, greaterThanOrEqualTo(200));
    expect(find.text('+10'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final int players in <int>[2, 4]) {
    for (final Size size in <Size>[
      const Size(320, 640),
      const Size(375, 667),
    ]) {
      testWidgets(
        '$players player game fits every life control at $size without scrolling',
        (WidgetTester tester) async {
          SharedPreferences.setMockInitialValues(<String, Object>{});
          await _show(
            tester,
            GameSessionScreen(
              format: GameFormat.standard,
              players: players,
              userId: 'alice',
              store: SharedGameStore(firestore: FakeFirebaseFirestore()),
            ),
            size: size,
          );
          final ScrollableState scroll = tester.state<ScrollableState>(
            find.descendant(
              of: find.byType(GridView),
              matching: find.byType(Scrollable),
            ),
          );
          expect(scroll.position.maxScrollExtent, lessThanOrEqualTo(1));
          for (int player = 0; player < players; player++) {
            expect(
              find
                  .byKey(ValueKey<String>('game-player-name-$player'))
                  .hitTestable(),
              findsOneWidget,
            );
          }
          for (final String delta in <String>['-1', '+1']) {
            expect(find.text(delta).hitTestable(), findsNWidgets(players));
            for (int player = 0; player < players; player++) {
              expect(
                tester
                    .getSize(
                      find.byKey(
                        ValueKey<String>(
                          'game-player-${delta == '+1' ? 'gain' : 'lose'}-$player',
                        ),
                      ),
                    )
                    .height,
                greaterThanOrEqualTo(44),
              );
            }
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'reopened local game waits for every earlier tap before accepting new changes',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferencesStorePlatform previous =
          SharedPreferencesStorePlatform.instance;
      final _DelayedPreferences preferences = _DelayedPreferences();
      SharedPreferencesStorePlatform.instance = preferences;
      addTearDown(() {
        if (!preferences.release.isCompleted) preferences.release.complete();
        SharedPreferencesStorePlatform.instance = previous;
      });
      final SharedGameStore store = SharedGameStore(
        firestore: FakeFirebaseFirestore(),
      );
      GameSessionScreen screen() => GameSessionScreen(
        format: GameFormat.standard,
        players: 2,
        userId: 'alice',
        store: store,
      );
      await _show(tester, screen());
      await tester.tap(find.text('+1').first);
      await tester.pumpAndSettle();
      expect(preferences.entered.isCompleted, isTrue);
      await tester.tap(find.text('+1').first);
      await tester.pumpAndSettle();
      expect(find.text('22'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await _show(tester, screen(), settle: false);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(preferences.writes, 1);
      preferences.release.complete();
      await tester.pumpAndSettle();
      expect(find.text('22'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('game-player-name-0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('+10').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('32').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Cancel').hitTestable());
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await _show(tester, screen());
      expect(find.text('32'), findsOneWidget);
      expect(preferences.writes, 3);
      expect(tester.takeException(), isNull);
    },
  );
  for (final double textScale in <double>[1, 2]) {
    testWidgets(
      '320px eight-player game fits touch controls at $textScale text scale',
      (WidgetTester tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        await _show(
          tester,
          GameSessionScreen(
            format: GameFormat.standard,
            players: 8,
            userId: 'alice',
            store: SharedGameStore(firestore: FakeFirebaseFirestore()),
          ),
          size: const Size(320, 667),
          textScale: textScale,
        );
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.text('Player 8'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Player 8'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('ending a shared game removes the board and stops progress', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final SharedGameStore store = SharedGameStore(firestore: database);
    const GameSession game = GameSession(
      id: '0123456789abcdef',
      ownerId: 'alice',
      format: GameFormat.standard,
      names: <String>['Alice', 'Bob'],
      life: <int>[20, 20],
      members: <String>['alice', 'bob'],
    );
    await database.doc('gameSessions/${game.id}').set(game.toMap());
    await _show(
      tester,
      GameSessionScreen(
        format: game.format,
        players: 2,
        sharedId: game.id,
        userId: 'bob',
        store: store,
      ),
    );
    expect(find.text('Alice'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('game-actions')));
    await tester.pumpAndSettle();
    expect(find.text('End session'), findsNothing);
    await tester.tap(find.text('Done').hitTestable());
    await tester.pumpAndSettle();
    await store.end(game.id);
    await tester.pumpAndSettle();
    expect(find.text('This session has ended.'), findsOneWidget);
    expect(find.text('Return to games'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shared stream failure stops progress and Retry restores the board',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const GameSession game = GameSession(
        id: '0123456789abcdef',
        ownerId: 'alice',
        format: GameFormat.standard,
        names: <String>['Alice', 'Bob'],
        life: <int>[20, 20],
        members: <String>['alice'],
      );
      await _show(
        tester,
        GameSessionScreen(
          format: game.format,
          players: 2,
          sharedId: game.id,
          userId: 'alice',
          store: _RetryStore(game),
        ),
      );
      expect(
        find.text('Could not load this session. Check your connection.'),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Alice'), findsNothing);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('game-actions')));
      await tester.pumpAndSettle();
      expect(find.text('End session').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Done').hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.text('Could not load this session. Check your connection.'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Commander is hidden by default and shown by the streamed preference',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await _show(
        tester,
        Provider<AppUser?>.value(
          value: AppUser(),
          child: HubDice(
            store: SharedGameStore(firestore: FakeFirebaseFirestore()),
            userId: 'alice',
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('games-mode-life')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('games-mode-life')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Commander · 40 life'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('game-format-commander')),
        findsNothing,
      );
      await _show(
        tester,
        Provider<AppUser?>.value(
          value: AppUser(showCommander: true),
          child: HubDice(
            store: SharedGameStore(firestore: FakeFirebaseFirestore()),
            userId: 'alice',
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('game-format-commander')),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Commander · 40 life'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Commander · 40 life'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('two-player board faces the upper player toward the opponent', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _show(
      tester,
      GameSessionScreen(
        format: GameFormat.standard,
        players: 2,
        userId: 'alice',
        store: SharedGameStore(firestore: FakeFirebaseFirestore()),
      ),
    );
    final Transform upper = tester.widget<Transform>(
      find.byKey(const ValueKey<String>('game-player-panel-0')),
    );
    final Transform lower = tester.widget<Transform>(
      find.byKey(const ValueKey<String>('game-player-panel-1')),
    );
    expect(upper.transform.entry(0, 0), closeTo(-1, .001));
    expect(lower.transform.entry(0, 0), closeTo(1, .001));
    await tester.tap(find.text('+1').last);
    await tester.pumpAndSettle();
    expect(find.text('21'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final int players in <int>[2, 4, 6, 8]) {
    testWidgets(
      '$players player saved game restores and scrolls on a narrow screen',
      (WidgetTester tester) async {
        final GameSession saved = GameSession(
          id: '',
          ownerId: 'alice',
          format: GameFormat.commander,
          names: List<String>.generate(players, (int i) => 'Saved ${i + 1}'),
          life: List<int>.generate(players, (int i) => 41 + i),
          members: <String>['alice'],
        );
        SharedPreferences.setMockInitialValues(<String, Object>{
          'game.alice.commander.$players': jsonEncode(saved.toMap()),
        });
        await _show(
          tester,
          GameSessionScreen(
            format: GameFormat.commander,
            players: players,
            userId: 'alice',
            store: SharedGameStore(firestore: FakeFirebaseFirestore()),
          ),
        );
        expect(find.text('Saved 1'), findsOneWidget);
        expect(find.text('41'), findsOneWidget);
        if (players > 2) {
          await tester.scrollUntilVisible(
            find.text('Saved $players'),
            230,
            scrollable: find.descendant(
              of: find.byType(GridView),
              matching: find.byType(Scrollable),
            ),
          );
        }
        expect(find.text('Saved $players'), findsOneWidget);
        expect(find.text('${40 + players}'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'local life change persists and reloads without leaking to another user',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedGameStore store = SharedGameStore(
        firestore: FakeFirebaseFirestore(),
      );
      await _show(
        tester,
        GameSessionScreen(
          format: GameFormat.standard,
          players: 2,
          userId: 'alice',
          store: store,
        ),
      );
      await tester.tap(find.text('+1').first);
      await tester.pumpAndSettle();
      expect(find.text('21'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await _show(
        tester,
        GameSessionScreen(
          format: GameFormat.standard,
          players: 2,
          userId: 'alice',
          store: store,
        ),
      );
      expect(find.text('21'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await _show(
        tester,
        GameSessionScreen(
          format: GameFormat.standard,
          players: 2,
          userId: 'bob',
          store: store,
        ),
      );
      expect(find.text('21'), findsNothing);
      expect(find.text('20'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'malformed saved session reports recovery and allows a fresh game',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'game.alice.standard.2': '{broken',
      });
      await _show(
        tester,
        GameSessionScreen(
          format: GameFormat.standard,
          players: 2,
          userId: 'alice',
          store: SharedGameStore(firestore: FakeFirebaseFirestore()),
        ),
      );
      expect(
        find.text('Could not restore the saved game. Starting a new session.'),
        findsOneWidget,
      );
      await tester.tap(find.text('+1').first);
      await tester.pumpAndSettle();
      expect(find.text('21'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
