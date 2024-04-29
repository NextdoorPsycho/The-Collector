import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/material.dart';
import 'package:the_collector/utils/data/card/card_type.dart';
import 'package:the_collector/utils/data/card/mtg_card.dart';

part 'mtg_artifact.mapper.dart';

@MappableClass()
// Extend MTG Card
class MTGArtifactCard extends MTGCard with MTGArtifactCardMappable {
  MTGArtifactCard({
    // Define super parameters for mtg card
    required super.name,
    required super.setId,
    required super.description,
    required super.flavorText,
    required super.rarity,
    super.quantity = 1,
    required super.manaCost,
    super.cardType = CardType.artifact,
  });

  @override
  IconData getIcon() => Icons.card_giftcard_sharp;
}
