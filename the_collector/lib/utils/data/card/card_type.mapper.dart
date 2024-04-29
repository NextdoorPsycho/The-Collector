// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'card_type.dart';

class CardTypeMapper extends EnumMapper<CardType> {
  CardTypeMapper._();

  static CardTypeMapper? _instance;
  static CardTypeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CardTypeMapper._());
    }
    return _instance!;
  }

  static CardType fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  CardType decode(dynamic value) {
    switch (value) {
      case 'generic':
        return CardType.generic;
      case 'land':
        return CardType.land;
      case 'creature':
        return CardType.creature;
      case 'enchantment':
        return CardType.enchantment;
      case 'artifact':
        return CardType.artifact;
      case 'instant':
        return CardType.instant;
      case 'sorcery':
        return CardType.sorcery;
      case 'planeswalker':
        return CardType.planeswalker;
      case 'tribal':
        return CardType.tribal;
      case 'artifactCreature':
        return CardType.artifactCreature;
      case 'enchantmentCreature':
        return CardType.enchantmentCreature;
      case 'artifactLand':
        return CardType.artifactLand;
      case 'enchantmentLand':
        return CardType.enchantmentLand;
      case 'legendary':
        return CardType.legendary;
      case 'snow':
        return CardType.snow;
      case 'world':
        return CardType.world;
      case 'conspiracy':
        return CardType.conspiracy;
      case 'plane':
        return CardType.plane;
      case 'phenomenon':
        return CardType.phenomenon;
      case 'scheme':
        return CardType.scheme;
      case 'vanguard':
        return CardType.vanguard;
      case 'token':
        return CardType.token;
      case 'emblem':
        return CardType.emblem;
      case 'hero':
        return CardType.hero;
      case 'saga':
        return CardType.saga;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(CardType self) {
    switch (self) {
      case CardType.generic:
        return 'generic';
      case CardType.land:
        return 'land';
      case CardType.creature:
        return 'creature';
      case CardType.enchantment:
        return 'enchantment';
      case CardType.artifact:
        return 'artifact';
      case CardType.instant:
        return 'instant';
      case CardType.sorcery:
        return 'sorcery';
      case CardType.planeswalker:
        return 'planeswalker';
      case CardType.tribal:
        return 'tribal';
      case CardType.artifactCreature:
        return 'artifactCreature';
      case CardType.enchantmentCreature:
        return 'enchantmentCreature';
      case CardType.artifactLand:
        return 'artifactLand';
      case CardType.enchantmentLand:
        return 'enchantmentLand';
      case CardType.legendary:
        return 'legendary';
      case CardType.snow:
        return 'snow';
      case CardType.world:
        return 'world';
      case CardType.conspiracy:
        return 'conspiracy';
      case CardType.plane:
        return 'plane';
      case CardType.phenomenon:
        return 'phenomenon';
      case CardType.scheme:
        return 'scheme';
      case CardType.vanguard:
        return 'vanguard';
      case CardType.token:
        return 'token';
      case CardType.emblem:
        return 'emblem';
      case CardType.hero:
        return 'hero';
      case CardType.saga:
        return 'saga';
    }
  }
}

extension CardTypeMapperExtension on CardType {
  String toValue() {
    CardTypeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<CardType>(this) as String;
  }
}
