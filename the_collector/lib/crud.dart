import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fire_crud/fire_crud.dart';
import 'package:magic_card/magic_card.dart';
import 'package:the_collector/utils/data/card/mtg_card.dart';
import 'package:the_collector/utils/data/deck/mtg_deck.dart';
import 'package:the_collector/utils/data/user/app_user.dart';
import 'package:the_collector/utils/data/user/app_user_restricted.dart';

class Crud {
  static FireCrud<MTGDeck> deck(String userId) => FireCrud(
        collection: FirebaseFirestore.instance
            .collection('user')
            .doc(userId)
            .collection('decks'),
        toMap: (d) => d.toMap(),
        fromMap: (id, data) => MTGDeckMapper.fromMap(data)..id = id,
      );

  static FireCrud<MTGCard> card(String userId) => FireCrud(
        collection: FirebaseFirestore.instance
            .collection('user')
            .doc(userId)
            .collection('cards'),
        toMap: (d) => d.toMap(),
        fromMap: (id, data) => MTGCardMapper.fromMap(data)..id = id,
      );

  static FireCrud<AppUser> user() => FireCrud(
        collection: FirebaseFirestore.instance.collection('user'),
        toMap: (d) => d.toMap(),
        fromMap: (id, data) => AppUserMapper.fromMap(data)..id = id,
      );

  static FireCrud<AppUserRestricted> userRestricted(String uid) => FireCrud(
        collection: FirebaseFirestore.instance
            .collection('user')
            .doc(uid)
            .collection("restricted"),
        toMap: (d) => d.toMap(),
        fromMap: (id, data) => AppUserRestrictedMapper.fromMap(data)..id = id,
      );
}

void go() async {
  String user = "123";
  MTGDeck deck = await Crud.deck(user).get("123");

  List<MTGCard> cards =
      await Future.wait(deck.cards.map((e) => Crud.card(user).get(e)));

  FireList<MTGCard> cardList = FireList(
    builder: (context, card) => CardView(id: card.id!),
    crud: Crud.card(user),
  );
}
