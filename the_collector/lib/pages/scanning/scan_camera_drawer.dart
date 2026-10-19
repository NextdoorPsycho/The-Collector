import 'dart:async';
import 'dart:math' as math;

import 'package:arcane/arcane.dart';
import 'package:scryfall_api/scryfall_api.dart' hide Color;

import '../../utils/scanning/scan_recognition.dart';
import '../../utils/scanning/scan_session.dart';

class ScanCameraDrawer extends StatefulWidget {
  const ScanCameraDrawer({
    super.key,
    required this.items,
    required this.submittedIds,
    required this.pendingPhotos,
    required this.busy,
    required this.error,
    required this.lastAddedName,
    required this.lastAddedId,
    required this.canUndo,
    required this.onUndo,
    required this.onEdit,
    required this.onRemove,
  });

  final List<ScanSessionItem> items;
  final Set<String> submittedIds;
  final int pendingPhotos;
  final bool busy;
  final String? error;
  final String? lastAddedName;
  final String? lastAddedId;
  final bool Function(String) canUndo;
  final Future<void> Function(String) onUndo;
  final Future<void> Function(ScanSessionItem) onEdit;
  final Future<void> Function(ScanSessionItem) onRemove;

  @override
  State<ScanCameraDrawer> createState() => _ScanCameraDrawerState();
}

class _ScanCameraDrawerState extends State<ScanCameraDrawer> {
  bool _expanded = false;
  int _page = 0;
  String? _working;
  String? _error;

  List<ScanSessionItem> get _needsCheck => widget.items
      .where(
        (ScanSessionItem item) =>
            !widget.submittedIds.contains(item.id) &&
            (item.phase == ScanItemPhase.needsReview ||
                item.phase == ScanItemPhase.noIdentity ||
                item.phase == ScanItemPhase.lookupFailed),
      )
      .toList();

  bool _current(ScanSessionItem item, ScanCrop crop) =>
      widget.items.any((ScanSessionItem current) => identical(current, item)) &&
      identical(item.crop, crop) &&
      !widget.submittedIds.contains(item.id);

