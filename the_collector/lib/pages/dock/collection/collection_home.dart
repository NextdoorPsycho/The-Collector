import 'package:flutter/material.dart';
import 'package:pandabar/main.view.dart';
import 'package:pandabar/model.dart';
import 'package:the_collector/pages/dock/collection/collection_landing.dart';
import 'package:the_collector/utils/data/user_manager.dart';

class CollectionHomePage extends StatefulWidget {
  const CollectionHomePage({super.key, required this.themeNotifier});

  final ValueNotifier<ThemeMode> themeNotifier;

  @override
  State<CollectionHomePage> createState() => _CollectionHomePageState();
}

class _CollectionHomePageState extends State<CollectionHomePage> {
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
            CollectionZone(),
            CollectionZone(),
            CollectionZone(),
            CollectionZone(),
          ],
        ),
        bottomNavigationBar: PandaBar(
          onFabButtonPressed: () async {},
          fabIcon: Icon(
            Icons.style_outlined,
            color: Theme.of(context).colorScheme.surface,
          ),
          fabColors: [
            Theme.of(context).colorScheme.onSurface,
            Theme.of(context).colorScheme.onSurface,
          ],
          buttonData: [
            PandaBarButtonData(
              id: '0',
              icon: Icons.view_array_outlined,
              title: 'Collection',
            ),
            PandaBarButtonData(
              id: '1',
              icon: Icons.add_circle_outline,
              title: '+Cards',
            ),
            PandaBarButtonData(
              id: '2',
              icon: Icons.input_outlined,
              title: 'Import',
            ),
            PandaBarButtonData(
              id: '3',
              icon: Icons.output_outlined,
              title: 'Export',
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
