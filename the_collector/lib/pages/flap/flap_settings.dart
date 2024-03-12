import 'package:flutter/material.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:the_collector/pages/screen_templates/template_settings_page.dart';

class FlapSettings extends StatefulWidget {
  const FlapSettings({super.key});

  @override
  _FlapSettingsState createState() => _FlapSettingsState();
}

class _FlapSettingsState extends State<FlapSettings> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return const BlankListingPage(groups: [
      SizedBox(height: 12),
      AdwPreferencesGroup(
        title: 'Pages',
        description: '''
Preferences are organized in pages, this example has the following pages:''',
        children: [
          AdwActionRow(
            title: 'Layout',
          ),
          AdwActionRow(
            title: 'Search',
          ),
        ],
      ),
    ]);
  }
}
