import 'package:arcane/arcane.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_collector/pages/dice/game_session_screen.dart';
import 'package:the_collector/pages/dock/hub_dice.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/games/game_session.dart';

Future<void> _openJoin(WidgetTester tester, SharedGameStore store) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.pumpWidget(
    ArcaneApp(
      theme: MyThemeData.themeData(ThemeMode.dark),
      home: Provider<AppUser?>.value(
        value: AppUser(),
        child: HubDice(store: store, userId: 'guest'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey<String>('games-mode-life')).hitTestable(),
    findsOneWidget,
  );
  await tester.tap(find.byKey(const ValueKey<String>('games-mode-life')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey<String>('life-sessions')));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey<String>('game-session-code')),
    findsOneWidget,
  );
}

void main() {
  testWidgets(
    'real join dialog adds the guest and opens the existing shared board',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final SharedGameStore store = SharedGameStore(firestore: database);
      final GameSession room = await store.create(
        'owner',
        GameFormat.standard,
        2,
      );
      await store.rename(room.id, 0, 'Host');
      await store.rename(room.id, 1, 'Visitor');
      await store.changeLife(room.id, 0, -3);
      await _openJoin(tester, store);
      await tester.enterText(
        find
            .descendant(
              of: find.byKey(const ValueKey<String>('game-session-code')),
              matching: find.byType(EditableText),
            )
            .hitTestable()
            .first,
        ' ${room.id.toUpperCase()} ',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('game-session-join')));
      await tester.pumpAndSettle();

      final GameSession joined = GameSession.fromMap(
        room.id,
        Map<String, Object?>.from(
          (await database.doc('gameSessions/${room.id}').get()).data()!,
        ),
      );
      expect(joined.members, <String>['owner', 'guest']);
      expect(joined.life, <int>[17, 20]);
      expect(
        find.byKey(const ValueKey<String>('game-session-code')),
        findsNothing,
      );
      expect(find.byType(GameSessionScreen), findsOneWidget);
      expect(find.text('Host'), findsOneWidget);
      expect(find.text('Visitor'), findsOneWidget);
      expect(find.text('17'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('game-actions')));
      await tester.pumpAndSettle();
      expect(find.text('Copy code').hitTestable(), findsOneWidget);
      expect(
        find
            .text('Could not join. Check the code and your connection.')
            .hitTestable(),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid dialog code leaves owner membership and existing scores unchanged',
    (WidgetTester tester) async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final SharedGameStore store = SharedGameStore(firestore: database);
      final GameSession room = await store.create(
        'owner',
        GameFormat.standard,
        2,
      );
      await _openJoin(tester, store);
      await tester.enterText(
        find
            .descendant(
              of: find.byKey(const ValueKey<String>('game-session-code')),
              matching: find.byType(EditableText),
            )
            .hitTestable()
            .first,
        '1234',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('game-session-join')));
      await tester.pumpAndSettle();

      final GameSession unchanged = GameSession.fromMap(
        room.id,
        Map<String, Object?>.from(
          (await database.doc('gameSessions/${room.id}').get()).data()!,
        ),
      );
      expect(unchanged.members, <String>['owner']);
      expect(unchanged.life, <int>[20, 20]);
      expect(find.byType(GameSessionScreen), findsNothing);
      expect(
        find
            .text('Could not join. Check the code and your connection.')
            .hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
