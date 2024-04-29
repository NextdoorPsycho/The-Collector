import 'package:flutter/material.dart';
import 'package:pandabar/main.view.dart';
import 'package:pandabar/model.dart';
import 'package:the_collector/pages/dock/hub_collection.dart';
import 'package:the_collector/pages/dock/hub_dice.dart';
import 'package:the_collector/pages/dock/hub_rules.dart';
import 'package:the_collector/pages/dock/hub_settings.dart';

class CollectorHub extends StatefulWidget {
  const CollectorHub({super.key});

  @override
  State<CollectorHub> createState() => _CollectorHubState();
}

class _CollectorHubState extends State<CollectorHub> {
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
        children: const [HubCollection(), HubDice(), HubRules(), HubSettings()],
      ),
      bottomNavigationBar: PandaBar(
        onFabButtonPressed: () async {},
        fabIcon: Icon(
          Icons.question_mark_outlined,
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
        buttonColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.40),
      ),
    );
  }
}
