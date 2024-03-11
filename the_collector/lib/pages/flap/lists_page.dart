import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:the_collector/functions/cloud_functions.dart';
import 'package:the_collector/pages/transitory/list_screen.dart';

class ListPage extends StatefulWidget {
  const ListPage({super.key});

  @override
  _ListPageState createState() => _ListPageState();
}

class _ListPageState extends State<ListPage> {
  List<Widget> _subpages = [];

  @override
  void initState() {
    super.initState();
    _refreshList();
  }

  Future<void> _refreshList() async {
    final subpages = await generateSubpages();
    setState(() {
      _subpages = subpages;
    });
  }

  Future<List<Widget>> generateSubpages() async {
    final items = await generateMapFromBucket();
    final subpages = <Widget>[];
    for (final item in items.entries) {
      subpages.add(
        AdwActionRow(
          title: item.key,
          end: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: item.value));
                  debugPrint('Copied the link: ${item.value}');
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () async {
                  await deleteFileFromBucket(context, objectName: item.key);
                  _refreshList();
                },
              ),
            ],
          ),
        ),
      );
    }
    return subpages;
  }

  @override
  Widget build(BuildContext context) {
    return ListScreen(
      title: "Uploaded List",
      description: "This is a collection of every file uploaded to the cloud bucket specified in settings. Press the button to refresh the list.",
      footer: AdwActionRow(
        title: 'Refresh Page',
        end: const Icon(Icons.refresh),
        onActivated: () => _refreshList(),
      ),
      subpages: _subpages,
    );
  }
}
