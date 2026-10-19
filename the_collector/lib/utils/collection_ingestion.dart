import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';

import 'collection_organization.dart';

import 'package:scryfall_api/scryfall_api.dart';

MTGCard cardFromScryfall(MtgCard card, {required Finish finish}) {
  if (finish == Finish.unknown || !card.finishes.contains(finish)) {
    throw ArgumentError.value(finish, 'finish', 'Unavailable printing finish.');
  }
  final List<CardFace> faces = card.cardFaces ?? const <CardFace>[];
  final ImageUris? front =
      card.imageUris ?? (faces.isEmpty ? null : faces.first.imageUris);
  final ImageUris? back = faces.length > 1 ? faces[1].imageUris : null;
  return MTGCard(
    name: card.name,
    setId: card.setId,
    description: card.printedText ?? card.oracleText ?? '',
    flavorText: card.flavorText ?? '',
    rarity: card.rarity,
    cmc: card.cmc,
    typeLine: card.typeLine,
    setType: card.setType,
    manaCost: card.manaCost,
    borderColor: card.borderColor,
    scryfallId: card.id,
    oracleId: card.oracleId,
    setCode: card.set,
    setName: card.setName,
    collectorNumber: card.collectorNumber,
    language: card.lang.json,
    finish: finish,
    colors:
        card.colors ??
        faces
            .expand((CardFace face) => face.colors ?? const <Color>[])
            .toSet()
            .toList(),
    colorIdentity: card.colorIdentity,
    oracleText:
        card.oracleText ??
        faces.map((CardFace face) => face.oracleText ?? '').join('\n\n'),
    imageUrl: front?.normal.toString(),
    backImageUrl: back?.normal.toString(),
    prices: CardPrices.fromScryfall(card.prices),
    pricesUpdatedAt: DateTime.now().toUtc(),
    legalities: <String, String>{
      'standard': card.legalities.standard.name,
      'commander': card.legalities.commander.name,
    },
    keywords: card.keywords,
  );
}

enum IngestionStatus { applied, previouslyApplied }

class IngestionResult {
  final String cardId;
  final IngestionStatus status;

  const IngestionResult({required this.cardId, required this.status});
}

class CollectionIngestion {
  static const List<DeckSection> destinationSections = <DeckSection>[
    DeckSection.mainboard,
    DeckSection.sideboard,
    DeckSection.commander,
  ];

