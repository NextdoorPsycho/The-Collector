import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fast_log/fast_log.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:magic_card/magic_card.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:throttled/throttled.dart';

class UserManager {
  // Check if the user is an 'admin'
  // User/uid/restricted/perms/{admin}
  static Stream<bool> streamAdminStatus() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      error(
          "User is not authenticated. Returning Stream.value(false) for admin status.");
      return Stream.value(false);
    }
    return FirebaseFirestore.instance
        .collection('user')
        .doc(uid)
        .collection("restricted")
        .doc("perms")
        .snapshots()
        .map((event) {
      bool isAdmin = event['admin'] == true;
      verbose("User admin status: ${isAdmin ? 'Admin' : 'Not an admin'}");
      return isAdmin;
    });
  }

  // Update the value of Light or Dark Mode
  // User/uid/{isDark}
  static Future<void> updateTheme({required bool isDark}) async {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      throttle("theme_switch", () {
        FirebaseFirestore.instance
            .collection('user')
            .doc(uid)
            .set({'isDark': isDark});
        verbose("Theme updated to: ${isDark ? 'Dark Mode' : 'Light Mode'}");
      }, leaky: true, cooldown: const Duration(seconds: 2));
    } else {
      error("User is not authenticated. Theme update skipped.");
    }
  }

  // Get the value of Light or Dark Mode
  // User/uid/{isDark}
  static Stream<bool> streamTheme() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      error(
          "User is not authenticated. Returning Stream.value(false) for theme (default to light theme).");
      return Stream.value(
          false); // Default to light theme if user is not signed in
    }
    return FirebaseFirestore.instance
        .collection('user')
        .doc(uid)
        .snapshots()
        .map((event) {
      bool isDarkMode = event['isDark'] == true;
      verbose("User theme: ${isDarkMode ? 'Dark Mode' : 'Light Mode'}");
      return isDarkMode;
    });
  }

  static Stream<Map<MtgCard, int>> streamCollection() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      error(
          "User is not authenticated. Returning an empty Stream for collection.");
      return Stream.value({});
    }

    return FirebaseFirestore.instance
        .collection('user')
        .doc(uid)
        .collection('cards')
        .snapshots()
        .asyncMap((snapshot) async {
      Map<MtgCard, int> cardCountMap = {};

      for (var doc in snapshot.docs) {
        String cardId = doc.id;
        int quantity = doc.data()['quantity'] ??
            0; // Get the quantity from the document data

        if (quantity > 0) {
          try {
            MtgCard? card = await CardSearch.getCardByID(
                cardId); // Use the instance to call the method
            if (card != null) {
              cardCountMap[card] = quantity; // Map the card to its count
            }
          } catch (e) {
            error("Error fetching card with ID $cardId: $e");
          }
        }
      }

      return cardCountMap;
    });
  }
}

// fixes the snap data
extension XStream<T> on Stream<T> {
  Widget build(Widget Function(T? data) builder) {
    return StreamBuilder<T>(
      stream: this,
      builder: (context, snap) {
        return builder(snap.data);
      },
    );
  }
}
