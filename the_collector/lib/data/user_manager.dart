import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class UserManager {
  // Check if the user is able to upload files
  // User/uid/restricted/perms/{uploader}
  static Stream<bool> streamUploaderStatus() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return Stream.value(false);
    }
    return FirebaseFirestore.instance.collection('user').doc(uid).collection("restricted").doc("perms").snapshots().map((event) => event['uploader'] == true);
  }

  // Check if the user is an 'admin'
  // User/uid/restricted/perms/{admin}
  static Stream<bool> streamAdminStatus() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return Stream.value(false);
    }
    return FirebaseFirestore.instance.collection('user').doc(uid).collection("restricted").doc("perms").snapshots().map((event) => event['admin'] == true);
  }

  // Update the value of Light or Dark Mode
  // User/uid/{isDark}
  static Future<void> updateTheme({required bool isDark}) async {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      await FirebaseFirestore.instance.collection('user').doc(uid).set({'isDark': isDark});
    }
  }

  // Get the value of Light or Dark Mode
  // User/uid/{isDark}
  static Stream<bool> streamTheme() {
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return Stream.value(false); // Default to light theme if user is not signed in
    }
    return FirebaseFirestore.instance.collection('user').doc(uid).snapshots().map((event) => event['isDark'] == true);
  }
}

// fixes the snap data
// Dont touch it.
extension XStream<T> on Stream<T> {
  Widget build(Widget Function(T? data) builder) => StreamBuilder<T>(stream: this, builder: (context, snap) => builder(snap.data));
}