  CollectionIngestion({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  static String inventoryId(MTGCard card) {
    final String? printingId = card.printingId;
    if (printingId == null || !_uuid.hasMatch(printingId)) {
      throw ArgumentError.value(
        printingId,
        'scryfallId',
        'Expected a printing UUID.',
      );
    }
    if (card.finish == null || card.finish == Finish.unknown) {
      throw ArgumentError.value(
        card.finish,
        'finish',
        'Select an explicit finish.',
      );
    }
    if (card.language == null ||
        !RegExp(r'^[a-z]{2,3}$').hasMatch(card.language!)) {
      throw ArgumentError.value(
        card.language,
        'language',
        'Expected a language code.',
      );
    }
    return card.finish == Finish.nonfoil
        ? printingId
        : '${printingId}__${card.finish!.name}';
  }

  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  String newOperationId() => _firestore.collection('operationIds').doc().id;

  Future<IngestionResult> add({
    required String userId,
    required String operationId,
    required MTGCard card,
    int quantity = 1,
    String? deckId,
    DeckSection deckSection = DeckSection.mainboard,
  }) async {
    if (userId.isEmpty || userId.contains('/')) {
      throw ArgumentError.value(userId, 'userId');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(operationId)) {
      throw ArgumentError.value(operationId, 'operationId');
    }
    if (quantity <= 0 || quantity > 1000000) {
      throw ArgumentError.value(
        quantity,
        'quantity',
        'Expected 1 to 1000000 copies.',
      );
    }
    if (deckId != null && (deckId.isEmpty || deckId.contains('/'))) {
      throw ArgumentError.value(deckId, 'deckId');
    }
    if (deckId != null && !destinationSections.contains(deckSection)) {
      throw ArgumentError.value(
        deckSection,
        'deckSection',
        'Scan into mainboard, sideboard or commander. Use Organize for other sections.',
      );
    }
    final String cardId = inventoryId(card);
    final DocumentReference<Map<String, dynamic>> owner = _firestore
        .collection('user')
        .doc(userId);
    final DocumentReference<Map<String, dynamic>> inventory = owner
        .collection('cards')
        .doc(cardId);
    final DocumentReference<Map<String, dynamic>> receipt = owner
        .collection('ingestionOperations')
        .doc(operationId);
    return _firestore.runTransaction<IngestionResult>((
      Transaction transaction,
    ) async {
      final DocumentSnapshot<Map<String, dynamic>> prior = await transaction
          .get(receipt);
      if (prior.exists) {
        final Map<String, dynamic> data = prior.data()!;
        if (data['cardId'] != cardId ||
            data['quantity'] != quantity ||
            data['language'] != card.language ||
            data['finish'] != card.finish!.name ||
            data['deckId'] != deckId ||
            data['deckSection'] != (deckId == null ? null : deckSection.name)) {
          throw StateError(
            'Operation ID was already used for another addition.',
          );
        }
        return IngestionResult(
          cardId: cardId,
          status: IngestionStatus.previouslyApplied,
        );
      }
      final DocumentSnapshot<Map<String, dynamic>> current = await transaction
          .get(inventory);
      final Map<String, dynamic>? stored = current.data();
      final DocumentReference<Map<String, dynamic>>? deckReference =
          deckId == null ? null : owner.collection('decks').doc(deckId);
      MTGDeck? deck;
      if (deckReference != null) {
        final DocumentSnapshot<Map<String, dynamic>> deckSnapshot =
            await transaction.get(deckReference);
        if (!deckSnapshot.exists) {
          throw StateError('Destination group no longer exists.');
        }
        deck = MTGDeckMapper.fromMap(deckSnapshot.data()!);
        if (deck.kind != CollectionGroupKind.deck &&
            deckSection != DeckSection.mainboard) {
          throw ArgumentError.value(
            deckSection,
            'deckSection',
            'Binders, boxes, folders and lists contain cards without deck sections.',
          );
        }
      }
      final int oldQuantity = stored == null
          ? 0
          : MTGCardMapper.fromMap(stored).quantity;
      if (stored != null &&
          ((stored['scryfallId'] != null &&
                  stored['scryfallId'] != card.printingId) ||
              (stored['language'] != null &&
                  stored['language'] != card.language) ||
              (stored['finish'] != null &&
                  stored['finish'] != card.finish!.name))) {
        throw StateError(
          'Stored printing metadata does not match this addition.',
        );
      }
      final Map<String, Object?> updated = card
          .copyWith(quantity: oldQuantity + quantity)
          .toMap();
      if (deck != null && deckReference != null) {
        final List<DeckEntry> entries = List<DeckEntry>.of(
          deck.effectiveEntries,
        );
        final int index = entries.indexWhere(
          (DeckEntry entry) =>
              entry.cardId == cardId && entry.section == deckSection,
        );
        if (index == -1) {
          entries.add(
            DeckEntry(
              scryfallId: card.printingId!,
              finish: card.finish,
              language: card.language,
              quantity: quantity,
              section: deckSection,
            ),
          );
        } else {
          entries[index] = entries[index].copyWith(
            quantity: entries[index].quantity + quantity,
          );
        }
        validateGroupCapacity(deck.copyWith(entries: entries));
        transaction.update(deckReference, <String, Object?>{
          'entries': entries.map((DeckEntry entry) => entry.toMap()).toList(),
        });
      }
      if (current.exists) {
        transaction.update(inventory, updated);
      } else {
        transaction.set(inventory, updated);
      }
      transaction.set(receipt, <String, Object?>{
        'cardId': cardId,
        'quantity': quantity,
        'language': card.language,
        'finish': card.finish!.name,
        'deckId': deckId,
        'deckSection': deckId == null ? null : deckSection.name,
        'createdAt': FieldValue.serverTimestamp(),
      });
      return IngestionResult(cardId: cardId, status: IngestionStatus.applied);
    });
  }
}
