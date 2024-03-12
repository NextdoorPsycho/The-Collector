import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:libadwaita_window_manager/libadwaita_window_manager.dart';
import 'package:the_collector/data/user_manager.dart';
import 'package:the_collector/pages/flap/flap_admin.dart';
import 'package:the_collector/pages/flap/flap_lists.dart';
import 'package:the_collector/pages/flap/flap_settings.dart';
import 'package:the_collector/pages/flap/flap_upload.dart';
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

  @override
  void initState() {
    super.initState();
    listController = ScrollController();
    settingsController = ScrollController();
    _flapController = FlapController();

    _flapController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    listController.dispose();
    settingsController.dispose();
    super.dispose();
  }

  void changeTheme() => widget.themeNotifier.value = widget.themeNotifier.value == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;

  @override
  Widget build(BuildContext context) {
    final developers = {
      'Brian Fopiano': 'NextdoorPsycho',
    };

    return UserManager.streamUploaderStatus().build((uploader) {
      return UserManager.streamAdminStatus().build((admin) {
        final isUploader = uploader ?? false;
        final isAdmin = admin ?? false;

        return AdwScaffold(
          flapController: _flapController,
          flapStyle: FlapStyle(
            locked: false,
            flapWidth: 200,
            breakpoint: MediaQuery.of(context).size.shortestSide < 600 ? double.infinity : 900,
          ),
          actions: AdwActions(),
          start: [
            AdwHeaderButton(
              icon: const Icon(Icons.view_sidebar_outlined, size: 19),
              isActive: _flapController.isOpen,
              onPressed: () => _flapController.toggle(),
            ),
            AdwHeaderButton(
              icon: Icon(widget.themeNotifier.value == ThemeMode.light ? Icons.nights_stay_sharp : Icons.wb_sunny_sharp, size: 15),
              onPressed: changeTheme,
            ),
          ],
          title: const Text('The Collector'),
          end: [
            GtkPopupMenu(
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
                      FirebaseAuth.instance.signOut();
                      Navigator.pushNamedAndRemoveUntil(context, '/sign-in', (route) => false);
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
          ],
          flap: (isDrawer) => AdwSidebar(
            currentIndex: _currentIndex,
            isDrawer: isDrawer,
            children: [
              const AdwSidebarItem(
                label: 'Welcome',
              ),
              if (isUploader)
                const AdwSidebarItem(
                  label: 'Uploader',
                ),
              if (isUploader)
                const AdwSidebarItem(
                  label: 'Lists',
                ),
              const AdwSidebarItem(
                label: 'Settings',
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
              const FlapWelcome(),
              if (isUploader) const FlapUpload(),
              if (isUploader) const FlapListing(),
              const FlapSettings(),
              if (isAdmin) const FlapAdmin(),
            ],
          ),
        );
      });
    });
  }
}
