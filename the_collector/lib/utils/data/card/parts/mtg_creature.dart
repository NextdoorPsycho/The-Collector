import 'package:dart_mappable/dart_mappable.dart';
import 'package:the_collector/utils/data/card/card_type.dart';
import 'package:the_collector/utils/data/card/mtg_card.dart';

part 'mtg_creature.mapper.dart';

@MappableClass()
// Extend MTG Card
class MTGCreatureCard extends MTGCard with MTGCreatureCardMappable {
  final int power;
  final int toughness;

  MTGCreatureCard(
      {required super.name,
      required super.setId,
      required super.description,
      required super.flavorText,
      required super.rarity,
      super.quantity = 1,
      required super.manaCost,
      required this.power,
      super.cardType = CardType.creature,
      required this.toughness});
}
