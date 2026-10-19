import 'package:arcane/arcane.dart';
import 'package:flutter/services.dart' show TextInputAction;
import 'package:the_collector/theme/collector_navigation.dart';
import 'package:arcane/generated/arcane_shadcn/src/components/overlay/dialog.dart'
    show showDialog;
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/card/card_add_dialog.dart';
import 'package:the_collector/pages/collection/card/card_thumbnail.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/pages/scanning/scan_screen.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/collection_organization.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/deck_checks.dart';

enum _DeckAction { format, rename, move, analysis, delete }

enum _EntryAction {
  mainboard,
  sideboard,
  commander,
  maybeboard,
  companion,
  remove,
}

class DeckFlyoutScreen extends StatefulWidget {
  final MTGDeck deck;
  final CollectionStore<MTGDeck>? store;
  final CollectionStore<MTGCard>? inventory;
  final CardCatalog? catalog;
  final Map<String, MTGCard> metadata;
  final Future<void> Function(MTGDeck group)? onScan;
  final bool embedded;
  final Widget? leadingContent;
  final String query;
  const DeckFlyoutScreen({
    super.key,
    required this.deck,
    this.store,
    this.inventory,
    this.catalog,
    this.metadata = const <String, MTGCard>{},
    this.onScan,
    this.embedded = false,
    this.leadingContent,
    this.query = '',
  });
  @override
  State<DeckFlyoutScreen> createState() => _DeckFlyoutScreenState();
}

class _DeckFlyoutScreenState extends State<DeckFlyoutScreen> {
  late final CollectionStore<MTGDeck> _store = widget.store ?? Crud.deck(u);
  late final CollectionOrganization _organization = CollectionOrganization(
    groups: _store,
  );
  late final CollectionStore<MTGCard> _inventory =
      widget.inventory ??
      CollectionStore<MTGCard>(
        collection: _store.collection.parent!.collection('cards'),
        toMap: (MTGCard card) => card.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGCardMapper.fromMap(data)..id = id,
      );
  late final Stream<MTGDeck?> _deck = _store.streamOrNull(widget.deck.id!);
  late final CardCatalog _catalog = widget.catalog ?? CardCatalog();
  late final Map<String, MTGCard> _metadata = <String, MTGCard>{
    ...widget.metadata,
  };
  final Set<String> _requested = <String>{};
  bool _busy = false;
  String? _error;
  String? _detailsError;
  (String, DeckSection, String?, String?)? _editing;

  (String, DeckSection, String?, String?) _entryKey(DeckEntry entry) =>
      (entry.cardId, entry.section, entry.language, entry.condition);

  @override
  void dispose() {
    if (widget.catalog == null) {
      _catalog.close();
    }
    super.dispose();
  }

