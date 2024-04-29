import 'package:dart_mappable/dart_mappable.dart';

part 'mtg_deck.mapper.dart';

// We need to tell mappable what types this is a superclass of for it to work
@MappableClass()
class MTGDeck with MTGDeckMappable {
  String? id;
  final String name;
  final List<String> cards;

  MTGDeck({required this.name, this.cards = const []});
}
