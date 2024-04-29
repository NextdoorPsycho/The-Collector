import 'dart:ui';

import 'package:fire_crud/fire_crud.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:padded/padded.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/crud.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/pages/nav_util.dart';
import 'package:the_collector/theme/animation/spinning_triangle.dart';
import 'package:the_collector/theme/toastification.dart';
import 'package:the_collector/utils/data/card/card_type.dart';
import 'package:the_collector/utils/data/card/mtg_card.dart';

class CollectionCards extends StatefulWidget {
  const CollectionCards({super.key});

  @override
  _CollectionCardsState createState() => _CollectionCardsState();
}

class _CollectionCardsState extends State<CollectionCards> {
  TextEditingController searchController = TextEditingController();
  Map<MtgCard, int> cardCountMap = {};

  @override
  Widget build(BuildContext context) {
    final apiClient = ScryfallApiClient();

    ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              Nav.goToHome(context);
            },
          ),
          title: PaddingAll(
            padding: 5,
            child: TextField(
              controller: searchController,
              decoration: InputDecoration(
                hintText: "Search Cards",
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    searchController.clear();
                  },
                ),
              ),
              onChanged: (value) {
                filterSearchResults(value);
              },
            ),
          )),
      body: FireGrid<MTGCard>(
        crud: Crud.card(u),
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        loading: SpinningTriangle(iconColor: theme.colorScheme.onSurface),
        empty: const Text('No cards found'),
        failed: const Text('Failed to load cards'),
        builder: (context, card) {
          return buildCardItem(card, apiClient);
        },
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'addCard',
        onPressed: () => showAddCardDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  void filterSearchResults(String query) {
    var dummySearchList = <MtgCard, int>{};
    dummySearchList.addAll(cardCountMap);
    if (query.isNotEmpty) {
      Map<MtgCard, int> filteredCards = {};
      dummySearchList.forEach((card, count) {
        if (card.name.toLowerCase().contains(query.toLowerCase())) {
          filteredCards[card] = count;
        }
      });
      setState(() {
        cardCountMap = filteredCards;
      });
    }
  }

  Widget buildCardItem(MTGCard card, ScryfallApiClient apiClient) {
    return FutureBuilder<Uint8List>(
      future: apiClient.getCardByIdAsImage(card.id!,
          imageVersion: ImageVersion.small),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          // Loading screen
          return Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(
              child: CircularProgressIndicator(),
            ),
          );
        } else if (snapshot.hasError) {
          // Error handling
          return const Text('Error loading image');
        } else if (snapshot.hasData) {
          // Image available
          return InkWell(
            onTap: () {
              // Nav.goToCard(context, card.id);
            },
            onLongPress: () {
              Crud.card(u).delete(card.id.toString());
              Toast.scaryToast(context, "DELETED CARD", "");
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                    child: Image.memory(
                      snapshot.data!,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 16,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surface
                                .withOpacity(0.8),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            card.name,
                            style: Theme.of(context).textTheme.titleLarge,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 4,
                            horizontal: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surface
                                .withOpacity(0.8),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            'Count: ${card.quantity}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        } else {
          // Placeholder when no data is available
          return const Text('No data');
        }
      },
    );
  }

  void showAddCardDialog(BuildContext context) {
    TextEditingController cardTextBoxController = TextEditingController();
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Add a Card (Search)'),
          content: TextField(
            controller: cardTextBoxController,
            decoration: const InputDecoration(hintText: 'Card Name'),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                final apiClient = ScryfallApiClient();
                var card = await apiClient.getRandomCard();
                Crud.card(u).set(
                    card.id,
                    MTGCard(
                        name: card.name,
                        setId: card.setId,
                        description: card.printedText ?? "",
                        flavorText: card.flavorText ?? "",
                        cardType: CardType.generic,
                        rarity: "Common",
                        manaCost: "manaCost"));
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }
}
