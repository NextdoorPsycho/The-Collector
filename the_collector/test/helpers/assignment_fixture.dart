import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/crud.dart';

class AssignmentDatabase extends FakeFirebaseFirestore {
  bool failNextTransaction = false;
  int transactions = 0;
  int committedWrites = 0;

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> handler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    transactions++;
    if (failNextTransaction) {
      failNextTransaction = false;
      throw StateError('Offline');
    }
    final _Transaction transaction = _Transaction();
    final T result = await handler(transaction);
    for (final Future<void> Function() write in transaction.writes) {
      await write();
      committedWrites++;
    }
    return result;
  }
}

class _Transaction extends Fake implements Transaction {
  final List<Future<void> Function()> writes = <Future<void> Function()>[];
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> reference,
  ) => reference.get();
  @override
  Transaction update(
    DocumentReference<Object?> reference,
    Map<Object, Object?> data,
  ) {
    writes.add(() => reference.update(data));
    return this;
  }
}

CollectionStore<MTGDeck> assignmentGroups(AssignmentDatabase database) =>
    CollectionStore<MTGDeck>(
      collection: database.collection('user/alice/decks'),
      toMap: (MTGDeck group) => group.toMap(),
      fromMap: (String id, Map<String, Object?> data) =>
          MTGDeckMapper.fromMap(data)..id = id,
    );

CollectionStore<MTGCard> assignmentCards(AssignmentDatabase database) =>
    CollectionStore<MTGCard>(
      collection: database.collection('user/alice/cards'),
      toMap: (MTGCard card) => card.toMap(),
      fromMap: (String id, Map<String, Object?> data) =>
          MTGCardMapper.fromMap(data)..id = id,
    );

MTGCard assignmentCard(
  String id, {
  String? printing,
  String name = 'Alpha',
  int quantity = 1,
  Finish finish = Finish.nonfoil,
  String language = 'en',
}) => MTGCard(
  name: name,
  setId: 'fixture',
  description: '',
  flavorText: '',
  cmc: 1,
  typeLine: 'Instant',
  rarity: Rarity.common,
  setType: SetType.expansion,
  manaCost: '{U}',
  scryfallId: printing ?? id,
  quantity: quantity,
  finish: finish,
  language: language,
  setCode: 'ICE',
  setName: 'Ice Age',
  collectorNumber: '1',
  oracleText: 'Fixture',
)..id = id;
