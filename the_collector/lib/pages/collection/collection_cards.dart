import 'package:flutter/material.dart';
import 'package:padded/padded.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/pages/nav_util.dart';
import 'package:the_collector/theme/toastification.dart';
import 'package:the_collector/utils/data/functions_file_interaction.dart';
import 'package:the_collector/utils/data/user_manager.dart';

class CollectionCards extends StatefulWidget {
  const CollectionCards({super.key});

  @override
  _CollectionCardsState createState() => _CollectionCardsState();
}

class _CollectionCardsState extends State<CollectionCards> {
  TextEditingController searchController = TextEditingController();
  Map<MtgCard, int> cardCountMap =
      {}; // Ensure you initialize this map appropriately

  @override
  void initState() {
    super.initState();
    loadInitialData();
  }

  void loadInitialData() async {
    // Load your cards into cardCountMap
    // Example:
    UserManager.streamCollection().listen((data) {
      setState(() {
        cardCountMap = data;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
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
                    loadInitialData(); // Refresh to initial data when cleared
                  },
                ),
              ),
              onChanged: (value) {
                filterSearchResults(value);
              },
            ),
          )),
      body: buildCardGrid(),
      floatingActionButton: FloatingActionButton(
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
    } else {
      loadInitialData();
    }
  }

  Widget buildCardGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: cardCountMap.length,
      itemBuilder: (context, index) {
        MtgCard card = cardCountMap.keys.elementAt(index);
        int count = cardCountMap[card] ?? 0;
        return buildCardItem(card, count);
      },
    );
  }

  Widget buildCardItem(MtgCard card, int count) {
    return InkWell(
      onTap: () {
        CardFunctions.removeCardFromCollection(
            card: card, context: context, quantity: 1);
      },
      onLongPress: () {
        CardFunctions.addCardToCollection(
            card: card, context: context, quantity: 1);
      },
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              card.name,
              style: Theme.of(context).textTheme.headline6,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Count: $count',
              style: Theme.of(context).textTheme.subtitle1,
            ),
          ],
        ),
      ),
    );
  }

  void showAddCardDialog(BuildContext context) {
    TextEditingController _cardTextBoxController = TextEditingController();
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Add a Card (Search)'),
          content: TextField(
            controller: _cardTextBoxController,
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
                Toast.successToast(context, "Creation Success",
                    "I Added a card! (Not really, but this is what it would look like if I did)");
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }
}
