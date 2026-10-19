import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:test/test.dart';

void main() {
  test('existing deck documents default to a root deck group', () {
    final MTGDeck deck = MTGDeckMapper.fromMap(<String, Object?>{
      'name': 'Existing',
    });
    expect(deck.kind, CollectionGroupKind.deck);
    expect(deck.parentId, isNull);
    expect(deck.sourceUrl, isNull);
  });

  test('organization kinds and imported sections retain their metadata', () {
    for (final CollectionGroupKind kind in CollectionGroupKind.values) {
      final MTGDeck group = MTGDeck(
        name: kind.name,
        kind: kind,
        parentId: 'folder',
        sourceUrl: 'https://moxfield.com/decks/example',
        sourceFormat: 'modern',
        entries: <DeckEntry>[
          const DeckEntry(
            scryfallId: 'maybe',
            quantity: 2,
            section: DeckSection.maybeboard,
            condition: 'Near Mint',
          ),
          const DeckEntry(
            scryfallId: 'companion',
            section: DeckSection.companion,
          ),
        ],
      );
      final MTGDeck decoded = MTGDeckMapper.fromJson(group.toJson());
      expect(decoded.kind, kind);
      expect(decoded.parentId, 'folder');
      expect(decoded.sourceFormat, 'modern');
      expect(decoded.sourceUrl, group.sourceUrl);
      expect(decoded.effectiveEntries.first.section, DeckSection.maybeboard);
      expect(decoded.effectiveEntries.first.condition, 'Near Mint');
      expect(decoded.effectiveEntries.last.section, DeckSection.companion);
    }
  });

  test('existing profiles retain theme and default Commander off', () {
    final AppUser profile = AppUserMapper.fromMap(<String, Object?>{
      'theme': true,
    });
    expect(profile.theme, isTrue);
    expect(profile.showCommander, isFalse);
    profile.showCommander = true;
    expect(AppUserMapper.fromJson(profile.toJson()).showCommander, isTrue);
  });

  test('existing deck card references retain multiplicity without rewrite', () {
    final MTGDeck deck = MTGDeckMapper.fromMap(<String, Object?>{
      'name': 'Existing deck',
      'cards': <String>['printing-a', 'printing-b', 'printing-a'],
    });
    expect(
      deck.effectiveEntries.map((DeckEntry entry) => entry.quantity),
      <int>[2, 1],
    );
    expect(deck.effectiveEntries.first.section, DeckSection.mainboard);
    expect(deck.toMap()['cards'], <String>[
      'printing-a',
      'printing-b',
      'printing-a',
    ]);
    expect(deck.entries, isNull);
  });

  test('explicit empty deck stays empty despite archived card references', () {
    final MTGDeck deck = MTGDeck(
      name: 'Empty',
      cards: <String>['old'],
      entries: <DeckEntry>[],
    );
    expect(MTGDeckMapper.fromJson(deck.toJson()).effectiveEntries, isEmpty);
  });

  test('deck sections and quantities persist independently of inventory', () {
    final MTGDeck deck = MTGDeck(
      name: 'Commander deck',
      entries: <DeckEntry>[
        const DeckEntry(
          scryfallId: 'unowned-printing',
          quantity: 3,
          finish: Finish.foil,
          language: 'ja',
          section: DeckSection.sideboard,
        ),
        const DeckEntry(
          scryfallId: 'commander-printing',
          section: DeckSection.commander,
        ),
      ],
    );
    final MTGDeck decoded = MTGDeckMapper.fromJson(deck.toJson());
    expect(decoded.effectiveEntries.first.quantity, 3);
    expect(decoded.effectiveEntries.first.finish, Finish.foil);
    expect(decoded.effectiveEntries.first.language, 'ja');
    expect(decoded.effectiveEntries.first.section, DeckSection.sideboard);
    expect(decoded.effectiveEntries.last.section, DeckSection.commander);
  });

  test('valuation uses finish and currency without substituting unavailable prices', () {
    final CardPrices prices = CardPrices.fromScryfall(
      const Prices(
        usd: '1.25',
        usdFoil: '4.50',
        usdEtched: '8.00',
        eur: '1.10',
        eurFoil: '3.40',
        tix: '0.20',
      ),
    );
    expect(prices.forFinish(Finish.nonfoil, CardCurrency.usd), 1.25);
    expect(prices.forFinish(Finish.foil, CardCurrency.usd), 4.5);
    expect(prices.forFinish(Finish.etched, CardCurrency.usd), 8.0);
    expect(prices.forFinish(Finish.foil, CardCurrency.eur), 3.4);
    expect(prices.forFinish(Finish.etched, CardCurrency.eur), isNull);
    expect(prices.forFinish(null, CardCurrency.usd), isNull);
    expect(CardPricesMapper.fromJson(prices.toJson()).usdEtched, 8.0);
  });

  test('missing and malformed prices remain unknown rather than zero', () {
    final CardPrices prices = CardPrices.fromScryfall(
      const Prices(usd: 'NaN', usdFoil: '-1', eur: 'invalid'),
    );
    expect(prices.usd, isNull);
    expect(prices.usdFoil, isNull);
    expect(prices.eur, isNull);
    expect(prices.tix, isNull);
  });
}
