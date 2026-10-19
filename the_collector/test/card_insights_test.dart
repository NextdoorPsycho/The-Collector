import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/utils/card_insights.dart';
import 'package:the_collector/utils/valuation.dart';

MTGCard _card({
  String? id,
  String? printing = 'first-print',
  String? oracle = 'oracle',
  String name = 'Shared name',
  int quantity = 1,
  sf.Finish? finish = sf.Finish.nonfoil,
  String? language = 'en',
  CardPrices? prices,
}) => MTGCard(
  name: name,
  setId: 'set',
  description: '',
  flavorText: '',
  cmc: 1,
  typeLine: 'Instant',
  rarity: sf.Rarity.common,
  setType: sf.SetType.expansion,
  manaCost: '{U}',
  scryfallId: printing,
  oracleId: oracle,
  quantity: quantity,
  finish: finish,
  language: language,
  prices: prices,
)..id = id;

void main() {
  test('groups owned printings by oracle without adding the selected copy', () {
    final MTGCard selected = _card(id: 'first-print', quantity: 3);
    final CardHoldings holdings = CardHoldings(
      selected: selected,
      inventory: <MTGCard>[
        selected,
        _card(id: 'first-print__foil', quantity: 2, finish: sf.Finish.foil),
        _card(id: 'second-print', printing: 'second-print', quantity: 4),
        _card(id: 'unrelated', printing: 'unrelated', oracle: 'other'),
      ],
    );

    expect(holdings.cards, hasLength(3));
    expect(holdings.copies, 9);
    expect(holdings.printingCount, 2);
    expect(holdings.finishes, <sf.Finish?, int>{
      sf.Finish.nonfoil: 7,
      sf.Finish.foil: 2,
    });
  });

  test('enriched selection retains its saved printing with no oracle ID', () {
    final CardHoldings holdings = CardHoldings(
      selected: _card(),
      inventory: <MTGCard>[
        _card(id: 'first-print', oracle: null, quantity: 3),
        _card(id: 'second-print', printing: 'second-print', quantity: 2),
        _card(id: 'unknown', printing: 'unknown', oracle: null, quantity: 7),
      ],
    );

    expect(holdings.copies, 5);
    expect(holdings.printingCount, 2);
  });

  test('missing oracle IDs never merge cards merely sharing a name', () {
    final CardHoldings holdings = CardHoldings(
      selected: _card(oracle: null),
      inventory: <MTGCard>[
        _card(id: 'first-print', oracle: 'recovered', quantity: 3),
        _card(id: 'second-print', printing: 'second-print', oracle: null),
        _card(id: 'conflict', oracle: 'conflicting'),
        _card(id: null, printing: null, oracle: null),
      ],
    );

    expect(holdings.copies, 4);
    expect(holdings.printingCount, 1);
    final CardHoldings conflicting = CardHoldings(
      selected: _card(),
      inventory: <MTGCard>[_card(oracle: 'different-oracle')],
    );
    expect(conflicting.copies, 0);
  });

  test('authoritative deletion never restores the tapped stale snapshot', () {
    final CardHoldings holdings = CardHoldings(
      selected: _card(quantity: 12),
      inventory: const <MTGCard>[],
    );

    expect(holdings.cards, isEmpty);
    expect(holdings.copies, 0);
    expect(holdings.printingCount, 0);
    expect(holdings.value(CardCurrency.usd).pricedCopies, 0);
  });

  test('duplicate inventory snapshots and invalid quantities do not inflate totals', () {
    final MTGCard duplicate = _card(id: 'first-print', quantity: 3);
    final CardHoldings holdings = CardHoldings(
      selected: duplicate,
      inventory: <MTGCard>[
        duplicate,
        _card(id: 'first-print', quantity: 3),
        _card(id: 'negative', quantity: -5),
        _card(id: 'zero', quantity: 0),
        _card(id: 'outside-ingestion-range', quantity: 1000001),
      ],
    );

    expect(holdings.copies, 3);
    expect(holdings.cards, hasLength(1));
  });

  test(
    'each market values actual finishes separately and counts missing quotes',
    () {
      const CardPrices quotes = CardPrices(
        usd: 2,
        usdFoil: 5,
        usdEtched: 7,
        eur: 3,
        eurFoil: 4,
        tix: .1,
      );
      final CardHoldings holdings = CardHoldings(
        selected: _card(),
        inventory: <MTGCard>[
          _card(id: 'normal', quantity: 3, prices: quotes),
          _card(
            id: 'foil',
            quantity: 2,
            finish: sf.Finish.foil,
            prices: quotes,
          ),
          _card(
            id: 'etched',
            quantity: 1,
            finish: sf.Finish.etched,
            prices: quotes,
          ),
          _card(id: 'unknown', quantity: 4, finish: null, prices: quotes),
        ],
      );

      final Valuation dollars = holdings.value(CardCurrency.usd);
      final Valuation euros = holdings.value(CardCurrency.eur);
      expect(dollars.total, 23);
      expect(dollars.pricedCopies, 6);
      expect(dollars.unpricedCopies, 4);
      expect(euros.total, 17);
      expect(euros.pricedCopies, 5);
      expect(euros.unpricedCopies, 5);
      expect(holdings.finishes[null], 4);
    },
  );

  test('invalid quotes remain unpriced while a zero quote is valid', () {
    final CardHoldings holdings = CardHoldings(
      selected: _card(),
      inventory: <MTGCard>[
        _card(
          id: 'nan',
          quantity: 2,
          prices: const CardPrices(usd: double.nan),
        ),
        _card(id: 'negative', prices: const CardPrices(usd: -3)),
        _card(
          id: 'infinite',
          prices: const CardPrices(usd: double.infinity),
        ),
        _card(id: 'zero', quantity: 4, prices: const CardPrices(usd: 0)),
        _card(id: 'missing', quantity: 3),
        _card(id: 'valid', quantity: 2, prices: const CardPrices(usd: 1.25)),
      ],
    );

    final Valuation dollars = holdings.value(CardCurrency.usd);
    expect(dollars.total, 2.5);
    expect(dollars.pricedCopies, 6);
    expect(dollars.unpricedCopies, 7);
  });

  test('overflowing quote multiplication never produces infinite value', () {
    final CardHoldings holdings = CardHoldings(
      selected: _card(),
      inventory: <MTGCard>[
        _card(
          id: 'overflow',
          quantity: 10,
          prices: const CardPrices(usd: 1e308),
        ),
        _card(id: 'valid', quantity: 2, prices: const CardPrices(usd: 5)),
      ],
    );

    final Valuation dollars = holdings.value(CardCurrency.usd);
    expect(dollars.total, 10);
    expect(dollars.pricedCopies, 2);
    expect(dollars.unpricedCopies, 10);
  });

  test('physical holdings cannot be reported as an MTGO inventory value', () {
    final CardHoldings holdings = CardHoldings(
      selected: _card(),
      inventory: <MTGCard>[_card(prices: const CardPrices(tix: 3))],
    );

    expect(() => holdings.value(CardCurrency.tix), throwsArgumentError);
  });

  test('container copies use exact print finish and language without multiplying ownership', () {
    final CardHoldings holdings = CardHoldings(
      selected: _card(),
      inventory: <MTGCard>[
        _card(id: 'normal', quantity: 3),
        _card(id: 'legacy-duplicate-key', quantity: 2),
        _card(id: 'foil', finish: sf.Finish.foil),
      ],
    );
    final MTGDeck binder = MTGDeck(
      name: 'Binder',
      kind: CollectionGroupKind.binder,
      entries: const <DeckEntry>[
        DeckEntry(
          scryfallId: 'first-print',
          quantity: 2,
          finish: sf.Finish.nonfoil,
          language: 'EN',
        ),
        DeckEntry(
          scryfallId: 'first-print',
          quantity: 1,
          finish: sf.Finish.foil,
          language: 'en',
        ),
        DeckEntry(
          scryfallId: 'first-print',
          quantity: 8,
          finish: sf.Finish.etched,
          language: 'en',
        ),
        DeckEntry(
          scryfallId: 'first-print',
          quantity: 9,
          finish: sf.Finish.nonfoil,
          language: 'de',
        ),
        DeckEntry(
          scryfallId: 'other-print',
          quantity: 7,
          finish: sf.Finish.nonfoil,
          language: 'en',
        ),
        DeckEntry(
          scryfallId: 'first-print',
          quantity: -4,
          finish: sf.Finish.nonfoil,
          language: 'en',
        ),
      ],
    );
    final MTGDeck deck = MTGDeck(
      name: 'Deck',
      entries: const <DeckEntry>[
        DeckEntry(
          scryfallId: 'first-print',
          quantity: 4,
          finish: sf.Finish.nonfoil,
          language: 'en',
        ),
        DeckEntry(
          scryfallId: 'first-print',
          quantity: 1,
          section: DeckSection.sideboard,
          finish: sf.Finish.nonfoil,
          language: 'en',
        ),
      ],
    );
    final List<CardGroupHolding> memberships = cardGroupHoldings(
      holdings,
      <MTGDeck>[binder, deck, MTGDeck(name: 'Empty')],
    );

    expect(memberships, hasLength(2));
    expect(memberships[0].group, same(binder));
    expect(memberships[0].copies, 3);
    expect(memberships[1].copies, 5);
    expect(holdings.copies, 6);
  });

  test('unknown membership finish is not silently matched as normal', () {
    final CardHoldings holdings = CardHoldings(
      selected: _card(),
      inventory: <MTGCard>[_card()],
    );
    final List<CardGroupHolding> memberships = cardGroupHoldings(
      holdings,
      <MTGDeck>[
        MTGDeck(name: 'Legacy', cards: const <String>['first-print']),
        MTGDeck(
          name: 'Unspecified',
          entries: const <DeckEntry>[
            DeckEntry(scryfallId: 'first-print', language: 'en'),
          ],
        ),
      ],
    );

    expect(memberships, isEmpty);
  });
}
