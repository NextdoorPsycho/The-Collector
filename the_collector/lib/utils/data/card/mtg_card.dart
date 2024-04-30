import 'package:dart_mappable/dart_mappable.dart';
import 'package:scryfall_api/scryfall_api.dart';

part 'mtg_card.mapper.dart';

@MappableClass()
class MTGCard with MTGCardMappable {
  String? id;
  final String name;
  final String setId;
  final String description;
  final String flavorText;
  final double cmc;
  final String typeLine;
  BorderColor? borderColor;
  final Rarity rarity;
  final int quantity;

  final SetType setType;
  final dynamic manaCost;

  MTGCard(
      {required this.name,
      required this.setId,
      required this.description,
      this.quantity = 1,
      required this.cmc,
      required this.typeLine,
      required this.flavorText,
      this.borderColor,
      required this.setType,
      required this.rarity,
      required this.manaCost});
}
