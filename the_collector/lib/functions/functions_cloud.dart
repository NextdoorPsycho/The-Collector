import 'package:fast_log/fast_log.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';
import 'package:uuid/uuid.dart';

String get uid => FirebaseAuth.instance.currentUser!.uid;
Map<String, String> mimes = {
  "jpg": "image/jpeg",
  "jpeg": "image/jpeg",
  "png": "image/png",
  "gif": "image/gif",
  "bmp": "image/bmp",
  "webp": "image/webp",
  "tiff": "image/tiff",
  "tif": "image/tiff",
  "svg": "image/svg+xml",
  "pdf": "application/pdf",
  "zip": "application/zip",
  "rar": "application/x-rar-compressed",
  "7z": "application/x-7z-compressed",
  "tar": "application/x-tar",
  "mp3": "audio/mpeg",
  "wav": "audio/wav",
  "ogg": "audio/ogg",
  "m4a": "audio/mp4",
  "mp4": "video/mp4",
  "mkv": "video/x-matroska",
  "webm": "video/webm",
  "avi": "video/x-msvideo",
  "mov": "video/quicktime",
  "txt": "text/plain",
  "csv": "text/csv",
  "json": "application/json",
  "xml": "application/xml",
  "html": "text/html",
  "css": "text/css",
  "js": "application/javascript",
  "dart": "application/dart",
  "exe": "application/x-msdownload",
  "iso": "application/x-iso9660-image",
  "img": "application/x-iso9660-image",
  "bin": "application/octet-stream",
  "sh": "application/x-sh",
  "bat": "application/x-msdownload",
};

Future<bool> uploadToPublic(BuildContext context, String path, String hint, {String? uploadedFile, Uint8List? uploadedBytes}) async {
  String mime = mimes[hint] ?? "application/octet-stream";
  try {
    final ref = FirebaseStorage.instance.ref(path);
    if (kIsWeb && uploadedBytes != null) {
      await ref.putData(uploadedBytes, SettableMetadata(contentType: mime));
    } else {
      await ref.putFile(File(path), SettableMetadata(contentType: mime));
    }
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
      return Future.wait(value.files.map((e) => kIsWeb ? uploadToPublic(context, "user/$uid/${uploadType.name}/${const Uuid().v4()}", e.name.split('.').last, uploadedBytes: e.bytes) : uploadToPublic(context, "user/$uid/${uploadType.name}/${const Uuid().v4()}", e.name.split('.').last, uploadedFile: e.path)));
    }
    return Future.value();
  });
}

enum UploadType {
  public,
  private,
}
