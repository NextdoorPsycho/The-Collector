import 'package:fast_log/fast_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:the_collector/pages/screen_templates/template_settings_page.dart';

enum FileVisibility { public, private, either }

class FlapListing extends StatefulWidget {
  const FlapListing({super.key});

  @override
  _FlapListingState createState() => _FlapListingState();
}

class _FlapListingState extends State<FlapListing> {
  List<Map<String, dynamic>> userFiles = [];

  @override
  void initState() {
    super.initState();
    userFiles = FileListBuilder.generateUserFileList('UsernameHere', FileVisibility.either);
  }

  @override
  Widget build(BuildContext context) {
    return BlankListingPage(groups: [
      const SizedBox(height: 12),
      AdwPreferencesGroup(
        title: 'Files',
        description: 'Your uploaded files are all stored here. You can manage them here.',
        children: FileListBuilder.buildFileList(context, userFiles),
      ),
    ]);
  }
}

class FileListBuilder {
  static List<Map<String, dynamic>> generateUserFileList(String user, FileVisibility visibility) {
    // TODO: Replace with actual file list, and get the actual firebase user
    return [
      {'name': 'File 1', 'link': 'https://example.com/file1', 'isPublic': false},
      {'name': 'File 2', 'link': 'https://example.com/file2', 'isPublic': true},
    ];
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
                      onPressed: () {
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
