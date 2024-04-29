import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/material.dart';
import 'package:the_collector/utils/data/card/card_type.dart';
import 'package:the_collector/utils/data/card/parts/mtg_artifact.dart';
import 'package:the_collector/utils/data/card/parts/mtg_creature.dart';
import 'package:the_collector/utils/data/card/parts/mtg_land.dart';

part 'mtg_card.mapper.dart';

// We need to tell mappable what types this is a superclass of for it to work
@MappableClass(
  includeSubClasses: [MTGLandCard, MTGArtifactCard, MTGCreatureCard],
)
class MTGCard with MTGCardMappable {
  String? id;
  final String name;
  final String setId;
  final String description;
  final String flavorText;
  final String rarity;
  final int quantity;
  final CardType cardType;
  final dynamic manaCost;

  MTGCard(
      {required this.name,
      required this.setId,
      required this.description,
      this.quantity = 1,
      required this.flavorText,
      required this.cardType,
      required this.rarity,
      required this.manaCost});

  bool get isLand => this is MTGLandCard;
  bool get isArtifact => this is MTGArtifactCard;
  bool get isCreature => this is MTGCreatureCard;

  IconData getIcon() => Icons.ac_unit;
}
