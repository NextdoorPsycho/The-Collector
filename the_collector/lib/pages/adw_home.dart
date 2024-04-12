import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:padded/padded.dart';
import 'package:the_collector/data/user_manager.dart';
import 'package:the_collector/main.dart';
import 'package:the_collector/pages/flap/fake_settings.dart';
import 'package:the_collector/pages/flap/flap_admin.dart';
import 'package:the_collector/pages/flap/flap_collection.dart';
import 'package:the_collector/pages/flap/flap_scan_collection.dart';
import 'package:the_collector/pages/flap/flap_welcome.dart';
import 'package:url_launcher/url_launcher.dart';

class AdwHomePage extends StatefulWidget {
  const AdwHomePage({super.key, required this.themeNotifier});

  final ValueNotifier<ThemeMode> themeNotifier;

  @override
  State<AdwHomePage> createState() => _AdwHomePageState();
}

class _AdwHomePageState extends State<AdwHomePage> {
  ValueNotifier<int> counter = ValueNotifier(0);
  int? _currentIndex = 0;

  late ScrollController listController;
  late ScrollController settingsController;
  late FlapController _flapController;
  late ThemeMode _initialThemeMode;

  @override
  void initState() {
    super.initState();
    listController = ScrollController();
    settingsController = ScrollController();
    _flapController = FlapController();

    _flapController.addListener(() => setState(() {}));

    // Get the initial theme mode
    UserManager.streamTheme().first.then((isDark) {
      setState(() {
        _initialThemeMode = isDark ? ThemeMode.dark : ThemeMode.light;
        widget.themeNotifier.value = _initialThemeMode;
      });
    });
  }

  @override
  void dispose() {
    listController.dispose();
    settingsController.dispose();
    super.dispose();
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
    final developers = {
      'Brian Fopiano': 'NextdoorPsycho',
    };
    return UserManager.streamAdminStatus().build((admin) {
      final isAdmin = admin ?? false;

      return AdwScaffold(
        title: const Text('The Collector'),
        flapController: _flapController,
        flapStyle: FlapStyle(
          locked: false,
          flapWidth: 200,
          breakpoint: MediaQuery.of(context).size.shortestSide < 600
              ? double.infinity
              : 900,
        ),
        start: [
          PaddingLeft(
            padding: 8,
            child: AdwHeaderButton(
              icon: const Icon(
                Icons.view_sidebar_outlined,
                size: 19,
              ),
              isActive: _flapController.isOpen,
              onPressed: () => _flapController.toggle(),
            ),
          ),
          AdwHeaderButton(
            icon: Icon(
              widget.themeNotifier.value == ThemeMode.light
                  ? Icons.nights_stay_sharp
                  : Icons.wb_sunny_sharp,
              size: 15,
            ),
            onPressed: changeTheme,
          ),
        ],
        end: [
          PaddingRight(
            padding: 8,
            child: GtkPopupMenu(
              body: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AdwButton.flat(
                    padding: AdwButton.defaultButtonPadding.copyWith(
                      top: 10,
                      bottom: 10,
                    ),
                    onPressed: () {
                      SignOutManager.signOut(context);
                    },
                    child: const Text(
                      'Sign Out',
                      style: TextStyle(fontSize: 15),
                    ),
                  ),
                  AdwButton.flat(
                    padding: AdwButton.defaultButtonPadding.copyWith(
                      top: 10,
                      bottom: 10,
                    ),
                    onPressed: () => showDialog<Widget>(
                      context: context,
                      builder: (ctx) => AdwAboutWindow(
                        issueTrackerLink: 'https://google.com',
                        appIcon: const Text(
                          'The Collector',
                          style: TextStyle(fontSize: 15),
                        ),
                        credits: [
                          AdwPreferencesGroup.creditsBuilder(
                            title: 'Developers',
                            itemCount: developers.length,
                            itemBuilder: (_, index) => AdwActionRow(
                              title: developers.keys.elementAt(index),
                              onActivated: () => launchUrl(
                                Uri.parse(
                                  'https://github.com/${developers.values.elementAt(index)}',
                                ),
                              ),
                            ),
                          ),
                        ],
                        copyright: 'Free Software Yay!',
                        license: const Text(
                          'MIT License',
                        ),
                      ),
                    ),
                    child: const Text(
                      'About This App',
                      style: TextStyle(fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        flap: (isDrawer) => AdwSidebar(
          currentIndex: _currentIndex,
          isDrawer: isDrawer,
          children: [
            const AdwSidebarItem(
              label: 'Welcome',
            ),
            if (!kIsWeb)
              const AdwSidebarItem(
                label: 'Scan-In Collection',
              ),
            const AdwSidebarItem(
              label: 'Card Collection',
            ),
            if (isAdmin)
              const AdwSidebarItem(
                label: 'Settings Breakdown',
              ),
            if (isAdmin)
              const AdwSidebarItem(
                label: 'Admin',
              ),
          ],
          onSelected: (index) => setState(() => _currentIndex = index),
        ),
        body: AdwViewStack(
          animationDuration: const Duration(milliseconds: 100),
          index: _currentIndex,
          children: [
            const FlapWelcome(), // landing page
            if (!kIsWeb) const FlapScanCollection(),
            const FlapCollection(),
            if (isAdmin) const FakeSettings(),
            if (isAdmin) const FlapAdmin(),
          ],
        ),
      );
    });
  }
}
