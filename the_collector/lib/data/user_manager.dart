import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fast_log/fast_log.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:throttled/throttled.dart';

class UserManager {
  // Check if the user is able to upload files
  // User/uid/restricted/perms/{uploader}
  static Stream<bool> streamUploaderStatus() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      info("User is not authenticated. Returning Stream.value(false) for uploader status.");
      return Stream.value(false);
    }
    info("Streaming uploader status for user with uid: $uid");
    return FirebaseFirestore.instance.collection('user').doc(uid).collection("restricted").doc("perms").snapshots().map((event) {
      bool isUploader = event['uploader'] == true;
      info("User uploader status: ${isUploader ? 'Uploader' : 'Not an uploader'}");
      return isUploader;
    });
  }

  // Check if the user is an 'admin'
  // User/uid/restricted/perms/{admin}
  static Stream<bool> streamAdminStatus() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      info("User is not authenticated. Returning Stream.value(false) for admin status.");
      return Stream.value(false);
    }
    info("Streaming admin status for user with uid: $uid");
    return FirebaseFirestore.instance.collection('user').doc(uid).collection("restricted").doc("perms").snapshots().map((event) {
      bool isAdmin = event['admin'] == true;
      info("User admin status: ${isAdmin ? 'Admin' : 'Not an admin'}");
      return isAdmin;
    });
  }

  // Update the value of Light or Dark Mode
  // User/uid/{isDark}
  static Future<void> updateTheme({required bool isDark}) async {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      info("Updating theme for user with uid: $uid");
      throttle("theme_switch", () {
        FirebaseFirestore.instance.collection('user').doc(uid).set({'isDark': isDark});
        info("Theme updated to: ${isDark ? 'Dark Mode' : 'Light Mode'}");
      }, leaky: true, cooldown: const Duration(seconds: 1));
    } else {
      info("User is not authenticated. Theme update skipped.");
    }
  }

  // Get the value of Light or Dark Mode
  // User/uid/{isDark}
  static Stream<bool> streamTheme() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      info("User is not authenticated. Returning Stream.value(false) for theme (default to light theme).");
      return Stream.value(false); // Default to light theme if user is not signed in
    }
    info("Streaming theme for user with uid: $uid");
    return FirebaseFirestore.instance.collection('user').doc(uid).snapshots().map((event) {
      bool isDarkMode = event['isDark'] == true;
      info("User theme: ${isDarkMode ? 'Dark Mode' : 'Light Mode'}");
      return isDarkMode;
    });
  }
}

// fixes the snap data
extension XStream<T> on Stream<T> {
  Widget build(Widget Function(T? data) builder) {
    info("Building StreamBuilder for Stream<$T>");
    return StreamBuilder<T>(
      stream: this,
      builder: (context, snap) {
        info("StreamBuilder data: ${snap.data}");
        return builder(snap.data);
      },
    );
  }
}
