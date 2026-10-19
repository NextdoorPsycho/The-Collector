import 'package:arcane/arcane.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_collector/pages/dock/hub.dart';
import 'package:the_collector/pages/dock/hub_dice.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/dice/dice_roller.dart';
import 'package:the_collector/utils/games/game_session.dart';

import 'dice_screen_test.dart' as fixture;
import 'helpers/dice_boundary_random.dart';
import 'helpers/load_collector_fonts.dart';

Finder control(String key) => find.byKey(ValueKey<String>(key));

Future<void> openEditor(WidgetTester tester, String key) async {
  await tester.ensureVisible(control(key));
  await tester.pumpAndSettle();
  await tester.tap(control(key));
  await tester.pumpAndSettle();
}

Future<void> closeEditor(WidgetTester tester) async {
  await tester.tap(control('tabletop-editor-close'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadCollectorFonts);
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
    'Roll Number Life are the tools and shared sessions live in Life',
    (WidgetTester tester) async {
      await fixture.showDice(tester, DiceRoller());
      expect(find.text('Roll'), findsOneWidget);
      expect(control('games-mode-sessions'), findsNothing);
      expect(control('life-sessions'), findsNothing);
      await fixture.chooseMode(tester, 'life');
      expect(control('life-sessions'), findsOneWidget);
      expect(control('game-format-commander'), findsNothing);
      await openEditor(tester, 'life-sessions');
      expect(find.text('Join a session'), findsOneWidget);
      expect(control('game-session-code'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rapid Roll input records every result during presentation', (
    WidgetTester tester,
  ) async {
    final DiceRoller roller = DiceRoller(random: BoundaryRandom(true));
    await fixture.showDice(tester, roller, animations: true);
    await tester.tap(control('dice-roll'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.widget<Button>(control('dice-roll')).onPressed, isNotNull);
    await tester.tap(control('dice-roll'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(control('dice-roll'));
    expect(roller.history, hasLength(3));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(control('dice-total')).data, '6');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'notation sheet edits next roll and history clears all outcomes',
    (WidgetTester tester) async {
      final DiceRoller roller = DiceRoller(random: BoundaryRandom(true));
      await fixture.showDice(tester, roller);
      expect(control('die-d20'), findsNothing);
      await openEditor(tester, 'dice-edit');
      await tester.tap(control('die-d20'));
      await tester.tap(find.widgetWithIcon(IconButton, Icons.plus));
      await closeEditor(tester);
      await tester.tap(control('dice-roll'));
      await tester.pumpAndSettle();
      expect(roller.history.single.values, <int>[20, 20]);
      expect(tester.widget<Text>(control('dice-total')).data, '40');
      await openEditor(tester, 'dice-edit');
      await tester.tap(control('die-d4'));
      await closeEditor(tester);
      expect(tester.widget<Text>(control('dice-total')).data, '40');
      await tester.tap(control('dice-roll'));
      await tester.pumpAndSettle();
      await openEditor(tester, 'dice-history');
      expect(find.text('2d20 · Total 40'), findsOneWidget);
      await tester.tap(find.text('Clear rolls'));
      await tester.pumpAndSettle();
      expect(roller.history, isEmpty);
      await closeEditor(tester);
      expect(tester.widget<Text>(control('dice-total')).data, 'Ready');
      expect(tester.takeException(), isNull);
    },
  );

  for (final ThemeMode theme in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'number editor preserves result and validates at ${theme.name} 2.35x',
      (WidgetTester tester) async {
        await fixture.showDice(
          tester,
          DiceRoller(),
          random: BoundaryRandom(true),
          mode: theme,
          scale: 2.35,
          size: const Size(320, 568),
        );
        await fixture.chooseMode(tester, 'number');
        await openEditor(tester, 'number-edit');
        await tester.enterText(control('number-minimum'), '-3');
        await tester.enterText(control('number-maximum'), '3');
        await tester.ensureVisible(control('number-range-save'));
        await tester.tap(control('number-range-save'));
        await tester.pumpAndSettle();
        await tester.tap(control('number-pick'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(control('number-result')).data, '3');
        await openEditor(tester, 'number-edit');
        await tester.enterText(control('number-minimum'), '4');
        await tester.ensureVisible(control('number-range-save'));
        await tester.tap(control('number-range-save'));
        await tester.pumpAndSettle();
        expect(find.text('Minimum must not exceed maximum.'), findsOneWidget);
        await closeEditor(tester);
        expect(tester.widget<Text>(control('number-result')).data, '3');
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('number presentation accepts repeated input and history clears', (
    WidgetTester tester,
  ) async {
    await fixture.showDice(
      tester,
      DiceRoller(),
      random: BoundaryRandom(true),
      animations: true,
    );
    await fixture.chooseMode(tester, 'number');
    await tester.tap(control('number-pick'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(control('number-pick'));
    await tester.pumpAndSettle();
    await openEditor(tester, 'number-history');
    expect(find.text('100 · 1 to 100'), findsNWidgets(2));
    await tester.tap(find.text('Clear numbers'));
    await tester.pumpAndSettle();
    expect(find.text('100 · 1 to 100'), findsNothing);
    await closeEditor(tester);
    expect(tester.widget<Text>(control('number-result')).data, 'Ready');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'range editor keeps Apply above the keyboard with enlarged text',
    (WidgetTester tester) async {
      await fixture.showDice(
        tester,
        DiceRoller(),
        scale: 2.35,
        size: const Size(320, 568),
      );
      await fixture.chooseMode(tester, 'number');
      await openEditor(tester, 'number-edit');
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.ensureVisible(control('number-maximum'));
      await tester.pumpAndSettle();
      await tester.enterText(control('number-maximum'), '12');
      expect(control('number-range-save').hitTestable(), findsOneWidget);
      expect(
        tester.getRect(control('number-range-save')).bottom,
        lessThanOrEqualTo(328),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final Size size in <Size>[const Size(320, 568), const Size(375, 667)]) {
    testWidgets(
      'large-text tabletop editors remain reachable above dock at $size',
      (WidgetTester tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 20, bottom: 34);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        await tester.pumpWidget(
          ArcaneApp(
            theme: MyThemeData.themeData(ThemeMode.light),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(2.35),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Provider<AppUser?>.value(
              value: AppUser(),
              child: CollectorHub(
                initialWorkspace: CollectorWorkspace.tabletop,
                cards: const SizedBox.shrink(),
                containers: const SizedBox.shrink(),
                scanner: const SizedBox.shrink(),
                more: const SizedBox.shrink(),
                tabletop: HubDice(
                  store: SharedGameStore(firestore: FakeFirebaseFirestore()),
                  userId: 'tabletop-layout-fixture',
                  roller: DiceRoller(random: BoundaryRandom(true)),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(control('dice-roll'));
        await tester.pumpAndSettle();
        for (final String key in <String>['dice-edit', 'dice-history']) {
          final Finder action = control(key);
          await tester.ensureVisible(action);
          await tester.pumpAndSettle();
          expect(action.hitTestable(), findsOneWidget);
          expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
          expect(
            tester.getRect(action).bottom,
            lessThanOrEqualTo(tester.getRect(control('dice-roll')).top),
          );
          await tester.tap(action);
          await tester.pumpAndSettle();
          expect(
            control('tabletop-editor-close').hitTestable(),
            findsOneWidget,
          );
          await closeEditor(tester);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
