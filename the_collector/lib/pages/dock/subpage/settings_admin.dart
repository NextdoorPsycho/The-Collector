import 'package:flutter/material.dart';

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
    const storageUsage = 10.5; // Example storage usage in GB

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: const Icon(Icons.people),
                  title: const Text('Users'),
                  subtitle: const Text('Total Storage Used: 0 bytes'),
                  onTap: () => showDialog(
                    context: context,
                    builder: (BuildContext context) {
                      return const AlertDialog(
                        title: Text('Users'),
                        content: null,
                      );
                    },
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.people),
                  title: const Text('Users'),
                  onTap: () => showDialog(
                    context: context,
                    builder: (BuildContext context) {
                      return const AlertDialog(
                        title: Text('Users'),
                        content: null,
                      );
                    },
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.storage),
                  title: const Text('Storage'),
                  subtitle: Text(
                      'Storage usage: ${storageUsage.toStringAsFixed(2)} GB'),
                ),
                ListTile(
                  leading: const Icon(Icons.warning),
                  title: const Text('Danger Zone'),
                  onTap: () {
                    // Navigate to /DangerZone page
                    Navigator.pushNamed(context, '/DangerZone');
                  },
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ListTile(
                  title: Text('App Settings'),
                ),
                ListTile(
                  leading: const Icon(Icons.notifications),
                  title: const Text('Notifications'),
                  subtitle: const Text('Manage app notifications'),
                  onTap: () {
                    // Handle notifications settings
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.security),
                  title: const Text('Security'),
                  subtitle: const Text('Manage app security settings'),
                  onTap: () {
                    // Handle security settings
                  },
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ListTile(
                  title: Text('Analytics'),
                ),
                ListTile(
                  leading: const Icon(Icons.insert_chart),
                  title: const Text('User Analytics'),
                  subtitle: const Text('View user analytics and insights'),
                  onTap: () {
                    // Navigate to user analytics page
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.trending_up),
                  title: const Text('App Performance'),
                  subtitle: const Text('Monitor app performance metrics'),
                  onTap: () {
                    // Navigate to app performance page
                  },
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ListTile(
                  title: Text('Maintenance'),
                ),
                ListTile(
                  leading: const Icon(Icons.build),
                  title: const Text('App Maintenance'),
                  subtitle: const Text('Perform app maintenance tasks'),
                  onTap: () {
                    // Handle app maintenance tasks
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.system_update),
                  title: const Text('System Updates'),
                  subtitle: const Text('Manage system updates'),
                  onTap: () {
                    // Handle system updates
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
