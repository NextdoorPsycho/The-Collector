import 'package:flutter/material.dart';
import 'package:the_collector/crud.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:toxic/toxic.dart';

class DeckCards extends StatefulWidget {
  const DeckCards({super.key, this.deckId});

  final String? deckId;

  @override
  State<DeckCards> createState() => _DeckCardsState();
}

class _DeckCardsState extends State<DeckCards> {
  int _currentIndex = 0;

  late ThemeMode _initialThemeMode;

  String get deckId => widget.deckId!;

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Crud.deck(u).stream(deckId).build((data) => Placeholder());
  }
}
