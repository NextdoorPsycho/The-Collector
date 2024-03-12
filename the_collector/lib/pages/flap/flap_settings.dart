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
    final switchVal = ValueNotifier(false);
    const choices = ['Test', 'Second', 'Third and a long name'];
    final selectionIndex = ValueNotifier<int>(0);

    return BlankListingPage(groups: [
      const AdwPreferencesGroup(
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
      AdwPreferencesGroup(
        children: [
          const AdwActionRow(
            start: Icon(Icons.settings),
            title: 'Rows have a title',
            subtitle: 'They also have a subtitle and an icon',
          ),
          AdwActionRow(
            title: 'Rows can have suffix widgets',
            end: AdwButton(
              onPressed: () {},
              child: const Text('Frobnicate'),
            ),
          )
        ],
      ),
      AdwPreferencesGroup(
        children: [
          ValueListenableBuilder<int>(
            valueListenable: selectionIndex,
            builder: (context, val, _) {
              return AdwComboRow(
                choices: choices,
                title: 'Combo row',
                selectedIndex: val,
                onSelected: (val) => selectionIndex.value = val,
              );
            },
          )
        ],
      ),
      AdwPreferencesGroup(
        children: List.generate(
          3,
          (index) => AdwActionRow(
            title: 'Index $index',
          ),
        ),
      ),
      AdwPreferencesGroup(
        children: [
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              title: const Text('Expander row'),
              children: [
                const ListTile(
                  title: Text('A nested row'),
                ),
                Divider(
                  color: context.borderColor,
                  height: 10,
                ),
                const ListTile(
                  title: Text('Another nested row'),
                )
              ],
            ),
          )
        ],
      ),
      const SizedBox(height: 12),
      AdwPreferencesGroup(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: switchVal,
            builder: (context, val, _) => AdwSwitchRow(
              title: 'Switch example',
              value: val,
              onChanged: (v) {
                switchVal.value = v;
              },
            ),
          ),
        ],
      ),
      const AdwPreferencesGroup(
        title: 'Groups',
        description: '''
Preferences are grouped together, a group can have a title and a description. 
Descriptions will be wrapped if they are too long. This page has the following groups:''',
        children: [
          AdwActionRow(title: 'An untitled group'),
          AdwActionRow(title: 'Pages'),
          AdwActionRow(title: 'Groups'),
          AdwActionRow(title: 'Preferences'),
        ],
      ),
      const SizedBox(height: 12),
      AdwPreferencesGroup(
        title: 'Subpages',
        description: 'Preferences windows can have subpages.',
        children: [
          AdwActionRow(
            title: 'Go to a subpage',
            end: const Icon(Icons.chevron_right),
            onActivated: () => debugPrint('Hi'),
          ),
          const AdwActionRow(
            title: 'Go to another subpage',
            end: Icon(Icons.chevron_right),
          ),
        ],
      ),
      const SizedBox(height: 12),
      AdwTextField(
        initialValue: 'some text',
        keyboardType: TextInputType.number,
        icon: Icons.insert_photo,
        onChanged: (String s) {},
      ),
    ]);
  }
}
