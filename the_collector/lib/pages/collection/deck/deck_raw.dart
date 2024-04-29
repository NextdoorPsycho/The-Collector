import 'package:flutter/material.dart';
import 'package:the_collector/crud.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:toxic/toxic.dart';

class DeckRaw extends StatefulWidget {
  const DeckRaw({super.key, this.deckId});

  final String? deckId;

  @override
  State<DeckRaw> createState() => _DeckRawState();
}

class _DeckRawState extends State<DeckRaw> {
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
