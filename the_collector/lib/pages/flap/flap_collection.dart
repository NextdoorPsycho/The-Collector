import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:infinite_carousel/infinite_carousel.dart';
import 'package:magic_card/magic_card.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/data/user_manager.dart';

class FlapCollection extends StatefulWidget {
  const FlapCollection({super.key});

  @override
  _FlapCollectionState createState() => _FlapCollectionState();
}

class _FlapCollectionState extends State<FlapCollection> {
  late InfiniteScrollController _carouselController;

  @override
  void initState() {
    super.initState();
    _carouselController = InfiniteScrollController();
  }

  @override
  void dispose() {
    _carouselController.dispose();
    super.dispose();
  }

  Widget buildCarousel(List<Widget> cardWidgets) {
    return SizedBox(
      height: 225,
      child: InfiniteCarousel.builder(
        itemCount: cardWidgets.length,
        itemExtent: 150,
        loop: true,
        center: true,
        physics: const InfiniteScrollPhysics(),
        controller: _carouselController,
        itemBuilder: (context, itemIndex, realIndex) => cardWidgets[realIndex],
      ),
    );
  }

  Widget buildGridList(Map<MtgCard, int> cards) {
    return GridView.builder(
      gridDelegate:
          const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3),
      itemCount: cards.length,
      itemBuilder: (context, index) {
        var card = cards.entries.elementAt(index).key;
        return CardView(
          id: card.id,
          back: false,
          foil: false,
          interactive3D: false,
          interactive: false,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final apiClient = ScryfallApiClient();
    return UserManager.streamCollection().build((collection) {
      Map<MtgCard, int> cards = collection ?? {};
      List<Widget> cardWidgets = cards.entries
          .map((entry) => FutureBuilder<Uint8List>(
                future: apiClient.getCardByIdAsImage(entry.key.id),
                builder: (context, snapshot) {
                  if (snapshot.hasData) {
                    return CardView(
                      id: entry.key.id,
                      back: false,
                      foil: false,
                      interactive3D: false,
                      interactive: false,
                    );
                  } else {
                    return const Center(child: CircularProgressIndicator());
                  }
                },
              ))
          .toList();

      return Column(
        children: [
          buildCarousel(cardWidgets),
          const TextField(
            decoration: InputDecoration(
              labelText: 'Search cards',
              suffixIcon: Icon(Icons.search),
            ),
          ),
          Expanded(child: buildGridList(cards)),
        ],
      );
    });
  }
}
