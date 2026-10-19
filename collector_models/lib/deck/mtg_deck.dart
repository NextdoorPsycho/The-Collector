import 'package:dart_mappable/dart_mappable.dart';

import 'deck_entry.dart';

part 'mtg_deck.mapper.dart';

@MappableEnum()
enum DeckFormat { casual, commander, standard }

@MappableEnum()
enum CollectionGroupKind { deck, binder, box, folder, list }

@MappableClass()
class MTGDeck with MTGDeckMappable {
  String? id;
  final String name;
  final List<String> cards;
  final List<DeckEntry>? entries;
  final DeckFormat format;
  final CollectionGroupKind kind;
  final String? parentId;
  final String? sourceUrl;
  final String? sourceFormat;

  MTGDeck({
    required this.name,
    this.cards = const <String>[],
    this.entries,
    this.format = DeckFormat.casual,
    this.kind = CollectionGroupKind.deck,
    this.parentId,
    this.sourceUrl,
    this.sourceFormat,
  });

  List<DeckEntry> get effectiveEntries {
    if (entries != null) {
      return entries!;
    }
    final Map<String, int> quantities = <String, int>{};
    for (final String cardId in cards) {
      quantities[cardId] = (quantities[cardId] ?? 0) + 1;
    }
    return quantities.entries
        .map(
          (MapEntry<String, int> entry) =>
              DeckEntry(scryfallId: entry.key, quantity: entry.value),
        )
        .toList();
  }
}
