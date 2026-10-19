import 'package:collector_models/deck/deck_entry.dart';
import 'package:flutter/foundation.dart';
import 'package:scryfall_api/scryfall_api.dart';

@immutable
class ScanCaptureDefaults {
  const ScanCaptureDefaults({
    this.finish = Finish.nonfoil,
    this.deckId,
    this.deckSection = DeckSection.mainboard,
  });

  final Finish finish;
  final String? deckId;
  final DeckSection deckSection;

  factory ScanCaptureDefaults.fromMap(Map<String, Object?> map) =>
      ScanCaptureDefaults(
        finish: Finish.values.byName(map['finish'] as String),
        deckId: map['deckId'] as String?,
        deckSection: DeckSection.values.byName(map['deckSection'] as String),
      );

  Map<String, Object?> toMap() => <String, Object?>{
    'finish': finish.name,
    'deckId': deckId,
    'deckSection': deckSection.name,
  };
}
