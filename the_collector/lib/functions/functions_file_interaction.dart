import 'package:fast_log/fast_log.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

String get uid => FirebaseAuth.instance.currentUser!.uid;
Future<Map<String, String>> getPublicFiles() async {
  try {
    final ref = FirebaseStorage.instance.ref("user/$uid/public");
    final listResult = await ref.listAll();
    final fileUrls = await Future.wait(
      listResult.items.map((item) => item.getDownloadURL()),
    );
    final fileNames = listResult.items.map((item) => item.name).toList();
    return Map.fromIterables(fileNames, fileUrls);
  } catch (e) {
    error("Error retrieving public files: $e");
    return {};
  }
}

Future<Map<String, String>> getPrivateFiles() async {
  try {
    final ref = FirebaseStorage.instance.ref("user/$uid/private");
    final listResult = await ref.listAll();
    final fileUrls = await Future.wait(
      listResult.items.map((item) => item.getDownloadURL()),
    );
    final fileNames = listResult.items.map((item) => item.name).toList();
    return Map.fromIterables(fileNames, fileUrls);
  } catch (e) {
    error("Error retrieving private files: $e");
    return {};
  }
}

enum UploadType {
  public,
  private,
}
