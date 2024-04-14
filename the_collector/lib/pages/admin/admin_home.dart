import 'package:flutter/material.dart';
import 'package:pandabar/main.view.dart';
import 'package:pandabar/model.dart';
import 'package:the_collector/pages/admin/admin_landing.dart';
import 'package:the_collector/utils/data/user_manager.dart';

class TheAdminZonePage extends StatefulWidget {
  const TheAdminZonePage({super.key, required this.themeNotifier});

  final ValueNotifier<ThemeMode> themeNotifier;

  @override
  State<TheAdminZonePage> createState() => _TheAdminZonePageState();
}

class _TheAdminZonePageState extends State<TheAdminZonePage> {
  int _currentIndex = 0;

  late ThemeMode _initialThemeMode;

  @override
  void initState() {
    super.initState();

    // Get the initial theme mode
    UserManager.streamTheme().first.then((isDark) {
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

  @override
  Widget build(BuildContext context) {
    return UserManager.streamAdminStatus().build((admin) {
      return Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: const [
            AdminHome(),
            AdminHome(),
            AdminHome(),
            AdminHome(),
          ],
        ),
        bottomNavigationBar: PandaBar(
          onFabButtonPressed: () async {},
          fabIcon: Icon(
            Icons.shield_outlined,
            color: Theme.of(context).colorScheme.surface,
          ),
          fabColors: [
            Theme.of(context).colorScheme.onSurface,
            Theme.of(context).colorScheme.onSurface,
          ],
          buttonData: [
            PandaBarButtonData(
              id: '0',
              icon: Icons.admin_panel_settings_outlined,
              title: 'Admin',
            ),
            PandaBarButtonData(
              id: '1',
              icon: Icons.admin_panel_settings_outlined,
              title: 'Admin',
            ),
            PandaBarButtonData(
              id: '2',
              icon: Icons.admin_panel_settings_outlined,
              title: 'Admin',
            ),
            PandaBarButtonData(
              id: '3',
              icon: Icons.admin_panel_settings_outlined,
              title: 'Admin',
            ),
          ],
          onChange: (id) {
            setState(() {
              _currentIndex = int.parse(id);
            });
          },
          backgroundColor: Theme.of(context).colorScheme.background,
          buttonSelectedColor: Theme.of(context).colorScheme.onSurface,
          buttonColor:
              Theme.of(context).colorScheme.onSurface.withOpacity(0.40),
        ),
      );
    });
  }
}