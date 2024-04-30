import 'package:fire_crud/fire_crud.dart';
import 'package:flutter/material.dart';
import 'package:padded/padded.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/pages/collection/card/card_add_dialog.dart';
import 'package:the_collector/pages/collection/card/card_item.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/pages/nav_util.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/data/card/mtg_card.dart';

class CollectionCards extends StatefulWidget {
  const CollectionCards({super.key});

  @override
  _CollectionCardsState createState() => _CollectionCardsState();
}

class _CollectionCardsState extends State<CollectionCards> {
  TextEditingController searchController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final apiClient = ScryfallApiClient();

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
              onChanged: (value) {},
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
        loading: const CircularProgressIndicator(),
        empty: Center(
          child: Text(
            'NO CARDS :(',
            style: Theme.of(context).textTheme.headline4,
          ),
        ),
        failed: const Placeholder(),
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
}
