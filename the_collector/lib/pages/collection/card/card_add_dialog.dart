import 'package:fast_log/fast_log.dart';
import 'package:flutter/material.dart';
import 'package:magic_card/magic_card.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/data/card/mtg_card.dart';

void showAddCardDialog(BuildContext context) {
  TextEditingController cardTextBoxController = TextEditingController();
  Future<List<MtgCard>>? searchResultsFuture;

  showDialog(
    context: context,
    builder: (BuildContext context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Add a Card (Search)'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: cardTextBoxController,
                  decoration: const InputDecoration(hintText: 'Card Name'),
                  onSubmitted: (value) {
                    final cardName = value.toLowerCase();
                    info(cardName);

                    searchResultsFuture =
                        CardSearch.searchCardsByStrings([cardName]);
                    info('Search results: $searchResultsFuture');
                    setState(() {});
                  },
                ),
                const SizedBox(height: 16),
                if (searchResultsFuture != null)
                  FutureBuilder<List<MtgCard>>(
                    future: searchResultsFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const CircularProgressIndicator();
                      } else if (snapshot.hasError) {
                        return Text('Error: ${snapshot.error}');
                      } else if (snapshot.hasData) {
                        final searchResults = snapshot.data!;
                        return Container(
                          height: 300,
                          decoration: BoxDecoration(
                            border: Border.all(
                              width: 1.25,
                            ),
                            borderRadius: BorderRadius.circular(16.0),
                          ),
                          child: Scrollbar(
                            child: ListView.builder(
                              itemCount: searchResults.length,
                              itemExtent: 250,
                              cacheExtent: 450,
                              itemBuilder: (context, index) {
                                final card = searchResults[index];
                                return GestureDetector(
                                  onTap: () async {
                                    final cardId = card.id;
                                    final crudCard = Crud.card(u);

                                    if (await crudCard.exists(cardId)) {
                                      final existingCard =
                                          await crudCard.get(cardId);
                                      final currentQuantity =
                                          existingCard.quantity;
                                      info(
                                          'Card already exists, Current quantity: $currentQuantity');

                                      await crudCard
                                          .txn(
                                              cardId,
                                              (data) => data.copyWith(
                                                  quantity:
                                                      currentQuantity + 1))
                                          .then((value) =>
                                              Navigator.pop(context));
                                      info(
                                          'Quantity updated to ${currentQuantity + 1}');
                                    } else {
                                      await crudCard
                                          .set(
                                            cardId,
                                            MTGCard(
                                              name: card.name,
                                              setId: card.setId,
                                              description:
                                                  card.printedText ?? "",
                                              flavorText: card.flavorText ?? "",
                                              quantity: 1,
                                              rarity: card.rarity,
                                              cmc: card.cmc,
                                              typeLine: card.typeLine,
                                              setType: card.setType,
                                              manaCost: card.manaCost,
                                            ),
                                          )
                                          .then((value) =>
                                              Navigator.pop(context));
                                    }
                                  },
                                  child: CardView(
                                    id: card.id,
                                    foil: false,
                                    back: false,
                                    interactive: false,
                                    interactive3D: false,
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      } else {
                        return const Text('No data');
                      }
                    },
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                },
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      );
    },
  );
}
