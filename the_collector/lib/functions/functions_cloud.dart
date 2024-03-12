import 'dart:io';

import 'package:fast_log/fast_log.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

//Uploads a file to the users Public Folder
// User/{user}/public/{file}
Future<bool> uploadToPublic(BuildContext context, {required File uploadedFile}) async {
  try {
    final fileContent = await uploadedFile.readAsBytes();
  } catch (e) {
    error("Firebase Upload Error $e");
  }
  return false;
}

//Uploads a file to the users Private Folder
// User/{user}/private/{file}
Future<bool> uploadToPrivate(BuildContext context, {required File uploadedFile}) async {
  try {
    final fileContent = await uploadedFile.readAsBytes();
  } catch (e) {
    error("Firebase Upload Error $e");
  }
  return false;
}

//Delete a file from the users Public Folder
Future<void> deleteFileFromPublic(BuildContext context, {required String objectName}) async {}

//Delete a file from the users Private Folder
Future<void> deleteFileFromPrivate(BuildContext context, {required String objectName}) async {}

//Get a list of all the files in the users Public Folder
Future<Map<String, String>> getPublicFiles() async {
  return {};
}

//Get a list of all the files in the users Private Folder
Future<Map<String, String>> getPrivateFiles() async {
  return {};
}

enum UploadType {
  public,
  private,
}

Future<void> uploadFiles({required BuildContext context, required UploadType uploadType}) async {
  FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);
  if (result != null) {
    final prefs = await SharedPreferences.getInstance();
    info('Bucket Name: ${prefs.getString("bucketName") ?? 'some_bucket_name'}');

    List<File> files = result.paths.map((path) => File(path!)).toList();
    List<Future> uploadTasks = [];

    for (File file in files) {
      if (uploadType == UploadType.public) {
        uploadTasks.add(uploadToPublic(context, uploadedFile: file));
      } else {
        uploadTasks.add(uploadToPrivate(context, uploadedFile: file));
      }
    }

    List<dynamic> uploadResults = await Future.wait(uploadTasks);

    //check if the updates are all true if not then spit an error
    bool allUploadsSuccessful = uploadResults.every((result) => result == true);
    if (allUploadsSuccessful) {
      info("All files uploaded successfully");
    } else {
      error("One or more file uploads failed");
    }
  }
}
