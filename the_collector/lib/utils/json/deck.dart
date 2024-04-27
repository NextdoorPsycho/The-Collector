import 'package:dart_mappable/dart_mappable.dart';
import 'package:the_collector/utils/json/mtg_card.dart';

part 'deck.mapper.dart';

@MappableClass()
class Deck with DeckMappable {
  final String name;
  final List<MtgCard> cards;
  String? id;
  bool? exists;

  Deck({
    required this.name,
    this.cards = const [],
  });
}
