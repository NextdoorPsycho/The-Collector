import 'package:dialoger/dialoger.dart';
import 'package:fire_crud/fire_crud.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:the_collector/crud.dart';
import 'package:the_collector/pages/collection/deck/deck.dart';
import 'package:the_collector/utils/data/deck/mtg_deck.dart';
import 'package:toxic/toxic.dart';

String get u => FirebaseAuth.instance.currentUser!.uid;

class CollectionDecks extends StatefulWidget {
  const CollectionDecks({super.key});

  @override
  _CollectionDecksState createState() => _CollectionDecksState();
}

class _CollectionDecksState extends State<CollectionDecks> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        floatingActionButton: const NewDeckButton(),
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              Navigator.pop(context);
            },
          ),
          title: const Text('Leave Collections'),
        ),
        body: FireGrid<MTGDeck>(
          padding: const EdgeInsets.all(16),
          gridDelegate: Grids.softSize(context, 200,
              crossAxisSpacing: 16, mainAxisSpacing: 16),
          crud: Crud.deck(u),
          builder: (context, deck) => DeckCard(deck: deck),
        ));
  }
}

class NewDeckButton extends StatelessWidget {
  const NewDeckButton({super.key});

  @override
  Widget build(BuildContext context) => FloatingActionButton(
        onPressed: () {
          dialogText(
              context: context,
              title: "New Deck",
              submitButtonText: "Create",
              onSubmit: (context, text) =>
                  Crud.deck(u).add(MTGDeck(name: text)));
        },
        child: const Icon(Icons.add),
      );
}

class DeckCard extends StatelessWidget {
  final MTGDeck deck;
  const DeckCard({super.key, required this.deck});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => DeckCards(
              deckId: deck.id,
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            deck.name,
            style: Theme.of(context).textTheme.headline6,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
