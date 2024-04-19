import 'dart:async';

import 'package:flutter/material.dart';
import 'package:the_collector/main.dart';
import 'package:the_collector/theme/color.dart';
import 'package:the_collector/utils/data/user_manager.dart';

class HubSettings extends StatefulWidget {
  final ValueNotifier<ThemeMode> themeNotifier;

  const HubSettings({super.key, required this.themeNotifier});

  @override
  _HubSettingsState createState() => _HubSettingsState();
}

class _HubSettingsState extends State<HubSettings> {
  late ThemeMode _initialThemeMode;

  late StreamSubscription<bool> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    // Get the initial theme mode
    _sub = UserManager.streamTheme().listen((isDark) {
      setState(() {
        _initialThemeMode = isDark ? ThemeMode.dark : ThemeMode.light;
        widget.themeNotifier.value = _initialThemeMode;
      });
    });
  }

  void changeTheme() {
    if (widget.themeNotifier.value == ThemeMode.light) {
      widget.themeNotifier.value = ThemeMode.dark;
      UserManager.updateTheme(isDark: true);
    } else {
      widget.themeNotifier.value = ThemeMode.light;
      UserManager.updateTheme(isDark: false);
    }
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
    var themeMode = widget.themeNotifier.value;
    var isDarkMode = themeMode == ThemeMode.dark;
    var iconColor = isDarkMode ? Colors.white : Colors.black;
    var textColor = isDarkMode ? Colors.white : Colors.black;

    return Scaffold(
      appBar: AppBar(
        title: Text('Settings', style: TextStyle(color: textColor)),
        iconTheme: IconThemeData(color: iconColor),
        backgroundColor: isDarkMode
            ? MyColors.darkHeaderBarBackground
            : MyColors.headerBarBackground,
      ),
      body: ListView(
        children: [
          ListTile(
            title: Text('Theme Toggle', style: TextStyle(color: textColor)),
            leading: Icon(
              isDarkMode ? Icons.dark_mode : Icons.light_mode,
              color: iconColor,
            ),
            onTap: () {
              setState(() {
                changeTheme();
              });
            },
            trailing: Text(
              isDarkMode ? '[Dark]' : '[Light]',
              style: TextStyle(color: textColor),
            ),
          ),
          ListTile(
            title: Text('Sign Out', style: TextStyle(color: textColor)),
            leading: Icon(Icons.exit_to_app, color: iconColor),
            onTap: () => confirmSignOut(context),
          ),
        ],
      ),
    );
  }
}
