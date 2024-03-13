import 'package:firebase_auth/firebase_auth.dart';

String get uid => FirebaseAuth.instance.currentUser!.uid;
