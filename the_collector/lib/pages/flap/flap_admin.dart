import 'package:flutter/material.dart';
import 'package:libadwaita/libadwaita.dart';
import 'package:the_collector/pages/screen_templates/template_settings_page.dart';

class FlapAdmin extends StatefulWidget {
  const FlapAdmin({super.key});

  @override
  _FlapAdminState createState() => _FlapAdminState();
}

class _FlapAdminState extends State<FlapAdmin> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final storageUsage = 10.5; // Example storage usage in GB

    return BlankListingPage(groups: [
      AdwPreferencesGroup(
        children: [
          AdwActionRow(
            start: const Icon(Icons.people),
            title: 'Users',
            onActivated: () {
              // Navigate to /AdminUsers page
              Navigator.pushNamed(context, '/AdminUsers');
            },
          ),
          AdwActionRow(
            start: const Icon(Icons.storage),
            title: 'Storage',
            subtitle: 'Storage usage: ${storageUsage.toStringAsFixed(2)} GB',
          ),
          AdwActionRow(
            start: const Icon(Icons.warning),
            title: 'Danger Zone',
            onActivated: () {
              // Navigate to /DangerZone page
              Navigator.pushNamed(context, '/DangerZone');
            },
          ),
        ],
      ),
      AdwPreferencesGroup(
        title: 'App Settings',
        children: [
          AdwActionRow(
            start: const Icon(Icons.notifications),
            title: 'Notifications',
            subtitle: 'Manage app notifications',
            onActivated: () {
              // Handle notifications settings
            },
          ),
          AdwActionRow(
            start: const Icon(Icons.security),
            title: 'Security',
            subtitle: 'Manage app security settings',
            onActivated: () {
              // Handle security settings
            },
          ),
        ],
      ),
      AdwPreferencesGroup(
        title: 'Analytics',
        children: [
          AdwActionRow(
            start: const Icon(Icons.insert_chart),
            title: 'User Analytics',
            subtitle: 'View user analytics and insights',
            onActivated: () {
              // Navigate to user analytics page
            },
          ),
          AdwActionRow(
            start: const Icon(Icons.trending_up),
            title: 'App Performance',
            subtitle: 'Monitor app performance metrics',
            onActivated: () {
              // Navigate to app performance page
            },
          ),
        ],
      ),
      AdwPreferencesGroup(
        title: 'Maintenance',
        children: [
          AdwActionRow(
            start: const Icon(Icons.build),
            title: 'App Maintenance',
            subtitle: 'Perform app maintenance tasks',
            onActivated: () {
              // Handle app maintenance tasks
            },
          ),
          AdwActionRow(
            start: const Icon(Icons.system_update),
            title: 'System Updates',
            subtitle: 'Manage system updates',
            onActivated: () {
              // Handle system updates
            },
          ),
        ],
      ),
    ]);
  }
}
