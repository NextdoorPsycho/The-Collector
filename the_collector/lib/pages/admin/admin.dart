import 'package:flutter/material.dart';
import 'package:pandabar/main.view.dart';
import 'package:pandabar/model.dart';
import 'package:the_collector/pages/admin/admin_users.dart';

class AdminHub extends StatefulWidget {
  const AdminHub({super.key});

  @override
  State<AdminHub> createState() => _AdminHubState();
}

class _AdminHubState extends State<AdminHub> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          AdminUsers(),
          AdminUsers(),
          AdminUsers(),
          AdminUsers(),
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
        buttonColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.40),
      ),
    );
  }
}
