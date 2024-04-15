import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fast_log/fast_log.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/theme/toastification.dart';
import 'package:uuid/uuid.dart';

class Deck {
  String id;
  String name;
  List<MtgCard> cards;

  Deck({required this.name, required this.cards})
      : id = const Uuid().v4(); // Generates a unique identifier for each deck
}

class DeckFunctions {
  static Future<List<Deck>> getAllDecksByUserId() async {
    String userId = FirebaseAuth.instance.currentUser!.uid;
    List<Deck> decks = [];
    try {
      QuerySnapshot snapshot = await FirebaseFirestore.instance
          .collection('user')
          .doc(userId)
          .collection('decks')
          .get();

      decks = snapshot.docs.map((doc) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        List<MtgCard> cards = (data['cards'] as List)
            .map((card) => MtgCard.fromJson(card))
            .toList();

        return Deck(
          name: data['name'],
          cards: cards,
        );
      }).toList();
    } catch (e) {
      error("Error fetching decks: $e");
    }
    return decks;
  }

  static Future<bool> createDeck({
    required String name,
    required List<MtgCard> cards,
  }) async {
    try {
      Deck newDeck = Deck(name: name, cards: cards);
      String userId = FirebaseAuth.instance.currentUser!.uid;
      DocumentReference deckRef = FirebaseFirestore.instance
          .collection('user')
          .doc(userId)
          .collection('decks')
          .doc(newDeck.id);

      await deckRef.set({
        'name': newDeck.name,
        'cards': newDeck.cards,
      });

      return true;
    } catch (e) {
      error("Error creating deck: $e");
      return false;
    }
  }

  static Future<void> addCardToDeck({
    required String deckId,
    required MtgCard card,
    required BuildContext context,
  }) async {
    try {
      String userId = FirebaseAuth.instance.currentUser!.uid;
      DocumentReference deckRef = FirebaseFirestore.instance
          .collection('user')
          .doc(userId)
          .collection('decks')
          .doc(deckId);

      // Atomically add a new card to the 'cards' array field
      await deckRef.update({
        'cards': FieldValue.arrayUnion([card])
      });

      Toast.successToast(
          context, "Card Added", "Card added to deck successfully.");
    } catch (e) {
      error("Error adding card to deck: $e");
      Toast.scaryToast(context, "Update Failed", "Could not add card to deck.");
    }
  }

  static Future<void> removeCardFromDeck({
    required String deckId,
    required MtgCard card,
    required BuildContext context,
  }) async {
    try {
      String userId = FirebaseAuth.instance.currentUser!.uid;
      DocumentReference deckRef = FirebaseFirestore.instance
          .collection('user')
          .doc(userId)
          .collection('decks')
          .doc(deckId);

      // Atomically remove a card from the 'cards' array field
      await deckRef.update({
        'cards': FieldValue.arrayRemove([card])
      });

      Toast.successToast(
          context, "Card Removed", "Card removed from deck successfully.");
    } catch (e) {
      error("Error removing card from deck: $e");
      Toast.scaryToast(
          context, "Update Failed", "Could not remove card from deck.");
    }
  }

  static void exportDeckSimple({
    required Deck deck,
    required BuildContext context,
  }) {
    try {
      String exportData = deck.cards.fold<String>("", (previousValue, element) {
        return "$previousValue\n1 ${element.name}";
      }).trim();
      Clipboard.setData(ClipboardData(text: exportData));
      Toast.successToast(
          context, "Deck Exported", "Deck exported to clipboard successfully.");
    } catch (e) {
      error("Error exporting deck: $e");
      Toast.scaryToast(context, "Export Failed", "Could not export deck.");
    }
  }

  static void exportDeckDetailed({
    required Deck deck,
    required BuildContext context,
  }) {
    try {
      String exportData = deck.cards.fold<String>("", (previousValue, element) {
        return "$previousValue\n1 ${element.name} ${element.set} ${element.foil}";
      }).trim();
      Clipboard.setData(ClipboardData(text: exportData));
      Toast.successToast(
          context, "Deck Exported", "Deck exported to clipboard successfully.");
    } catch (e) {
      error("Error exporting deck: $e");
      Toast.scaryToast(context, "Export Failed", "Could not export deck.");
    }
  }

  static Future<Map<String, List<MtgCard>>> getCardsFromDeck() async {
    String userId = FirebaseAuth.instance.currentUser!.uid;
    Map<String, List<MtgCard>> deckCards = {};
    try {
      QuerySnapshot snapshot = await FirebaseFirestore.instance
          .collection('user')
          .doc(userId)
          .collection('decks')
          .get();

      for (var doc in snapshot.docs) {
        String deckId = doc.id;
        Map<String, dynamic>? data = doc.data() as Map<String, dynamic>?;
        List<MtgCard> cards = (data?['cards'] as List?)
                ?.map((card) => MtgCard.fromJson(card))
                .toList() ??
            [];
        deckCards[deckId] = cards;
      }
    } catch (e) {
      error("Error fetching cards from decks: $e");
    }
    return deckCards;
  }
}
