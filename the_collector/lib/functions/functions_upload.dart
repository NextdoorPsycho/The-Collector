import 'package:fast_log/fast_log.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';

String get uid => FirebaseAuth.instance.currentUser!.uid;
Map<String, String> mimes = {
  "jpg": "image/jpeg",
  "jpeg": "image/jpeg",
  "png": "image/png",
  "gif": "image/gif",
  "bmp": "image/bmp",
  "webp": "image/webp",
  "tiff": "image/tiff",
  "svg": "image/svg+xml",
  "pdf": "application/pdf",
  "zip": "application/zip",
  "mp3": "audio/mpeg",
  "wav": "audio/wav",
  "ogg": "audio/ogg",
  "mp4": "video/mp4",
  "mkv": "video/x-matroska",
  "webm": "video/webm",
  "mov": "video/quicktime",
  "txt": "text/plain",
  "json": "application/json",
};

// Updated uploadToPublic function with fileName parameter
Future<bool> uploadToPublic(BuildContext context, String path, String hint, {String? uploadedFile, Uint8List? uploadedBytes, String? fileName}) async {
  String mime = mimes[hint] ?? "application/octet-stream";
  try {
    // If fileName is provided, use it; otherwise, use the default path
    final String uploadPath = fileName != null ? "$path/$fileName" : path;
    final ref = FirebaseStorage.instance.ref(uploadPath);
    verbose('Starting upload of $uploadPath');
    if (kIsWeb && uploadedBytes != null) {
      await ref.putData(uploadedBytes, SettableMetadata(contentType: mime));
    } else if (uploadedFile != null) {
      await ref.putFile(File(uploadedFile), SettableMetadata(contentType: mime));
    }
    verbose('Finished upload of $uploadPath');
    return true;
  } catch (e) {
    error("Firebase Upload Error $e");
    return false;
  }
}

Future<void> uploadFiles({required BuildContext context, required UploadType uploadType}) async {
  FilePicker.platform
      .pickFiles(
    withData: kIsWeb,
    allowMultiple: true,
  )
      .then((value) {
    if (value != null) {
      return Future.wait(value.files.map((e) {
        String filePath = "user/$uid/${uploadType.name}/${e.name}";
        return uploadToPublic(context, filePath, e.extension ?? 'bin', uploadedBytes: e.bytes);
      }));
    }
    return Future.value();
  });
}

enum UploadType {
  public,
  private,
}
