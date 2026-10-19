import 'package:arcane/arcane.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/card/card_add_dialog.dart';
import 'package:the_collector/pages/collection/card/card_item.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/pages/collection/collection_prices.dart';
import 'package:the_collector/theme/collector_brand.dart';
import 'package:the_collector/theme/components/collector_search.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/collection_organization.dart';
import 'package:the_collector/utils/crud.dart';

enum _InventorySort { name, copies, value }

class _AssignOwnedCards extends StatefulWidget {
  const _AssignOwnedCards({required this.groups, required this.cards});

  final CollectionStore<MTGDeck> groups;
  final List<MTGCard> cards;

  @override
  State<_AssignOwnedCards> createState() => _AssignOwnedCardsState();
}

class _AssignOwnedCardsState extends State<_AssignOwnedCards> {
  late final Stream<List<MTGDeck>> _groups = widget.groups.streamAll();
  final TextEditingController _search = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _assign(MTGDeck group) async {
    if (_saving || group.id == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await CollectionOrganization(groups: widget.groups)
          .assignOwnedCards(groupId: group.id!, cards: widget.cards);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is StateError
              ? error.message
              : 'Assignment failed. Choose a container to retry.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      headers: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
          child: Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'Assign owned',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.x, semanticLabel: 'Close assignment'),
                onPressed: _saving ? null : () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: TextField(
            controller: _search,
            semanticLabel: 'Search containers',
            placeholder: const Text('Search containers'),
            onChanged: (String _) => setState(() {}),
          ),
        ),
      ],
      child: StreamBuilder<List<MTGDeck>>(
        stream: _groups,
        builder: (BuildContext context, AsyncSnapshot<List<MTGDeck>> snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Containers unavailable'));
          }
          if (!snapshot.hasData) {
            return const CollectorLoading(label: 'Loading containers…');
          }
          final List<MTGDeck> groups =
              snapshot.data!
                  .where(
                    (MTGDeck group) => group.name.toLowerCase().contains(
                      _search.text.trim().toLowerCase(),
                    ),
                  )
                  .toList()
                ..sort(
                  (MTGDeck first, MTGDeck second) =>
                      first.name.compareTo(second.name),
                );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!),
                ),
              if (_saving) const LinearProgressIndicator(),
              Expanded(
                child: groups.isEmpty
                    ? const Center(child: Text('No containers'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: groups.length,
                        itemBuilder: (BuildContext context, int index) {
                          final MTGDeck group = groups[index];
                          return Tile(
                            key: ValueKey<String>('assign-owned-${group.id}'),
                            title: Text(group.name),
                            subtitle: Text(groupKindLabel(group.kind)),
                            onPressed: _saving ? null : () => _assign(group),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class CollectionCards extends StatefulWidget {
  const CollectionCards({
    super.key,
    this.store,
    this.catalog,
    this.active = true,
    this.onValue,
  });

  final bool active;
  final CollectionStore<MTGCard>? store;
  final CardCatalog? catalog;
  final ValueChanged<List<MTGCard>?>? onValue;

  @override
  State<CollectionCards> createState() => _CollectionCardsState();
}

class _CollectionCardsState extends State<CollectionCards> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _type = TextEditingController();
  late final CardCatalog _catalog = widget.catalog ?? CardCatalog();
  final Map<String, MTGCard> _metadata = <String, MTGCard>{};
  final Set<String> _requested = <String>{};
  final Set<String> _selected = <String>{};
  late final CollectionStore<MTGCard> _store = widget.store ?? Crud.card(u);
  late final Stream<List<MTGCard>> _cards = _store.streamAll();
  late final CollectionStore<MTGDeck> _groups = CollectionStore<MTGDeck>(
    collection: _store.collection.parent!.collection('decks'),
    toMap: (MTGDeck group) => group.toMap(),
    fromMap: (String id, Map<String, Object?> data) =>
        MTGDeckMapper.fromMap(data)..id = id,
  );
  String _set = 'All sets';
  sf.Rarity? _rarity;
  sf.Finish? _finish;
  sf.Color? _color;
  _InventorySort _sort = _InventorySort.name;
  bool _filters = false;
  bool _selecting = false;
  bool _removing = false;
  bool _enriching = false;
  String? _removalError;

  @override
  void dispose() {
    _search.dispose();
    _type.dispose();
    if (widget.catalog == null) _catalog.close();
    super.dispose();
  }

  bool _needsMetadata(MTGCard card) =>
      card.scryfallId == null ||
      card.imageUrl == null ||
      card.setCode == null ||
      card.setName == null ||
      card.collectorNumber == null ||
      card.language == null ||
      card.oracleText == null;

  Future<void> _enrich(List<MTGCard> cards) async {
    if (!widget.active || _enriching) return;
    final List<String> ids = cards
        .where(_needsMetadata)
        .map((MTGCard card) => card.printingId)
        .whereType<String>()
        .where((String id) => !_requested.contains(id))
        .toSet()
        .take(75)
        .toList();
    if (ids.isEmpty) return;
    _requested.addAll(ids);
    _enriching = true;
    bool succeeded = false;
    try {
      final Map<String, sf.MtgCard> found = await _catalog.printings(ids);
      if (!mounted) return;
      succeeded = true;
      for (final sf.MtgCard card in found.values) {
        final sf.Finish? finish = card.finishes
            .where((sf.Finish finish) => finish != sf.Finish.unknown)
            .firstOrNull;
        if (finish != null) {
          _metadata[card.id] = cardFromScryfall(card, finish: finish);
        }
      }
    } catch (_) {
      _requested.removeAll(ids);
    } finally {
      _enriching = false;
      if (succeeded && mounted) setState(() {});
    }
  }

  MTGCard _display(MTGCard stored) {
    final MTGCard? enriched = _metadata[stored.printingId];
    if (enriched == null) return stored;
    return stored.copyWith(
      scryfallId: stored.scryfallId ?? enriched.scryfallId,
      oracleId: stored.oracleId ?? enriched.oracleId,
      imageUrl: stored.imageUrl ?? enriched.imageUrl,
      backImageUrl: stored.backImageUrl ?? enriched.backImageUrl,
      setCode: stored.setCode ?? enriched.setCode,
      setName: stored.setName ?? enriched.setName,
      collectorNumber: stored.collectorNumber ?? enriched.collectorNumber,
      language: stored.language ?? enriched.language,
      oracleText: stored.oracleText ?? enriched.oracleText,
      colors: stored.colors.isEmpty ? enriched.colors : stored.colors,
      colorIdentity: stored.colorIdentity.isEmpty
          ? enriched.colorIdentity
          : stored.colorIdentity,
      keywords: stored.keywords.isEmpty ? enriched.keywords : stored.keywords,
      legalities: stored.legalities.isEmpty
          ? enriched.legalities
          : stored.legalities,
    )..id = stored.id;
  }

  int get _filterCount => <bool>[
    _set != 'All sets',
    _rarity != null,
    _finish != null,
    _color != null,
    _type.text.trim().isNotEmpty,
  ].where((bool enabled) => enabled).length;

  bool get _filtered => _filterCount > 0 || _search.text.trim().isNotEmpty;

  int _compare(MTGCard a, MTGCard b) {
    final int comparison = switch (_sort) {
      _InventorySort.name => a.name.toLowerCase().compareTo(
        b.name.toLowerCase(),
      ),
      _InventorySort.copies => b.quantity.compareTo(a.quantity),
      _InventorySort.value =>
        ((b.unitPrice(CardCurrency.usd) ?? -1) * b.quantity).compareTo(
          (a.unitPrice(CardCurrency.usd) ?? -1) * a.quantity,
        ),
    };
    if (comparison != 0) return comparison;
    final int name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return name == 0 ? (a.id ?? '').compareTo(b.id ?? '') : name;
  }

  void _resetFilters() => setState(() {
    _set = 'All sets';
    _rarity = null;
    _finish = null;
    _color = null;
    _type.clear();
  });

  void _leaveSelection() => setState(() {
    _selecting = false;
    _selected.clear();
    _removalError = null;
  });

  void _toggle(MTGCard card) {
    final String? id = card.id;
    if (_removing || id == null) return;
    setState(() {
      _selecting = true;
      _removalError = null;
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  Future<void> _add() => CardPrintingDialog(
    catalog: _catalog,
    ingestion: CollectionIngestion(firestore: _store.collection.firestore),
    userId: _store.collection.parent!.id,
    groups: _groups.streamAll(),
  ).open<void>(context);

  void _value(List<MTGCard> visible) {
    final List<MTGCard>? scope = _filtered
        ? List<MTGCard>.unmodifiable(visible)
        : null;
    if (widget.onValue != null) {
      widget.onValue!(scope);
      return;
    }
    Arcane.push(
      context,
      CollectionPrices(
        cardsStore: _store,
        groupsStore: _groups,
        cardIds: scope
            ?.map((MTGCard card) => card.id)
            .whereType<String>()
            .toSet(),
      ),
    );
  }

  void _confirmRemoval(List<MTGCard> cards) {
    final int copies = cards.fold(
      0,
      (int total, MTGCard card) => total + card.quantity,
    );
    DialogConfirm(
      title: 'Remove $copies copies?',
      description:
          '${cards.length} selected printings. Container assignments stay unchanged.',
      confirmText: 'Remove copies',
      destructive: true,
      onConfirm: () => _remove(cards),
    ).open(context);
  }

  Future<void> _assign(List<MTGCard> cards) async {
    final bool? assigned = await Sheet(
      builder: (BuildContext context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: _AssignOwnedCards(
          groups: _groups,
          cards: List<MTGCard>.of(cards),
        ),
      ),
    ).open<bool>(context);
    if (mounted && assigned == true) _leaveSelection();
  }

  Future<void> _remove(List<MTGCard> cards) async {
    if (_removing) return;
    setState(() {
      _removing = true;
      _removalError = null;
    });
    final Set<String> failed = <String>{};
    for (int start = 0; start < cards.length; start += 20) {
      await Future.wait<void>(
        cards.skip(start).take(20).map((MTGCard card) async {
          final String? id = card.id;
          if (id == null) return;
          try {
            await _store.delete(id);
            _selected.remove(id);
          } catch (_) {
            failed.add(id);
          }
        }),
      );
    }
    if (!mounted) return;
    setState(() {
      _removing = false;
      _selected
        ..clear()
        ..addAll(failed);
      _selecting = failed.isNotEmpty;
      if (failed.isNotEmpty) {
        _removalError =
            'Could not remove ${failed.length} ${failed.length == 1 ? "printing" : "printings"}.';
      }
    });
  }

  Widget _action(String label, VoidCallback? onPressed) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    child: TextButton(
      density: ButtonDensity(
        (EdgeInsets padding) =>
            const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      ),
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(fontSize: 13)),
    ),
  );

  Widget _filter(String label, Widget child) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(label, style: const TextStyle(fontSize: 12)),
      const SizedBox(height: 4),
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: child,
      ),
    ],
  );

  Widget _editor(List<String> sets, String activeSet) => Column(
    children: <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Filter & sort',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            _action('Reset', _resetFilters),
          ],
        ),
      ),
      Expanded(
        child: ListView(
          key: const ValueKey<String>('inventory-filter-editor'),
          padding: const EdgeInsets.all(12),
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final _InventorySort sort in _InventorySort.values)
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    child: Button(
                      style: _sort == sort
                          ? ButtonVariance.primary
                          : ButtonVariance.outline,
                      onPressed: () => setState(() => _sort = sort),
                      child: Text(switch (sort) {
                        _InventorySort.name => 'Name',
                        _InventorySort.copies => 'Most copies',
                        _InventorySort.value => 'Highest value',
                      }),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: <Widget>[
                _filter(
                  'Set',
                  Selector<String>(
                    value: activeSet,
                    values: sets,
                    labelBuilder: (String value) =>
                        value == 'All sets' ? value : value.toUpperCase(),
                    onChanged: (String? value) =>
                        setState(() => _set = value ?? 'All sets'),
                  ),
                ),
                _filter(
                  'Rarity',
                  Selector<sf.Rarity>(
                    value: _rarity,
                    canUnselect: true,
                    values: sf.Rarity.values,
                    labelBuilder: (sf.Rarity value) => value.name,
                    onChanged: (sf.Rarity? value) =>
                        setState(() => _rarity = value),
                  ),
                ),
                _filter(
                  'Finish',
                  Selector<sf.Finish>(
                    value: _finish,
                    canUnselect: true,
                    values: sf.Finish.values
                        .where((sf.Finish value) => value != sf.Finish.unknown)
                        .toList(),
                    labelBuilder: (sf.Finish value) =>
                        value == sf.Finish.nonfoil ? 'Normal' : value.name,
                    onChanged: (sf.Finish? value) =>
                        setState(() => _finish = value),
                  ),
                ),
                _filter(
                  'Color',
                  Selector<sf.Color>(
                    value: _color,
                    canUnselect: true,
                    values: sf.Color.values
                        .where((sf.Color value) => value != sf.Color.unknown)
                        .toList(),
                    labelBuilder: (sf.Color value) => value.name,
                    onChanged: (sf.Color? value) =>
                        setState(() => _color = value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _type,
              placeholder: const Text('Card type'),
              onChanged: (String value) => setState(() {}),
              features: const <InputFeature>[InputFeature.clear()],
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: double.infinity,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: PrimaryButton(
              onPressed: () => setState(() => _filters = false),
              child: const Text('Apply'),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _toolbar(
    List<MTGCard> cards,
    Widget searchButton,
    Widget? searchField,
  ) {
    final int copies = cards.fold(
      0,
      (int total, MTGCard card) => total + card.quantity,
    );
    final List<MTGCard> priced = cards
        .where((MTGCard card) => card.unitPrice(CardCurrency.usd) != null)
        .toList();
    final double total = priced.fold(
      0,
      (double total, MTGCard card) =>
          total + card.unitPrice(CardCurrency.usd)! * card.quantity,
    );
    final int pricedCopies = priced.fold(
      0,
      (int total, MTGCard card) => total + card.quantity,
    );
    final Widget summary = Button(
      key: const ValueKey<String>('collection-value'),
      style: ButtonStyle.ghost(
        density: ButtonDensity((EdgeInsets _) => EdgeInsets.zero),
      ),
      onPressed: () => _value(cards),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            label: 'View collection value',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${cards.length} ${cards.length == 1 ? "printing" : "printings"} • $copies cards',
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  priced.isEmpty
                      ? 'No saved prices'
                      : 'USD ${total.toStringAsFixed(2)}${pricedCopies == copies ? "" : " · $pricedCopies/$copies priced"}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    Widget tool(
      String label,
      IconData icon,
      VoidCallback? action, {
      Key? key,
    }) => Tooltip(
      tooltip: (BuildContext context) => TooltipContainer(child: Text(label)),
      child: SizedBox.square(
        dimension: 44,
        child: IconButton(
          key: key,
          icon: Icon(icon, size: 20, semanticLabel: label),
          variance: ButtonVariance.ghost,
          onPressed: action,
        ),
      ),
    );
    final Widget actions = Wrap(
      spacing: 4,
      runSpacing: 4,
      children: <Widget>[
        searchButton,
        tool(
          _filterCount == 0
              ? 'Filter collection'
              : 'Filter collection, $_filterCount active',
          Icons.funnel,
          () => setState(() => _filters = true),
        ),
        tool(
          'Select cards',
          Icons.check_square,
          cards.isEmpty ? null : () => setState(() => _selecting = true),
          key: const ValueKey<String>('collection-select'),
        ),
        tool('Add a printing', Icons.plus, _add),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: <Widget>[
          if (searchField != null) ...<Widget>[
            searchField,
            const SizedBox(height: 8),
          ],
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool stacked =
                  constraints.maxWidth <
                  196 + 120 * MediaQuery.textScalerOf(context).scale(1);
              return stacked
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[summary, actions],
                    )
                  : Row(
                      children: <Widget>[
                        Expanded(child: summary),
                        const SizedBox(width: 8),
                        actions,
                      ],
                    );
            },
          ),
        ],
      ),
    );
  }

  Widget _selectionToolbar(List<MTGCard> cards) {
    final List<MTGCard> selected = cards
        .where((MTGCard card) => _selected.contains(card.id))
        .toList();
    final int copies = selected.fold(
      0,
      (int total, MTGCard card) => total + card.quantity,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${selected.length} selected · $copies copies',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              _action('Done', _removing ? null : _leaveSelection),
            ],
          ),
          Wrap(
            spacing: 8,
            children: <Widget>[
              _action(
                'All shown',
                _removing
                    ? null
                    : () => setState(
                        () => _selected.addAll(
                          cards
                              .map((MTGCard card) => card.id)
                              .whereType<String>(),
                        ),
                      ),
              ),
              _action(
                'Assign',
                selected.isEmpty || _removing ? null : () => _assign(selected),
              ),
              _action(
                _removalError == null ? 'Remove' : 'Retry removal',
                selected.isEmpty || _removing
                    ? null
                    : () => _confirmRemoval(selected),
              ),
            ],
          ),
          if (_removing) const Text('Removing…'),
          if (_removalError != null) Text(_removalError!),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => CollectorSearch(
    controller: _search,
    label: 'Search cards',
    fieldKey: const ValueKey<String>('collection-search'),
    enabled: widget.active && !_filters && !_selecting,
    onChanged: (String _) => setState(() {}),
    builder: (BuildContext context, Widget searchButton, Widget? searchField) =>
        CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            if (_filters || _selecting)
              const SingleActivator(LogicalKeyboardKey.escape): () {
                if (_filters) setState(() => _filters = false);
                if (_selecting && !_removing) _leaveSelection();
              },
          },
          child: Scaffold(
            child: StreamBuilder<List<MTGCard>>(
              stream: widget.active ? _cards : null,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<List<MTGCard>> snapshot,
                  ) {
                    final List<MTGCard> all = snapshot.data ?? <MTGCard>[];
                    _enrich(all);
                    final List<MTGCard> display = all.map(_display).toList();
                    final List<String> sets = <String>[
                      'All sets',
                      ...display
                          .map((MTGCard card) => card.setCode ?? card.setId)
                          .toSet()
                          .toList()
                        ..sort(),
                    ];
                    final String activeSet = sets.contains(_set)
                        ? _set
                        : 'All sets';
                    if (_filters) return _editor(sets, activeSet);
                    final String query = _search.text.trim().toLowerCase();
                    final String type = _type.text.trim().toLowerCase();
                    final List<MTGCard> cards =
                        display
                            .where(
                              (MTGCard card) =>
                                  card.name.toLowerCase().contains(query) &&
                                  card.typeLine.toLowerCase().contains(type) &&
                                  (activeSet == 'All sets' ||
                                      (card.setCode ?? card.setId) ==
                                          activeSet) &&
                                  (_rarity == null || card.rarity == _rarity) &&
                                  (_finish == null || card.finish == _finish) &&
                                  (_color == null ||
                                      (_color == sf.Color.colorless
                                          ? card.scryfallId != null &&
                                                card.colors.isEmpty
                                          : card.colors.contains(_color))),
                            )
                            .toList()
                          ..sort(_compare);
                    return CustomScrollView(
                      key: const PageStorageKey<String>('inventory-list'),
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      slivers: <Widget>[
                        SliverToBoxAdapter(
                          child: _selecting
                              ? _selectionToolbar(cards)
                              : _toolbar(cards, searchButton, searchField),
                        ),
                        if (snapshot.hasError)
                          const SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Text(
                                'Could not load cards. Check your connection.',
                              ),
                            ),
                          )
                        else if (!snapshot.hasData)
                          const SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: CollectorLoading(label: 'Loading cards…'),
                            ),
                          )
                        else if (cards.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  all.isEmpty
                                      ? 'No cards yet.'
                                      : 'No matching cards.',
                                ),
                              ),
                            ),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                            sliver: SliverList.builder(
                              itemCount: cards.length,
                              itemBuilder: (BuildContext context, int index) =>
                                  Column(
                                    key: ValueKey<String>(
                                      'inventory-row-${cards[index].id}',
                                    ),
                                    children: <Widget>[
                                      const Divider(),
                                      buildCardItem(
                                        cards[index],
                                        store: _store,
                                        catalog: _catalog,
                                        selecting: _selecting,
                                        selected: _selected.contains(
                                          cards[index].id,
                                        ),
                                        enabled: !_removing,
                                        onSelect: () => _toggle(cards[index]),
                                      ),
                                    ],
                                  ),
                            ),
                          ),
                      ],
                    );
                  },
            ),
          ),
        ),
  );
}
