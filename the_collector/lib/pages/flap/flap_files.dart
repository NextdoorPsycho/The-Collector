import 'package:fast_log/fast_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:padded/padded.dart';
import 'package:the_collector/functions/functions_file_interaction.dart';
import 'package:the_collector/pages/screen_templates/template_settings_page.dart';

enum FileVisibility { public, private, either }

class FlapListing extends StatefulWidget {
  const FlapListing({super.key});

  @override
  _FlapListingState createState() => _FlapListingState();
}

class _FlapListingState extends State<FlapListing> {
  List<Map<String, dynamic>> userFiles = [];
  bool isLoading = true; // Added flag to track loading state

  @override
  void initState() {
    super.initState();
    loadUserFiles(); // Trigger async operation to load files
  }

  Future<void> loadUserFiles() async {
    // Asynchronously load user files and update the state
    userFiles = await FileListBuilder.generateUserFileList(FileVisibility.either);
    setState(() {
      isLoading = false; // Update loading flag when done
    });
  }

  @override
  Widget build(BuildContext context) {
    // Display loading indicator while data is loading
    if (isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Once data is loaded, display your actual UI
    return Scaffold(
      body: BlankListingPage(groups: [
        const SizedBox(height: 12),
        AdwPreferencesGroup(
          title: 'Files',
          description: 'Your uploaded files are all stored here. You can manage them here.',
          children: userFiles.isEmpty
              ? [
                  const Center(
                      child: PaddingAll(
                    padding: 10,
                    child: Text(
                      'You have no files in storage, please upload some!',
                      style: TextStyle(
                        fontSize: 16,
                      ),
                    ),
                  )),
                ]
              : FileListBuilder.buildFileList(context, userFiles),
        ),
      ]),
    );
  }
}

class FileListBuilder {
  static Future<List<Map<String, dynamic>>> generateUserFileList(FileVisibility visibility) async {
    if (visibility == FileVisibility.either) {
      Map<String, String> publicFiles = await getPublicFiles();
      Map<String, String> privateFiles = await getPrivateFiles();

      List<Map<String, dynamic>> files = [];

      for (var entry in publicFiles.entries) {
        files.add({'name': entry.key, 'isPublic': true, 'link': entry.value});
      }

      for (var entry in privateFiles.entries) {
        files.add({'name': entry.key, 'isPublic': false, 'link': entry.value});
      }

      return files;
    } else if (visibility == FileVisibility.public) {
      Map<String, String> publicFiles = await getPublicFiles();

      return publicFiles.entries.map((entry) {
        return {'name': entry.key, 'isPublic': true, 'link': entry.value};
      }).toList();
    } else if (visibility == FileVisibility.private) {
      Map<String, String> publicFiles = await getPublicFiles();

      return publicFiles.entries.map((entry) {
        return {'name': entry.key, 'isPublic': false, 'link': entry.value};
      }).toList();
    } else {
      Map<String, String> privateFiles = await getPrivateFiles();

      return privateFiles.entries.map((entry) {
        return {'name': entry.key, 'isPublic': false, 'link': entry.value};
      }).toList();
    }
  }

  static List<Widget> buildFileList(BuildContext context, List<Map<String, dynamic>> files) {
    return files.map((file) {
      return StatefulBuilder(
        builder: (context, setState) {
          return Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              title: Text(file['name']),
              children: [
                ListTile(
                  title: const Text('Is the file public?'),
                  trailing: AdwSwitch(
                    value: file['isPublic'],
                    onChanged: (value) {
                      // Update the state of the file on Firebase
                      setState(() {
                        file['isPublic'] = value;
                      });
                    },
                  ),
                ),
                if (file['isPublic'])
                  Divider(
                    color: context.borderColor,
                    height: 10,
                  ),
                if (file['isPublic'])
                  ListTile(
                    title: const Text('Copy file link'),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () async {
                        Clipboard.setData(ClipboardData(text: file['link']));
                        info('Link copied: ${file['link']}');
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      );
    }).toList();
  }
}
