import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:scryfall_api/scryfall_api.dart' hide Color;

import '../../utils/card_catalog.dart';
import '../../utils/scanning/scan_recognition.dart';
import '../../utils/scanning/scan_resolver.dart';
import '../../utils/scanning/scan_session.dart';
import '../collection/card/card_add_dialog.dart';
import 'scan_printing_evidence.dart';

class ScanCorrectionEditor extends StatefulWidget {
  const ScanCorrectionEditor({
    super.key,
    required this.crop,
    required this.onConfirmed,
    required this.onClose,
    this.catalog,
    this.decks = const <MTGDeck>[],
    this.initialResolution,
    this.initialSelection,
    this.progressLabel,
    this.confirmLabel = 'Save',
    this.preferredFinish = Finish.nonfoil,
    this.preferredQuantity = 1,
    this.preferredDeckId,
    this.preferredDeckSection = DeckSection.mainboard,
    this.phase,
    this.lookupError,
    this.onRetry,
    this.onRemove,
    this.onLater,
    this.onRescan,
  });

  final ScanCrop crop;
  final ValueChanged<PrintingSelection> onConfirmed;
  final VoidCallback onClose;
  final CardCatalog? catalog;
  final List<MTGDeck> decks;
  final ScanResolution? initialResolution;
  final PrintingSelection? initialSelection;
  final String? progressLabel;
  final String confirmLabel;
  final Finish? preferredFinish;
  final int preferredQuantity;
  final String? preferredDeckId;
  final DeckSection preferredDeckSection;
  final ScanItemPhase? phase;
  final String? lookupError;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onRemove;
  final VoidCallback? onLater;
  final VoidCallback? onRescan;

  @override
  State<ScanCorrectionEditor> createState() => _ScanCorrectionEditorState();
}

class _ScanCorrectionEditorState extends State<ScanCorrectionEditor> {
  final StreamController<List<MTGDeck>> _groups =
      StreamController<List<MTGDeck>>.broadcast();
  late final ScanCrop _source;
  ScanResolution? _initialResolution;
  ScanResolution? _resolution;
  late final PrintingSelection? _initialSelection;
  List<MtgCard> get _printings => <MtgCard>[
    for (final ScanCandidate candidate
        in _resolution?.candidates ?? const <ScanCandidate>[])
      candidate.card,
  ];
  MtgCard? _evidence;
  bool _busy = false;
  bool _replaced = false;
  bool _edited = false;
  int _selectorGeneration = 0;
  int _generation = 0;
  String? _error;

  MtgCard? get _selected {
    final PrintingSelection? selection = _initialSelection;
    if (selection == null) return _printings.firstOrNull;
    return selection.printing ??
        _printings
            .where((MtgCard card) => card.id == selection.card.printingId)
            .firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    _source = widget.crop;
    _initialResolution = widget.initialResolution;
    _resolution = widget.initialResolution;
    _initialSelection = widget.initialSelection;
    _publishGroups();
  }

