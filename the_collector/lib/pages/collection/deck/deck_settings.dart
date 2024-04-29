import 'package:flutter/material.dart';
import 'package:the_collector/crud.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:toxic/toxic.dart';

class DeckSettings extends StatefulWidget {
  const DeckSettings({super.key, this.deckId});

  final String? deckId;

  @override
  State<DeckSettings> createState() => _DeckSettingsState();
}

class _DeckSettingsState extends State<DeckSettings> {
  String get deckId => widget.deckId!;

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Crud.deck(u).stream(deckId).build((data) => const Placeholder());
  }
}
