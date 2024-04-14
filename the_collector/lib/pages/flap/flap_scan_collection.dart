import 'package:fast_log/fast_log.dart';
import 'package:flutter/material.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/data/functions_file_interaction.dart';
import 'package:the_collector/data/user_manager.dart';

class FlapScanCollection extends StatefulWidget {
  const FlapScanCollection({
    super.key,
  });

  @override
  _FlapScanCollectionState createState() => _FlapScanCollectionState();
}

class _FlapScanCollectionState extends State<FlapScanCollection> {
  @override
  Widget build(BuildContext c) {
    return UserManager.streamCollection().build((collection) {
      info('Collection - : $collection');
      Map<MtgCard, int> cardIds = collection ?? {};

      return Scaffold(
        body: cardIds.isEmpty
            ? const Center(
                child: Text('No cards found in your collection.'),
              )
            : ListView.builder(
                itemCount: cardIds.length,
                itemBuilder: (context, index) {
                  MtgCard card = cardIds.keys.elementAt(index);
                  int quantity = cardIds.values.elementAt(index);

                  return InkWell(
                    onTap: () {
                      // Remove the card from the collection when pressed
                      CardFunctions.removeCardFromCollection(
                        quantity: 1,
                        card: card,
                        context: context,
                      );
                    },
                    onLongPress: () {
                      // Add 1 to the quantity when long-pressed
                      CardFunctions.addCardToCollection(
                        quantity: 1,
                        card: card,
                        context: context,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Card ID: ${card.id}, Name: ${card.name}',
                            style: const TextStyle(fontSize: 16.0),
                          ),
                          const SizedBox(height: 8.0),
                          Text(
                            'Quantity: $quantity',
                            style: const TextStyle(fontSize: 14.0),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
        floatingActionButton: FloatingActionButton(
          onPressed: () async {
            MtgCard card = await ScryfallApiClient().getRandomCard();
            info('Adding card to collection: $card');
            CardFunctions.addCardToCollection(
              quantity: 1,
              card: card,
              context: context,
            );
          },
          child: const Icon(Icons.add),
        ),
      );
    });
  }
}
