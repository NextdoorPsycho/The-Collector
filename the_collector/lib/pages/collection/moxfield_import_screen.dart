import 'package:arcane/arcane.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/card/card_add_dialog.dart';
import 'package:the_collector/pages/collection/card/card_thumbnail.dart';
import 'package:the_collector/theme/collector_brand.dart';
import 'package:the_collector/theme/collector_navigation.dart';
import 'package:the_collector/utils/collection_organization.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/moxfield_import.dart';

enum _ImportView { ready, attention, destination }

class MoxfieldImportScreen extends StatefulWidget {
  const MoxfieldImportScreen({
    super.key,
    required this.groups,
    this.service,
    this.parentId,
    this.pickFile,
    this.pickPrinting,
    this.catalog,
    this.organization,
  });

  final CollectionStore<MTGDeck> groups;
  final MoxfieldImportService? service;
  final String? parentId;
  final Future<XFile?> Function()? pickFile;
  final Future<PrintingSelection?> Function(BuildContext)? pickPrinting;
  final CardCatalog? catalog;
  final CollectionOrganization? organization;

  @override
  State<MoxfieldImportScreen> createState() => _MoxfieldImportScreenState();
}

class _MoxfieldImportScreenState extends State<MoxfieldImportScreen> {
  final TextEditingController _source = TextEditingController();
  final TextEditingController _name = TextEditingController();
  late final MoxfieldImportService _service =
      widget.service ?? MoxfieldImportService();
  late final CollectionOrganization _organization = CollectionOrganization(
    groups: widget.groups,
  );
  late final Stream<List<MTGDeck>> _folders = widget.groups.streamAll();
  final FocusNode _shortcutFocus = FocusNode(debugLabel: 'Moxfield import');
  _ImportView _view = _ImportView.ready;
  CollectionGroupKind _kind = CollectionGroupKind.deck;
  MoxfieldImportPreview? _preview;
  List<MoxfieldResolvedEntry> _entries = <MoxfieldResolvedEntry>[];
  List<MoxfieldImportIssue> _issues = <MoxfieldImportIssue>[];
  MoxfieldImportRow? _editingRow;
  MoxfieldImportIssue? _editingIssue;
  int? _editingIndex;
  late String? _parentId = widget.parentId;
  int _page = 0;
  String? _sourceName;
  String? _operationId;
  String? _error;
  bool _reading = false;
  bool _choosingFile = false;
  bool _saving = false;
  bool _acceptedPrintings = false;
  int _generation = 0;
  int _resolved = 0;
  int _total = 0;

  @override
  void dispose() {
    _generation++;
    _source.dispose();
    _name.dispose();
    _shortcutFocus.dispose();
    if (widget.service == null) _service.close();
    super.dispose();
  }

  void _close() {
    if (_saving) return;
    if (_editingRow != null) {
      _cancelPrinting();
      return;
    }
    if (_view == _ImportView.destination) {
      setState(
        () => _view = _attentionCount == 0
            ? _ImportView.ready
            : _ImportView.attention,
      );
      return;
    }
    _generation++;
    Navigator.pop(context);
  }

  void _edit() {
    if (_saving) return;
    _generation++;
    setState(() {
      _reading = false;
      _preview = null;
      _entries = <MoxfieldResolvedEntry>[];
      _issues = <MoxfieldImportIssue>[];
      _editingRow = null;
      _editingIndex = null;
      _editingIssue = null;
      _page = 0;
      _view = _ImportView.ready;
      _error = null;
      _operationId = null;
      _acceptedPrintings = false;
    });
    _shortcutFocus.requestFocus();
  }

