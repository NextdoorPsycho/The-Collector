import 'dart:convert';

import 'package:collector_models/card/mtg_card.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:test/test.dart';

Map<String, Object?> _storedCard({String? manaCost = '{1}{U}'}) =>
    <String, Object?>{
      'name': 'Stored card',
      'setId': 'scryfall-set-id',
      'description': 'Draw a card.',
      'quantity': 3,
      'cmc': 2.0,
      'typeLine': 'Instant',
      'flavorText': '',
      'borderColor': 'black',
      'setType': 'fromTheVault',
      'rarity': 'rare',
      'manaCost': manaCost,
    };

void main() {
  test('persisted Scryfall enum names retain their Firestore schema', () {
    final Map<String, Object?> stored = _storedCard();
    final MTGCard card = MTGCardMapper.fromMap(stored);

    expect(card.borderColor, BorderColor.black);
    expect(card.setType, SetType.fromTheVault);
    expect(card.rarity, Rarity.rare);
    expect(card.id, isNull);
    expect(card.toMap(), containsPair('setType', stored['setType']));
    for (final MapEntry<String, Object?> field in stored.entries) {
      expect(card.toMap()[field.key], field.value);
    }
    expect(card.finish, isNull);
    expect(card.language, isNull);

    final Map<String, Object?> json =
        jsonDecode(card.toJson()) as Map<String, Object?>;
    for (final MapEntry<String, Object?> field in stored.entries) {
      expect(json[field.key], field.value);
    }
  });

  test('all current Scryfall enum values round trip through JSON', () {
    final MTGCard original = MTGCardMapper.fromMap(_storedCard());
    for (final Rarity rarity in Rarity.values) {
      final MTGCard card = original.copyWith(rarity: rarity);
      final MTGCard decoded = MTGCardMapper.fromJson(card.toJson());
      expect(decoded.rarity, rarity);
    }
    for (final SetType setType in SetType.values) {
      final MTGCard card = original.copyWith(setType: setType);
      final MTGCard decoded = MTGCardMapper.fromJson(card.toJson());
      expect(decoded.setType, setType);
    }
    for (final BorderColor borderColor in BorderColor.values) {
      final MTGCard card = original.copyWith(borderColor: borderColor);
      final MTGCard decoded = MTGCardMapper.fromJson(card.toJson());
      expect(decoded.borderColor, borderColor);
    }
  });

  test('cards with no mana cost remain persistable and copyable', () {
    final Map<String, Object?> stored = _storedCard(manaCost: null);
    stored['borderColor'] = null;
    final MTGCard card = MTGCardMapper.fromMap(stored);
    final MTGCard copy = card.copyWith(quantity: 4);

    expect(card.manaCost, isNull);
    expect(card.borderColor, isNull);
    expect(copy.quantity, 4);
    expect(copy.manaCost, isNull);
    expect(copy.toMap()['manaCost'], isNull);
    expect(MTGCardMapper.fromJson(copy.toJson()).manaCost, isNull);
    expect(MTGCardMapper.fromJson(copy.toJson()).quantity, 4);
  });

  test('missing quantity retains the stored single-card default', () {
    final Map<String, Object?> stored = _storedCard()..remove('quantity');
    final MTGCard card = MTGCardMapper.fromMap(stored);
    expect(card.quantity, 1);
    expect(card.toMap()['quantity'], 1);
  });
}
