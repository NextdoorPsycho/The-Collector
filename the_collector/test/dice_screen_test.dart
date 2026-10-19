import 'dart:async';
import 'dart:math';

import 'package:arcane/arcane.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_collector/pages/dock/hub_dice.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/dice/dice_roller.dart';
import 'package:the_collector/utils/games/game_session.dart';

import 'helpers/dice_boundary_random.dart';
import 'helpers/load_collector_fonts.dart';

class _PendingSessionsStore extends SharedGameStore {
  _PendingSessionsStore(this.sessions)
    : super(firestore: FakeFirebaseFirestore());

  final Stream<List<GameSession>> sessions;

  @override
  Stream<List<GameSession>> mySessions(String userId) => sessions;
}

class _RetrySessionsStore extends SharedGameStore {
  _RetrySessionsStore() : super(firestore: FakeFirebaseFirestore());

  int subscriptions = 0;

  @override
  Stream<List<GameSession>> mySessions(String userId) {
    subscriptions++;
    if (subscriptions == 1) {
      return Stream<List<GameSession>>.error(StateError('Unavailable'));
    }
    return Stream<List<GameSession>>.value(<GameSession>[
      GameSession(
        id: '0123456789abcdef',
        ownerId: userId,
        format: GameFormat.standard,
        names: const <String>['Alice', 'Bob'],
        life: const <int>[20, 20],
        members: <String>[userId],
      ),
    ]);
  }
}

class _JoinStore extends SharedGameStore {
  _JoinStore() : super(firestore: FakeFirebaseFirestore());
  final List<String> codes = <String>[];
  final Completer<GameSession> result = Completer<GameSession>();
  @override
  Future<GameSession> join(String code, String userId) {
    codes.add(code);
    expect(userId, 'dice-fixture');
    return result.future;
  }
}

Future<void> showDice(
  WidgetTester tester,
  DiceRoller roller, {
  ThemeMode mode = ThemeMode.dark,
  double scale = 1,
  bool commander = false,
  SharedGameStore? store,
  bool animations = false,
  Size size = const Size(320, 667),
  Random? random,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(mode),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: !animations,
        ),
        child: child!,
      ),
      home: Provider<AppUser?>.value(
        value: AppUser().copyWith(showCommander: commander),
        child: HubDice(
          store: store ?? SharedGameStore(firestore: FakeFirebaseFirestore()),
          userId: 'dice-fixture',
          roller: roller,
          random: random,
        ),
      ),
    ),
  );
  if (animations) {
    await tester.pump(const Duration(milliseconds: 100));
  } else {
    await tester.pumpAndSettle();
  }
}