  Future<void> _paste() async {
    if (_reading || _saving) return;
    final int generation = _generation;
    try {
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted ||
          generation != _generation ||
          data?.text == null ||
          _saving ||
          _reading) {
        return;
      }
      setState(() {
        _source.text = data!.text!;
        _sourceName = null;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = 'Could not paste. Choose an export file instead.',
        );
      }
    }
  }

  Future<void> _file() async {
    if (_saving || _reading || _choosingFile) return;
    final int generation = _generation;
    _choosingFile = true;
    try {
      final XFile? file =
          await (widget.pickFile?.call() ??
              openFile(
                acceptedTypeGroups: const <XTypeGroup>[
                  XTypeGroup(
                    label: 'Moxfield export',
                    extensions: <String>['csv', 'txt'],
                    uniformTypeIdentifiers: <String>[
                      'public.plain-text',
                      'public.comma-separated-values-text',
                    ],
                  ),
                ],
              ));
      if (file == null || !mounted || generation != _generation) return;
      if (await file.length() > 2 * 1024 * 1024) {
        throw const FormatException('Choose an export no larger than 2 MiB.');
      }
      final String source = await file.readAsString();
      if (!mounted || generation != _generation || _reading || _saving) return;
      setState(() {
        _source.text = source;
        _sourceName = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
        _error = null;
      });
      await _read();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : 'Could not read that export. Choose a CSV or text file.',
        );
      }
    } finally {
      _choosingFile = false;
    }
  }

  Future<void> _read() async {
    if (_reading || _saving || _source.text.trim().isEmpty) return;
    final int generation = ++_generation;
    FocusScope.of(context).unfocus();
    setState(() {
      _reading = true;
      _error = null;
      _resolved = 0;
      _total = 0;
    });
    try {
      final MoxfieldImportPreview preview = await _service.prepare(
        _source.text,
        sourceName: _sourceName,
        isCancelled: () => !mounted || generation != _generation,
        onProgress: (int resolved, int total) {
          if (mounted && generation == _generation) {
            setState(() {
              _resolved = resolved;
              _total = total;
            });
          }
        },
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _preview = preview;
        _entries = List<MoxfieldResolvedEntry>.of(preview.entries);
        _issues = List<MoxfieldImportIssue>.of(preview.issues);
        _name.text = preview.document.sourceName;
        _acceptedPrintings = false;
        _operationId = widget.groups.collection.doc().id;
        _page = 0;
        _view = _attentionCount == 0
            ? _ImportView.ready
            : _ImportView.attention;
      });
      _shortcutFocus.requestFocus();
    } on MoxfieldImportCancelled {
      return;
    } on MoxfieldImportException catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => _error =
              'Could not read this list. Retry or choose a Moxfield export.',
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _reading = false);
        _shortcutFocus.requestFocus();
      }
    }
  }

  Future<void> _printing(int index) async {
    if (_saving || _reading) return;
    await _correct(_entries[index].row, index: index);
  }

  Future<void> _correct(
    MoxfieldImportRow row, {
    int? index,
    MoxfieldImportIssue? issue,
  }) async {
    if (_saving || _reading) return;
    final int generation = _generation;
    setState(() {
      _editingRow = row;
      _editingIndex = index;
      _editingIssue = issue;
    });
    if (widget.pickPrinting != null) {
      final PrintingSelection? selection = await widget.pickPrinting!(context);
      if (!mounted || generation != _generation || _editingRow != row) return;
      if (selection == null) {
        _cancelPrinting();
      } else {
        _applyPrinting(selection);
      }
    }
  }

  void _cancelPrinting() => setState(() {
    _editingRow = null;
    _editingIndex = null;
    _editingIssue = null;
  });

  void _applyPrinting(PrintingSelection selection) {
    final MoxfieldImportRow? row = _editingRow;
    if (row == null || _saving || selection.card.printingId == null) return;
    final int? index = _editingIndex;
    final DeckEntry? previous = index == null ? null : _entries[index].entry;
    final MoxfieldResolvedEntry replacement = MoxfieldResolvedEntry(
      row: row,
      card: selection.card,
      exactPrinting: true,
      entry: DeckEntry(
        scryfallId: selection.card.printingId!,
        finish: selection.card.finish,
        language: selection.card.language,
        quantity: previous?.quantity ?? row.quantity,
        section: previous?.section ?? row.section,
        condition: previous?.condition ?? row.condition,
      ),
    );
    setState(() {
      if (index == null) {
        _entries.add(replacement);
      } else {
        _entries[index] = replacement;
      }
      if (_editingIssue != null) _issues.remove(_editingIssue);
      _editingRow = null;
      _editingIndex = null;
      _editingIssue = null;
      _page = 0;
      _view = _attentionCount == 0 ? _ImportView.ready : _ImportView.attention;
      _operationId = widget.groups.collection.doc().id;
    });
    _shortcutFocus.requestFocus();
  }

  int get _suggestions => _entries
      .where((MoxfieldResolvedEntry entry) => !entry.exactPrinting)
      .length;
  int get _attentionCount =>
      _issues.length + (_acceptedPrintings ? 0 : _suggestions);
  int get _readyCount =>
      _entries.length - (_acceptedPrintings ? 0 : _suggestions);
  int get _resolvedQuantity => _entries.fold(
    0,
    (int total, MoxfieldResolvedEntry entry) => total + entry.entry.quantity,
  );

  MoxfieldImportRow? _issueRow(MoxfieldImportIssue issue) =>
      issue.kind == MoxfieldImportIssueKind.lookup
      ? _preview?.document.rows
            .where(
              (MoxfieldImportRow row) =>
                  row.line == issue.line && row.source == issue.source,
            )
            .firstOrNull
      : null;

  bool get _canImport =>
      !_reading &&
      !_saving &&
      _preview != null &&
      _issues.isEmpty &&
      _resolvedQuantity == _preview!.totalQuantity &&
      _entries.isNotEmpty &&
      _name.text.trim().isNotEmpty &&
      (_acceptedPrintings ||
          _entries.every((MoxfieldResolvedEntry entry) => entry.exactPrinting));

  Future<void> _save() async {
    if (!_canImport) return;
    final MoxfieldImportDocument source = _preview!.document;
    final DeckFormat format = switch (source.deckFormat?.toLowerCase()) {
      'commander' || 'edh' => DeckFormat.commander,
      'standard' => DeckFormat.standard,
      _ => DeckFormat.casual,
    };
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final String id = await (widget.organization ?? _organization)
          .createGroup(
            name: _name.text.trim(),
            kind: _kind,
            parentId: _parentId,
            sourceUrl: source.sourceUrl,
            sourceFormat: source.deckFormat,
            entries: _entries
                .map((MoxfieldResolvedEntry entry) => entry.entry)
                .toList(),
            format: _kind == CollectionGroupKind.deck
                ? format
                : DeckFormat.casual,
            operationId: _operationId,
          );
      if (mounted) Navigator.pop(context, id);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StateError
              ? error.message
              : error is FormatException
              ? error.message
              : 'Could not save the import. Retry with this preview.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _sourceForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      TextField(
        key: const ValueKey<String>('moxfield-source'),
        semanticLabel: 'Moxfield link or export',
        controller: _source,
        enabled: !_reading,
        minLines: 3,
        maxLines: 6,
        textInputAction: TextInputAction.newline,
        placeholder: const Text('Public Moxfield URL or TXT / CSV'),
        onChanged: (String _) => setState(() => _sourceName = null),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: <Widget>[
          _touch(
            SecondaryButton(
              key: const ValueKey<String>('moxfield-file'),
              onPressed: _reading ? null : _file,
              child: const Text('Open file', style: TextStyle(fontSize: 14)),
            ),
          ),
          _touch(
            TextButton(
              onPressed: _reading ? null : _paste,
              child: const Text('Paste', style: TextStyle(fontSize: 14)),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        'TXT / CSV · 2 MiB · 10,000 rows',
        style: TextStyle(fontSize: 12),
      ),
      if (_reading) ...<Widget>[
        const SizedBox(height: 16),
        CollectorLoading(
          label: _total == 0
              ? 'Reading list…'
              : 'Matching $_resolved / $_total cards…',
        ),
      ],
    ],
  );

  String _kindLabel(CollectionGroupKind kind) => switch (kind) {
    CollectionGroupKind.deck => 'Deck',
    CollectionGroupKind.binder => 'Binder',
    CollectionGroupKind.box => 'Box',
    CollectionGroupKind.folder => 'Folder',
    CollectionGroupKind.list => 'List',
  };

  Widget _touch(Widget child) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    child: child,
  );

  Widget _destinationEditor() => ListView(
    key: const ValueKey<String>('moxfield-destination-editor'),
    children: <Widget>[
      TextField(
        key: const ValueKey<String>('moxfield-name'),
        semanticLabel: 'Imported container name',
        controller: _name,
        enabled: !_saving,
        placeholder: const Text('Group name'),
        onChanged: (String _) =>
            setState(() => _operationId = widget.groups.collection.doc().id),
      ),
      const SizedBox(height: 8),
      _touch(
        Selector<CollectionGroupKind>(
          key: const ValueKey<String>('moxfield-kind'),
          value: _kind,
          values: CollectionGroupKind.values,
          labelBuilder: _kindLabel,
          onChanged: _saving
              ? null
              : (CollectionGroupKind? kind) => setState(() {
                  _kind = kind ?? CollectionGroupKind.deck;
                  _operationId = widget.groups.collection.doc().id;
                }),
        ),
      ),
      const SizedBox(height: 8),
      StreamBuilder<List<MTGDeck>>(
        stream: _folders,
        builder: (BuildContext context, AsyncSnapshot<List<MTGDeck>> snapshot) {
          final List<MTGDeck> folders = (snapshot.data ?? <MTGDeck>[])
              .where(
                (MTGDeck group) => group.kind == CollectionGroupKind.folder,
              )
              .toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _touch(
                Selector<String>(
                  key: const ValueKey<String>('moxfield-parent'),
                  value: _parentId ?? '',
                  values: <String>{
                    '',
                    ...folders
                        .map((MTGDeck group) => group.id)
                        .whereType<String>(),
                    ?_parentId,
                  }.toList(),
                  labelBuilder: (String id) => id.isEmpty
                      ? 'No parent folder'
                      : folders
                                .where((MTGDeck group) => group.id == id)
                                .firstOrNull
                                ?.name ??
                            (snapshot.hasData
                                ? 'Unavailable folder'
                                : 'Selected folder'),
                  onChanged: _saving
                      ? null
                      : (String? id) => setState(() {
                          _parentId = id == null || id.isEmpty ? null : id;
                          _operationId = widget.groups.collection.doc().id;
                        }),
                ),
              ),
              if (snapshot.hasError)
                const Text(
                  'Folders unavailable',
                  style: TextStyle(fontSize: 12),
                ),
            ],
          );
        },
      ),
      const SizedBox(height: 12),
      const Text(
        'Owned quantities stay unchanged.',
        style: TextStyle(fontSize: 12),
      ),
    ],
  );

  Widget _entryRow(int index) => _touch(
    CardButton(
      key: ValueKey<String>('moxfield-entry-$index'),
      onPressed: _saving ? null : () => _printing(index),
      child: Row(
        children: <Widget>[
          CardThumbnail(card: _entries[index].card, width: 32),
          const SizedBox(width: 8),
          Text(
            '${_entries[index].entry.quantity}×',
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _entries[index].card.name,
                  style: const TextStyle(fontSize: 14),
                ),
                Text(
                  '${_entries[index].card.setCode?.toUpperCase() ?? ""} #${_entries[index].card.collectorNumber ?? "?"} · ${_entries[index].entry.section.name} · ${_entries[index].entry.finish?.name == "nonfoil" ? "Normal" : _entries[index].entry.finish?.name ?? ""}',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            _entries[index].exactPrinting || _acceptedPrintings
                ? Icons.check
                : Icons.pencil,
            size: 16,
          ),
        ],
      ),
    ),
  );

  Widget _issueCard(MoxfieldImportIssue issue) {
    final MoxfieldImportRow? row = _issueRow(issue);
    return _touch(
      CardButton(
        key: ValueKey<String>('moxfield-issue-${issue.line}'),
        onPressed: _saving
            ? null
            : () => row == null ? _edit() : _correct(row, issue: issue),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Line ${issue.line}: ${issue.message}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    row?.name ?? issue.source,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    row == null ? 'Edit source' : 'Choose printing',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.pencil, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _viewControl(_ImportView view, String label) => _touch(
    Button(
      style: _view == view
          ? const ButtonStyle.primary()
          : const ButtonStyle.outline(),
      onPressed: _saving
          ? null
          : () => setState(() {
              _view = view;
              _page = 0;
            }),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    ),
  );

  Widget _approval() => _touch(
    TextButton(
      key: const ValueKey<String>('moxfield-approve-printings'),
      onPressed: _saving
          ? null
          : () => setState(() {
              _acceptedPrintings = true;
              _page = 0;
              if (_attentionCount == 0) _view = _ImportView.ready;
            }),
      child: Text(
        'Approve $_suggestions ${_suggestions == 1 ? "suggested printing" : "suggested printings"}',
        style: const TextStyle(fontSize: 12),
      ),
    ),
  );

  Widget _previewContent() {
    final List<Widget Function()> rows = <Widget Function()>[
      if (_view == _ImportView.attention)
        for (final MoxfieldImportIssue issue in _issues)
          () => _issueCard(issue),
      for (int index = 0; index < _entries.length; index++)
        if ((_entries[index].exactPrinting || _acceptedPrintings) ==
            (_view == _ImportView.ready))
          () => _entryRow(index),
    ];
    final bool largeText = MediaQuery.textScalerOf(context).scale(14) > 21;
    final int pageSize = largeText ? 2 : 4;
    final int pageCount = rows.isEmpty ? 1 : (rows.length / pageSize).ceil();
    final int page = _page.clamp(0, pageCount - 1);
    return ListView(
      key: const ValueKey<String>('moxfield-preview'),
      children: <Widget>[
        _touch(
          CardButton(
            key: const ValueKey<String>('moxfield-destination'),
            onPressed: _saving
                ? null
                : () => setState(() => _view = _ImportView.destination),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _name.text,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(_kindLabel(_kind), style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 6),
                const Icon(Icons.pencil, size: 16),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${_preview!.totalQuantity} cards · ${_entries.length} ${_entries.length == 1 ? "printing" : "printings"}',
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            _viewControl(_ImportView.ready, 'Ready · $_readyCount'),
            _viewControl(
              _ImportView.attention,
              'Needs attention · $_attentionCount',
            ),
          ],
        ),
        if (_view == _ImportView.attention &&
            !_acceptedPrintings &&
            _suggestions > 0)
          _approval(),
        const SizedBox(height: 6),
        if (rows.isEmpty)
          Text(
            _view == _ImportView.ready
                ? 'No ready printings'
                : 'Nothing to correct',
            style: const TextStyle(fontSize: 12),
          ),
        ...rows
            .skip(page * pageSize)
            .take(pageSize)
            .map((Widget Function() build) => build()),
        if (pageCount > 1)
          Row(
            children: <Widget>[
              _touch(
                IconButton(
                  icon: const Icon(
                    Icons.caret_left,
                    semanticLabel: 'Previous import page',
                  ),
                  onPressed: page == 0
                      ? null
                      : () => setState(() => _page = page - 1),
                ),
              ),
              Expanded(
                child: Text(
                  '${page + 1} / $pageCount',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              _touch(
                IconButton(
                  icon: const Icon(
                    Icons.caret_right,
                    semanticLabel: 'Next import page',
                  ),
                  onPressed: page + 1 == pageCount
                      ? null
                      : () => setState(() => _page = page + 1),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _footer() => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final Widget controls = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _touch(
            TextButton(
              key: const ValueKey<String>('moxfield-cancel'),
              onPressed: _saving ? null : _close,
              child: const Text('Cancel', style: TextStyle(fontSize: 14)),
            ),
          ),
          if (_preview != null)
            _touch(
              TextButton(
                onPressed: _saving ? null : _edit,
                child: const Text('Edit', style: TextStyle(fontSize: 14)),
              ),
            ),
        ],
      );
      final Widget submit = _touch(
        PrimaryButton(
          key: const ValueKey<String>('moxfield-submit'),
          onPressed: _preview == null
              ? (_reading || _source.text.trim().isEmpty ? null : _read)
              : (_canImport ? _save : null),
          child: Text(
            _saving
                ? 'Saving…'
                : _preview == null
                ? 'Read list'
                : 'Create ${_kind.name}',
            style: const TextStyle(fontSize: 14),
          ),
        ),
      );
      final bool stacked = MediaQuery.textScalerOf(context).scale(14) > 22;
      final Widget actions = stacked
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                submit,
                Align(alignment: Alignment.centerLeft, child: controls),
              ],
            )
          : Row(
              children: <Widget>[
                controls,
                const SizedBox(width: 8),
                Expanded(child: submit),
              ],
            );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 80),
                child: SingleChildScrollView(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(_error!, style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ),
            ),
          if (_error != null &&
              _preview == null &&
              _source.text.trim().startsWith('https://'))
            _touch(
              TextButton(
                onPressed: _reading ? null : _file,
                child: const Text(
                  'Use TXT / CSV',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          actions,
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.escape): _close,
    },
    child: Focus(
      autofocus: true,
      focusNode: _shortcutFocus,
      child: PopScope(
        canPop: !_saving,
        child: Scaffold(
          headers: <Widget>[
            if (!usesSwipeBack)
              AppBar(
                leading: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.arrow_left),
                    onPressed: _saving ? null : _close,
                  ),
                ],
              ),
          ],
          child: _editingRow != null
              ? CardPrintingSelector(
                  key: ValueKey<String>(
                    'moxfield-correction-${_editingRow!.line}',
                  ),
                  printingOnly: true,
                  catalog: widget.catalog,
                  initialQuery:
                      '!"${_editingRow!.name.replaceAll('"', '\\"')}"',
                  initialFinish: _editingIndex == null
                      ? _editingRow!.finish
                      : _entries[_editingIndex!].entry.finish ??
                            sf.Finish.nonfoil,
                  initialQuantity: _editingIndex == null
                      ? _editingRow!.quantity
                      : _entries[_editingIndex!].entry.quantity,
                  initialDeckSection: _editingIndex == null
                      ? _editingRow!.section
                      : _entries[_editingIndex!].entry.section,
                  confirmLabel: 'Use printing',
                  onSelected: _applyPrinting,
                  onCancel: _cancelPrinting,
                )
              : SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const Text(
                          'Import from Moxfield',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _view == _ImportView.destination
                              ? _destinationEditor()
                              : _preview == null
                              ? SingleChildScrollView(child: _sourceForm())
                              : _previewContent(),
                        ),
                        const SizedBox(height: 8),
                        if (_view == _ImportView.destination)
                          _touch(
                            PrimaryButton(
                              onPressed: () => setState(
                                () => _view = _attentionCount == 0
                                    ? _ImportView.ready
                                    : _ImportView.attention,
                              ),
                              child: const Text(
                                'Done',
                                style: TextStyle(fontSize: 14),
                              ),
                            ),
                          )
                        else
                          _footer(),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    ),
  );
}
