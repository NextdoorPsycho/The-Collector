import 'dart:io';

import 'package:fast_log/fast_log.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_collector/pages/transitory/toast_functions.dart';

import 'cloud_functions.dart';

Future<void> uploadFiles({required BuildContext context}) async {
  FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);
  if (result != null) {
    ToastFunctions.warning(context, t: "Uploading Files", st: "One second please!");
    final prefs = await SharedPreferences.getInstance();
    info('Bucket Name: ${prefs.getString("bucketName") ?? 'some_bucket_name'}');

    List<File> files = result.paths.map((path) => File(path!)).toList();
    List<Future> uploadTasks = [];

    for (File file in files) {
      uploadTasks.add(uploadFileToStorage(context, uploadedFile: file));
    }

    List<dynamic> uploadResults = await Future.wait(uploadTasks);
    bool allUploadsSuccessful = uploadResults.every((result) => result["etag"] != null && result["etag"]!.isNotEmpty);

    if (allUploadsSuccessful) {
      info("All files uploaded successfully");
    } else {
      error("One or more file uploads failed");
    }
  }
}
