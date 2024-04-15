import 'package:flutter/material.dart';
import 'package:the_collector/theme/screen_templates/template_animate_simple.dart';
import 'package:the_collector/theme/toastification.dart';
import 'package:the_collector/utils/data/deck_tools.dart';
import 'package:the_collector/utils/data/user_manager.dart';

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
    return UserManager.streamAdminStatus().build((admin) {
      return Scaffold(
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            TextEditingController _deckNameController = TextEditingController();

            showDialog(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text('Create a new deck'),
                  content: TextField(
                    controller: _deckNameController,
                    decoration: const InputDecoration(
                      hintText: 'Deck Name',
                    ),
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
                        String deckName = _deckNameController.text;

                        bool nameExists = false;
                        DeckFunctions.getAllDecksByUserId()
                            .then((value) => value.forEach((deck) {
                                  if (deck.name == deckName) {
                                    nameExists = true;
                                  }
                                }));
                        if (!nameExists) {
                          await DeckFunctions.createDeck(
                            name: deckName,
                            cards: [],
                          ).then((value) => value == true
                              ? {
                                  Toast.successToast(
                                      context,
                                      "Creation Success",
                                      "Deck $deckName created successfully.")
                                }
                              : {
                                  Toast.scaryToast(context, "Creation Failed",
                                      "Deck could not be created.")
                                });
                          Navigator.pop(context);
                        } else {
                          Toast.scaryToast(context, "Creation Failed",
                              "Deck with this name already exists.");
                        }
                      },
                      child: const Text('Create'),
                    ),
                  ],
                );
              },
            );
          },
          child: const Icon(Icons.add),
        ),
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              Navigator.pop(context);
            },
          ),
          title: const Text('Leave Collections'),
        ),
        body: UserManager.streamDecks().build((decks) {
          if (decks == null || decks.isEmpty) {
            return const AnimatedSimpleScreen(
              title: 'No Decks',
              description: 'You have no decks yet!',
            );
          } else {
            return GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: decks.length,
              itemBuilder: (context, index) {
                Deck deck = decks[index];
                return InkWell(
                  onTap: () {
                    // Handle deck tap
                    // Navigate to deck details screen or perform any desired action
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
              },
            );
          }
        }),
      );
    });
  }
}
