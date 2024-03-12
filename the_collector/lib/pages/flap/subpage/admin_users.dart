import 'package:flutter/material.dart';
import 'package:flyout/flyout.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:the_collector/pages/screen_templates/template_settings_page.dart';

class UserFlyout extends StatelessWidget {
  const UserFlyout({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: ListView(
          // Scrolling will move the flyout and the scroller
          controller: flyoutController(context),
          children: [
            BlankListingPage(groups: [
              const AdwActionRow(
                start: Icon(Icons.storage),
                title: 'Storage',
                subtitle: 'Storage usage: GB',
              ),
              AdwActionRow(
                start: const Icon(Icons.warning),
                title: 'Danger Zone',
                onActivated: () {
                  // Navigate to /DangerZone page
                  Navigator.pushNamed(context, '/DangerZone');
                },
              ),
            ]),
          ],
        ),
      );
}
