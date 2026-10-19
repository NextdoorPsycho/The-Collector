import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/collection_organization.dart';
import 'package:the_collector/utils/crud.dart';

CollectionStore<MTGDeck> _groups(FakeFirebaseFirestore database) =>
    CollectionStore<MTGDeck>(
      collection: database.collection('user/alice/decks'),
      toMap: (MTGDeck group) => group.toMap(),
      fromMap: (String id, Map<String, Object?> data) =>
          MTGDeckMapper.fromMap(data)..id = id,
    );

// FakeFirestore's transaction writes are not awaited or isolated.
class _TransactionalFirestore extends FakeFirebaseFirestore {
  Future<void> _tail = Future<void>.value();
  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> handler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    final Future<void> previous = _tail;
    final Completer<void> release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      final _StagedTransaction transaction = _StagedTransaction();
      final T result = await handler(transaction);
      for (final Future<void> Function() write in transaction.writes) {
        await write();
      }
      return result;
    } finally {
      release.complete();
    }
  }
}

class _StagedTransaction extends Fake implements Transaction {
  final List<Future<void> Function()> writes = <Future<void> Function()>[];
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> reference,
  ) => reference.get();
  @override
  Transaction set<T>(
    DocumentReference<T> reference,
    T data, [
    SetOptions? options,
  ]) {
    writes.add(() => reference.set(data, options));
    return this;
  }

  @override
  Transaction update(
    DocumentReference<Object?> reference,
    Map<Object, Object?> data,
  ) {
    writes.add(() => reference.update(data));
    return this;
  }

  @override
  Transaction delete(DocumentReference<Object?> reference) {
    writes.add(reference.delete);
    return this;
  }
}

MTGCard _card({Finish finish = Finish.nonfoil, String language = 'en'}) =>
    MTGCard(
      name: 'Stored printing',
      setId: 'set',
      description: '',
      flavorText: '',
      cmc: 1,
      typeLine: 'Instant',
      rarity: Rarity.common,
      setType: SetType.expansion,
      manaCost: '{U}',
      scryfallId: 'printing',
      finish: finish,
      language: language,
    );