  Future<void> _loadCards(MTGDeck deck) async {
    final List<String> ids = deck.effectiveEntries
        .map((DeckEntry entry) => entry.scryfallId)
        .toSet()
        .where(
          (String id) => !_metadata.containsKey(id) && !_requested.contains(id),
        )
        .toList();
    if (ids.isEmpty) {
      return;
    }
    _requested.addAll(ids);
    try {
      final Map<String, sf.MtgCard> printings = await _catalog.printings(ids);
      if (!mounted) {
        return;
      }
      setState(() {
        _detailsError = null;
        for (final sf.MtgCard card in printings.values) {
          final sf.Finish? finish = card.finishes
              .where((sf.Finish finish) => finish != sf.Finish.unknown)
              .firstOrNull;
          if (finish != null) {
            _metadata[card.id] = cardFromScryfall(card, finish: finish);
          }
        }
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _detailsError = 'Some printing details could not load. Saved deck entries are unchanged.',
        );
      }
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StateError
              ? error.message
              : 'Could not save the group. Check your connection and retry.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _add(PrintingSelection selection) async {
    _metadata[selection.card.printingId!] = selection.card;
    await _action(
      () => _store.txn(widget.deck.id!, (MTGDeck deck) {
        final List<DeckEntry> entries = List<DeckEntry>.of(
          deck.effectiveEntries,
        );
        final String id = CollectionIngestion.inventoryId(selection.card);
        final int index = entries.indexWhere(
          (DeckEntry entry) =>
              entry.cardId == id &&
              entry.section == DeckSection.mainboard &&
              entry.condition == null &&
              entry.language?.toLowerCase() ==
                  selection.card.language?.toLowerCase(),
        );
        if (index < 0) {
          entries.add(
            DeckEntry(
              scryfallId: selection.card.printingId!,
              finish: selection.card.finish,
              language: selection.card.language,
              quantity: selection.quantity,
            ),
          );
        } else {
          entries[index] = entries[index].copyWith(
            quantity: entries[index].quantity + selection.quantity,
          );
        }
        final MTGDeck updated = deck.copyWith(entries: entries);
        validateGroupCapacity(updated);
        return updated;
      }),
    );
  }

  Future<void> _search() async {
    final PrintingSelection? selection = await selectCardPrinting(context);
    if (selection != null && mounted) {
      await _add(selection);
    }
  }

  Future<void> _scan(MTGDeck group) async {
    if (widget.onScan != null) {
      if (!widget.embedded && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      await widget.onScan!(group);
      return;
    }
    await Arcane.push<void>(
      context,
      ScanScreen(
        userId: _store.collection.parent!.id,
        openCamera: true,
        destination: group,
      ),
    );
  }

  Future<void> _fromCollection() async {
    try {
      final List<MTGCard> cards = await _inventory.streamAll().first;
      if (!mounted) {
        return;
      }
      final MTGCard? selected = await Arcane.push<MTGCard>(
        context,
        _CollectionPicker(cards: cards),
      );
      if (selected == null || !mounted) {
        return;
      }
      MTGCard? card = selected;
      if (card.finish == null || card.language == null) {
        final String? id = card.printingId;
        final sf.MtgCard? printing = id == null
            ? null
            : (await _catalog.printings(<String>[id]))[id];
        if (!mounted) {
          return;
        }
        if (printing == null) {
          throw StateError('Printing metadata unavailable.');
        }
        final sf.Finish? finish = await _FinishPicker(printing: printing)
            .open<sf.Finish>(context);
        if (finish == null || !mounted) {
          return;
        }
        card = cardFromScryfall(printing, finish: finish);
      }
      await _add(PrintingSelection(card: card, quantity: 1));
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not load collection printings. Retry.');
      }
    }
  }

  Future<void> _change(DeckEntry selected, int delta) => _action(
    () => _store.txn(widget.deck.id!, (MTGDeck deck) {
      final List<DeckEntry> entries = List<DeckEntry>.of(deck.effectiveEntries);
      final int index = entries.indexWhere(
        (DeckEntry entry) =>
            entry.cardId == selected.cardId &&
            entry.language == selected.language &&
            entry.condition == selected.condition &&
            entry.section == selected.section,
      );
      if (index < 0) {
        throw StateError('Entry no longer exists.');
      }
      final int quantity = entries[index].quantity + delta;
      if (quantity <= 0) {
        entries.removeAt(index);
      } else {
        entries[index] = entries[index].copyWith(quantity: quantity);
      }
      final MTGDeck updated = deck.copyWith(entries: entries);
      validateGroupCapacity(updated);
      return updated;
    }),
  );

  Future<void> _move(DeckEntry selected, DeckSection section) => _action(
    () => _store.txn(widget.deck.id!, (MTGDeck deck) {
      final List<DeckEntry> entries = List<DeckEntry>.of(deck.effectiveEntries);
      final int index = entries.indexWhere(
        (DeckEntry entry) =>
            entry.cardId == selected.cardId &&
            entry.language == selected.language &&
            entry.condition == selected.condition &&
            entry.section == selected.section,
      );
      if (index < 0) {
        throw StateError('Entry no longer exists.');
      }
      final DeckEntry moving = entries.removeAt(index);
      final int target = entries.indexWhere(
        (DeckEntry entry) =>
            entry.cardId == moving.cardId &&
            entry.section == section &&
            entry.language == moving.language &&
            entry.condition == moving.condition,
      );
      if (target < 0) {
        entries.add(moving.copyWith(section: section));
      } else {
        entries[target] = entries[target].copyWith(
          quantity: entries[target].quantity + moving.quantity,
        );
      }
      final MTGDeck updated = deck.copyWith(entries: entries);
      validateGroupCapacity(updated);
      return updated;
    }),
  );

  Future<T?> _choose<T>(String title, List<(T, String)> options) =>
      showDialog<T>(
        context: context,
        builder: (BuildContext dialogContext) => ArcaneDialog(
          title: Text(title),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(dialogContext).height * .6,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final (T, String) option in options)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SecondaryButton(
                        onPressed: () =>
                            Navigator.pop(dialogContext, option.$1),
                        child: Text(option.$2, textAlign: TextAlign.center),
                      ),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Future<void> _options(MTGDeck deck) async {
    final _DeckAction? action = await _choose<_DeckAction>(
      '${groupKindLabel(deck.kind)} options',
      <(_DeckAction, String)>[
        if (deck.kind == CollectionGroupKind.deck)
          (
            _DeckAction.format,
            'Format: ${deck.sourceFormat ?? deck.format.name}',
          ),
        (_DeckAction.rename, 'Rename ${groupKindLabel(deck.kind)}'),
        (_DeckAction.move, 'Move to folder'),
        if (deck.kind == CollectionGroupKind.deck)
          (_DeckAction.analysis, 'Mana curve & checks'),
        (_DeckAction.delete, 'Delete ${groupKindLabel(deck.kind)}'),
      ],
    );
    if (!mounted || _busy || action == null) return;
    switch (action) {
      case _DeckAction.format:
        final DeckFormat? format = await _choose<DeckFormat>(
          'Choose format',
          <(DeckFormat, String)>[
            for (final DeckFormat format in DeckFormat.values)
              (format, format.name),
          ],
        );
        if (mounted &&
            format != null &&
            (format != deck.format || deck.sourceFormat != null)) {
          await _action(
            () => _store.txn(
              widget.deck.id!,
              (MTGDeck current) =>
                  current.copyWith(format: format, sourceFormat: null),
            ),
          );
        }
      case _DeckAction.rename:
        final String? name = await promptGroupName(
          context,
          title: 'Rename ${groupKindLabel(deck.kind)}',
          initialValue: deck.name,
        );
        if (mounted && name != null) {
          await _action(
            () =>
                _organization.renameGroup(groupId: widget.deck.id!, name: name),
          );
        }
      case _DeckAction.move:
        await _action(() async {
          final List<MTGDeck> groups = await _store.streamAll().first;
          if (!mounted) {
            return;
          }
          final String? parent = await _choose<String>(
            'Move ${deck.name}',
            <(String, String)>[
              ('', 'Collection root'),
              for (final MTGDeck folder in groups)
                if (folder.kind == CollectionGroupKind.folder &&
                    folder.id != deck.id)
                  (folder.id!, folder.name),
            ],
          );
          if (mounted && parent != null) {
            await _organization.moveGroup(
              groupId: deck.id!,
              parentId: parent.isEmpty ? null : parent,
            );
          }
        });
      case _DeckAction.analysis:
        await _analysis(deck);
      case _DeckAction.delete:
        final bool confirmed = await confirmGroupDeletion(
          context,
          title: 'Delete ${groupKindLabel(deck.kind)}',
          description:
              'Delete ${deck.name}? Your collection quantities stay unchanged. Move any nested groups first.',
        );
        if (mounted && confirmed) {
          await _action(() async {
            await _organization.deleteGroup(groupId: widget.deck.id!);
            if (mounted) {
              Navigator.pop(context);
            }
          });
        }
    }
  }

  Future<void> _entryOptions(DeckEntry entry, CollectionGroupKind kind) async {
    final _EntryAction? action = await _choose<_EntryAction>(
      _metadata[entry.scryfallId]?.name ?? 'Card options',
      <(_EntryAction, String)>[
        for (final DeckSection section
            in (kind == CollectionGroupKind.deck
                ? DeckSection.values
                : const <DeckSection>[]))
          if (section != entry.section)
            (
              switch (section) {
                DeckSection.mainboard => _EntryAction.mainboard,
                DeckSection.sideboard => _EntryAction.sideboard,
                DeckSection.commander => _EntryAction.commander,
                DeckSection.maybeboard => _EntryAction.maybeboard,
                DeckSection.companion => _EntryAction.companion,
              },
              'Move to ${section.name}',
            ),
        (_EntryAction.remove, 'Remove'),
      ],
    );
    if (!mounted || _busy || action == null) return;
    if (action == _EntryAction.remove) {
      await _change(entry, -entry.quantity);
    } else {
      await _move(entry, switch (action) {
        _EntryAction.mainboard => DeckSection.mainboard,
        _EntryAction.sideboard => DeckSection.sideboard,
        _EntryAction.commander => DeckSection.commander,
        _EntryAction.maybeboard => DeckSection.maybeboard,
        _EntryAction.companion => DeckSection.companion,
        _EntryAction.remove => throw StateError(
          'Removal does not move an entry.',
        ),
      });
    }
  }

  Future<void> _analysis(MTGDeck deck) => showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) {
      final Map<int, int> curve = deckManaCurve(deck, _metadata);
      final List<String> checks = deckFormatChecks(deck, _metadata);
      return ArcaneDialog(
        title: const Text('Mana curve & checks'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(dialogContext).height * .6,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text('Mainboard nonlands').large(),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: <Widget>[
                    for (int value = 0; value <= 6; value++)
                      Text(
                        '${value == 6 ? "6+" : value}: ${curve[value] ?? 0}',
                      ),
                  ],
                ),
                if (deck.format != DeckFormat.casual) ...<Widget>[
                  const SizedBox(height: 16),
                  const Text('Basic Format Checks').large(),
                  if (checks.isEmpty)
                    const Text(
                      'No issues found in these checks. Verify card-specific rules before play.',
                    ),
                  for (final String check in checks)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(check),
                    ),
                ],
                const SizedBox(height: 16),
                const Text(
                  'Deck quantities are independent of your collection.',
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _optionsButton(MTGDeck deck) => Semantics(
    key: const ValueKey<String>('deck-options'),
    label: '${groupKindLabel(deck.kind)} options',
    child: SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        icon: const Icon(Icons.dots_three),
        onPressed: _busy ? null : () => _options(deck),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => StreamBuilder<MTGDeck?>(
    stream: _deck,
    builder: (BuildContext context, AsyncSnapshot<MTGDeck?> snapshot) {
      if (snapshot.connectionState == ConnectionState.active &&
          !snapshot.hasError &&
          snapshot.data == null) {
        return Scaffold(
          headers: <Widget>[
            if (!usesSwipeBack)
              AppBar(
                title: const Text('Deck'),
                leading: <Widget>[
                  if (!usesSwipeBack)
                    IconButton(
                      icon: const Icon(Icons.arrow_left),
                      onPressed: () => Navigator.pop(context),
                    ),
                ],
              ),
          ],
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                widget.deck.kind == CollectionGroupKind.deck
                    ? 'This deck has been deleted. Return to your decks to choose another.'
                    : 'This group has been deleted. Return to your collection to choose another.',
              ),
            ),
          ),
        );
      }
      final MTGDeck deck = snapshot.data ?? widget.deck;
      _loadCards(deck);
      return Scaffold(
        headers: <Widget>[
          if (!widget.embedded && !usesSwipeBack)
            AppBar(
              leading: <Widget>[
                if (!usesSwipeBack)
                  IconButton(
                    icon: const Icon(Icons.arrow_left),
                    onPressed: () => Navigator.pop(context),
                  ),
              ],
              title: Text(groupKindLabel(deck.kind)),
              trailing: <Widget>[_optionsButton(deck)],
            ),
        ],
        child: ListView(
          physics: widget.embedded
              ? const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                )
              : null,
          padding: const EdgeInsets.all(12),
          children: <Widget>[
            if (widget.leadingContent != null) widget.leadingContent!,
            if (usesSwipeBack || widget.embedded)
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      deck.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _optionsButton(deck),
                ],
              )
            else
              Text(
                deck.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            Text(
              <String>[
                deck.kind == CollectionGroupKind.deck
                    ? (deck.sourceFormat ?? deck.format.name)
                    : groupKindLabel(deck.kind),
                '${deck.effectiveEntries.fold<int>(0, (int total, DeckEntry entry) => total + entry.quantity)} cards',
                '${deck.effectiveEntries.map((DeckEntry entry) => entry.scryfallId).toSet().length} ${deck.effectiveEntries.map((DeckEntry entry) => entry.scryfallId).toSet().length == 1 ? "printing" : "printings"}',
              ].join(' · '),
              style: const TextStyle(fontSize: 12),
            ).muted(),
            const SizedBox(height: 12),
            if (_error != null) Text(_error!),
            if (_detailsError != null) ...<Widget>[
              Text(_detailsError!),
              TextButton(
                onPressed: () {
                  _requested.clear();
                  _loadCards(deck);
                },
                child: const Text('Retry Card Details'),
              ),
            ],
            if (snapshot.hasError)
              const Text(
                'Could not load the current deck. Retry when connected.',
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: PrimaryButton(
                    key: const ValueKey<String>('group-scan-cards'),
                    onPressed: _busy ? null : () => _scan(deck),
                    child: const Text('Scan cards'),
                  ),
                ),
                SecondaryButton(
                  onPressed: _busy ? null : _search,
                  child: const Text('Search Cards'),
                ),
                SecondaryButton(
                  onPressed: _busy ? null : _fromCollection,
                  child: const Text('From Collection'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (deck.effectiveEntries.isEmpty)
              Text(
                deck.kind == CollectionGroupKind.deck
                    ? 'No deck entries yet. Add a printing to start building.'
                    : 'No cards here yet. Add a printing or choose from your collection.',
              ),
            for (final DeckSection section in DeckSection.values)
              if (deck.effectiveEntries.any(
                (DeckEntry entry) => entry.section == section,
              )) ...<Widget>[
                Text(
                  '${deck.kind == CollectionGroupKind.deck ? section.name : "Cards"} • ${deck.effectiveEntries.where((DeckEntry entry) => entry.section == section).fold(0, (int total, DeckEntry entry) => total + entry.quantity)}',
                ).large(),
                ...deck.effectiveEntries
                    .where(
                      (DeckEntry entry) =>
                          entry.section == section &&
                          (_metadata[entry.scryfallId]?.name ??
                                  entry.scryfallId)
                              .toLowerCase()
                              .contains(widget.query.trim().toLowerCase()),
                    )
                    .map(
                      (DeckEntry entry) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Tile(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    _editing = _editing == _entryKey(entry)
                                        ? null
                                        : _entryKey(entry);
                                  }),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 6,
                            ),
                            trailing: Text(
                              '${entry.quantity}',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            leading: _metadata[entry.scryfallId] == null
                                ? null
                                : CardThumbnail(
                                    card: _metadata[entry.scryfallId]!,
                                    width: 32,
                                  ),
                            title: Text(
                              _metadata[entry.scryfallId]?.name ??
                                  entry.scryfallId,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              <String>[
                                if (_metadata[entry.scryfallId]?.setCode !=
                                    null)
                                  '${_metadata[entry.scryfallId]!.setCode!.toUpperCase()} #${_metadata[entry.scryfallId]!.collectorNumber ?? "?"}',
                                entry.finish == sf.Finish.nonfoil
                                    ? 'Normal'
                                    : entry.finish?.name ??
                                          'Finish not recorded',
                                if (entry.language != null)
                                  entry.language!.toUpperCase(),
                                if (entry.condition != null) entry.condition!,
                              ].join(' · '),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          if (_editing == _entryKey(entry))
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: <Widget>[
                                Semantics(
                                  label:
                                      'Remove one ${_metadata[entry.scryfallId]?.name ?? "card"} from ${section.name}',
                                  child: SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: IconButton(
                                      icon: const Icon(Icons.minus),
                                      onPressed: _busy
                                          ? null
                                          : () => _change(entry, -1),
                                    ),
                                  ),
                                ),
                                Text('${entry.quantity}'),
                                Semantics(
                                  label:
                                      'Add one ${_metadata[entry.scryfallId]?.name ?? "card"} to ${section.name}',
                                  child: SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: IconButton(
                                      icon: const Icon(Icons.plus),
                                      onPressed: _busy
                                          ? null
                                          : () => _change(entry, 1),
                                    ),
                                  ),
                                ),
                                Semantics(
                                  label:
                                      '${_metadata[entry.scryfallId]?.name ?? "Card"} options in ${section.name}',
                                  child: SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: IconButton(
                                      icon: const Icon(Icons.dots_three),
                                      onPressed: _busy
                                          ? null
                                          : () =>
                                                _entryOptions(entry, deck.kind),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          const SizedBox(height: 4),
                        ],
                      ),
                    ),
              ],
          ],
        ),
      );
    },
  );
}

