import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/valuation.dart';

class _Printing extends Fake implements MtgCard {
  _Printing(this.prices);
  @override
  final Prices prices;
}

MTGCard _card(int quantity, Finish? finish, CardPrices? prices) => MTGCard(
  name: 'Card',
  setId: 'set',
  description: '',
  flavorText: '',
  cmc: 0,
  typeLine: 'Artifact',
  rarity: Rarity.common,
  setType: SetType.expansion,
  manaCost: null,
  quantity: quantity,
  finish: finish,
  prices: prices,
);

void main() {
  test('maybeboard does not inflate deck value or priced copy counts', () {
    final MTGDeck deck = MTGDeck(
      name: 'Deck',
      entries: const <DeckEntry>[
        DeckEntry(scryfallId: 'same', quantity: 2, finish: Finish.nonfoil),
        DeckEntry(
          scryfallId: 'same',
          quantity: 50,
          finish: Finish.foil,
          section: DeckSection.maybeboard,
        ),
        DeckEntry(
          scryfallId: 'missing',
          quantity: 90,
          section: DeckSection.maybeboard,
        ),
        DeckEntry(
          scryfallId: 'same',
          quantity: 1,
          finish: Finish.foil,
          section: DeckSection.companion,
        ),
      ],
    );
    final Valuation value = valueDeck(deck, <String, MtgCard>{
      'same': _Printing(const Prices(usd: '2', usdFoil: '5')),
    }, CardCurrency.usd);
    expect(value.total, 9);
    expect(value.pricedCopies, 3);
    expect(value.unpricedCopies, 0);
  });
  test(
    'saved deck quotes survive reopening and preserve printing and finish',
    () {
      final MTGDeck deck = MTGDeck(
        name: 'Saved',
        entries: const <DeckEntry>[
          DeckEntry(scryfallId: 'same', quantity: 2, finish: Finish.nonfoil),
          DeckEntry(scryfallId: 'same', quantity: 3, finish: Finish.foil),
          DeckEntry(scryfallId: 'same', quantity: 4),
          DeckEntry(scryfallId: 'missing', quantity: 5, finish: Finish.nonfoil),
        ],
      );
      final Map<String, CardPrices> saved = savedPricesByPrinting(<MTGCard>[
        _card(7, Finish.nonfoil, const CardPrices(usd: 1, usdFoil: 6)).copyWith(
          scryfallId: 'same',
          pricesUpdatedAt: DateTime.utc(2026, 10, 2),
        ),
        _card(1, Finish.foil, const CardPrices(usd: 99, usdFoil: 99)).copyWith(
          scryfallId: 'same',
          pricesUpdatedAt: DateTime.utc(2026, 10, 1),
        ),
        _card(
          1,
          Finish.foil,
          const CardPrices(usd: 100, usdFoil: 100),
        ).copyWith(scryfallId: 'same'),
        _card(
          1,
          Finish.nonfoil,
          const CardPrices(usd: 200),
        ).copyWith(scryfallId: 'other'),
      ]);
      final Valuation offline = valueDeck(
        deck,
        <String, MtgCard>{},
        CardCurrency.usd,
        savedPrices: saved,
      );
      expect(offline.total, 20);
      expect(offline.pricedCopies, 5);
      expect(offline.unpricedCopies, 9);
      final Valuation fresh = valueDeck(
        deck,
        <String, MtgCard>{'same': _Printing(const Prices(usd: '3'))},
        CardCurrency.usd,
        savedPrices: saved,
      );
      expect(fresh.total, 6);
      expect(fresh.pricedCopies, 2);
      expect(fresh.unpricedCopies, 12);
    },
  );

  test('collection uses finish-specific prices and counts unpriced copies', () {
    const CardPrices prices = CardPrices(
      usd: 2,
      usdFoil: 5,
      usdEtched: 9,
      eur: 3,
      eurFoil: 7,
      tix: 0.5,
    );
    final List<MTGCard> cards = <MTGCard>[
      _card(3, Finish.nonfoil, prices),
      _card(2, Finish.foil, prices),
      _card(1, Finish.etched, prices),
      _card(4, null, prices),
      _card(5, Finish.nonfoil, null),
    ];
    final Valuation usd = valueCollection(cards, CardCurrency.usd);
    expect(usd.total, 25);
    expect(usd.pricedCopies, 6);
    expect(usd.unpricedCopies, 9);
    final Valuation eur = valueCollection(cards, CardCurrency.eur);
    expect(eur.total, 23);
    expect(eur.pricedCopies, 5);
    expect(eur.unpricedCopies, 10);
    final Valuation tix = valueCollection(cards, CardCurrency.tix);
    expect(tix.total, 5);
    expect(tix.pricedCopies, 10);
    expect(tix.unpricedCopies, 5);
  });

  test('zero prices are valid and empty inventories remain zero', () {
    final Valuation zero = valueCollection(<MTGCard>[
      _card(2, Finish.nonfoil, const CardPrices(usd: 0)),
    ], CardCurrency.usd);
    expect(zero.total, 0);
    expect(zero.pricedCopies, 2);
    expect(zero.unpricedCopies, 0);
    final Valuation empty = valueCollection(<MTGCard>[], CardCurrency.usd);
    expect(empty.total, 0);
    expect(empty.pricedCopies + empty.unpricedCopies, 0);
    expect(formatValue(12.345, CardCurrency.eur), 'EUR 12.35');
  });

  test(
    'deck prices quantities across sections without substituting finishes',
    () {
      final MTGDeck deck = MTGDeck(
        name: 'Deck',
        entries: const <DeckEntry>[
          DeckEntry(scryfallId: 'same', quantity: 3, finish: Finish.nonfoil),
          DeckEntry(
            scryfallId: 'same',
            quantity: 2,
            finish: Finish.foil,
            section: DeckSection.sideboard,
          ),
          DeckEntry(
            scryfallId: 'same',
            finish: Finish.etched,
            section: DeckSection.commander,
          ),
          DeckEntry(scryfallId: 'missing', quantity: 4, finish: Finish.nonfoil),
        ],
      );
      final Map<String, MtgCard> printings = <String, MtgCard>{
        'same': _Printing(
          const Prices(
            usd: '2',
            usdFoil: '7',
            eur: '3',
            eurFoil: '8',
            tix: '0.25',
          ),
        ),
      };
      final Valuation usd = valueDeck(deck, printings, CardCurrency.usd);
      expect(usd.total, 20);
      expect(usd.pricedCopies, 5);
      expect(usd.unpricedCopies, 5);
      final Valuation eur = valueDeck(deck, printings, CardCurrency.eur);
      expect(eur.total, 25);
      expect(valueDeck(deck, printings, CardCurrency.tix).total, 1.5);
    },
  );

  test('legacy duplicated references count every copy but unknown finish stays unpriced', () {
    final MTGDeck deck = MTGDeck(
      name: 'Old',
      cards: <String>['same', 'same', 'missing'],
    );
    final Valuation legacy = valueDeck(deck, <String, MtgCard>{
      'same': _Printing(const Prices(usd: '99')),
    }, CardCurrency.usd);
    expect(legacy.total, 0);
    expect(legacy.pricedCopies, 0);
    expect(legacy.unpricedCopies, 3);
    expect(
      deck.effectiveEntries
          .singleWhere((DeckEntry e) => e.scryfallId == 'same')
          .quantity,
      2,
    );
  });
}
