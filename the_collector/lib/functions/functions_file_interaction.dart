import 'package:fast_log/fast_log.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:the_collector/theme/toastification.dart';
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
    Toast.successToast(context, "File uploaded", "View in your Files page");
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
        Toast.infoToast(context, "Uploading ${e.name}", "Please wait... This may take a while depending on your internet speed, and the file size.");
        return uploadToPublic(context, filePath, e.extension ?? 'bin', uploadedBytes: e.bytes);
      }));
    }
    Toast.warningToast(context, "No file selected", "Please select a file to upload");
    return Future.value();
  });
}

Future<Map<String, String>> getPublicFiles() async {
  try {
    final ref = FirebaseStorage.instance.ref("user/$uid/${UploadType.public.name}/");
    final listResult = await ref.listAll();
    final fileUrls = await Future.wait(
      listResult.items.map((item) => item.getDownloadURL()),
    );
    final fileNames = listResult.items.map((item) => item.name).toList();
    info(" -=[ Public Files ]=------$fileNames");
    return Map.fromIterables(fileNames, fileUrls);
  } catch (e) {
    error("Error retrieving public files: $e");
    return {};
  }
}

Future<Map<String, String>> getPrivateFiles() async {
  try {
    final ref = FirebaseStorage.instance.ref("user/$uid/${UploadType.private.name}/");
    final listResult = await ref.listAll();
    final fileUrls = await Future.wait(
      listResult.items.map((item) => item.getDownloadURL()),
    );
    final fileNames = listResult.items.map((item) => item.name).toList();
    info(" -=[ Private Files Names ]=------$fileNames");
    return Map.fromIterables(fileNames, fileUrls);
  } catch (e) {
    error("Error retrieving private files: $e");
    return {};
  }
}

Future<bool> moveFile(BuildContext context, String sourcePath, String destinationPath) async {
  try {
    final sourceRef = FirebaseStorage.instance.ref(sourcePath);
    final data = await sourceRef.getData();

    final destinationRef = FirebaseStorage.instance.ref(destinationPath);
    await destinationRef.putData(data!);
    await deleteFile(context, sourcePath);
    verbose('Moved $sourcePath to $destinationPath');
    Toast.infoToast(context, "File moved", 'Moved $sourcePath to $destinationPath');
    return true;
  } catch (e) {
    error("Error moving file: $e");
    return false;
  }
}

Future<bool> deleteFile(BuildContext context, String filePath) async {
  try {
    final ref = FirebaseStorage.instance.ref(filePath);
    await ref.delete();
    verbose('Deleted $filePath');
    return true;
  } catch (e) {
    error("Firebase Delete Error: $e");
    return false;
  }
}

enum UploadType {
  public,
  private,
}
