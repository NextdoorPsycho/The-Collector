import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:the_collector/functions/functions_cloud.dart';
import 'package:the_collector/pages/screen_templates/template_list.dart';

class FlapListing extends StatefulWidget {
  const FlapListing({super.key});

  @override
  _FlapListingState createState() => _FlapListingState();
}

class _FlapListingState extends State<FlapListing> {
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
    final items = await getPublicFiles();
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
