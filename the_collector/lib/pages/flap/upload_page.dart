import 'package:flutter/material.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:the_collector/functions/file_functions.dart';
import 'package:the_collector/pages/transitory/simple_screen.dart';

class UploaderPage extends StatefulWidget {
  const UploaderPage({
    super.key,
  });

  @override
  _UploaderPageState createState() => _UploaderPageState();
}

class _UploaderPageState extends State<UploaderPage> {
  @override
  Widget build(BuildContext c) {
    return SimpleScreen(
      title: 'Upload File Example',
      description: 'Press the button to upload a file. This will be uploaded to the cloud bucked specified in settings',
      footer: AdwButton.pill(
        onPressed: () => {
          uploadFiles(context: c),
        },
        child: const Text('Upload Files'),
      ),
    );
  }
}