class _CollectionPicker extends StatefulWidget {
  final List<MTGCard> cards;
  const _CollectionPicker({required this.cards});
  @override
  State<_CollectionPicker> createState() => _CollectionPickerState();
}

class _CollectionPickerState extends State<_CollectionPicker> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String query = _search.text.trim().toLowerCase();
    final List<MTGCard> cards = widget.cards
        .where(
          (MTGCard card) =>
              '${card.name} ${card.setCode ?? card.setId} ${card.collectorNumber ?? ""} ${card.finish == sf.Finish.nonfoil ? "Normal" : card.finish?.name ?? ""} ${card.language ?? ""}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    return Scaffold(
      headers: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'Choose From Collection',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            key: const ValueKey<String>('inventory-picker-search'),
            semanticLabel: 'Search owned cards',
            controller: _search,
            placeholder: const ExcludeSemantics(
              child: Text('Search owned cards'),
            ),
            features: const <InputFeature>[InputFeature.clear()],
            textInputAction: TextInputAction.done,
            onSubmitted: (String _) =>
                FocusManager.instance.primaryFocus?.unfocus(),
            onChanged: (String _) => setState(() {}),
          ),
        ),
      ],
      child: cards.isEmpty
          ? Center(
              child: Text(
                widget.cards.isEmpty
                    ? 'Your collection is empty.'
                    : 'No owned cards match.',
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: cards.length,
              itemBuilder: (BuildContext context, int index) {
                final MTGCard card = cards[index];
                return Tile(
                  key: ValueKey<String>('owned-printing-${card.id}'),
                  leading: CardThumbnail(card: card),
                  title: Text(
                    card.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    <String>[
                      '${card.setCode?.toUpperCase() ?? card.setId} #${card.collectorNumber ?? "?"}',
                      card.finish == sf.Finish.nonfoil
                          ? 'Normal'
                          : card.finish?.name ?? 'Finish not recorded',
                      if (card.language != null) card.language!.toUpperCase(),
                      '${card.quantity} owned',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12),
                  ),
                  onPressed: () => Navigator.pop(context, card),
                );
              },
            ),
    );
  }
}

class _FinishPicker extends StatelessWidget with ArcaneDialogLauncher {
  final sf.MtgCard printing;
  const _FinishPicker({required this.printing});
  @override
  Widget build(BuildContext context) => ArcaneDialog(
    title: const Text('Choose Printing Finish'),
    content: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .5,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '${printing.set.toUpperCase()} #${printing.collectorNumber} • ${printing.lang.json.toUpperCase()}',
            ),
            ...printing.finishes
                .where((sf.Finish finish) => finish != sf.Finish.unknown)
                .map(
                  (sf.Finish finish) => SecondaryButton(
                    onPressed: () => Navigator.pop(context, finish),
                    child: Text(
                      finish == sf.Finish.nonfoil ? 'Normal' : finish.name,
                    ),
                  ),
                ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ),
  );
}
