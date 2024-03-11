import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class UserManager {
  static Stream<bool> streamUploaderStatus() {
    String uid = FirebaseAuth.instance.currentUser!.uid;
    return FirebaseFirestore.instance.collection('user').doc(uid).collection("restricted").doc("perms").snapshots().map((event) => event['uploader'] == true);
  }
}

// fixes the snap data
extension XStream<T> on Stream<T> {
  Widget build(Widget Function(T? data) builder) => StreamBuilder<T>(stream: this, builder: (context, snap) => builder(snap.data));
}
