import 'package:dart_mappable/dart_mappable.dart';
import 'package:the_collector/utils/data/card/card_type.dart';
import 'package:the_collector/utils/data/card/mana_color.dart';
import 'package:the_collector/utils/data/card/mtg_card.dart';

part 'mtg_land.mapper.dart';

@MappableClass()
// Extend MTG Card
class MTGLandCard extends MTGCard with MTGLandCardMappable {
  final ManaColor manaColor;
  final int manaValue;

  MTGLandCard(
      {required super.name,
      required super.setId,
      required super.description,
      required super.flavorText,
      required super.rarity,
      required super.manaCost,
      super.quantity = 1,
      super.cardType = CardType.land,
      required this.manaColor,
      required this.manaValue});
}
