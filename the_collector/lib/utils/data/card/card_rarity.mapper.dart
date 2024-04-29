// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'card_rarity.dart';

class CardRarityMapper extends EnumMapper<CardRarity> {
  CardRarityMapper._();

  static CardRarityMapper? _instance;
  static CardRarityMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CardRarityMapper._());
    }
    return _instance!;
  }

  static CardRarity fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  CardRarity decode(dynamic value) {
    switch (value) {
      case 'common':
        return CardRarity.common;
      case 'uncommon':
        return CardRarity.uncommon;
      case 'rare':
        return CardRarity.rare;
      case 'special':
        return CardRarity.special;
      case 'mythic':
        return CardRarity.mythic;
      case 'bonus':
        return CardRarity.bonus;
      case 'unknown':
        return CardRarity.unknown;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(CardRarity self) {
    switch (self) {
      case CardRarity.common:
        return 'common';
      case CardRarity.uncommon:
        return 'uncommon';
      case CardRarity.rare:
        return 'rare';
      case CardRarity.special:
        return 'special';
      case CardRarity.mythic:
        return 'mythic';
      case CardRarity.bonus:
        return 'bonus';
      case CardRarity.unknown:
        return 'unknown';
    }
  }
}

extension CardRarityMapperExtension on CardRarity {
  String toValue() {
    CardRarityMapper.ensureInitialized();
    return MapperContainer.globals.toValue<CardRarity>(this) as String;
  }
}
