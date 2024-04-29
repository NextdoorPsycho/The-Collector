import 'package:dart_mappable/dart_mappable.dart';

part 'card_rarity.mapper.dart';

@MappableEnum()
enum CardRarity {
  /// Common rarity.
  common,

  /// Uncommon rarity.
  uncommon,

  /// Rare rarity.
  rare,

  /// Special rarity.
  special,

  /// Mythic rarity.
  mythic,

  /// Bonus rarity.
  bonus,

  /// Unknown rarity.
  unknown,
}
