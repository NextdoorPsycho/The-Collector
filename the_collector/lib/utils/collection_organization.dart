import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:the_collector/utils/crud.dart';

void validateGroupCapacity(MTGDeck group) {
  final int payloadSize =
      utf8.encode(jsonEncode(group.toMap())).length +
      group.effectiveEntries.length * 96;
  if (payloadSize > 900000) {
    throw StateError('Container full. Choose another container.');
  }
}

class CollectionOrganization {
  final CollectionStore<MTGDeck> groups;

  CollectionOrganization({required this.groups});

  String _groupId(String id) {
    if (id.isEmpty || id.contains('/')) {
      throw ArgumentError.value(id, 'groupId', 'Choose a saved group.');
    }
    return id;
  }

  String _name(String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Enter a group name.');
    }
    return trimmed;
  }

  Future<MTGDeck> _folder(Transaction transaction, String id) async {
    final MTGDeck? folder = (await transaction.get(
      groups.collection.doc(_groupId(id)),
    )).data();
    if (folder == null || folder.kind != CollectionGroupKind.folder) {
      throw StateError('Choose an existing folder.');
    }
    return folder;
  }

  Future<String> createGroup({
    required String name,
    CollectionGroupKind kind = CollectionGroupKind.deck,
    String? parentId,
    String? sourceUrl,
    String? sourceFormat,
    List<DeckEntry> entries = const <DeckEntry>[],
    DeckFormat format = DeckFormat.casual,
    String? operationId,
  }) async {
    if (entries.any(
      (DeckEntry entry) => entry.quantity < 1 || entry.quantity > 1000000,
    )) {
      throw ArgumentError.value(
        entries,
        'entries',
        'Card quantities must be between 1 and 1000000.',
      );
    }
    final MTGDeck group = MTGDeck(
      name: _name(name),
      kind: kind,
      parentId: parentId,
      sourceUrl: sourceUrl,
      sourceFormat: sourceFormat,
      entries: List<DeckEntry>.of(entries),
      format: format,
    );
    validateGroupCapacity(group);
    if (operationId != null &&
        (operationId.isEmpty || operationId.contains('/'))) {
      throw ArgumentError.value(operationId, 'operationId');
    }
    final DocumentReference<MTGDeck> reference = groups.collection.doc(
      operationId,
    );
    await groups.collection.firestore.runTransaction<void>((
      Transaction transaction,
    ) async {
      final MTGDeck? existing = (await transaction.get(reference)).data();
      if (existing != null) {
        final Map<String, Object?> existingPayload = existing.toMap()
          ..remove('id');
        final Map<String, Object?> intendedPayload = group.toMap()
          ..remove('id');
        if (jsonEncode(existingPayload) != jsonEncode(intendedPayload)) {
          throw StateError(
            'This operation ID already belongs to another group.',
          );
        }
        return;
      }
      final MTGDeck? parent = parentId == null
          ? null
          : await _folder(transaction, parentId);
      if (parent != null) {
        transaction.set(groups.collection.doc(parentId), parent);
      }
      transaction.set(reference, group);
    });
    return reference.id;
  }

  Future<void> renameGroup({required String groupId, required String name}) {
    final String trimmed = _name(name);
    return groups.txn(_groupId(groupId), (MTGDeck group) {
      final MTGDeck updated = group.copyWith(name: trimmed);
      validateGroupCapacity(updated);
      return updated;
    });
  }

  Future<void> assignOwnedCards({
    required String groupId,
    required List<MTGCard> cards,
    DeckSection section = DeckSection.mainboard,
  }) {
    final Map<(String, String?), DeckEntry> selections =
        <(String, String?), DeckEntry>{};
    for (final MTGCard card in cards) {
      final String? printingId = card.printingId;
      if (card.id == null ||
          card.id!.isEmpty ||
          printingId == null ||
          printingId.isEmpty ||
          card.quantity < 1) {
        throw ArgumentError('Choose saved owned cards.');
      }
      final DeckEntry entry = DeckEntry(
        scryfallId: printingId,
        finish: card.finish,
        language: card.language?.toLowerCase(),
        quantity: card.quantity,
        section: section,
      );
      final (String, String?) key = (entry.cardId, entry.language);
      final int quantity = (selections[key]?.quantity ?? 0) + entry.quantity;
      if (quantity > 1000000) {
        throw ArgumentError('Use at most 1000000 copies.');
      }
      selections[key] = entry.copyWith(quantity: quantity);
    }
    if (selections.isEmpty) return Future<void>.value();
    return groups.txn(_groupId(groupId), (MTGDeck group) {
      final Map<(String, String?), int> remaining = <(String, String?), int>{
        for (final MapEntry<(String, String?), DeckEntry> selection
            in selections.entries)
          selection.key: selection.value.quantity,
      };
      final List<DeckEntry> entries = <DeckEntry>[];
      for (final DeckEntry entry in group.effectiveEntries) {
        final (String, String?) key = (
          entry.cardId,
          entry.language?.toLowerCase(),
        );
        final int? desired = entry.section == section ? remaining[key] : null;
        if (desired == null) {
          entries.add(entry);
        } else if (desired > 0) {
          final int retained = entry.quantity < desired
              ? entry.quantity
              : desired;
          entries.add(entry.copyWith(quantity: retained));
          remaining[key] = desired - retained;
        }
      }
      for (final MapEntry<(String, String?), int> remainder
          in remaining.entries) {
        if (remainder.value > 0) {
          entries.add(
            selections[remainder.key]!.copyWith(quantity: remainder.value),
          );
        }
      }
      final MTGDeck updated = group.copyWith(entries: entries);
      validateGroupCapacity(updated);
      return updated;
    });
  }

  Future<void> setCardMembership({
    required MTGCard card,
    required String groupId,
    required int quantity,
    DeckSection section = DeckSection.mainboard,
  }) {
    if (quantity < 0 || quantity > 1000000) {
      throw ArgumentError.value(
        quantity,
        'quantity',
        'Quantity must be between 0 and 1000000.',
      );
    }
    final String? printingId = card.printingId;
    if (printingId == null || printingId.isEmpty) {
      throw ArgumentError('Choose a card printing.');
    }
    final String? language = card.language?.toLowerCase();
    final DeckEntry membership = DeckEntry(
      scryfallId: printingId,
      quantity: quantity,
      section: section,
      finish: card.finish,
      language: language,
    );
    return groups.txn(_groupId(groupId), (MTGDeck group) {
      final List<DeckEntry> previous = group.effectiveEntries
          .where(
            (DeckEntry entry) =>
                entry.cardId == membership.cardId &&
                entry.language?.toLowerCase() == language &&
                entry.section == section,
          )
          .toList();
      final List<DeckEntry> entries = group.effectiveEntries
          .where(
            (DeckEntry entry) =>
                !(entry.cardId == membership.cardId &&
                    entry.language?.toLowerCase() == language &&
                    entry.section == section),
          )
          .toList();
      if (quantity > 0) {
        if (previous.length <= 1) {
          entries.add(
            membership.copyWith(condition: previous.firstOrNull?.condition),
          );
        } else {
          int remaining = quantity;
          for (final DeckEntry entry in previous) {
            if (remaining == 0) {
              break;
            }
            final int retained = entry.quantity < remaining
                ? entry.quantity
                : remaining;
            if (retained > 0) {
              entries.add(entry.copyWith(quantity: retained));
              remaining -= retained;
            }
          }
          if (remaining > 0) {
            entries.add(membership.copyWith(quantity: remaining));
          }
        }
      }
      final MTGDeck updated = group.copyWith(entries: entries);
      validateGroupCapacity(updated);
      return updated;
    });
  }

  Future<void> moveGroup({required String groupId, String? parentId}) => groups
      .collection
      .firestore
      .runTransaction<void>((Transaction transaction) async {
        final DocumentReference<MTGDeck> reference = groups.collection.doc(
          _groupId(groupId),
        );
        final MTGDeck? group = (await transaction.get(reference)).data();
        if (group == null) {
          throw StateError('This group has been deleted.');
        }
        final Set<String> visited = <String>{groupId};
        final Map<String, MTGDeck> ancestors = <String, MTGDeck>{};
        String? next = parentId;
        while (next != null) {
          if (!visited.add(next)) {
            throw StateError('A folder cannot contain itself or its ancestor.');
          }
          final MTGDeck folder = await _folder(transaction, next);
          ancestors[next] = folder;
          next = folder.parentId;
        }
        // Parent writes serialize hierarchy changes with folder deletion.
        for (final MapEntry<String, MTGDeck> ancestor in ancestors.entries) {
          transaction.set(groups.collection.doc(ancestor.key), ancestor.value);
        }
        transaction.set(reference, group.copyWith(parentId: parentId));
      });

  Future<void> deleteGroup({required String groupId}) => groups
      .collection
      .firestore
      .runTransaction<void>((Transaction transaction) async {
        final DocumentReference<MTGDeck> reference = groups.collection.doc(
          _groupId(groupId),
        );
        final MTGDeck? group = (await transaction.get(reference)).data();
        if (group == null) {
          return;
        }
        final QuerySnapshot<MTGDeck> children = await groups.collection
            .where('parentId', isEqualTo: groupId)
            .limit(1)
            .get();
        if (children.docs.isNotEmpty) {
          throw StateError(
            'Move the groups inside this folder before deleting it.',
          );
        }
        transaction.delete(reference);
      });
}
