import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fast_log/fast_log.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:the_collector/functions/functions_file_interaction.dart';
import 'package:throttled/throttled.dart';

class UserManager {
  // Stream the user storage value (int)
  // User/uid/restricted/perms/{allocated}
  static Stream<int> streamStorage() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      error("User is not authenticated. Returning Stream.value(0) for storage.");
      return Stream.value(0);
    }
    return FirebaseFirestore.instance.collection('user').doc(uid).collection("restricted").doc("perms").snapshots().map((event) {
      int storage = event['allocated'] ?? 0;
      verbose("User storage: $storage");
      return storage;
    });
  }

  // Stream the user storage usage value (int)
  // User/uid/restricted/perms/{allocated}
  static Stream<int> streamStorageUsage() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      error("User is not authenticated. Returning Stream.value(0) for storage usage.");
      return Stream.value(0);
    }
    return FirebaseFirestore.instance.collection('user').doc(uid).collection("restricted").doc("perms").snapshots().asyncMap((event) async {
      int allocatedStorage = event['allocated'] ?? 0;
      int totalUsed = await calculateTotalUsed();
      verbose("User storage: $allocatedStorage, Total used: $totalUsed");
      return totalUsed;
    });
  }

  // Stream the user storage usage percentage (double)
  // User/uid/restricted/perms/{allocated}
  static Stream<double> streamStorageUsagePercentage() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      error("User is not authenticated. Returning Stream.value(0.0) for storage usage percentage.");
      return Stream.value(0.0);
    }
    return FirebaseFirestore.instance.collection('user').doc(uid).collection("restricted").doc("perms").snapshots().asyncMap((event) async {
      int allocatedStorage = event['allocated'] ?? 0;
      int totalUsed = await calculateTotalUsed();
      double usagePercentage = (totalUsed / allocatedStorage);
      verbose("User storage usage: ${(usagePercentage * 100).toStringAsFixed(2)}%");
      return usagePercentage;
    });
  }

  // Calculate the total storage used everyone
  //
  static Future<int> calculateTotalUsed() async {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      error("User is not authenticated. Returning 0 for total storage used.");
      return 0;
    }
    int allSizes = await calculateFolderSize("user/");
    verbose("Total data used: $allSizes");
    return allSizes;
  }

  // Check if the user is able to upload files
  // User/uid/restricted/perms/{uploader}
  static Stream<bool> streamUploaderStatus() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      error("User is not authenticated. Returning Stream.value(false) for uploader status.");
      return Stream.value(false);
    }
    return FirebaseFirestore.instance.collection('user').doc(uid).collection("restricted").doc("perms").snapshots().map((event) {
      bool isUploader = event['uploader'] == true;
      verbose("User uploader status: ${isUploader ? 'Uploader' : 'Not an uploader'}");
      return isUploader;
    });
  }

  // Check if the user is an 'admin'
  // User/uid/restricted/perms/{admin}
  static Stream<bool> streamAdminStatus() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      error("User is not authenticated. Returning Stream.value(false) for admin status.");
      return Stream.value(false);
    }
    return FirebaseFirestore.instance.collection('user').doc(uid).collection("restricted").doc("perms").snapshots().map((event) {
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
        FirebaseFirestore.instance.collection('user').doc(uid).set({'isDark': isDark});
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
      error("User is not authenticated. Returning Stream.value(false) for theme (default to light theme).");
      return Stream.value(false); // Default to light theme if user is not signed in
    }
    return FirebaseFirestore.instance.collection('user').doc(uid).snapshots().map((event) {
      bool isDarkMode = event['isDark'] == true;
      verbose("User theme: ${isDarkMode ? 'Dark Mode' : 'Light Mode'}");
      return isDarkMode;
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
