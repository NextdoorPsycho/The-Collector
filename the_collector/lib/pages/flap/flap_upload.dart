import 'package:flutter/material.dart';
import 'package:the_collector/functions/functions_file_interaction.dart';
import 'package:the_collector/pages/screen_templates/template_dual_simple.dart';
import 'package:the_collector/theme/toastification.dart';

class FlapUpload extends StatefulWidget {
  const FlapUpload({
    super.key,
  });

  @override
  _FlapUploadState createState() => _FlapUploadState();
}

class _FlapUploadState extends State<FlapUpload> {
  @override
  Widget build(BuildContext c) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SimpleDualScreen(
          title: 'Private Upload',
          description: 'The file will be uploaded to your Private repository.',
          footer: TextButton(
            onPressed: () {
              uploadFiles(context: context, uploadType: UploadType.private);
              Toast.infoToast(context, "Select your file, and wait!", "You can select multiple!");
            },
            child: const Text('Upload (PRIVATE)'),
          ),
          secondDescription: 'The file will be uploaded to the Public repository.',
          secondTitle: 'Public Upload',
          secondFooter: TextButton(
            onPressed: () {
              Toast.infoToast(context, "Select your file, and wait!", "You can select multiple!");
              uploadFiles(context: context, uploadType: UploadType.public);
            },
            child: const Text('Upload (PUBLIC)'),
          ),
        ),
      ],
    );
  }
}