  Future<void> _edit(ScanSessionItem item, ScanCrop crop) async {
    if (widget.busy || _working != null || !_current(item, crop)) return;
    setState(() {
      _working = item.id;
      _error = null;
    });
    try {
      await widget.onEdit(item);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open correction');
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  Future<void> _remove(ScanSessionItem item, ScanCrop crop) async {
    if (widget.busy || _working != null || !_current(item, crop)) return;
    setState(() {
      _working = item.id;
      _error = null;
    });
    try {
      await widget.onRemove(item);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not remove');
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  Future<void> _undo(String id) async {
    if (widget.busy || _working != null || !widget.canUndo(id)) return;
    setState(() {
      _working = id;
      _error = null;
    });
    try {
      await widget.onUndo(id);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not undo');
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  String _name(ScanSessionItem item) =>
      item.approval?.card.name ??
      item.printing?.name ??
      item.liveIdentityName ??
      'Unidentified card';

  String _status(ScanSessionItem item) {
    if (widget.submittedIds.contains(item.id)) return 'Added';
    return switch (item.phase) {
      ScanItemPhase.processing || ScanItemPhase.retrying => 'Reading',
      ScanItemPhase.noIdentity => 'No match',
      ScanItemPhase.lookupFailed => 'Lookup failed',
      ScanItemPhase.ready => 'Ready',
      ScanItemPhase.needsReview =>
        item.printing == null
            ? 'Needs check'
            : '${item.printing!.set.toUpperCase()} ${item.printing!.collectorNumber}',
    };
  }

  Widget _artwork(ScanSessionItem item) {
    final MtgCard? printing = item.printing;
    final Uri? uri =
        (printing?.imageUris ?? printing?.cardFaces?.firstOrNull?.imageUris)
            ?.small;
    final Widget fallback = Center(
      child: Icon(
        Icons.cards,
        size: 20,
        color: Theme.of(context).colorScheme.foreground,
      ),
    );
    return SizedBox(
      width: 34,
      height: 46,
      child: uri == null
          ? fallback
          : Image.network(
              uri.toString(),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }

  Widget _row(ScanSessionItem item, {required bool check}) {
    final ScanCrop source = item.crop;
    return SizedBox(
      height: MediaQuery.textScalerOf(context).scale(13) > 20 ? 88 : 54,
      child: Row(
        children: <Widget>[
          Expanded(
            child: GhostButton(
              key: ValueKey<String>(
                'camera-drawer-${check ? 'check' : 'latest'}-${item.id}',
              ),
              density: ButtonDensity.compact,
              onPressed:
                  widget.busy ||
                      _working != null ||
                      widget.submittedIds.contains(item.id)
                  ? null
                  : () => unawaited(_edit(item, source)),
              child: Row(
                children: <Widget>[
                  _artwork(item),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _name(item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _status(item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.pencil_simple,
                    size: 18,
                    semanticLabel: 'Correct ${_name(item)}',
                  ),
                ],
              ),
            ),
          ),
          if (!widget.submittedIds.contains(item.id)) ...<Widget>[
            const SizedBox(width: 4),
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                key: ValueKey<String>('camera-drawer-remove-${item.id}'),
                icon: Icon(
                  Icons.x,
                  size: 20,
                  semanticLabel: 'Remove ${_name(item)}',
                ),
                onPressed: widget.busy || _working != null
                    ? null
                    : () => unawaited(_remove(item, source)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _receipt(String id, String name) => Row(
    children: <Widget>[
      Expanded(
        child: Semantics(
          liveRegion: true,
          child: Text(
            'Added · $name',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      SizedBox(
        height: 44,
        child: TextButton(
          key: const ValueKey<String>('camera-drawer-undo'),
          onPressed: widget.busy || _working != null || !widget.canUndo(id)
              ? null
              : () => unawaited(_undo(id)),
          child: const Text('Undo', style: TextStyle(fontSize: 13)),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints bounds) {
      final bool largeText = MediaQuery.textScalerOf(context).scale(13) > 20;
      final List<ScanSessionItem> checks = _needsCheck;
      final ScanSessionItem? latest = widget.items.lastOrNull;
      final int pageSize =
          largeText || (bounds.hasBoundedHeight && bounds.maxHeight < 260)
          ? 1
          : 3;
      final int pages = math.max(1, (checks.length / pageSize).ceil());
      final int page = math.min(_page, pages - 1);
      final String? error = _error ?? widget.error;
      final String? addedId = widget.lastAddedId;
      final String? addedName = widget.lastAddedName;
      final bool receipt = addedId != null && addedName != null;
      return Container(
        key: const ValueKey<String>('camera-drawer'),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.background,
          border: Border.all(color: Theme.of(context).colorScheme.foreground),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (receipt && !_expanded) _receipt(addedId, addedName),
            if (checks.isNotEmpty)
              SizedBox(
                height: 44,
                child: TextButton(
                  key: const ValueKey<String>('camera-drawer-needs-check'),
                  onPressed: widget.busy
                      ? null
                      : () => setState(() => _expanded = !_expanded),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          'Needs check ${checks.length}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.caret_down : Icons.caret_up,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
            if (_expanded && checks.isNotEmpty) ...<Widget>[
              for (final ScanSessionItem item
                  in checks.skip(page * pageSize).take(pageSize))
                _row(item, check: true),
              if (pages > 1)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: IconButton(
                        key: const ValueKey<String>('camera-drawer-previous'),
                        icon: const Icon(
                          Icons.caret_left,
                          semanticLabel: 'Previous captures',
                        ),
                        onPressed: page == 0 || widget.busy
                            ? null
                            : () => setState(() => _page = page - 1),
                      ),
                    ),
                    Text(
                      '${page + 1} / $pages',
                      style: const TextStyle(fontSize: 12),
                    ),
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: IconButton(
                        key: const ValueKey<String>('camera-drawer-next'),
                        icon: const Icon(
                          Icons.caret_right,
                          semanticLabel: 'Next captures',
                        ),
                        onPressed: page + 1 >= pages || widget.busy
                            ? null
                            : () => setState(() => _page = page + 1),
                      ),
                    ),
                  ],
                ),
            ] else if (!receipt && latest != null)
              _row(latest, check: false)
            else if (!receipt && checks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  widget.pendingPhotos > 0
                      ? 'Reading ${widget.pendingPhotos}'
                      : 'Ready',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
