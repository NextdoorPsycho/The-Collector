import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/firebase_options.dart';
import 'package:the_collector/utils/collection_ingestion.dart';

const String _printing = 'd88a8e2d-2577-4a67-af86-e33c0ba94114';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native Firestore transactions preserve counts across concurrent retries',
    (WidgetTester tester) async {
      const bool emulators = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
      expect(
        emulators,
        isTrue,
        reason: 'This test requires local Firebase emulators.',
      );
      const String host = String.fromEnvironment(
        'FIREBASE_EMULATOR_HOST',
        defaultValue: '127.0.0.1',
      );
      final FirebaseApp app = await Firebase.initializeApp(
        name: 'ingestion-emulator-${DateTime.now().microsecondsSinceEpoch}',
        options: FirebaseOptions(
          apiKey: 'A00000000000000000000000000000000000000',
          appId: DefaultFirebaseOptions.currentPlatform.appId,
          messagingSenderId: '123456789',
          projectId: 'demo-the-collector',
          authDomain: 'localhost',
        ),
      );
      addTearDown(app.delete);
      final FirebaseFirestore database = FirebaseFirestore.instanceFor(
        app: app,
      );
      addTearDown(database.terminate);
      final FirebaseAuth auth = FirebaseAuth.instanceFor(app: app);
      addTearDown(() async {
        try {
          await auth.currentUser?.delete();
        } finally {
          await auth.signOut();
        }
      });
      await auth.useAuthEmulator(host, 19099);
      database.useFirestoreEmulator(host, 18080);
      database.settings = const Settings(persistenceEnabled: false);
      final UserCredential credentials = await auth.signInAnonymously();
      final String userId = credentials.user!.uid;
      final CollectionIngestion ingestion = CollectionIngestion(
        firestore: database,
      );
      final MTGCard card = MTGCard(
        name: 'Local emulator printing',
        setId: 'fixture-set',
        description: '',
        flavorText: '',
        cmc: 1,
        typeLine: 'Instant',
        rarity: Rarity.common,
        setType: SetType.expansion,
        manaCost: '{R}',
        scryfallId: _printing,
        finish: Finish.nonfoil,
        language: 'en',
      );
      final DocumentReference<Map<String, dynamic>> inventory = database.doc(
        'user/$userId/cards/$_printing',
      );
      final DocumentReference<Map<String, dynamic>> deck = database.doc(
        'user/$userId/decks/bulk',
      );
      await inventory.set(<String, Object?>{
        ...card.copyWith(quantity: 17).toMap(),
        'customNote': 'Preserve existing data',
      });
      await deck.set(
        MTGDeck(name: 'Local batch', cards: <String>[_printing]).toMap(),
      );
      final List<Future<IngestionResult>> additions = <Future<IngestionResult>>[
        for (int index = 0; index < 4; index++)
          ingestion.add(
            userId: userId,
            operationId: 'bulk-$index',
            card: card,
            quantity: 2,
            deckId: 'bulk',
          ),
      ];
      final List<IngestionResult> applied = await Future.wait(additions);
      expect(
        applied.every(
          (IngestionResult result) => result.status == IngestionStatus.applied,
        ),
        isTrue,
      );
      final List<IngestionResult> retried = await Future.wait(
        <Future<IngestionResult>>[
          for (int index = 0; index < 4; index++)
            ingestion.add(
              userId: userId,
              operationId: 'bulk-$index',
              card: card,
              quantity: 2,
              deckId: 'bulk',
            ),
        ],
      );
      expect(
        retried.every(
          (IngestionResult result) =>
              result.status == IngestionStatus.previouslyApplied,
        ),
        isTrue,
      );
      final Map<String, dynamic> stored = (await inventory.get(
        const GetOptions(source: Source.server),
      )).data()!;
      expect(stored['quantity'], 25);
      expect(stored['customNote'], 'Preserve existing data');
      final MTGDeck savedDeck = MTGDeckMapper.fromMap(
        (await deck.get(const GetOptions(source: Source.server))).data()!,
      );
      expect(savedDeck.effectiveEntries.single.quantity, 9);
      final QuerySnapshot<Map<String, dynamic>> receipts = await database
          .collection('user/$userId/ingestionOperations')
          .get(const GetOptions(source: Source.server));
      expect(receipts.docs.length, 4);
      await expectLater(
        ingestion.add(
          userId: userId,
          operationId: 'missing-destination',
          card: card,
          deckId: 'deleted-deck',
        ),
        throwsStateError,
      );
      expect(
        (await inventory.get(const GetOptions(source: Source.server)))
            .data()!['quantity'],
        25,
      );
      expect(
        (await database
                .doc('user/$userId/ingestionOperations/missing-destination')
                .get())
            .exists,
        isFalse,
      );
    },
  );
}
