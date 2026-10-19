import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, TextInputAction;
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/crud.dart';

class PrintingSelection {
  const PrintingSelection({
    required this.card,
    required this.quantity,
    this.printing,
    this.destinationId,
    this.deckSection = DeckSection.mainboard,
  });

  final MTGCard card;
  final int quantity;
  final sf.MtgCard? printing;
  final String? destinationId;
  final DeckSection deckSection;
}

Future<PrintingSelection?> selectCardPrinting(BuildContext context) =>
    const CardPrintingDialog(addToCollection: false)
        .open<PrintingSelection>(context);

class CardPrintingDialog extends StatelessWidget with ArcaneDialogLauncher {
  const CardPrintingDialog({
    super.key,
    this.addToCollection = true,
    this.printingOnly = false,
    this.catalog,
    this.ingestion,
    this.userId,
    this.groups,
    this.initialQuery = '',
    this.initialPrinting,
    this.initialPrintings = const <sf.MtgCard>[],
    this.initialFinish = sf.Finish.nonfoil,
    this.initialQuantity = 1,
    this.initialDestinationId,
    this.initialDeckSection = DeckSection.mainboard,
    this.onPrintingArtworkTap,
    this.onEdited,
  });

  final bool addToCollection;
  final bool printingOnly;
  final CardCatalog? catalog;
  final CollectionIngestion? ingestion;
  final String? userId;
  final Stream<List<MTGDeck>>? groups;
  final String initialQuery;
  final sf.MtgCard? initialPrinting;
  final List<sf.MtgCard> initialPrintings;
  final sf.Finish? initialFinish;
  final int initialQuantity;
  final String? initialDestinationId;
  final DeckSection initialDeckSection;
  final ValueChanged<sf.MtgCard>? onPrintingArtworkTap;
  final VoidCallback? onEdited;

  @override
  Future<T?> open<T>(BuildContext context) => Sheet(
    builder: (BuildContext context) =>
        SizedBox(height: MediaQuery.sizeOf(context).height * .92, child: this),
  ).open<T>(context);

  @override
  Widget build(BuildContext context) => CardPrintingSelector(
    addToCollection: addToCollection,
    printingOnly: printingOnly,
    catalog: catalog,
    ingestion: ingestion,
    userId: userId,
    groups: groups,
    initialQuery: initialQuery,
    initialPrinting: initialPrinting,
    initialPrintings: initialPrintings,
    initialFinish: initialFinish,
    initialQuantity: initialQuantity,
    initialDestinationId: initialDestinationId,
    initialDeckSection: initialDeckSection,
    onPrintingArtworkTap: onPrintingArtworkTap,
    onEdited: onEdited,
    onCancel: () => Navigator.pop(context),
    onSelected: (PrintingSelection selection) =>
        Navigator.pop(context, selection),
  );
}

class CardPrintingSelector extends StatefulWidget {
  const CardPrintingSelector({
    super.key,
    required this.onSelected,
    required this.onCancel,
    this.addToCollection = false,
    this.printingOnly = false,
    this.catalog,
    this.ingestion,
    this.userId,
    this.groups,
    this.initialQuery = '',
    this.initialPrinting,
    this.initialPrintings = const <sf.MtgCard>[],
    this.initialFinish = sf.Finish.nonfoil,
    this.initialQuantity = 1,
    this.initialDestinationId,
    this.initialDeckSection = DeckSection.mainboard,
    this.onPrintingArtworkTap,
    this.onEdited,
    this.confirmLabel,
    this.secondaryAction,
  }) : assert(!printingOnly || !addToCollection);

  final ValueChanged<PrintingSelection> onSelected;
  final VoidCallback onCancel;
  final bool addToCollection;
  final bool printingOnly;
  final CardCatalog? catalog;
  final CollectionIngestion? ingestion;
  final String? userId;
  final Stream<List<MTGDeck>>? groups;
  final String initialQuery;
  final sf.MtgCard? initialPrinting;
  final List<sf.MtgCard> initialPrintings;
  final sf.Finish? initialFinish;
  final int initialQuantity;
  final String? initialDestinationId;
  final DeckSection initialDeckSection;
  final ValueChanged<sf.MtgCard>? onPrintingArtworkTap;
  final VoidCallback? onEdited;
  final String? confirmLabel;
  final Widget? secondaryAction;

  @override
  State<CardPrintingSelector> createState() => _CardPrintingSelectorState();
}

