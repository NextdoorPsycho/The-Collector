import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:collector_models/user/app_user_restricted.dart';

class CollectionStore<T> {
  final CollectionReference<T> collection;
  final Map<String, Object?> Function(T data) _toMap;

  CollectionStore({
    required CollectionReference<Map<String, dynamic>> collection,
    required Map<String, Object?> Function(T data) toMap,
    required T Function(String id, Map<String, Object?> data) fromMap,
  }) : _toMap = toMap,
       collection = collection.withConverter<T>(
         fromFirestore: (
           DocumentSnapshot<Map<String, dynamic>> snapshot,
           SnapshotOptions? options,
         ) => fromMap(snapshot.id, snapshot.data()!),
         toFirestore: (T data, SetOptions? options) => toMap(data),
       );

  Future<T> get(String id) async {
    final DocumentSnapshot<T> snapshot = await collection.doc(id).get();
    final T? data = snapshot.data();
    if (data == null) {
      throw StateError('Document ${snapshot.reference.path} does not exist.');
    }
    return data;
  }

  Future<bool> exists(String id) async =>
      (await collection.doc(id).get()).exists;

  Future<void> set(String id, T data) => collection.doc(id).set(data);

  Future<String> add(T data) async {
    final DocumentReference<T> reference = await collection.add(data);
    return reference.id;
  }

  Future<void> delete(String id) => collection.doc(id).delete();

  Stream<T?> streamOrNull(String id) => collection
      .doc(id)
      .snapshots()
      .map((DocumentSnapshot<T> snapshot) => snapshot.data());

  Stream<List<T>> streamAll() => collection.snapshots().map(
    (QuerySnapshot<T> snapshot) => snapshot.docs
        .map((QueryDocumentSnapshot<T> document) => document.data())
        .toList(),
  );

  Future<void> txn(String id, T Function(T data) update) => collection.firestore
      .runTransaction<void>((Transaction transaction) async {
        final DocumentReference<T> reference = collection.doc(id);
        final DocumentSnapshot<T> snapshot = await transaction.get(reference);
        final T? data = snapshot.data();
        if (data == null) {
          throw StateError('Document ${reference.path} does not exist.');
        }
        transaction.update(reference, _toMap(update(data)));
      });
}

class Crud {
  static CollectionStore<MTGDeck> deck(String userId) =>
      CollectionStore<MTGDeck>(
        collection: FirebaseFirestore.instance
            .collection('user')
            .doc(userId)
            .collection('decks'),
        toMap: (MTGDeck data) => data.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGDeckMapper.fromMap(data)..id = id,
      );

  static CollectionStore<MTGCard> card(String userId) =>
      CollectionStore<MTGCard>(
        collection: FirebaseFirestore.instance
            .collection('user')
            .doc(userId)
            .collection('cards'),
        toMap: (MTGCard data) => data.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGCardMapper.fromMap(data)..id = id,
      );

  static CollectionStore<AppUser> user() => CollectionStore<AppUser>(
    collection: FirebaseFirestore.instance.collection('user'),
    toMap: (AppUser data) => data.toMap(),
    fromMap: (String id, Map<String, Object?> data) =>
        AppUserMapper.fromMap(data)..id = id,
  );

  static CollectionStore<AppUserRestricted> userRestricted(String uid) =>
      CollectionStore<AppUserRestricted>(
        collection: FirebaseFirestore.instance
            .collection('user')
            .doc(uid)
            .collection('restricted'),
        toMap: (AppUserRestricted data) => data.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            AppUserRestrictedMapper.fromMap(data)..id = id,
      );
}
