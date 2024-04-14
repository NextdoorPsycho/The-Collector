import 'package:flutter/material.dart';
import 'package:pandabar/main.view.dart';
import 'package:pandabar/model.dart';
import 'package:the_collector/pages/dock/dock_card.dart';
import 'package:the_collector/pages/dock/dock_home.dart';
import 'package:the_collector/pages/dock/dock_settings.dart';
import 'package:the_collector/utils/data/user_manager.dart';
import 'package:the_collector/utils/functions/ocr_utils.dart';

class AppHome extends StatefulWidget {
  const AppHome({super.key, required this.themeNotifier});

  final ValueNotifier<ThemeMode> themeNotifier;

  @override
  State<AppHome> createState() => _AppHomeState();
}

class _AppHomeState extends State<AppHome> {
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
          children: [
            const FlapWelcome(),
            const FlapCard(),
            const FlapCard(),
            DockSettings(themeNotifier: widget.themeNotifier)
          ],
        ),
        bottomNavigationBar: PandaBar(
          onFabButtonPressed: () async {
            OCRUtilities().pickAndProcessImage(context);
          },
          fabIcon: Icon(
            Icons.document_scanner_outlined,
            color: Theme.of(context).colorScheme.surface,
          ),
          fabColors: [
            Theme.of(context).colorScheme.onSurface,
            Theme.of(context).colorScheme.onSurface,
          ],
          buttonData: [
            PandaBarButtonData(
                id: '0', icon: Icons.style_outlined, title: 'Collection'),
            PandaBarButtonData(
              id: '1',
              icon: Icons.games_outlined,
              title: 'Dice',
            ),
            PandaBarButtonData(
              id: '2',
              icon: Icons.menu_book_outlined,
              title: 'Rules',
            ),
            PandaBarButtonData(
              id: '3',
              icon: Icons.settings_outlined,
              title: 'Settings',
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