class _CardPrintingSelectorState extends State<CardPrintingSelector> {
  late final CardCatalog _catalog = widget.catalog ?? CardCatalog();
  late final CollectionIngestion _ingestion =
      widget.ingestion ?? CollectionIngestion();
  late final TextEditingController _search = TextEditingController(
    text: widget.initialQuery,
  );
  late final TextEditingController _quantity = TextEditingController(
    text: '${widget.initialQuantity}',
  );
  final TextEditingController _set = TextEditingController();
  final TextEditingController _number = TextEditingController();
  final FocusNode _shortcuts = FocusNode();
  final ScrollController _scroll = ScrollController();
  late sf.MtgCard? _selected = widget.initialPrinting;
  late sf.Finish? _finish = widget.initialFinish;
  late String _groupId = widget.initialDestinationId ?? '';
  late DeckSection _deckSection = widget.initialDeckSection;
  late final String? _userId = widget.addToCollection
      ? widget.userId ?? u
      : widget.userId;
  List<sf.MtgCard> _results = <sf.MtgCard>[];
  List<MTGDeck> _groups = <MTGDeck>[];
  StreamSubscription<List<MTGDeck>>? _groupSubscription;
  String? _error;
  String? _groupError;
  String? _operationId;
  String _query = '';
  int _request = 0;
  int _page = 1;
  bool _searching = false;
  bool _saving = false;
  bool _hasMore = false;
  bool _filters = false;
  bool _retryNext = false;

  bool get _showDestination =>
      !widget.printingOnly && (widget.addToCollection || widget.groups != null);

