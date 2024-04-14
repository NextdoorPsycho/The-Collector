import 'package:flutter/material.dart';
import 'package:pandabar/main.view.dart';
import 'package:pandabar/model.dart';
import 'package:the_collector/pages/dock/dock_home.dart';
import 'package:the_collector/utils/data/user_manager.dart';

class TheCollectorHomePage extends StatefulWidget {
  const TheCollectorHomePage({super.key, required this.themeNotifier});

  final ValueNotifier<ThemeMode> themeNotifier;

  @override
  State<TheCollectorHomePage> createState() => _MaterialHomePageState();
}

class _MaterialHomePageState extends State<TheCollectorHomePage> {
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
      final isAdmin = admin ?? false;

      return Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: const [
            FlapWelcome(),
            FlapWelcome(),
            FlapWelcome(),
            FlapWelcome(),
          ],
        ),
        bottomNavigationBar: PandaBar(
          onFabButtonPressed: () async {},
          fabIcon: Icon(
            Icons.add_card_sharp,
            color: Theme.of(context).colorScheme.surface,
          ),
          fabColors: [
            Theme.of(context).colorScheme.onSurface,
            Theme.of(context).colorScheme.onSurface,
          ],
          buttonData: [
            PandaBarButtonData(
              id: '0',
              icon: Icons.style_outlined,
              title: 'Cards',
            ),
            PandaBarButtonData(
              id: '1',
              icon: Icons.document_scanner_outlined,
              title: 'Scan-In',
            ),
            PandaBarButtonData(
              id: '2',
              icon: Icons.inbox_outlined,
              title: 'Decks',
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
