import 'package:flutter/material.dart';

class FakeSettings extends StatefulWidget {
  const FakeSettings({super.key});

  @override
  _FakeSettingsState createState() => _FakeSettingsState();
}

class _FakeSettingsState extends State<FakeSettings> {
  bool _switchValue = false;
  int _selectedIndex = 0;
  final TextEditingController _textController =
      TextEditingController(text: 'some text');

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const choices = ['Test', 'Second', 'Third and a long name'];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          const Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  title: Text('Fake Settings so I have a reference!'),
                  subtitle: Text(
                      'Preferences are organized in pages, this example has the following pages:'),
                ),
                ListTile(
                  title: Text('Layout'),
                ),
                ListTile(
                  title: Text('Search'),
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ListTile(
                  leading: Icon(Icons.settings),
                  title: Text('Rows have a title'),
                  subtitle: Text('They also have a subtitle and an icon'),
                ),
                ListTile(
                  title: const Text('Rows can have suffix widgets'),
                  trailing: ElevatedButton(
                    onPressed: () {},
                    child: const Text('Frobnicate'),
                  ),
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  title: const Text('Combo row'),
                  trailing: DropdownButton<int>(
                    value: _selectedIndex,
                    onChanged: (int? newValue) {
                      setState(() {
                        _selectedIndex = newValue!;
                      });
                    },
                    items: List.generate(
                      choices.length,
                      (index) => DropdownMenuItem<int>(
                        value: index,
                        child: Text(choices[index]),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: List.generate(
                3,
                (index) => ListTile(
                  title: Text('Index $index'),
                ),
              ),
            ),
          ),
          Card(
            child: Theme(
              data:
                  Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: const ExpansionTile(
                title: Text('Expander row'),
                children: [
                  ListTile(
                    title: Text('A nested row'),
                  ),
                  Divider(),
                  ListTile(
                    title: Text('Another nested row'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              title: const Text('Switch example'),
              value: _switchValue,
              onChanged: (bool value) {
                setState(() {
                  _switchValue = value;
                });
              },
            ),
          ),
          const Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  title: Text('Groups'),
                  subtitle: Text(
                      'Preferences are grouped together, a group can have a title and a description. Descriptions will be wrapped if they are too long. This page has the following groups:'),
                ),
                ListTile(title: Text('An untitled group')),
                ListTile(title: Text('Pages')),
                ListTile(title: Text('Groups')),
                ListTile(title: Text('Preferences')),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ListTile(
                  title: Text('Subpages'),
                  subtitle: Text('Preferences windows can have subpages.'),
                ),
                ListTile(
                  title: const Text('Go to a subpage'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => debugPrint('Hi'),
                ),
                const ListTile(
                  title: Text('Go to another subpage'),
                  trailing: Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _textController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                icon: Icon(Icons.insert_photo),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
