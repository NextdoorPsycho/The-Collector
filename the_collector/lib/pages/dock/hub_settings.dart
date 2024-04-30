import 'package:flutter/material.dart';
import 'package:the_collector/main.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/theme/color.dart';
import 'package:the_collector/utils/crud.dart';

class HubSettings extends StatefulWidget {
  const HubSettings({super.key});

  @override
  _HubSettingsState createState() => _HubSettingsState();
}

class _HubSettingsState extends State<HubSettings> {
  @override
  void dispose() {
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
  }

  void confirmSignOut(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Sign Out'),
          content: const Text('Are you sure you want to sign out?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                SignOutManager.signOut(context);
              },
              child: const Text('Sign Out'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Theme Toggle'),
            leading: const Icon(Icons.lightbulb_outline_rounded,
                color: MyColors.orange5),
            onTap: () {
              Crud.user().txn(u, (data) => data..toggleTheme());
            },
          ),
          ListTile(
            title: const Text(
              'Sign Out',
            ),
            leading: const Icon(
              Icons.exit_to_app,
              color: MyColors.red5,
            ),
            onTap: () => confirmSignOut(context),
          ),
        ],
      ),
    );
  }
}