void main() {
  test(
    'a box holds 3200 distinct printings and 3200 copies independently',
    () async {
      final CollectionStore<MTGDeck> groups = _groups(
        _TransactionalFirestore(),
      );
      final CollectionOrganization organization = CollectionOrganization(
        groups: groups,
      );
      final List<DeckEntry> entries = <DeckEntry>[
        for (int index = 0; index < 3200; index++)
          DeckEntry(
            scryfallId:
                'd88a8e2d-2577-4a67-af86-${index.toString().padLeft(12, '0')}',
            finish: Finish.nonfoil,
            language: 'en',
            condition: 'Near Mint',
          ),
      ];
      final String distinct = await organization.createGroup(
        name: 'Archive box',
        kind: CollectionGroupKind.box,
        entries: entries,
      );
      expect((await groups.get(distinct)).effectiveEntries, hasLength(3200));
      final String copies = await organization.createGroup(
        name: 'Basic lands',
        kind: CollectionGroupKind.box,
        entries: <DeckEntry>[entries.first.copyWith(quantity: 3200)],
      );
      expect((await groups.get(copies)).effectiveEntries.single.quantity, 3200);
    },
  );

  test('membership growth rejects an oversized document before changing saved data', () async {
    final CollectionStore<MTGDeck> groups = _groups(_TransactionalFirestore());
    await groups.set(
      'full',
      MTGDeck(
        name: 'Full',
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
      ),
    );
    final CollectionOrganization organization = CollectionOrganization(
      groups: groups,
    );
    await expectLater(
      organization.setCardMembership(
        card: _card(),
        groupId: 'full',
        quantity: 1,
      ),
      throwsStateError,
    );
    expect((await groups.get('full')).effectiveEntries, hasLength(4500));
  });
  test('condition-specific rows survive quantity replacement and extra copies do not invent condition', () async {
    final CollectionStore<MTGDeck> groups = _groups(_TransactionalFirestore());
    final CollectionOrganization organization = CollectionOrganization(
      groups: groups,
    );
    await groups.set(
      'binder',
      MTGDeck(
        name: 'Binder',
        entries: const <DeckEntry>[
          DeckEntry(
            scryfallId: 'printing',
            quantity: 2,
            finish: Finish.nonfoil,
            language: 'en',
            condition: 'Near Mint',
          ),
          DeckEntry(
            scryfallId: 'printing',
            quantity: 3,
            finish: Finish.nonfoil,
            language: 'en',
            condition: 'Played',
          ),
        ],
      ),
    );
    await organization.setCardMembership(
      card: _card(),
      groupId: 'binder',
      quantity: 5,
    );
    final List<DeckEntry> unchanged = (await groups.get('binder'))
        .effectiveEntries;
    expect(unchanged.map((DeckEntry entry) => entry.condition), <String>[
      'Near Mint',
      'Played',
    ]);
    expect(unchanged.map((DeckEntry entry) => entry.quantity), <int>[2, 3]);
    await organization.setCardMembership(
      card: _card(),
      groupId: 'binder',
      quantity: 7,
    );
    final List<DeckEntry> increased = (await groups.get('binder'))
        .effectiveEntries;
    expect(increased.map((DeckEntry entry) => entry.quantity), <int>[2, 3, 2]);
    expect(increased.last.condition, isNull);
    expect(
      () => organization.setCardMembership(
        card: _card(),
        groupId: 'binder',
        quantity: 1000001,
      ),
      throwsArgumentError,
    );
    expect(
      () => organization.setCardMembership(
        card: _card(),
        groupId: 'bad/path',
        quantity: 1,
      ),
      throwsArgumentError,
    );
  });

  test('membership is replaced independently of owned quantity, section, finish and language', () async {
    final FakeFirebaseFirestore database = _TransactionalFirestore();
    final CollectionStore<MTGDeck> groups = _groups(database);
    final CollectionOrganization organization = CollectionOrganization(
      groups: groups,
    );
    await database.doc('user/alice/cards/printing').set(<String, Object?>{
      'quantity': 12,
    });
    await groups.set(
      'binder',
      MTGDeck(
        name: 'Binder',
        kind: CollectionGroupKind.binder,
        entries: <DeckEntry>[
          const DeckEntry(
            scryfallId: 'printing',
            quantity: 4,
            finish: Finish.nonfoil,
            language: 'en',
            condition: 'Near Mint',
          ),
          const DeckEntry(
            scryfallId: 'printing',
            quantity: 2,
            finish: Finish.foil,
            language: 'en',
          ),
          const DeckEntry(
            scryfallId: 'printing',
            quantity: 3,
            finish: Finish.nonfoil,
            language: 'ja',
          ),
          const DeckEntry(
            scryfallId: 'printing',
            quantity: 5,
            finish: Finish.nonfoil,
            language: 'en',
            section: DeckSection.sideboard,
          ),
        ],
      ),
    );
    await organization.setCardMembership(
      card: _card(),
      groupId: 'binder',
      quantity: 7,
    );
    await organization.setCardMembership(
      card: _card(),
      groupId: 'binder',
      quantity: 7,
    );
    final MTGDeck replaced = await groups.get('binder');
    expect(replaced.effectiveEntries, hasLength(4));
    final DeckEntry main = replaced.effectiveEntries.singleWhere(
      (DeckEntry entry) =>
          entry.section == DeckSection.mainboard &&
          entry.language == 'en' &&
          entry.finish == Finish.nonfoil,
    );
    expect(main.quantity, 7);
    expect(main.condition, 'Near Mint');
    await organization.setCardMembership(
      card: _card(),
      groupId: 'binder',
      quantity: 0,
    );
    expect((await groups.get('binder')).effectiveEntries, hasLength(3));
    expect(
      (await database.doc('user/alice/cards/printing').get())
          .data()!['quantity'],
      12,
    );
  });

  test('moving a nested folder rejects self, descendants, invalid parents and preserves the prior hierarchy', () async {
    final CollectionStore<MTGDeck> groups = _groups(_TransactionalFirestore());
    final CollectionOrganization organization = CollectionOrganization(
      groups: groups,
    );
    await groups.set(
      'root',
      MTGDeck(name: 'Root', kind: CollectionGroupKind.folder),
    );
    await groups.set(
      'child',
      MTGDeck(
        name: 'Child',
        kind: CollectionGroupKind.folder,
        parentId: 'root',
      ),
    );
    await groups.set(
      'box',
      MTGDeck(name: 'Box', kind: CollectionGroupKind.box),
    );
    await expectLater(
      organization.moveGroup(groupId: 'root', parentId: 'root'),
      throwsStateError,
    );
    await expectLater(
      organization.moveGroup(groupId: 'root', parentId: 'child'),
      throwsStateError,
    );
    await expectLater(
      organization.moveGroup(groupId: 'child', parentId: 'box'),
      throwsStateError,
    );
    await expectLater(
      organization.moveGroup(groupId: 'child', parentId: 'missing'),
      throwsStateError,
    );
    expect((await groups.get('child')).parentId, 'root');
    await organization.moveGroup(groupId: 'child');
    expect((await groups.get('child')).parentId, isNull);
    await organization.moveGroup(groupId: 'box', parentId: 'child');
    expect((await groups.get('box')).parentId, 'child');
  });

  test('delete never cascades to nested groups or owned cards', () async {
    final FakeFirebaseFirestore database = _TransactionalFirestore();
    final CollectionStore<MTGDeck> groups = _groups(database);
    final CollectionOrganization organization = CollectionOrganization(
      groups: groups,
    );
    await groups.set(
      'folder',
      MTGDeck(name: 'Folder', kind: CollectionGroupKind.folder),
    );
    await groups.set(
      'list',
      MTGDeck(
        name: 'List',
        kind: CollectionGroupKind.list,
        parentId: 'folder',
        cards: <String>['printing'],
      ),
    );
    await database.doc('user/alice/cards/printing').set(<String, Object?>{
      'quantity': 12,
    });
    await expectLater(
      organization.deleteGroup(groupId: 'folder'),
      throwsStateError,
    );
    expect(await groups.exists('folder'), isTrue);
    await organization.deleteGroup(groupId: 'list');
    await organization.deleteGroup(groupId: 'folder');
    expect(await groups.exists('folder'), isFalse);
    expect(
      (await database.doc('user/alice/cards/printing').get())
          .data()!['quantity'],
      12,
    );
  });

  test('import creation retries one atomic payload and rejects unrelated operation reuse', () async {
    final FakeFirebaseFirestore database = _TransactionalFirestore();
    final CollectionStore<MTGDeck> groups = _groups(database);
    final CollectionOrganization organization = CollectionOrganization(
      groups: groups,
    );
    await groups.set(
      'folder',
      MTGDeck(name: 'Folder', kind: CollectionGroupKind.folder),
    );
    Future<String> save() => organization.createGroup(
      name: 'Imported',
      kind: CollectionGroupKind.deck,
      parentId: 'folder',
      sourceUrl: 'https://moxfield.com/decks/example',
      sourceFormat: 'modern',
      entries: const <DeckEntry>[
        DeckEntry(
          scryfallId: 'printing',
          quantity: 4,
          section: DeckSection.maybeboard,
        ),
      ],
      operationId: 'import-id',
    );
    expect(await save(), 'import-id');
    expect(await save(), 'import-id');
    expect((await groups.streamAll().first), hasLength(2));
    final MTGDeck imported = await groups.get('import-id');
    expect(imported.parentId, 'folder');
    expect(imported.effectiveEntries.single.quantity, 4);
    expect(imported.effectiveEntries.single.section, DeckSection.maybeboard);
    await expectLater(
      organization.createGroup(name: 'Other', operationId: 'import-id'),
      throwsStateError,
    );
    await expectLater(
      organization.createGroup(
        name: 'Invalid',
        parentId: 'missing',
        operationId: 'invalid',
      ),
      throwsStateError,
    );
    expect(await groups.exists('invalid'), isFalse);
    expect((await database.collection('user/alice/cards').get()).docs, isEmpty);
  });

  test('concurrent inverse folder moves cannot create a cycle', () async {
    final CollectionStore<MTGDeck> groups = _groups(_TransactionalFirestore());
    final CollectionOrganization organization = CollectionOrganization(
      groups: groups,
    );
    await groups.set('a', MTGDeck(name: 'A', kind: CollectionGroupKind.folder));
    await groups.set('b', MTGDeck(name: 'B', kind: CollectionGroupKind.folder));
    Future<bool> move(String group, String parent) async {
      try {
        await organization.moveGroup(groupId: group, parentId: parent);
        return true;
      } on StateError {
        return false;
      }
    }

    final List<bool> moves = await Future.wait<bool>(<Future<bool>>[
      move('a', 'b'),
      move('b', 'a'),
    ]);
    expect(moves.where((bool accepted) => accepted), hasLength(1));
    final MTGDeck a = await groups.get('a');
    final MTGDeck b = await groups.get('b');
    expect(a.parentId == 'b' && b.parentId == 'a', isFalse);
  });

  test('oversized groups fail before any write while a reasonable imported list saves atomically', () async {
    final CollectionStore<MTGDeck> groups = _groups(_TransactionalFirestore());
    final CollectionOrganization organization = CollectionOrganization(
      groups: groups,
    );
    final List<DeckEntry> large = List<DeckEntry>.generate(
      10000,
      (int index) => DeckEntry(
        scryfallId:
            '00000000-0000-0000-0000-${index.toString().padLeft(12, '0')}',
        quantity: 4,
        language: 'en',
        finish: Finish.nonfoil,
        condition: 'Near Mint',
      ),
    );
    await expectLater(
      organization.createGroup(
        name: 'Oversized',
        kind: CollectionGroupKind.list,
        entries: large,
        operationId: 'large',
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('Container full'),
        ),
      ),
    );
    expect(await groups.exists('large'), isFalse);
    await organization.createGroup(
      name: 'Reasonable',
      kind: CollectionGroupKind.list,
      entries: large.take(1000).toList(),
      operationId: 'reasonable',
    );
    expect((await groups.get('reasonable')).effectiveEntries, hasLength(1000));
    expect((await groups.streamAll().first), hasLength(1));
  });
}
