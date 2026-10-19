import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/collection_organization.dart';
import 'package:the_collector/utils/crud.dart';

import 'helpers/assignment_fixture.dart';

void main() {
  test('assignment preserves variants, conditions, other sections and owned counts on repeat', () async {
    final AssignmentDatabase database = AssignmentDatabase();
    final CollectionStore<MTGDeck> groups = assignmentGroups(database);
    final CollectionStore<MTGCard> owned = assignmentCards(database);
    final List<MTGCard> selected = <MTGCard>[
      assignmentCard(
        'foil-a',
        printing: 'printing',
        quantity: 2,
        finish: Finish.foil,
        language: 'EN',
      ),
      assignmentCard(
        'foil-b',
        printing: 'printing',
        quantity: 3,
        finish: Finish.foil,
      ),
      assignmentCard('normal', printing: 'printing', quantity: 4),
    ];
    for (final MTGCard card in selected) {
      await owned.set(card.id!, card);
    }
    final Map<String, Object?> ownedBefore = <String, Object?>{
      for (final MTGCard card in await owned.streamAll().first)
        card.id!: card.toMap(),
    };
    await groups.set(
      'binder',
      MTGDeck(
        name: 'Trade binder',
        kind: CollectionGroupKind.binder,
        parentId: 'folder',
        sourceFormat: 'manual',
        entries: const <DeckEntry>[
          DeckEntry(
            scryfallId: 'printing',
            quantity: 3,
            finish: Finish.foil,
            language: 'en',
            condition: 'Lightly Played',
          ),
          DeckEntry(
            scryfallId: 'printing',
            quantity: 1,
            finish: Finish.foil,
            language: 'EN',
            condition: 'Near Mint',
          ),
          DeckEntry(
            scryfallId: 'printing',
            quantity: 7,
            finish: Finish.foil,
            language: 'en',
            section: DeckSection.sideboard,
            condition: 'Played',
          ),
          DeckEntry(
            scryfallId: 'printing',
            quantity: 2,
            finish: Finish.foil,
            language: 'fr',
            condition: 'Near Mint',
          ),
          DeckEntry(scryfallId: 'unrelated', quantity: 8),
        ],
      ),
    );
    final CollectionOrganization organization = CollectionOrganization(
      groups: groups,
    );
    await organization.assignOwnedCards(groupId: 'binder', cards: selected);
    final MTGDeck once = await groups.get('binder');
    expect(once.kind, CollectionGroupKind.binder);
    expect(once.parentId, 'folder');
    expect(once.sourceFormat, 'manual');
    final List<DeckEntry> foil = once.effectiveEntries
        .where(
          (DeckEntry entry) =>
              entry.finish == Finish.foil &&
              entry.language?.toLowerCase() == 'en' &&
              entry.section == DeckSection.mainboard,
        )
        .toList();
    expect(foil.map((DeckEntry entry) => entry.quantity), <int>[3, 1, 1]);
    expect(foil.map((DeckEntry entry) => entry.condition), <String?>[
      'Lightly Played',
      'Near Mint',
      null,
    ]);
    expect(
      once.effectiveEntries
          .singleWhere((DeckEntry entry) => entry.finish == Finish.nonfoil)
          .quantity,
      4,
    );
    expect(
      once.effectiveEntries
          .singleWhere(
            (DeckEntry entry) => entry.section == DeckSection.sideboard,
          )
          .quantity,
      7,
    );
    expect(
      once.effectiveEntries
          .singleWhere((DeckEntry entry) => entry.language == 'fr')
          .quantity,
      2,
    );
    expect(
      once.effectiveEntries
          .singleWhere((DeckEntry entry) => entry.scryfallId == 'unrelated')
          .quantity,
      8,
    );
    await organization.assignOwnedCards(groupId: 'binder', cards: selected);
    expect((await groups.get('binder')).toMap(), once.toMap());
    expect(<String, Object?>{
      for (final MTGCard card in await owned.streamAll().first)
        card.id!: card.toMap(),
    }, ownedBefore);
  });

  test('capacity failure leaves every existing and selected entry unchanged', () async {
    final AssignmentDatabase database = AssignmentDatabase();
    final CollectionStore<MTGDeck> groups = assignmentGroups(database);
    await groups.set(
      'full',
      MTGDeck(
        name: 'Full box',
        kind: CollectionGroupKind.box,
        entries: <DeckEntry>[
          for (int index = 0; index < 4500; index++)
            DeckEntry(
              scryfallId:
                  'd88a8e2d-2577-4a67-af86-${index.toString().padLeft(12, '0')}',
              finish: Finish.nonfoil,
              language: 'en',
              condition: 'Near Mint',
            ),
        ],
      ),
    );
    final Map<String, Object?> before = (await groups.get('full')).toMap();
    await expectLater(
      CollectionOrganization(groups: groups).assignOwnedCards(
        groupId: 'full',
        cards: <MTGCard>[
          assignmentCard('one', quantity: 4),
          assignmentCard('two', quantity: 5),
        ],
      ),
      throwsStateError,
    );
    expect((await groups.get('full')).toMap(), before);
    expect(database.committedWrites, 0);
  });

  test(
    'invalid or oversized selected variants fail before changing a container',
    () async {
      final AssignmentDatabase database = AssignmentDatabase();
      final CollectionStore<MTGDeck> groups = assignmentGroups(database);
      await groups.set('binder', MTGDeck(name: 'Binder'));
      final CollectionOrganization organization = CollectionOrganization(
        groups: groups,
      );
      for (final MTGCard invalid in <MTGCard>[
        assignmentCard('missing')..id = null,
        assignmentCard('empty', printing: ''),
        assignmentCard('zero', quantity: 0),
        assignmentCard('too-many', quantity: 1000001),
      ]) {
        expect(
          () => organization.assignOwnedCards(
            groupId: 'binder',
            cards: <MTGCard>[invalid],
          ),
          throwsArgumentError,
        );
      }
      expect(database.transactions, 0);
      expect((await groups.get('binder')).effectiveEntries, isEmpty);
    },
  );
}
