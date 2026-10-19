import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:collector_models/deck/deck_entry.dart';

const String _printing = 'd88a8e2d-2577-4a67-af86-e33c0ba94114';

MTGCard _card({Finish finish = Finish.nonfoil, String language = 'en'}) =>
    MTGCard(
      name: 'Test printing',
      setId: 'set-id',
      description: '',
      flavorText: '',
      cmc: 1,
      typeLine: 'Instant',
      rarity: Rarity.common,
      setType: SetType.expansion,
      manaCost: '{U}',
      scryfallId: _printing,
      finish: finish,
      language: language,
    );

void main() {
  test('a full scan destination rejects without adding inventory or a receipt', () async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final CollectionIngestion service = CollectionIngestion(
      firestore: database,
    );
    await database
        .doc('user/alice/decks/full')
        .set(
          MTGDeck(
            name: 'Full',
            kind: CollectionGroupKind.box,
            entries: <DeckEntry>[
              for (int index = 0; index < 4500; index++)
                DeckEntry(
                  scryfallId:
                      'd88a8e2d-2577-4a67-af86-${index.toString().padLeft(12, '0')}',
                  finish: Finish.nonfoil,
                  language: 'en',
                  condition: 'Near Mint',
                ),
            ],
          ).toMap(),
        );
    await expectLater(
      service.add(
        userId: 'alice',
        operationId: 'scan-full',
        card: _card(),
        deckId: 'full',
      ),
      throwsStateError,
    );
    expect((await database.collection('user/alice/cards').get()).docs, isEmpty);
    expect(
      (await database.collection('user/alice/ingestionOperations').get()).docs,
      isEmpty,
    );
    final MTGDeck full = MTGDeckMapper.fromMap(
      (await database.doc('user/alice/decks/full').get()).data()!,
    );
    expect(full.effectiveEntries, hasLength(4500));
  });
  for (final CollectionGroupKind kind in CollectionGroupKind.values) {
    test(
      'scan ingestion into ${kind.name} is atomic and receipt replay is idempotent',
      () async {
        final FakeFirebaseFirestore database = FakeFirebaseFirestore();
        final CollectionIngestion service = CollectionIngestion(
          firestore: database,
        );
        await database
            .doc('user/alice/decks/destination')
            .set(MTGDeck(name: 'Destination', kind: kind).toMap());
        for (int attempt = 0; attempt < 2; attempt++) {
          await service.add(
            userId: 'alice',
            operationId: 'container-scan',
            card: _card(),
            quantity: 3,
            deckId: 'destination',
          );
        }
        final MTGDeck group = MTGDeckMapper.fromMap(
          (await database.doc('user/alice/decks/destination').get()).data()!,
        );
        expect(group.kind, kind);
        expect(group.effectiveEntries.single.quantity, 3);
        expect(group.effectiveEntries.single.section, DeckSection.mainboard);
        expect(
          (await database.doc('user/alice/cards/$_printing').get())
              .data()!['quantity'],
          3,
        );
        expect(
          (await database.collection('user/alice/ingestionOperations').get())
              .docs,
          hasLength(1),
        );
        if (kind != CollectionGroupKind.deck) {
          await expectLater(
            service.add(
              userId: 'alice',
              operationId: 'invalid-section',
              card: _card(),
              deckId: 'destination',
              deckSection: DeckSection.sideboard,
            ),
            throwsArgumentError,
          );
          expect(
            (await database.doc('user/alice/cards/$_printing').get())
                .data()!['quantity'],
            3,
          );
          expect(
            (await database.collection('user/alice/ingestionOperations').get())
                .docs,
            hasLength(1),
          );
        }
      },
    );
  }
  test('scanner destination choices match the published receipt contract', () {
    final String rules = File('../firestore.rules').readAsStringSync();
    final RegExpMatch match = RegExp(r'deckSection in \[(.*?)\]')
        .firstMatch(rules)!;
    final Set<String> accepted = RegExp(r"'([^']+)'")
        .allMatches(match.group(1)!)
        .map((RegExpMatch value) => value.group(1)!)
        .toSet();
    expect(
      CollectionIngestion.destinationSections
          .map((DeckSection section) => section.name)
          .toSet(),
      accepted,
    );
  });

  test('unsupported scan sections fail before writes and imported sections remain intact', () async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final CollectionIngestion service = CollectionIngestion(
      firestore: database,
    );
    await database
        .doc('user/alice/decks/imported')
        .set(
          MTGDeck(
            name: 'Moxfield',
            entries: const <DeckEntry>[
              DeckEntry(
                scryfallId: _printing,
                quantity: 4,
                section: DeckSection.maybeboard,
              ),
            ],
          ).toMap(),
        );
    for (final DeckSection section in <DeckSection>[
      DeckSection.maybeboard,
      DeckSection.companion,
    ]) {
      await expectLater(
        service.add(
          userId: 'alice',
          operationId: section.name,
          card: _card(),
          deckId: 'imported',
          deckSection: section,
        ),
        throwsArgumentError,
      );
      expect(
        (await database.collection('user/alice/cards').get()).docs,
        isEmpty,
      );
      expect(
        (await database.collection('user/alice/ingestionOperations').get())
            .docs,
        isEmpty,
      );
    }
    await service.add(
      userId: 'alice',
      operationId: 'valid',
      card: _card(),
      deckId: 'imported',
    );
    final MTGDeck group = MTGDeckMapper.fromMap(
      (await database.doc('user/alice/decks/imported').get()).data()!,
    );
    expect(
      group.effectiveEntries
          .where((DeckEntry entry) => entry.section == DeckSection.maybeboard)
          .single
          .quantity,
      4,
    );
    expect(
      group.effectiveEntries
          .where((DeckEntry entry) => entry.section == DeckSection.mainboard)
          .single
          .quantity,
      1,
    );
    expect(
      (await database.doc('user/alice/cards/$_printing').get())
          .data()!['quantity'],
      1,
    );
  });

  test(
    'collection and destination deck increment once using the same receipt',
    () async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionIngestion service = CollectionIngestion(
        firestore: database,
      );
      await database
          .doc('user/alice/decks/deck')
          .set(MTGDeck(name: 'Existing', cards: <String>[_printing]).toMap());
      await service.add(
        userId: 'alice',
        operationId: 'scan',
        card: _card(),
        quantity: 2,
        deckId: 'deck',
      );
      await service.add(
        userId: 'alice',
        operationId: 'scan',
        card: _card(),
        quantity: 2,
        deckId: 'deck',
      );
      final MTGDeck deck = MTGDeckMapper.fromMap(
        (await database.doc('user/alice/decks/deck').get()).data()!,
      );
      expect(deck.effectiveEntries.single.quantity, 3);
      expect(deck.cards, <String>[_printing]);
      expect(
        (await database.doc('user/alice/cards/$_printing').get())
            .data()!['quantity'],
        2,
      );
      await expectLater(
        service.add(
          userId: 'alice',
          operationId: 'scan',
          card: _card(),
          quantity: 2,
          deckId: 'other',
        ),
        throwsStateError,
      );
      await expectLater(
        service.add(
          userId: 'alice',
          operationId: 'scan',
          card: _card(),
          quantity: 2,
          deckId: 'deck',
          deckSection: DeckSection.sideboard,
        ),
        throwsStateError,
      );
    },
  );

  test('missing destination deck rejects ingestion before any inventory or receipt write', () async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    await expectLater(
      CollectionIngestion(firestore: database).add(
        userId: 'alice',
        operationId: 'scan',
        card: _card(),
        deckId: 'missing',
      ),
      throwsStateError,
    );
    expect((await database.collection('user/alice/cards').get()).docs, isEmpty);
    expect(
      (await database.collection('user/alice/ingestionOperations').get()).docs,
      isEmpty,
    );
  });
  test(
    'replayed queued operation adds quantity once and new operation increments',
    () async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionIngestion service = CollectionIngestion(
        firestore: database,
      );
      final MTGCard card = _card();
      final IngestionResult first = await service.add(
        userId: 'alice',
        operationId: 'scan-item-1',
        card: card,
        quantity: 2,
      );
      final IngestionResult retry = await service.add(
        userId: 'alice',
        operationId: 'scan-item-1',
        card: card,
        quantity: 2,
      );
      expect(first.status, IngestionStatus.applied);
      expect(retry.status, IngestionStatus.previouslyApplied);
      await service.add(userId: 'alice', operationId: 'manual-1', card: card);
      final DocumentSnapshot<Map<String, dynamic>> stored = await database
          .doc('user/alice/cards/$_printing')
          .get();
      expect(stored.data()!['quantity'], 3);
    },
  );

  test('receipt survives inventory removal and prevents delayed retry resurrection', () async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final CollectionIngestion service = CollectionIngestion(
      firestore: database,
    );
    await service.add(userId: 'alice', operationId: 'queued', card: _card());
    await database.doc('user/alice/cards/$_printing').delete();
    expect(
      (await service.add(
        userId: 'alice',
        operationId: 'queued',
        card: _card(),
      )).status,
      IngestionStatus.previouslyApplied,
    );
    expect(
      (await database.doc('user/alice/cards/$_printing').get()).exists,
      isFalse,
    );
  });

  test(
    'different finishes stay separate and users have isolated receipts',
    () async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionIngestion service = CollectionIngestion(
        firestore: database,
      );
      await service.add(userId: 'alice', operationId: 'same', card: _card());
      await service.add(
        userId: 'alice',
        operationId: 'foil',
        card: _card(finish: Finish.foil),
        quantity: 4,
      );
      await service.add(
        userId: 'bob',
        operationId: 'same',
        card: _card(),
        quantity: 3,
      );
      expect(
        (await database.doc('user/alice/cards/$_printing').get())
            .data()!['quantity'],
        1,
      );
      expect(
        (await database.doc('user/alice/cards/${_printing}__foil').get())
            .data()!['quantity'],
        4,
      );
      expect(
        (await database.doc('user/bob/cards/$_printing').get())
            .data()!['quantity'],
        3,
      );
    },
  );

  test(
    'old card quantities and unknown fields survive metadata enrichment',
    () async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final Map<String, Object?> legacy = _card().copyWith(quantity: 7).toMap()
        ..remove('scryfallId')
        ..remove('finish')
        ..remove('language');
      legacy['userNote'] = 'Keep this note';
      await database.doc('user/alice/cards/$_printing').set(legacy);
      await CollectionIngestion(firestore: database)
          .add(userId: 'alice', operationId: 'add', card: _card());
      final Map<String, dynamic> stored =
          (await database.doc('user/alice/cards/$_printing').get()).data()!;
      expect(stored['quantity'], 8);
      expect(stored['userNote'], 'Keep this note');
      expect(stored['scryfallId'], _printing);
    },
  );

  test(
    'changed retry payload fails without another inventory update',
    () async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      final CollectionIngestion service = CollectionIngestion(
        firestore: database,
      );
      await service.add(userId: 'alice', operationId: 'same', card: _card());
      await expectLater(
        service.add(
          userId: 'alice',
          operationId: 'same',
          card: _card(),
          quantity: 2,
        ),
        throwsStateError,
      );
      await expectLater(
        service.add(
          userId: 'alice',
          operationId: 'same',
          card: _card(finish: Finish.foil),
        ),
        throwsStateError,
      );
      expect(
        (await database.doc('user/alice/cards/$_printing').get())
            .data()!['quantity'],
        1,
      );
    },
  );

  test('invalid quantity, owner paths, operation IDs and unknown finish fail before writes', () async {
    final FakeFirebaseFirestore database = FakeFirebaseFirestore();
    final CollectionIngestion service = CollectionIngestion(
      firestore: database,
    );
    await expectLater(
      service.add(
        userId: 'alice',
        operationId: 'op',
        card: _card(),
        quantity: 0,
      ),
      throwsArgumentError,
    );
    await expectLater(
      service.add(userId: 'alice/bob', operationId: 'op', card: _card()),
      throwsArgumentError,
    );
    await expectLater(
      service.add(userId: 'alice', operationId: '../op', card: _card()),
      throwsArgumentError,
    );
    await expectLater(
      service.add(
        userId: 'alice',
        operationId: 'op',
        card: _card(finish: Finish.unknown),
      ),
      throwsArgumentError,
    );
    expect(
      await database.collection('user/alice/cards').get(),
      isA<QuerySnapshot<Map<String, dynamic>>>(),
    );
    expect((await database.collection('user/alice/cards').get()).docs, isEmpty);
  });

  test(
    'preference transaction retains unmodeled fields and Commander setting',
    () async {
      final FakeFirebaseFirestore database = FakeFirebaseFirestore();
      await database.doc('user/alice').set(<String, Object?>{
        'theme': false,
        'showCommander': true,
        'userNote': 'Retain',
      });
      final CollectionStore<AppUser> store = CollectionStore<AppUser>(
        collection: database.collection('user'),
        toMap: (AppUser profile) => profile.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            AppUserMapper.fromMap(data)..id = id,
      );
      await store.txn('alice', (AppUser profile) => profile..toggleTheme());
      final Map<String, dynamic> result =
          (await database.doc('user/alice').get()).data()!;
      expect(result['theme'], isTrue);
      expect(result['showCommander'], isTrue);
      expect(result['userNote'], 'Retain');
    },
  );
}
