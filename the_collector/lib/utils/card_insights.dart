import 'dart:collection';

import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/utils/valuation.dart';

class CardHoldings {
  CardHoldings({
    required MTGCard selected,
    required Iterable<MTGCard> inventory,
  }) : cards = List<MTGCard>.unmodifiable(_matchingCards(selected, inventory));

  final List<MTGCard> cards;

  int get copies =>
      cards.fold<int>(0, (int total, MTGCard card) => total + card.quantity);

  int get printingCount => cards
      .map((MTGCard card) => _nonempty(card.printingId))
      .whereType<String>()
      .toSet()
      .length;

  Map<sf.Finish?, int> get finishes {
    final Map<sf.Finish?, int> result = <sf.Finish?, int>{};
    for (final MTGCard card in cards) {
      result[card.finish] = (result[card.finish] ?? 0) + card.quantity;
    }
    return Map<sf.Finish?, int>.unmodifiable(result);
  }

  /// TIX describes MTGO cards and cannot value the owned paper inventory.
  Valuation value(CardCurrency currency) {
    if (currency == CardCurrency.tix) {
      throw ArgumentError.value(
        currency,
        'currency',
        'Paper inventory requires USD or EUR.',
      );
    }
    final List<MTGCard> valued = <MTGCard>[];
    double total = 0;
    for (final MTGCard card in cards) {
      final double? quote = card.unitPrice(currency);
      final double? contribution = quote == null ? null : quote * card.quantity;
      if (quote == null ||
          !quote.isFinite ||
          quote < 0 ||
          contribution == null ||
          !contribution.isFinite ||
          !(total + contribution).isFinite) {
        valued.add(card.copyWith(prices: null));
      } else {
        total += contribution;
        valued.add(card);
      }
    }
    return valueCollection(valued, currency);
  }
}

Iterable<MTGCard> _matchingCards(
  MTGCard selected,
  Iterable<MTGCard> inventory,
) sync* {
  final String? oracle = _nonempty(selected.oracleId);
  final String? printing = _nonempty(selected.printingId);
  final Set<String> documents = <String>{};
  final Set<MTGCard> anonymous = HashSet<MTGCard>.identity();
  for (final MTGCard card in inventory) {
    if (!_validQuantity(card.quantity)) continue;
    final String? candidateOracle = _nonempty(card.oracleId);
    final bool matches = oracle != null && candidateOracle != null
        ? oracle == candidateOracle
        : printing != null && printing == _nonempty(card.printingId);
    if (!matches) continue;
    final String? id = _nonempty(card.id);
    if (id == null ? anonymous.add(card) : documents.add(id)) {
      yield card;
    }
  }
}

class CardGroupHolding {
  const CardGroupHolding({required this.group, required this.copies});

  final MTGDeck group;
  final int copies;
}

typedef _MembershipIdentity = ({
  String printing,
  sf.Finish? finish,
  String? language,
});

/// Memberships can overlap and do not increase the number of owned cards.
List<CardGroupHolding> cardGroupHoldings(
  CardHoldings holdings,
  Iterable<MTGDeck> groups,
) {
  final Set<_MembershipIdentity> identities = <_MembershipIdentity>{
    for (final MTGCard card in holdings.cards)
      if (_identity(card.printingId, card.finish, card.language)
          case final _MembershipIdentity identity)
        identity,
  };
  final List<CardGroupHolding> result = <CardGroupHolding>[];
  for (final MTGDeck group in groups) {
    int copies = 0;
    for (final DeckEntry entry in group.effectiveEntries) {
      if (_validQuantity(entry.quantity) &&
          identities.contains(
            _identity(entry.scryfallId, entry.finish, entry.language),
          )) {
        copies += entry.quantity;
      }
    }
    if (copies > 0) {
      result.add(CardGroupHolding(group: group, copies: copies));
    }
  }
  return List<CardGroupHolding>.unmodifiable(result);
}

_MembershipIdentity? _identity(
  String? printing,
  sf.Finish? finish,
  String? language,
) {
  final String? id = _nonempty(printing);
  return id == null
      ? null
      : (
          printing: id,
          finish: finish,
          language: _nonempty(language)?.toLowerCase(),
        );
}

bool _validQuantity(int quantity) => quantity > 0 && quantity <= 1000000;

String? _nonempty(String? value) {
  final String? trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
