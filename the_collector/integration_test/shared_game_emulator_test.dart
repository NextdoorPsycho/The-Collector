import 'package:arcane/arcane.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:the_collector/pages/dock/hub_dice.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/utils/firebase_environment.dart';
import 'package:the_collector/utils/games/game_session.dart';

const String _host = String.fromEnvironment(
  'FIREBASE_EMULATOR_HOST',
  defaultValue: '127.0.0.1',
);

class _EmulatorClient {
  _EmulatorClient(this.app, this.auth, this.database);
  final FirebaseApp app;
  final FirebaseAuth auth;
  final FirebaseFirestore database;
  String get userId => auth.currentUser!.uid;

  Future<void> close() async {
    try {
      await auth.currentUser?.delete();
      await auth.signOut();
    } finally {
      try {
        await database.terminate();
      } finally {
        await app.delete();
      }
    }
  }
}

Future<_EmulatorClient> _connect(String name, FirebaseOptions options) async {
  final FirebaseApp app = await Firebase.initializeApp(
    name: name,
    options: options,
  );
  final FirebaseAuth auth = FirebaseAuth.instanceFor(app: app);
  final FirebaseFirestore database = FirebaseFirestore.instanceFor(app: app);
  final _EmulatorClient client = _EmulatorClient(app, auth, database);
  addTearDown(client.close);
  await auth.useAuthEmulator(_host, 19099);
  database.useFirestoreEmulator(_host, 18080);
  database.settings = const Settings(persistenceEnabled: false);
  await auth.signInAnonymously();
  return client;
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  final Stopwatch elapsed = Stopwatch()..start();
  while (finder.evaluate().isEmpty &&
      elapsed.elapsed < const Duration(seconds: 30)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsOneWidget);
  expect(tester.takeException(), isNull);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'independent emulator clients join, synchronize life, and observe owner ending the room',
    (WidgetTester tester) async {
      expect(
        const bool.fromEnvironment('USE_FIREBASE_EMULATORS'),
        isTrue,
        reason: 'This test requires local Firebase emulators.',
      );
      await initializeCollectorFirebase();
      final FirebaseOptions options = Firebase.app().options;
      expect(options.projectId, 'demo-the-collector');
      final String runId = DateTime.now().microsecondsSinceEpoch.toString();
      final _EmulatorClient owner = await _connect(
        'wireless-owner-$runId',
        options,
      );
      final _EmulatorClient guest = await _connect(
        'wireless-guest-$runId',
        options,
      );
      expect(owner.userId, isNot(guest.userId));
      final SharedGameStore ownerStore = SharedGameStore(
        firestore: owner.database,
      );
      final SharedGameStore guestStore = SharedGameStore(
        firestore: guest.database,
      );
      final GameSession room = await ownerStore.create(
        owner.userId,
        GameFormat.standard,
        2,
      );
      addTearDown(() async {
        final DocumentReference<Map<String, dynamic>> reference = owner.database
            .doc('gameSessions/${room.id}');
        if ((await reference.get(const GetOptions(source: Source.server)))
            .exists) {
          await ownerStore.end(room.id);
        }
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
      await ownerStore.rename(room.id, 0, 'Host');
      await ownerStore.rename(room.id, 1, 'Visitor');
      await ownerStore.changeLife(room.id, 0, -3);

      await tester.pumpWidget(
        ArcaneApp(
          theme: MyThemeData.themeData(ThemeMode.dark),
          home: Provider<AppUser?>.value(
            value: AppUser(),
            child: HubDice(store: guestStore, userId: guest.userId),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('games-mode-sessions')),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Join a session'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Join a session'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .descendant(
              of: find.byType(DialogText),
              matching: find.byType(EditableText),
            )
            .hitTestable()
            .first,
        ' ${room.id.toUpperCase()} ',
      );
      await tester.tap(find.text('Join').hitTestable());
      await _waitFor(tester, find.text('Host'));
      expect(find.text('Visitor'), findsOneWidget);
      expect(find.text('17'), findsOneWidget);
      final Map<String, Object?> joined = Map<String, Object?>.from(
        (await owner.database
                .doc('gameSessions/${room.id}')
                .get(const GetOptions(source: Source.server)))
            .data()!,
      );
      expect(joined['members'], <String>[owner.userId, guest.userId]);
      expect(joined['life'], <int>[17, 20]);

      final Future<GameSession?> ownerChange = ownerStore
          .stream(room.id)
          .firstWhere((GameSession? game) => game?.life.first == 16)
          .timeout(const Duration(seconds: 30));
      await tester.tap(find.text('-1').hitTestable().first);
      final GameSession synchronized = (await ownerChange)!;
      expect(synchronized.life, <int>[16, 20]);
      await _waitFor(tester, find.text('16'));

      await ownerStore.end(room.id);
      await _waitFor(tester, find.text('This session has ended.'));
      expect(find.text('Host'), findsNothing);
      expect(find.text('Return to games'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
