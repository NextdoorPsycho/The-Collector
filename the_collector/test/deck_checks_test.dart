import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/utils/deck_checks.dart';

MTGCard _card(
  String name, {
  String type = 'Instant',
  double cmc = 1,
  String? oracleId,
  List<sf.Color> identity = const <sf.Color>[],
}) => MTGCard(
  name: name,
  setId: 'set',
  description: '',
  flavorText: '',
  cmc: cmc,
  typeLine: type,
  rarity: sf.Rarity.common,
  setType: sf.SetType.expansion,
  manaCost: '{U}',
  oracleId: oracleId,
  colorIdentity: identity,
  legalities: const <String, String>{'commander': 'legal', 'standard': 'legal'},
);

void main() {
  test('Commander duplicate check groups different printings of the same oracle card', () {
    final MTGDeck deck = MTGDeck(
      name: 'Duplicates',
      format: DeckFormat.commander,
      entries: <DeckEntry>[
        const DeckEntry(scryfallId: 'a'),
        const DeckEntry(scryfallId: 'b'),
        const DeckEntry(scryfallId: 'lands', quantity: 97),
        const DeckEntry(scryfallId: 'leader', section: DeckSection.commander),
      ],
    );
    final List<String> issues = deckFormatChecks(deck, <String, MTGCard>{
      'a': _card('Same card', oracleId: 'same'),
      'b': _card('Same card', oracleId: 'same'),
      'lands': _card('Island', type: 'Basic Land — Island'),
      'leader': _card(
        'Leader',
        type: 'Legendary Creature',
        identity: <sf.Color>[sf.Color.blue],
      ),
    });
    expect(
      issues.where((String issue) => issue.contains('Same card: 2 copies')),
      hasLength(1),
    );
    expect(issues.any((String issue) => issue.contains('Island:')), isFalse);
    expect(issues.any((String issue) => issue.contains('100 cards')), isFalse);
  });

  test(
    'Standard counts mainboard, sideboard and copy limits across sections',
    () {
      final MTGDeck deck = MTGDeck(
        name: 'Standard',
        format: DeckFormat.standard,
        entries: <DeckEntry>[
          const DeckEntry(scryfallId: 'spell', quantity: 4),
          const DeckEntry(
            scryfallId: 'spell',
            quantity: 1,
            section: DeckSection.sideboard,
          ),
          const DeckEntry(scryfallId: 'lands', quantity: 56),
        ],
      );
      final List<String> issues = deckFormatChecks(deck, <String, MTGCard>{
        'spell': _card('Spell'),
        'lands': _card('Plains', type: 'Basic Land — Plains'),
      });
      expect(
        issues.any((String issue) => issue.contains('Spell: 5 copies')),
        isTrue,
      );
      expect(
        issues.any((String issue) => issue.contains('60 mainboard')),
        isFalse,
      );
    },
  );

  test(
    'Commander color identity and unavailable metadata remain visible issues',
    () {
      final MTGDeck deck = MTGDeck(
        name: 'Identity',
        format: DeckFormat.commander,
        entries: <DeckEntry>[
          const DeckEntry(scryfallId: 'leader', section: DeckSection.commander),
          const DeckEntry(scryfallId: 'red'),
          const DeckEntry(scryfallId: 'missing'),
        ],
      );
      final List<String> issues = deckFormatChecks(deck, <String, MTGCard>{
        'leader': _card('Blue leader', identity: <sf.Color>[sf.Color.blue]),
        'red': _card('Red spell', identity: <sf.Color>[sf.Color.red]),
      });
      expect(
        issues.any((String issue) => issue.contains('Red spell is outside')),
        isTrue,
      );
      expect(
        issues.any((String issue) => issue.contains('checks are incomplete')),
        isTrue,
      );
    },
  );

  test(
    'binders, boxes, folders and lists never receive deck legality checks',
    () {
      for (final CollectionGroupKind kind in CollectionGroupKind.values.where(
        (CollectionGroupKind kind) => kind != CollectionGroupKind.deck,
      )) {
        expect(
          deckFormatChecks(
            MTGDeck(
              name: 'Stored cards',
              kind: kind,
              format: DeckFormat.commander,
              entries: const <DeckEntry>[
                DeckEntry(scryfallId: 'missing', quantity: 20),
              ],
            ),
            <String, MTGCard>{},
          ),
          isEmpty,
        );
      }
    },
  );

  test('maybeboard does not affect deck size, duplicate or missing metadata checks', () {
    final MTGDeck deck = MTGDeck(
      name: 'Standard',
      format: DeckFormat.standard,
      entries: const <DeckEntry>[
        DeckEntry(scryfallId: 'spell', quantity: 4),
        DeckEntry(scryfallId: 'lands', quantity: 56),
        DeckEntry(
          scryfallId: 'spell',
          quantity: 20,
          section: DeckSection.maybeboard,
        ),
        DeckEntry(scryfallId: 'missing', section: DeckSection.maybeboard),
      ],
    );
    expect(
      deckFormatChecks(deck, <String, MTGCard>{
        'spell': _card('Spell'),
        'lands': _card('Plains', type: 'Basic Land — Plains'),
      }),
      isEmpty,
    );
  });

  test('mana curve respects deck copies and excludes lands and sideboard', () {
    final MTGDeck deck = MTGDeck(
      name: 'Curve',
      entries: <DeckEntry>[
        const DeckEntry(scryfallId: 'spell', quantity: 3),
        const DeckEntry(
          scryfallId: 'spell',
          quantity: 5,
          section: DeckSection.sideboard,
        ),
        const DeckEntry(scryfallId: 'land', quantity: 20),
        const DeckEntry(scryfallId: 'large', quantity: 2),
      ],
    );
    expect(
      deckManaCurve(deck, <String, MTGCard>{
        'spell': _card('Spell', cmc: 2),
        'land': _card('Land', type: 'Land'),
        'large': _card('Large', cmc: 8),
      }),
      <int, int>{2: 3, 6: 2},
    );
  });
}
