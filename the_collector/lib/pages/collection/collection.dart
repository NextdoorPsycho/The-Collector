import 'package:flutter/material.dart';
import 'package:pandabar/main.view.dart';
import 'package:pandabar/model.dart';
import 'package:the_collector/pages/collection/collection_cards.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/pages/collection/collection_prices.dart';
import 'package:the_collector/pages/collection/collection_shops.dart';
import 'package:the_collector/utils/functions/ocr_utils.dart';

class CollectionHub extends StatefulWidget {
  const CollectionHub({super.key});

  @override
  State<CollectionHub> createState() => _CollectionHubState();
}

class _CollectionHubState extends State<CollectionHub> {
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
        children: [
          CollectionCards(),
          CollectionDecks(),
          CollectionPrices(),
          CollectionShops(),
        ],
      ),
      bottomNavigationBar: PandaBar(
        onFabButtonPressed: () async {
          OCRUtilities().pickAndProcessImage(context);
        },
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
            icon: Icons.style_outlined,
            title: 'Cards',
          ),
          PandaBarButtonData(
            id: '1',
            icon: Icons.inbox_outlined,
            title: 'Decks',
          ),
          PandaBarButtonData(
            id: '2',
            icon: Icons.attach_money_outlined,
            title: 'Prices',
          ),
          PandaBarButtonData(
            id: '3',
            icon: Icons.add_business_outlined,
            title: 'Shops',
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
