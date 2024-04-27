import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fire_crud/fire_crud.dart';
import 'package:the_collector/utils/json/deck.dart';

class Crud {
  static FireCrud<Deck> deck(String userId) => FireCrud(
      collection: FirebaseFirestore.instance
          .collection('user')
          .doc(userId)
          .collection('decks'),
      toMap: (d) => d.toMap(),
      fromMap: (id, data) => Deck.fromMap(data)
        ..id = id
        ..exists = true);
}
