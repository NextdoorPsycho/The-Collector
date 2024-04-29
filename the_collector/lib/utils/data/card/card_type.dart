import 'package:dart_mappable/dart_mappable.dart';

part 'card_type.mapper.dart';

@MappableEnum()
enum CardType {
  generic,
  land,
  creature,
  enchantment,
  artifact,
  instant,
  sorcery,
  planeswalker,
  tribal,
  artifactCreature,
  enchantmentCreature,
  artifactLand,
  enchantmentLand,
  legendary,
  snow,
  world,
  conspiracy,
  plane,
  phenomenon,
  scheme,
  vanguard,
  token,
  emblem,
  hero,
  saga,
}