Future<void> see(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> chooseMode(WidgetTester tester, String mode) async {
  await tester.tap(find.byKey(ValueKey<String>('games-mode-$mode')));
  await tester.pumpAndSettle();
}

Finder keyed(String key) => find.byKey(ValueKey<String>(key));

Future<void> edit(WidgetTester tester, String key) async {
  await tester.ensureVisible(keyed(key));
  await tester.pumpAndSettle();
  await tester.tap(keyed(key));
  await tester.pumpAndSettle();
}

Future<void> dismissEditor(WidgetTester tester) async {
  await tester.tap(keyed('tabletop-editor-close'));
  await tester.pumpAndSettle();
}

Future<void> showSessions(WidgetTester tester) async {
  await chooseMode(tester, 'life');
  await tester.ensureVisible(keyed('life-sessions'));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(keyed('life-sessions'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> range(WidgetTester tester, String minimum, String maximum) async {
  await edit(tester, 'number-edit');
  await tester.enterText(keyed('number-minimum'), minimum);
  await tester.enterText(keyed('number-maximum'), maximum);
  await tester.tap(keyed('number-range-save'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadCollectorFonts);
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('large-text mode names remain complete words', (
    WidgetTester tester,
  ) async {
    await showDice(
      tester,
      DiceRoller(),
      scale: 2.35,
      size: const Size(375, 667),
    );
    for (final String mode in <String>['dice', 'number', 'life']) {
      final Finder text = find
          .descendant(
            of: keyed('games-mode-$mode'),
            matching: find.byType(RichText),
          )
          .first;
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        text,
      );
      final String label = paragraph.text.toPlainText();
      expect(
        paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: label.length),
        ),
        hasLength(1),
        reason: label,
      );
    }
  });

  testWidgets('normal-size notation editor occupies only its controls', (
    WidgetTester tester,
  ) async {
    await showDice(tester, DiceRoller(), size: const Size(375, 667));
    await edit(tester, 'dice-edit');
    expect(
      tester.getRect(keyed('tabletop-editor-close')).top,
      greaterThan(300),
    );
    for (final int sides in DiceRoller.supportedSides) {
      expect(keyed('die-d$sides').hitTestable(), findsOneWidget);
    }
    expect(
      find.widgetWithIcon(IconButton, Icons.plus).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('session code joins once and pending work cannot be duplicated', (
    WidgetTester tester,
  ) async {
    final _JoinStore store = _JoinStore();
    await showDice(tester, DiceRoller(), store: store);
    await showSessions(tester);
    await tester.pumpAndSettle();
    final Finder join = keyed('game-session-join');
    expect(tester.widget<PrimaryButton>(join).onPressed, isNull);
    await tester.enterText(keyed('game-session-code'), '0123456789abcdef');
    await tester.pumpAndSettle();
    await tester.tap(join);
    await tester.pumpAndSettle();
    expect(store.codes, <String>['0123456789abcdef']);
    expect(tester.widget<PrimaryButton>(join).onPressed, isNull);
    expect(
      tester.widget<TextButton>(keyed('game-session-start')).onPressed,
      isNull,
    );
    await tester.tap(find.text('Joining…'));
    expect(store.codes, hasLength(1));
    store.result.completeError(StateError('private room diagnostic'));
    await tester.pumpAndSettle();
    expect(
      find
          .text('Could not join. Check the code and your connection.')
          .hitTestable(),
      findsOneWidget,
    );
    expect(find.textContaining('private room diagnostic'), findsNothing);
    expect(tester.widget<PrimaryButton>(join).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared session list retries a failed subscription in Life', (
    WidgetTester tester,
  ) async {
    final _RetrySessionsStore store = _RetrySessionsStore();
    await showDice(tester, DiceRoller(), store: store);
    await showSessions(tester);
    await tester.pumpAndSettle();
    expect(store.subscriptions, 1);
    expect(
      find.text('Could not load shared sessions. Check your connection.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(OutlineButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(store.subscriptions, 2);
    expect(find.text('Alice · Bob'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'shared loading resolves data and errors at ${mode.name} 2.35x',
      (WidgetTester tester) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        final StreamController<List<GameSession>> sessions =
            StreamController<List<GameSession>>();
        try {
          await showDice(
            tester,
            DiceRoller(),
            mode: mode,
            scale: 2.35,
            store: _PendingSessionsStore(sessions.stream),
            animations: true,
          );
          await showSessions(tester);
          final Finder label = find.text('Loading shared sessions…');
          await tester.scrollUntilVisible(
            label,
            200,
            scrollable: find.byType(Scrollable).last,
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(label.hitTestable(), findsOneWidget);
          expect(
            find.bySemanticsLabel('Loading shared sessions…'),
            findsOneWidget,
          );
          final Size artwork = tester.getSize(find.byType(SvgPicture));
          expect(artwork.width, closeTo(artwork.height, .01));
          expect(artwork.width, inInclusiveRange(40, 64));
          expect(tester.takeException(), isNull);
          sessions.add(<GameSession>[
            const GameSession(
              id: 'saved-room',
              ownerId: 'dice-fixture',
              format: GameFormat.standard,
              names: <String>['Alice', 'Bob'],
              life: <int>[21, 20],
              members: <String>['dice-fixture'],
            ),
          ]);
          await tester.pumpAndSettle();
          expect(label, findsNothing);
          expect(find.text('Alice · Bob'), findsOneWidget);
          sessions.addError(StateError('Unavailable'));
          await tester.pumpAndSettle();
          expect(find.text('Alice · Bob'), findsNothing);
          expect(
            find.text('Could not load shared sessions. Check your connection.'),
            findsOneWidget,
          );
          sessions.add(<GameSession>[]);
          await tester.pumpAndSettle();
          expect(find.text('No shared sessions yet.'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          semantics.dispose();
          unawaited(sessions.close());
        }
      },
    );
  }

  for (final bool upper in <bool>[false, true]) {
    testWidgets(
      'number range includes the ${upper ? 'upper' : 'lower'} endpoint and clears history',
      (WidgetTester tester) async {
        final DiceRoller roller = DiceRoller();
        await showDice(tester, roller, random: BoundaryRandom(upper));
        await chooseMode(tester, 'number');
        await range(tester, '-3', '3');
        await tester.tap(keyed('number-pick'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(keyed('number-result')).data,
          upper ? '3' : '-3',
        );
        expect(find.text('-3 to 3 · inclusive'), findsOneWidget);
        expect(roller.history, isEmpty);
        await range(tester, '3', '3');
        await tester.tap(keyed('number-pick'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(keyed('number-result')).data, '3');
        await edit(tester, 'number-history');
        expect(find.text('${upper ? 3 : -3} · -3 to 3'), findsOneWidget);
        await dismissEditor(tester);
        await chooseMode(tester, 'life');
        await chooseMode(tester, 'number');
        expect(tester.widget<Text>(keyed('number-result')).data, '3');
        await edit(tester, 'number-history');
        await tester.tap(find.text('Clear numbers'));
        await tester.pumpAndSettle();
        await dismissEditor(tester);
        expect(tester.widget<Text>(keyed('number-result')).data, 'Ready');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'number range rejects invalid signed bounds without changing the active range',
    (WidgetTester tester) async {
      await showDice(tester, DiceRoller(), random: BoundaryRandom(true));
      await chooseMode(tester, 'number');
      for (final ({String minimum, String maximum, String error}) invalid
          in <({String minimum, String maximum, String error})>[
            (
              minimum: '4',
              maximum: '3',
              error: 'Minimum must not exceed maximum.',
            ),
            (
              minimum: '1.5',
              maximum: '3',
              error: 'Use whole numbers from −999999 to 999999.',
            ),
            (
              minimum: '999999999999',
              maximum: '3',
              error: 'Use whole numbers from −999999 to 999999.',
            ),
            (
              minimum: '-9223372036854775808',
              maximum: '3',
              error: 'Use whole numbers from −999999 to 999999.',
            ),
            (
              minimum: '1',
              maximum: '-9223372036854775808',
              error: 'Use whole numbers from −999999 to 999999.',
            ),
          ]) {
        await range(tester, invalid.minimum, invalid.maximum);
        expect(find.text(invalid.error), findsOneWidget);
        await dismissEditor(tester);
        expect(tester.widget<Text>(keyed('number-result')).data, 'Ready');
      }
      await tester.tap(keyed('number-pick'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(keyed('number-result')).data, '100');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'number animation announces the generated value and retains twelve results',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        await showDice(
          tester,
          DiceRoller(),
          random: BoundaryRandom(true),
          animations: true,
        );
        await chooseMode(tester, 'number');
        await range(tester, '1', '999999');
        for (int index = 0; index < 13; index++) {
          await tester.tap(keyed('number-pick'));
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(
          find.bySemanticsLabel('999999, picked from 1 to 999999, inclusive.'),
          findsOneWidget,
        );
        expect(
          tester.widget<Button>(keyed('number-pick')).onPressed,
          isNotNull,
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(keyed('number-result')).data, '999999');
        await edit(tester, 'number-history');
        expect(find.text('999999 · 1 to 999999'), findsNWidgets(12));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'animated roll exposes the true outcome once and can settle on a mode change',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        final DiceRoller roller = DiceRoller(random: BoundaryRandom(true));
        await showDice(tester, roller, animations: true);
        expect(
          find.bySemanticsLabel('No roll yet. 1 die with 6 sides.'),
          findsOneWidget,
        );
        await edit(tester, 'dice-edit');
        await tester.tap(keyed('die-d20'));
        await dismissEditor(tester);
        await tester.tap(keyed('dice-roll'));
        await tester.pump();
        expect(roller.history.single.values, <int>[20]);
        expect(find.bySemanticsLabel('1d20: 20, total 20'), findsOneWidget);
        final Finder motion = keyed('dice-total-motion');
        final double opacity = tester.widget<Opacity>(motion).opacity;
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.widget<Opacity>(motion).opacity, isNot(opacity));
        expect(tester.widget<Text>(keyed('dice-total')).data, '20');
        await chooseMode(tester, 'life');
        await chooseMode(tester, 'dice');
        expect(roller.history, hasLength(1));
        expect(tester.widget<Opacity>(motion).opacity, 1);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'reduced motion shows the roll immediately and dispose cancels presentation',
    (WidgetTester tester) async {
      await showDice(tester, DiceRoller(random: BoundaryRandom(false)));
      await tester.tap(keyed('dice-roll'));
      await tester.pump();
      expect(tester.widget<Text>(keyed('dice-total')).data, '1');
      expect(tester.widget<Opacity>(keyed('dice-total-motion')).opacity, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await showDice(tester, DiceRoller(), animations: true);
      await tester.tap(keyed('dice-roll'));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'ten d100 outcomes remain reachable at 320px ${mode.name} 2.35x',
      (WidgetTester tester) async {
        final DiceRoller roller = DiceRoller(random: BoundaryRandom(true));
        await showDice(tester, roller, mode: mode, scale: 2.35);
        await edit(tester, 'dice-edit');
        final Finder minus = find.widgetWithIcon(IconButton, Icons.minus);
        final Finder plus = find.widgetWithIcon(IconButton, Icons.plus);
        expect(tester.widget<IconButton>(minus).onPressed, isNull);
        await see(tester, keyed('die-d100'));
        await tester.tap(keyed('die-d100'));
        await see(tester, plus);
        for (int index = 0; index < 9; index++) {
          await tester.tap(plus);
          await tester.pumpAndSettle();
        }
        expect(tester.widget<IconButton>(plus).onPressed, isNull);
        await dismissEditor(tester);
        final Button roll = tester.widget<Button>(keyed('dice-roll'));
        expect(roll.disableTransition, isTrue);
        expect(roll.enableFeedback, isFalse);
        expect(
          tester.getSize(keyed('dice-roll')).height,
          greaterThanOrEqualTo(44),
        );
        await tester.tap(keyed('dice-roll'));
        await tester.pumpAndSettle();
        expect(find.text('1000'), findsOneWidget);
        expect(find.text('100'), findsNWidgets(10));
        await see(tester, keyed('dice-history'));
        await edit(tester, 'dice-history');
        expect(find.text('Clear rolls').hitTestable(), findsOneWidget);
        await dismissEditor(tester);
        await chooseMode(tester, 'life');
        expect(find.text('Standard · 20 life'), findsOneWidget);
        expect(keyed('game-format-commander'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('die selection semantics and Commander presets follow Settings', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await showDice(tester, DiceRoller(), commander: true);
      await edit(tester, 'dice-edit');
      expect(find.bySemanticsLabel('Add one die'), findsOneWidget);
      expect(find.bySemanticsLabel('Remove one die'), findsOneWidget);
      final Semantics selected = tester.widget<Semantics>(
        find
            .ancestor(of: keyed('die-d6'), matching: find.byType(Semantics))
            .first,
      );
      expect(selected.properties.selected, isTrue);
      await dismissEditor(tester);
      await chooseMode(tester, 'life');
      await tester.tap(keyed('game-players-3'));
      await tester.tap(keyed('game-format-commander'));
      await tester.pumpAndSettle();
      expect(find.text('Commander · 40 life'), findsOneWidget);
      expect(keyed('game-players-3'), findsNothing);
      for (final int count in <int>[2, 4, 6, 8]) {
        expect(keyed('game-players-$count'), findsOneWidget);
      }
      await tester.tap(keyed('game-players-8'));
      await tester.tap(keyed('game-format-standard'));
      await tester.pumpAndSettle();
      expect(keyed('game-players-8'), findsNothing);
      expect(keyed('game-players-3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  for (final ThemeMode mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      '320px ${mode.name} keeps primary actions visible and mode changes preserve rolls',
      (WidgetTester tester) async {
        final DiceRoller roller = DiceRoller(random: BoundaryRandom(true));
        await showDice(tester, roller, mode: mode, size: const Size(320, 568));
        for (final String tool in <String>['dice', 'number', 'life']) {
          expect(keyed('games-mode-$tool').hitTestable(), findsOneWidget);
          expect(
            tester.getSize(keyed('games-mode-$tool')).height,
            greaterThanOrEqualTo(44),
          );
        }
        expect(keyed('dice-roll').hitTestable(), findsOneWidget);
        await tester.tap(keyed('dice-roll'));
        await tester.pumpAndSettle();
        await chooseMode(tester, 'life');
        expect(keyed('game-new').hitTestable(), findsOneWidget);
        expect(keyed('life-sessions').hitTestable(), findsOneWidget);
        expect(keyed('game-players-3').hitTestable(), findsOneWidget);
        await chooseMode(tester, 'dice');
        expect(roller.history.single.values, <int>[6]);
        expect(tester.widget<Text>(keyed('dice-total')).data, '6');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
