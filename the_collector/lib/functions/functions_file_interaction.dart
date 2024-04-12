import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fast_log/fast_log.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/theme/toastification.dart';

String get uid => FirebaseAuth.instance.currentUser!.uid;
const int DEFAULT_BYTES_ALLOWED = 250 * 1024 * 1024; // 250MB in bytes

Map<String, String> mimes = {
  "jpg": "image/jpeg",
  "jpeg": "image/jpeg",
  "png": "image/png",
  "gif": "image/gif",
  "bmp": "image/bmp",
  "webp": "image/webp",
  "tiff": "image/tiff",
  "svg": "image/svg+xml",
  "json": "application/json",
};

class CardFunctions {
  static Future<void> _add(
      BuildContext context, MtgCard card, int quantity) async {
    info(card.name);
    info(card.id);
    try {
      String userId = FirebaseAuth.instance.currentUser!.uid;
      DocumentReference collectionRef = FirebaseFirestore.instance
          .collection('user')
          .doc(userId)
          .collection('cards')
          .doc(card.id);

      await collectionRef.set({'quantity': FieldValue.increment(quantity)},
          SetOptions(merge: true));

      Toast.successToast(context, "Collection updated",
          "Added $quantity of $card.id to the collection.");
    } catch (e) {
      error("Error updating collection: $e");
      Toast.scaryToast(
          context, "Update Failed", "Could not add to collection.");
    }
  }

  static Future<void> _remove(
      BuildContext context, MtgCard card, int quantity) async {
    try {
      String userId = FirebaseAuth.instance.currentUser!.uid;
      DocumentReference collectionRef = FirebaseFirestore.instance
          .collection('user')
          .doc(userId)
          .collection('cards')
          .doc(card.id);

      DocumentSnapshot snapshot = await collectionRef.get();
      Map<String, dynamic>? data = snapshot.data() as Map<String, dynamic>?;
      int currentQuantity = data?['quantity'] ?? 0;

      if (currentQuantity <= quantity) {
        await collectionRef.delete();
        Toast.successToast(context, "Collection updated",
            "Removed all of ${card.id} from the collection.");
      } else {
        await collectionRef
            .update({'quantity': FieldValue.increment(-quantity)});
        Toast.successToast(context, "Collection updated",
            "Removed $quantity of ${card.id} from the collection.");
      }
    } catch (e) {
      error("Error updating collection: $e");
      Toast.scaryToast(
          context, "Update Failed", "Could not remove from collection.");
    }
  }

  static Future<void> addCardToCollection({
    required MtgCard card,
    required BuildContext context,
    required int quantity,
  }) async {
    if (quantity <= 0) {
      Toast.infoToast(context, "No changes made", "Quantity must be positive.");
      return;
    }
    _add(context, card, quantity);
  }

  static Future<void> removeCardFromCollection({
    required MtgCard card,
    required BuildContext context,
    required int quantity,
  }) async {
    if (quantity <= 0) {
      Toast.infoToast(context, "No changes made", "Quantity must be positive.");
      return;
    }
    _remove(context, card, quantity);
  }
}
