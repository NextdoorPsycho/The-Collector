import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pandabar/main.view.dart';
import 'package:pandabar/model.dart';
import 'package:the_collector/pages/collection/deck/deck_raw.dart';
import 'package:the_collector/pages/collection/deck/deck_settings.dart';

class DeckCards extends StatefulWidget {
  const DeckCards({super.key, this.deckId});

  final String? deckId;

  @override
  State<DeckCards> createState() => _DeckCardsState();
}

class _DeckCardsState extends State<DeckCards> {
  int _currentIndex = 0;

  late StreamSubscription<bool> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        title: const Text('Leave Deck'),
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          DeckCards(),
          DeckRaw(),
          DeckCards(),
          DeckSettings(),
        ],
      ),
      bottomNavigationBar: PandaBar(
        onFabButtonPressed: () async {},
        fabIcon: Icon(
          Icons.sensor_window_outlined,
          color: Theme.of(context).colorScheme.surface,
        ),
        fabColors: [
          Theme.of(context).colorScheme.onSurface,
          Theme.of(context).colorScheme.onSurface,
        ],
        buttonData: [
          PandaBarButtonData(
            id: '0',
            icon: Icons.sensor_window_outlined,
            title: 'Cards',
          ),
          PandaBarButtonData(
            id: '1',
            icon: Icons.sensor_window_outlined,
            title: 'Cards',
          ),
          PandaBarButtonData(
            id: '2',
            icon: Icons.sensor_window_outlined,
            title: 'Cards',
          ),
          PandaBarButtonData(
            id: '3',
            icon: Icons.sensor_window_outlined,
            title: 'Cards',
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