  void _publishGroups() {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _groups.add(List<MTGDeck>.of(widget.decks));
    });
  }

  bool _sameSource(ScanCrop other) {
    if (identical(_source, other)) return true;
    if (_source.imagePath != other.imagePath ||
        _source.width != other.width ||
        _source.height != other.height ||
        _source.rectified != other.rectified ||
        _source.sourceCorners.length != other.sourceCorners.length) {
      return false;
    }
    for (int index = 0; index < _source.sourceCorners.length; index++) {
      if (_source.sourceCorners[index].x != other.sourceCorners[index].x ||
          _source.sourceCorners[index].y != other.sourceCorners[index].y) {
        return false;
      }
    }
    return true;
  }

  @override
  void didUpdateWidget(ScanCorrectionEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _publishGroups();
    if (!_sameSource(widget.crop)) {
      _generation++;
      _replaced = true;
      _busy = false;
      _error = 'Capture replaced';
    } else if (!_edited &&
        !identical(widget.initialResolution, oldWidget.initialResolution) &&
        widget.initialResolution != null) {
      _resolution = widget.initialResolution;
      _initialResolution ??= _resolution;
      _selectorGeneration++;
    }
  }

  @override
  void dispose() {
    _generation++;
    _groups.close();
    super.dispose();
  }

  void _confirm(PrintingSelection selection) {
    if (_busy || _replaced || !_sameSource(widget.crop)) return;
    if (selection.destinationId != null &&
        !widget.decks.any(
          (MTGDeck deck) => deck.id == selection.destinationId,
        )) {
      setState(() => _error = 'Destination unavailable');
      return;
    }
    widget.onConfirmed(selection);
  }

  void _close() {
    if (!_busy) widget.onClose();
  }

  Future<void> _run(
    Future<void> Function() action,
    String error, {
    bool close = false,
  }) async {
    if (_busy || _replaced) return;
    final int generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted || generation != _generation) return;
      if (close) widget.onClose();
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _error = error);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Widget _action(
    String id,
    String label,
    IconData icon,
    VoidCallback? action,
  ) => SizedBox(
    width: 44,
    height: 44,
    child: IconButton(
      key: ValueKey<String>('scan-correction-$id'),
      icon: Icon(icon, size: 20, semanticLabel: label),
      onPressed: _busy || (_replaced && id != 'close') ? null : action,
    ),
  );

  String? get _status => switch (widget.phase) {
    ScanItemPhase.processing || ScanItemPhase.retrying => 'Reading',
    ScanItemPhase.noIdentity => 'No match',
    ScanItemPhase.lookupFailed => 'Lookup failed',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final PrintingSelection? selection = _initialSelection;
    final MtgCard? evidence = _evidence;
    final String? status = _error ?? widget.lookupError ?? _status;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_busy) return;
          if (_evidence != null) {
            setState(() => _evidence = null);
          } else {
            widget.onClose();
          }
        },
      },
      child: ColoredBox(
        color: Theme.of(context).colorScheme.background,
        child: Column(
          key: const ValueKey<String>('scan-correction-editor'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        widget.progressLabel ?? status ?? 'Printing',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.onRetry != null)
                  _action(
                    'retry',
                    'Retry identification',
                    Icons.arrow_clockwise,
                    () => unawaited(_run(widget.onRetry!, 'Could not retry')),
                  ),
                if (widget.onLater != null)
                  _action('later', 'Later', Icons.arrow_right, widget.onLater),
                if (widget.onRescan != null)
                  _action('rescan', 'Rescan', Icons.camera, widget.onRescan),
                _action('close', 'Close correction', Icons.x, widget.onClose),
              ],
            ),
            if (widget.progressLabel != null && status != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(status, style: const TextStyle(fontSize: 12)),
                ),
              ),
            Expanded(
              child: IndexedStack(
                index: evidence == null ? 0 : 1,
                children: <Widget>[
                  IgnorePointer(
                    ignoring: _busy || _replaced,
                    child: CardPrintingSelector(
                      key: ValueKey<int>(_selectorGeneration),
                      catalog: widget.catalog,
                      groups: _groups.stream,
                      initialPrintings: _printings,
                      initialPrinting: _selected,
                      initialFinish:
                          selection?.card.finish ?? widget.preferredFinish,
                      initialQuantity:
                          selection?.quantity ?? widget.preferredQuantity,
                      initialDestinationId: selection == null
                          ? widget.preferredDeckId
                          : selection.destinationId,
                      initialDeckSection:
                          selection?.deckSection ?? widget.preferredDeckSection,
                      confirmLabel: widget.confirmLabel,
                      secondaryAction: widget.onRemove == null
                          ? null
                          : TextButton(
                              key: const ValueKey<String>(
                                'scan-correction-remove',
                              ),
                              onPressed: _busy || _replaced
                                  ? null
                                  : () => unawaited(
                                      _run(
                                        widget.onRemove!,
                                        'Could not remove',
                                        close: true,
                                      ),
                                    ),
                              child: const Text(
                                'Remove',
                                style: TextStyle(fontSize: 14),
                              ),
                            ),
                      onSelected: _confirm,
                      onCancel: _close,
                      onEdited: () => _edited = true,
                      onPrintingArtworkTap: (MtgCard card) =>
                          setState(() => _evidence = card),
                    ),
                  ),
                  if (evidence != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        SizedBox(
                          height: 44,
                          child: TextButton(
                            key: const ValueKey<String>(
                              'scan-correction-artwork',
                            ),
                            onPressed: () => setState(() => _evidence = null),
                            child: const Text('Artwork'),
                          ),
                        ),
                        Expanded(
                          child: ScanPrintingEvidence(
                            initialResolution: _initialResolution,
                            candidate:
                                _initialResolution?.candidates
                                    .where(
                                      (ScanCandidate candidate) =>
                                          candidate.card.id == evidence.id,
                                    )
                                    .firstOrNull ??
                                ScanCandidate(evidence, const <ScanEvidence>{}),
                            crop: _source,
                          ),
                        ),
                      ],
                    )
                  else
                    const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
