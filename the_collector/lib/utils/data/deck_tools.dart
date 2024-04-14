import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fast_log/fast_log.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/theme/toastification.dart';
import 'package:uuid/uuid.dart';

//await DeckFunctions.createDeck(
//   name: "My Fun Deck",
//   cards: cardsList,
//   color: "Red",
//   context: context,
// );
//
// DeckFunctions.exportDeckSimple(deck: myFunDeck, context: context);
// DeckFunctions.exportDeckDetailed(deck: myFunDeck, context: context);

class Deck {
  String id;
  String name;
  String? color;
  List<MtgCard> cards;
  String? coverImage;

  Deck({required this.name, this.color, required this.cards, this.coverImage})
      : id = const Uuid().v4(); // Generates a unique identifier for each deck
}

class DeckFunctions {
  static Future<void> createDeck({
    required String name,
    required List<MtgCard> cards,
    String? color,
    String? coverImage,
    required BuildContext context,
  }) async {
    try {
      Deck newDeck =
          Deck(name: name, cards: cards, color: color, coverImage: coverImage);
      String userId = FirebaseAuth.instance.currentUser!.uid;
      DocumentReference deckRef = FirebaseFirestore.instance
          .collection('user')
          .doc(userId)
          .collection('decks')
          .doc(newDeck.id);

      await deckRef.set({
        'name': newDeck.name,
        'color': newDeck.color,
        'coverImage': newDeck.coverImage,
        'cards': newDeck.cards.map((card) => card.toJson()).toList(),
      });

      Toast.successToast(
          context, "Deck Created", "Your new deck '${newDeck.name}' is ready.");
    } catch (e) {
      error("Error creating deck: $e");
      Toast.scaryToast(
          context, "Creation Failed", "Could not create the deck.");
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
        'cards': FieldValue.arrayUnion([card.toJson()])
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
        'cards': FieldValue.arrayRemove([card.toJson()])
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
}

// Utility function to convert MtgCard to JSON, assuming MtgCard class has this method
extension on MtgCard {
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'set': set,
      'type': typeLine,
      'colors': colors,
      'cmc': cmc,
      'manaCost': manaCost,
      'oracleText': oracleText,
      'foil': foil,
      'power': power,
      'toughness': toughness,
      'rarity': rarity,
      'image': imageUris?.normal,
    };
  }
}
