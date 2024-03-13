import 'package:fast_log/fast_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:padded/padded.dart';
import 'package:the_collector/functions/functions_file_interaction.dart';
import 'package:the_collector/pages/screen_templates/template_settings_page.dart';
import 'package:the_collector/theme/animation/spinning_triangle.dart';
import 'package:the_collector/theme/color.dart';
import 'package:the_collector/theme/toastification.dart';

enum FileVisibility { public, private, either }

class FlapListing extends StatefulWidget {
  const FlapListing({super.key});

  @override
  _FlapListingState createState() => _FlapListingState();
}

class _FlapListingState extends State<FlapListing> {
  Map<String, String> publicFiles = {};
  Map<String, String> privateFiles = {};
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    loadUserFiles();
  }

  Future<void> loadUserFiles() async {
    Map<String, String> loadedPublicFiles = await FileListBuilder.generateUserFileList(FileVisibility.public);
    Map<String, String> loadedPrivateFiles = await FileListBuilder.generateUserFileList(FileVisibility.private);
    info('Public files: $loadedPublicFiles');
    info('Private files: $loadedPrivateFiles');
    setState(() {
      publicFiles = loadedPublicFiles;
      privateFiles = loadedPrivateFiles;
      isLoading = false;
    });
  }

  void removePublicFile(String key) {
    setState(() {
      publicFiles.remove(key);
    });
  }

  void removePrivateFile(String key) {
    setState(() {
      privateFiles.remove(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Scaffold(
          body: Center(
        child: SpinningTriangle(iconColor: context.textColor),
      ));
    }

    return Scaffold(
      body: BlankListingPage(groups: [
        const SizedBox(height: 12),
        AdwPreferencesGroup(
          title: 'Public Files',
          description: 'Your public files are accessible to everyone.',
          children: publicFiles.isEmpty
              ? [
                  const Center(
                      child: PaddingAll(
                    padding: 10,
                    child: Text(
                      'You have no public files in storage.',
                      style: TextStyle(
                        fontSize: 16,
                      ),
                    ),
                  )),
                ]
              : FileListBuilder.buildFileList(context, publicFiles, true, removePublicFile),
        ),
        const Divider(),
        AdwPreferencesGroup(
          title: 'Private Files',
          description: 'Your private files are only accessible to you.',
          children: privateFiles.isEmpty
              ? [
                  const Center(
                      child: PaddingAll(
                    padding: 10,
                    child: Text(
                      'You have no private files in storage.',
                      style: TextStyle(
                        fontSize: 16,
                      ),
                    ),
                  )),
                ]
              : FileListBuilder.buildFileList(context, privateFiles, false, removePrivateFile),
        ),
      ]),
    );
  }
}

class FileListBuilder {
  static Future<Map<String, String>> generateUserFileList(FileVisibility visibility) async {
    switch (visibility) {
      case FileVisibility.public:
        return await getPublicFiles();
      case FileVisibility.private:
        return await getPrivateFiles();
      default:
        return {};
    }
  }

  static List<Widget> buildFileList(
    BuildContext context,
    Map<String, String> files,
    bool isPublic,
    Function(String) onDelete,
  ) {
    return files.entries.map((entry) {
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text(entry.key),
          children: [
            if (isPublic)
              ListTile(
                title: AdwButton(
                  onPressed: () async {
                    Clipboard.setData(ClipboardData(text: entry.value));
                    Toast.infoToast(context, "Link Copied", "Straight to your clipboard!");
                  },
                  child: const Text('Copy Link'),
                ),
                trailing: AdwButton(
                  backgroundColor: MyColors.red4,
                  onPressed: () async {
                    deleteFile(context, "user/$uid/${UploadType.public.name}/${entry.key}").then((value) {
                      onDelete(entry.key);
                    });
                    Toast.scaryToast(context, "File deleted", 'Deleted ${entry.key}');
                  },
                  child: const Text('Delete File'),
                ),
              ),
            if (!isPublic)
              ListTile(
                title: AdwButton(
                  onPressed: () async {
                    Clipboard.setData(ClipboardData(text: entry.value));
                    info('Link Copied: ${entry.value}');
                    Toast.infoToast(context, "Link Copied", "Straight to your clipboard!");
                  },
                  child: const Text('Copy Link'),
                ),
                trailing: AdwButton(
                  backgroundColor: MyColors.red4,
                  onPressed: () async {
                    deleteFile(context, "user/$uid/${UploadType.private.name}/${entry.key}").then((value) {
                      onDelete(entry.key);
                    });
                    Toast.scaryToast(context, "File deleted", 'Deleted ${entry.key}');
                  },
                  child: const Text('Delete File'),
                ),
              ),
          ],
        ),
      );
    }).toList();
  }
}
