import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;

Map<int, int> deckManaCurve(MTGDeck deck, Map<String, MTGCard> cards) {
  final Map<int, int> result = <int, int>{};
  for (final DeckEntry entry in deck.effectiveEntries) {
    final MTGCard? card = cards[entry.scryfallId];
    if (entry.section != DeckSection.mainboard ||
        card == null ||
        card.typeLine.contains('Land')) {
      continue;
    }
    final int bucket = card.cmc.floor().clamp(0, 6);
    result[bucket] = (result[bucket] ?? 0) + entry.quantity;
  }
  return result;
}

List<String> deckFormatChecks(MTGDeck deck, Map<String, MTGCard> cards) {
  if (deck.kind != CollectionGroupKind.deck ||
      deck.format == DeckFormat.casual) {
    return <String>[];
  }
  final List<DeckEntry> entries = deck.effectiveEntries;
  final int main = entries
      .where((DeckEntry entry) => entry.section == DeckSection.mainboard)
      .fold(0, (int total, DeckEntry entry) => total + entry.quantity);
  final int side = entries
      .where((DeckEntry entry) => entry.section == DeckSection.sideboard)
      .fold(0, (int total, DeckEntry entry) => total + entry.quantity);
  final List<DeckEntry> commanders = entries
      .where((DeckEntry entry) => entry.section == DeckSection.commander)
      .toList();
  final int commandCount = commanders.fold(
    0,
    (int total, DeckEntry entry) => total + entry.quantity,
  );
  final List<String> issues = <String>[];
  if (deck.format == DeckFormat.standard) {
    if (main < 60) {
      issues.add('Standard needs at least 60 mainboard cards ($main now).');
    }
    if (side > 15) {
      issues.add('Standard allows at most 15 sideboard cards ($side now).');
    }
    if (commandCount != 0) {
      issues.add('Standard has no command zone.');
    }
  } else {
    if (main + commandCount != 100) {
      issues.add(
        'Commander needs 100 cards including commanders (${main + commandCount} now).',
      );
    }
    if (commandCount < 1 || commandCount > 2) {
      issues.add(
        'Choose one commander, or two with a valid partner/background ability.',
      );
    }
    if (commandCount == 2) {
      issues.add(
        'Check the partner/background eligibility of both commanders.',
      );
    }
    if (side != 0) {
      issues.add('Commander has no normal sideboard.');
    }
  }
  final Map<String, int> quantities = <String, int>{};
  final Map<String, MTGCard> metadata = <String, MTGCard>{};
  bool missingMetadata = false;
  for (final DeckEntry entry in entries) {
    if (entry.section == DeckSection.maybeboard) continue;
    final MTGCard? card = cards[entry.scryfallId];
    if (card == null) {
      missingMetadata = true;
      continue;
    }
    final String key = card.oracleId ?? card.name.toLowerCase();
    quantities[key] = (quantities[key] ?? 0) + entry.quantity;
    metadata[key] = card;
  }
  if (missingMetadata) {
    issues.add('Some card metadata is unavailable; checks are incomplete.');
  }
  for (final MapEntry<String, int> entry in quantities.entries) {
    final MTGCard card = metadata[entry.key]!;
    final bool basic = card.typeLine.contains('Basic Land');
    final bool unlimited =
        card.oracleText?.contains('any number of cards named') ?? false;
    final int limit = deck.format == DeckFormat.commander ? 1 : 4;
    if (!basic && !unlimited && entry.value > limit) {
      issues.add(
        '${card.name}: ${entry.value} copies, normally at most $limit. Check card-specific exceptions.',
      );
    }
    final String? legality = card.legalities[deck.format.name];
    if (legality != null && legality != 'legal') {
      issues.add('${card.name}: ${deck.format.name} legality is $legality.');
    }
  }
  if (deck.format == DeckFormat.commander && commanders.isNotEmpty) {
    final Set<sf.Color> allowed = commanders
        .expand(
          (DeckEntry entry) =>
              cards[entry.scryfallId]?.colorIdentity ?? <sf.Color>[],
        )
        .toSet();
    final bool complete = commanders.every(
      (DeckEntry entry) => cards.containsKey(entry.scryfallId),
    );
    if (complete) {
      for (final MTGCard card in metadata.values) {
        if (card.colorIdentity.any(
          (sf.Color color) =>
              color != sf.Color.colorless && !allowed.contains(color),
        )) {
          issues.add('${card.name} is outside the commander color identity.');
        }
      }
    }
  }
  return issues;
}