  @override
  void initState() {
    super.initState();
    _results = <String, sf.MtgCard>{
      for (final sf.MtgCard card in widget.initialPrintings) card.id: card,
      if (_selected case final sf.MtgCard card) card.id: card,
    }.values.toList();
    if (_selected case final sf.MtgCard card) {
      _finish = _supportedFinish(card, _finish);
    }
    if (_showDestination) {
      _groupSubscription = (widget.groups ?? Crud.deck(_userId!).streamAll())
          .listen(
            (List<MTGDeck> groups) {
              if (mounted) {
                setState(() {
                  _groups = groups;
                  _groupError = null;
                });
              }
            },
            onError: (Object _) {
              if (mounted) {
                setState(() => _groupError = 'Containers unavailable');
              }
            },
          );
    }
    if (widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) _find();
      });
    }
  }

  @override
  void dispose() {
    _request++;
    _search.dispose();
    _quantity.dispose();
    _set.dispose();
    _number.dispose();
    _shortcuts.dispose();
    _scroll.dispose();
    _groupSubscription?.cancel();
    if (widget.catalog == null) _catalog.close();
    super.dispose();
  }

  sf.Finish? _supportedFinish(sf.MtgCard card, sf.Finish? preferred) {
    final List<sf.Finish> choices = card.finishes
        .where((sf.Finish f) => f != sf.Finish.unknown)
        .toList();
    if (choices.contains(preferred)) return preferred;
    if (choices.contains(sf.Finish.nonfoil)) return sf.Finish.nonfoil;
    return choices.length == 1 ? choices.single : null;
  }

  String _quoted(String value) =>
      '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

  String _searchQuery() {
    final String query = _search.text.trim();
    final bool filtering =
        _set.text.trim().isNotEmpty || _number.text.trim().isNotEmpty;
    return <String>[
      if (query.isNotEmpty) filtering ? '($query)' : query,
      if (_set.text.trim().isNotEmpty) 'set:${_quoted(_set.text.trim())}',
      if (_number.text.trim().isNotEmpty) 'cn:${_quoted(_number.text.trim())}',
    ].join(' ');
  }

  Future<void> _find({bool next = false}) async {
    if (_saving || (next && _searching)) return;
    final String query = next ? _query : _searchQuery();
    if (query.isEmpty) return;
    _shortcuts.requestFocus();
    final int request = ++_request;
    final int requestedPage = next ? _page + 1 : 1;
    setState(() {
      _searching = true;
      _error = null;
      if (!next) {
        _query = query;
        _page = 1;
        _hasMore = false;
        _results = <sf.MtgCard>[];
      }
    });
    try {
      final sf.PaginableList<sf.MtgCard> page = await _catalog.search(
        query,
        page: requestedPage,
        allPrintings: true,
      );
      if (!mounted || request != _request) return;
      setState(() {
        final Map<String, sf.MtgCard> unique = <String, sf.MtgCard>{
          if (next)
            for (final sf.MtgCard card in _results) card.id: card,
          for (final sf.MtgCard card in page.data) card.id: card,
        };
        _results = unique.values.toList();
        _hasMore = page.hasMore;
        _page = requestedPage;
      });
    } catch (_) {
      if (mounted && request == _request) {
        setState(() {
          _error = 'Search unavailable';
          _retryNext = next;
        });
      }
    } finally {
      if (mounted && request == _request) setState(() => _searching = false);
    }
  }

  void _select(sf.MtgCard card) {
    if (_saving) return;
    widget.onEdited?.call();
    setState(() {
      _selected = card;
      _finish = _supportedFinish(card, _finish);
      _error = null;
      _operationId = null;
    });
    _shortcuts.requestFocus();
  }

  Future<void> _confirm() async {
    if (_saving || _selected == null || _finish == null) return;
    _shortcuts.requestFocus();
    final int? quantity = int.tryParse(_quantity.text.trim());
    if (quantity == null || quantity < 1 || quantity > 1000000) {
      setState(() => _error = 'Enter a quantity from 1 to 1000000.');
      return;
    }
    if (_showDestination &&
        _groupId.isNotEmpty &&
        !_groups.any((MTGDeck group) => group.id == _groupId)) {
      setState(() => _error = 'Choose an available destination');
      return;
    }
    final MTGCard card = cardFromScryfall(_selected!, finish: _finish!);
    final PrintingSelection selection = PrintingSelection(
      card: card,
      quantity: quantity,
      printing: _selected,
      destinationId: _groupId.isEmpty ? null : _groupId,
      deckSection: _deckSection,
    );
    if (!widget.addToCollection) {
      widget.onSelected(selection);
      return;
    }
    _operationId ??= _ingestion.newOperationId();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final IngestionResult result = await _ingestion.add(
        userId: _userId!,
        operationId: _operationId!,
        card: card,
        quantity: quantity,
        deckId: selection.destinationId,
        deckSection: selection.deckSection,
      );
      card.id = result.cardId;
      if (mounted) widget.onSelected(selection);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not add this printing. Retry to finish the same addition.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _touch(Widget child) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    child: child,
  );

  Widget _searchControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      TextField(
        key: const ValueKey<String>('printing-search'),
        controller: _search,
        placeholder: const Text('Card name or Scryfall query'),
        enabled: !_saving,
        textInputAction: TextInputAction.search,
        onChanged: (String _) => widget.onEdited?.call(),
        onSubmitted: (String _) {
          widget.onEdited?.call();
          _find();
        },
        features: const <InputFeature>[InputFeature.clear()],
      ),
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 8,
        children: <Widget>[
          _touch(
            TextButton(
              key: const ValueKey<String>('printing-search-submit'),
              onPressed: _saving
                  ? null
                  : () {
                      widget.onEdited?.call();
                      _find();
                    },
              child: const Text('Search', style: TextStyle(fontSize: 14)),
            ),
          ),
          _touch(
            TextButton(
              onPressed: _saving
                  ? null
                  : () => setState(() => _filters = !_filters),
              child: const Text('Filter', style: TextStyle(fontSize: 14)),
            ),
          ),
        ],
      ),
      if (_filters) ...<Widget>[
        TextField(
          key: const ValueKey<String>('printing-set-filter'),
          controller: _set,
          placeholder: const Text('Set code'),
          enabled: !_saving,
          onChanged: (String _) => widget.onEdited?.call(),
          onSubmitted: (String _) {
            widget.onEdited?.call();
            _find();
          },
        ),
        const SizedBox(height: 6),
        TextField(
          key: const ValueKey<String>('printing-number-filter'),
          controller: _number,
          placeholder: const Text('Collector number'),
          enabled: !_saving,
          onChanged: (String _) => widget.onEdited?.call(),
          onSubmitted: (String _) {
            widget.onEdited?.call();
            _find();
          },
        ),
        _touch(
          TextButton(
            onPressed: _saving
                ? null
                : () {
                    widget.onEdited?.call();
                    _set.clear();
                    _number.clear();
                    _find();
                  },
            child: const Text('Clear filters'),
          ),
        ),
      ],
    ],
  );

  Widget _choice(sf.MtgCard card) {
    final bool selected = _selected?.id == card.id;
    final sf.ImageUris? image =
        card.imageUris ?? card.cardFaces?.firstOrNull?.imageUris;
    final Color ink = Theme.of(context).colorScheme.foreground;
    final Widget fallback = Container(
      color: Theme.of(context).colorScheme.muted,
      alignment: Alignment.center,
      child: const Icon(
        Icons.cards,
        size: 20,
        semanticLabel: 'Artwork unavailable',
      ),
    );
    final Widget artwork = SizedBox(
      width: 38,
      height: 53,
      child: image == null
          ? fallback
          : Image.network(
              image.small.toString(),
              fit: BoxFit.contain,
              cacheWidth: 114,
              errorBuilder: (
                BuildContext context,
                Object error,
                StackTrace? stack,
              ) => fallback,
            ),
    );
    return Semantics(
      selected: selected,
      child: ButtonStyleOverride(
        decoration:
            (
              BuildContext context,
              Set<WidgetState> states,
              Decoration decoration,
            ) => BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.muted
                  : Theme.of(context).colorScheme.background,
              border: selected || states.contains(WidgetState.focused)
                  ? Border.all(color: ink)
                  : null,
            ),
        child: CardButton(
          key: ValueKey<String>('printing-choice-${card.id}'),
          onPressed: _saving ? null : () => _select(card),
          density: ButtonDensity(
            (EdgeInsets padding) =>
                const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          ),
          child: Row(
            children: <Widget>[
              if (widget.onPrintingArtworkTap == null)
                artwork
              else
                _touch(
                  IconButton(
                    key: ValueKey<String>('printing-artwork-${card.id}'),
                    icon: Semantics(
                      label:
                          'Printing evidence: ${card.name}, ${card.set.toUpperCase()} ${card.collectorNumber}',
                      child: artwork,
                    ),
                    density: ButtonDensity(
                      (EdgeInsets padding) => EdgeInsets.zero,
                    ),
                    onPressed: _saving
                        ? null
                        : () => widget.onPrintingArtworkTap!(card),
                  ),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      card.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${card.setName} · ${card.set.toUpperCase()} #${card.collectorNumber}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(
                      '${card.lang.json.toUpperCase()} · ${card.finishes.where((sf.Finish f) => f != sf.Finish.unknown).map(_finishLabel).join(" / ")}',
                      style: const TextStyle(fontSize: 12),
                    ).muted(),
                  ],
                ),
              ),
              if (selected)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.check, size: 18),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _finishLabel(sf.Finish finish) => switch (finish) {
    sf.Finish.nonfoil => 'Normal',
    sf.Finish.foil => 'Foil',
    sf.Finish.etched => 'Etched',
    sf.Finish.glossy => 'Glossy',
    _ => 'Unknown',
  };

  List<Widget> _resultRows() => <Widget>[
    if (_searching)
      const Padding(padding: EdgeInsets.all(12), child: Text('Searching…')),
    if (!_searching && _results.isEmpty)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          _query.isEmpty
              ? 'Search a name, set, or collector number.'
              : 'No printings match.',
        ),
      ),
    if (!_searching && _results.isEmpty && _query.isNotEmpty)
      _touch(
        TextButton(
          onPressed: _saving
              ? null
              : () {
                  widget.onEdited?.call();
                  _set.clear();
                  _number.clear();
                  _find();
                },
          child: const Text('Search without filters'),
        ),
      ),
    for (final sf.MtgCard card in _results) _choice(card),
    if (_hasMore)
      _touch(
        TextButton(
          onPressed: _searching || _saving ? null : () => _find(next: true),
          child: const Text('More Printings'),
        ),
      ),
  ];

  Widget _selectedControls({required bool stacked}) {
    final sf.MtgCard? card = _selected;
    if (card == null) return const SizedBox.shrink();
    final Widget finish = _touch(
      Selector<sf.Finish>(
        key: const ValueKey<String>('printing-finish'),
        value: _finish,
        values: card.finishes
            .where((sf.Finish finish) => finish != sf.Finish.unknown)
            .toList(),
        labelBuilder: _finishLabel,
        onChanged: _saving
            ? null
            : (sf.Finish? finish) => setState(() {
                widget.onEdited?.call();
                _finish = finish;
                _operationId = null;
              }),
      ),
    );
    final Widget copies = TextField(
      key: const ValueKey<String>('printing-copies'),
      controller: _quantity,
      semanticLabel: 'Copies',
      placeholder: const Text('Quantity'),
      keyboardType: TextInputType.number,
      enabled: !_saving,
      onChanged: (String _) {
        widget.onEdited?.call();
        _operationId = null;
      },
      textInputAction: TextInputAction.done,
      onSubmitted: (String _) => _shortcuts.requestFocus(),
    );
    return Column(
      key: const ValueKey<String>('printing-selected-details'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          card.name,
          key: const ValueKey<String>('printing-identity'),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        Text(
          '${card.set.toUpperCase()} #${card.collectorNumber} · ${card.lang.json.toUpperCase()}',
          key: const ValueKey<String>('printing-metadata'),
          style: const TextStyle(fontSize: 12),
        ).muted(),
        const SizedBox(height: 6),
        if (_finish == null) const Text('Choose a finish'),
        if (widget.printingOnly)
          finish
        else if (stacked) ...<Widget>[
          finish,
          const SizedBox(height: 6),
          copies,
        ] else
          Row(
            children: <Widget>[
              Expanded(child: finish),
              const SizedBox(width: 8),
              Expanded(child: copies),
            ],
          ),
        if (_showDestination) ...<Widget>[
          const SizedBox(height: 6),
          _touch(
            Selector<String>(
              key: const ValueKey<String>('printing-destination'),
              value: _groupId,
              values: <String>{
                '',
                ..._groups.map((MTGDeck group) => group.id).whereType<String>(),
                if (_groupId.isNotEmpty) _groupId,
              }.toList(),
              labelBuilder: (String id) {
                if (id.isEmpty) return 'Collection';
                final MTGDeck? group = _groups
                    .where((MTGDeck group) => group.id == id)
                    .firstOrNull;
                return group == null
                    ? 'Unavailable destination'
                    : '${groupKindLabel(group.kind)}: ${group.name}';
              },
              onChanged: _saving
                  ? null
                  : (String? id) => setState(() {
                      widget.onEdited?.call();
                      _groupId = id ?? '';
                      _operationId = null;
                    }),
            ),
          ),
          if (_groupError != null) Text(_groupError!),
          if (_groups
                  .where((MTGDeck group) => group.id == _groupId)
                  .firstOrNull
                  ?.kind ==
              CollectionGroupKind.deck) ...<Widget>[
            const SizedBox(height: 6),
            _touch(
              Selector<DeckSection>(
                key: const ValueKey<String>('printing-deck-section'),
                value: _deckSection,
                values: DeckSection.values,
                labelBuilder: (DeckSection section) => switch (section) {
                  DeckSection.mainboard => 'Mainboard',
                  DeckSection.sideboard => 'Sideboard',
                  DeckSection.commander => 'Commander',
                  DeckSection.maybeboard => 'Maybeboard',
                  DeckSection.companion => 'Companion',
                },
                onChanged: _saving
                    ? null
                    : (DeckSection? section) => setState(() {
                        widget.onEdited?.call();
                        _deckSection = section ?? DeckSection.mainboard;
                        _operationId = null;
                      }),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _actions() {
    final Widget secondary = _touch(
      widget.secondaryAction ??
          TextButton(
            key: const ValueKey<String>('printing-cancel'),
            onPressed: _saving ? null : widget.onCancel,
            child: const Text('Cancel', style: TextStyle(fontSize: 14)),
          ),
    );
    final Widget confirm = _touch(
      PrimaryButton(
        key: const ValueKey<String>('printing-confirm'),
        onPressed: _saving || _selected == null || _finish == null
            ? null
            : _confirm,
        child: Text(
          _saving
              ? 'Adding…'
              : widget.confirmLabel ??
                    (widget.addToCollection
                        ? (_groupId.isEmpty
                              ? 'Add to Collection'
                              : 'Add to group')
                        : 'Add printing'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints bounds) {
        if (MediaQuery.textScalerOf(context).scale(14) > 21 ||
            bounds.maxWidth < 280) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[confirm, const SizedBox(height: 4), secondary],
          );
        }
        return Row(
          children: <Widget>[
            secondary,
            const SizedBox(width: 8),
            Expanded(child: confirm),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!_saving) widget.onCancel();
        },
      },
      child: Focus(
        focusNode: _shortcuts,
        autofocus: true,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              12,
              12,
              12 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints bounds) {
                final bool compact =
                    bounds.maxHeight < 440 ||
                    MediaQuery.textScalerOf(context).scale(14) > 21;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (!compact) _searchControls(),
                    Expanded(
                      child: ListView(
                        controller: _scroll,
                        children: <Widget>[
                          if (compact) _searchControls(),
                          if (compact && _selected != null) ...<Widget>[
                            _selectedControls(stacked: true),
                            const SizedBox(height: 8),
                          ],
                          ..._resultRows(),
                        ],
                      ),
                    ),
                    if (!compact && _selected != null) ...<Widget>[
                      const SizedBox(height: 8),
                      _selectedControls(stacked: false),
                    ],
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Semantics(
                          liveRegion: true,
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              if (_error == 'Search unavailable')
                                _touch(
                                  TextButton(
                                    onPressed: () => _find(next: _retryNext),
                                    child: const Text('Retry'),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    _actions(),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}
