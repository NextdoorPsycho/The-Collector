import 'dart:io';

import 'package:fast_log/fast_log.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:googleapis/storage/v1.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_collector/pages/transitory/toast_functions.dart';

connectGoogleCloudJson({required BuildContext context}) async {
  FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['json'],
  );

  if (result != null) {
    File file = File(result.files.single.path!);
    String fileContent = file.readAsStringSync();
    if (fileContent.isNotEmpty) {
      await setGSA(fileContent);
      ToastFunctions.successToast(context, t: "Google Cloud Service Account", st: "Connected");
    } else {
      ToastFunctions.errorToast(context, t: "Google Cloud Service Account", st: "Failed to connect");
    }
  }
}

Future<String> getGSA() async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  // info('Google Cloud Service Account: ${prefs.getString("google-cloud-service-account") ?? ''}');
  return prefs.getString("google-cloud-service-account") ?? '';
}

Future<bool> setGSA(String value) async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("google-cloud-service-account", value);
  return true;
}

Future<String> getBN() async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  info('Google Cloud Bucket Name: ${prefs.getString("bucket-name") ?? ''}');
  return prefs.getString("bucket-name") ?? '';
}

Future<bool> setBN(String value) async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString("bucket-name", value);
  return true;
}

Future<bool> uploadFileToStorage(BuildContext context, {required File uploadedFile}) async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  try {
    final credentials = ServiceAccountCredentials.fromJson(prefs.getString("google-cloud-service-account"));
    final httpClient = await clientViaServiceAccount(credentials, [StorageApi.devstorageReadWriteScope]);
    final storage = StorageApi(httpClient);
    final formattedDate = DateFormat('MM-dd-yyyy').format(DateTime.now());
    final fileName = path.basename(uploadedFile.path);
    final fileFolderAndName = "collector-uploads/$formattedDate - $fileName";
    final fileContent = await uploadedFile.readAsBytes();
    final bucketObject = Object(name: fileFolderAndName);
    final resp = await storage.objects.insert(
      bucketObject,
      await getBN(),
      uploadMedia: Media(
        Stream<List<int>>.fromIterable([fileContent]),
        fileContent.length,
      ),
    );
    if (resp.id != null && resp.id!.isNotEmpty) {
      ToastFunctions.successToast(context, t: "File uploaded successfully", st: "File: $fileName");
      return true;
    }
  } catch (e) {
    error("Upload GCS Error $e");
    ToastFunctions.errorToast(context, t: "Upload GCS Error", st: e.toString());
  }
  return false;
}

Future<Map<String, String>> generateMapFromBucket() async {
  final credentials = ServiceAccountCredentials.fromJson(
    await getGSA(),
  );
  final httpClient = await clientViaServiceAccount(credentials, [StorageApi.devstorageReadWriteScope]);
  final storage = StorageApi(httpClient);
  final bucketName = await getBN();
  info('Bucket Name: $bucketName');
  final bucketObjects = await storage.objects.list(bucketName, prefix: 'collector-uploads/');
  final mapFilesIDs = <String, String>{};
  for (Object object in bucketObjects.items!) {
    final link = object.mediaLink;
    final name = object.name?.split('/').last;
    if (link != null && name != null) {
      mapFilesIDs[name] = link;
    }
  }
  info(mapFilesIDs);
  return mapFilesIDs;
}

Future<void> deleteFileFromBucket(BuildContext context, {required String objectName}) async {
  final credentials = ServiceAccountCredentials.fromJson(
    await getGSA(),
  );
  final httpClient = await clientViaServiceAccount(credentials, [StorageApi.devstorageReadWriteScope]);
  final storage = StorageApi(httpClient);
  final bucketName = await getBN();
  try {
    await storage.objects.delete(bucketName, 'collector-uploads/$objectName');
    ToastFunctions.successToast(context, t: "File Deleted", st: 'File: collector-uploads/$objectName');
  } catch (e) {
    error("Delete GCS Error $e");
    ToastFunctions.errorToast(context, t: "Delete GCS Error", st: e.toString());
  }
}
