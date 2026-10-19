import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:scryfall_api/scryfall_api.dart';

class Valuation {
  const Valuation({
    required this.total,
    required this.pricedCopies,
    required this.unpricedCopies,
  });
  final double total;
  final int pricedCopies;
  final int unpricedCopies;
}

Valuation _value(Iterable<({double? price, int quantity})> entries) {
  double total = 0;
  int priced = 0;
  int unpriced = 0;
  for (final ({double? price, int quantity}) entry in entries) {
    if (entry.price == null) {
      unpriced += entry.quantity;
    } else {
      total += entry.price! * entry.quantity;
      priced += entry.quantity;
    }
  }
  return Valuation(
    total: total,
    pricedCopies: priced,
    unpricedCopies: unpriced,
  );
}

Valuation valueCollection(List<MTGCard> cards, CardCurrency currency) => _value(
  cards.map(
    (MTGCard card) =>
        (price: card.unitPrice(currency), quantity: card.quantity),
  ),
);

Valuation valueDeck(
  MTGDeck deck,
  Map<String, MtgCard> printings,
  CardCurrency currency, {
  Map<String, CardPrices> savedPrices = const <String, CardPrices>{},
}) => _value(
  deck.effectiveEntries
      .where((DeckEntry entry) => entry.section != DeckSection.maybeboard)
      .map((DeckEntry entry) {
        final MtgCard? printing = printings[entry.scryfallId];
        final CardPrices? prices = printing == null
            ? savedPrices[entry.scryfallId]
            : CardPrices.fromScryfall(printing.prices);
        return (
          price: prices?.forFinish(entry.finish, currency),
          quantity: entry.quantity,
        );
      }),
);

Map<String, CardPrices> savedPricesByPrinting(Iterable<MTGCard> cards) {
  final Map<String, MTGCard> newest = <String, MTGCard>{};
  for (final MTGCard card in cards) {
    final String? id = card.printingId;
    if (id == null || card.prices == null) continue;
    final MTGCard? previous = newest[id];
    if (previous == null ||
        (card.pricesUpdatedAt != null &&
            (previous.pricesUpdatedAt == null ||
                card.pricesUpdatedAt!.isAfter(previous.pricesUpdatedAt!)))) {
      newest[id] = card;
    }
  }
  return <String, CardPrices>{
    for (final MapEntry<String, MTGCard> entry in newest.entries)
      entry.key: entry.value.prices!,
  };
}

String formatValue(double value, CardCurrency currency) =>
    '${currency.name.toUpperCase()} ${value.toStringAsFixed(2)}';
