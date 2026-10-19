import 'package:arcane/arcane.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/theme/collector_brand.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/external_links.dart';
import 'package:the_collector/utils/rules_reference.dart';

typedef RulesLoader = Future<RulesReference> Function({bool refresh});
typedef CardRulingsLoader = Future<List<Ruling>> Function(String cardId);

class HubRules extends StatefulWidget {
  const HubRules({super.key, this.catalog, this.rulesLoader});
  final CardCatalog? catalog;
  final RulesLoader? rulesLoader;
  @override
  State<HubRules> createState() => _HubRulesState();
}

class _HubRulesState extends State<HubRules> {
  late final CardCatalog _catalog = widget.catalog ?? CardCatalog();
  final TextEditingController _cardSearch = TextEditingController();
  final TextEditingController _ruleSearch = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _comprehensive = false;
  Future<PaginableList<MtgCard>>? _results;
  Future<RulesReference>? _reference;
  String _submittedQuery = '';
  int _page = 1;
  String? _linkError;
  bool _sourceOpen = false;

  @override
  void initState() {
    super.initState();
    _ruleSearch.addListener(_rulesChanged);
  }

  void _rulesChanged() => setState(() {});
  Future<RulesReference> _load({bool refresh = false}) =>
      widget.rulesLoader?.call(refresh: refresh) ??
      RulesReference.load(refresh: refresh);

  @override
  void dispose() {
    if (widget.catalog == null) _catalog.close();
    _cardSearch.dispose();
    _ruleSearch.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _searchCards({String? query, int page = 1}) {
    final String text = (query ?? _cardSearch.text).trim();
    if (text.isEmpty) return;
    setState(() {
      _submittedQuery = text;
      _page = page;
      _results = _catalog.search(text, page: page);
    });
    FocusManager.instance.primaryFocus?.unfocus();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _mode(int index) => setState(() {
    _comprehensive = index == 1;
    if (_comprehensive) _reference ??= _load();
  });

  Future<void> _openRules() async {
    try {
      await openCollectorLink(RulesReference.index);
    } catch (_) {
      if (mounted) setState(() => _linkError = 'Could not open the rules website.');
    }
  }

  Widget _modes() => Wrap(
    spacing: 4,
    children: <Widget>[
      for (int index = 0; index < 2; index++)
        Semantics(
          selected: _comprehensive == (index == 1),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Button(
              key: ValueKey<String>(index == 0 ? 'rules-mode-card' : 'rules-mode-game'),
              style: _comprehensive == (index == 1)
                  ? const ButtonStyle.primary() : const ButtonStyle.ghost(),
              onPressed: () => _mode(index),
              child: Text(index == 0 ? 'Card rulings' : 'Game rules'),
            ),
          ),
        ),
    ],
  );

  Widget _query() => _comprehensive
      ? TextField(
          semanticLabel: 'Rule number or keyword',
          key: const ValueKey<String>('rules-rule-query'),
          controller: _ruleSearch,
          placeholder: const ExcludeSemantics(child: Text('Rule number or keyword')),
          onSubmitted: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          features: const <InputFeature>[
            InputFeature.clear(icon: Icon(LucideIcons.x, semanticLabel: 'Clear rule search')),
          ],
        )
      : Row(children: <Widget>[
          Expanded(child: TextField(
            semanticLabel: 'Card name or Scryfall query',
            key: const ValueKey<String>('rules-card-query'),
            controller: _cardSearch,
            placeholder: const ExcludeSemantics(child: Text('Card name or Scryfall query')),
            onSubmitted: (_) => _searchCards(),
            features: const <InputFeature>[
              InputFeature.clear(icon: Icon(LucideIcons.x, semanticLabel: 'Clear card search')),
            ],
          )),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: SecondaryButton(
              key: const ValueKey<String>('rules-card-search'),
              onPressed: _searchCards,
              child: const Text('Search'),
            ),
          ),
        ]);

  Widget _message(Widget child) => SliverToBoxAdapter(
    child: Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: child),
  );

  Widget _resultRow({required String title, required String detail, required VoidCallback open}) =>
      Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.border))),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Button(
            style: const ButtonStyle.ghost(),
            alignment: Alignment.centerLeft,
            onPressed: open,
            child: SizedBox(
              width: double.infinity,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 4),
                Text(detail, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              ]),
            ),
          ),
        ),
      );

  Widget _cards() {
    final Future<PaginableList<MtgCard>>? pending = _results;
    if (pending == null) return _message(const Text('Search a card for Oracle text and rulings.'));
    final String query = _submittedQuery;
    final int page = _page;
    return FutureBuilder<PaginableList<MtgCard>>(
      future: pending,
      builder: (BuildContext context, AsyncSnapshot<PaginableList<MtgCard>> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _message(const CollectorLoading(label: 'Finding cards…'));
        }
        if (snapshot.hasError) {
          return _message(Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text('Could not search “$query”. Check your connection.'),
            const SizedBox(height: 8),
            SecondaryButton(onPressed: () => _searchCards(query: query, page: page),
              child: const Text('Retry search')),
          ]));
        }
        final PaginableList<MtgCard> result = snapshot.data!;
        if (result.data.isEmpty) {
          return _message(Text('No cards found for “$query”. Try another name or query.'));
        }
        return SliverMainAxisGroup(slivers: <Widget>[
          SliverList.builder(
            itemCount: result.data.length,
            itemBuilder: (BuildContext context, int index) {
              final MtgCard card = result.data[index];
              return _resultRow(
                title: card.name, detail: card.typeLine,
                open: () => Arcane.push<void>(context, CardRulingsScreen(card: card, rulingsLoader: _catalog.rulings)),
              );
            },
          ),
          if (page > 1 || result.hasMore)
            SliverToBoxAdapter(child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
                if (page > 1)
                  SecondaryButton(
                    key: const ValueKey<String>('rules-page-previous'),
                    onPressed: () => _searchCards(query: query, page: page - 1),
                    child: const Text('Previous page'),
                  ),
                Text('Page $page', style: const TextStyle(fontSize: 13)),
                if (result.hasMore)
                  SecondaryButton(
                    key: const ValueKey<String>('rules-page-next'),
                    onPressed: () => _searchCards(query: query, page: page + 1),
                    child: const Text('Next page'),
                  ),
              ]),
            )),
        ]);
      },
    );
  }

  Widget _rules() => FutureBuilder<RulesReference>(
    future: _reference,
    builder: (BuildContext context, AsyncSnapshot<RulesReference> snapshot) {
      if (!snapshot.hasData && snapshot.connectionState != ConnectionState.done) {
        return _message(const CollectorLoading(label: 'Loading official rules…'));
      }
      if (snapshot.hasError) {
        return _message(Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Text('Could not download the rules. Check your connection.'),
          const SizedBox(height: 8),
          SecondaryButton(onPressed: () => setState(() { _reference = _load(refresh: true); }),
            child: const Text('Retry download')),
          TextButton(onPressed: _openRules, child: const Text('Open official rules')),
          if (_linkError != null) Text(_linkError!),
        ]));
      }
      final RulesReference reference = snapshot.data!;
      final String query = _ruleSearch.text.trim();
      final bool browsing = query.isEmpty;
      final List<RuleParagraph> matches = browsing ? reference.sections : reference.find(query);
      return SliverMainAxisGroup(slivers: <Widget>[
        SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
            TextButton(
              key: const ValueKey<String>('rules-source'),
              onPressed: () => setState(() => _sourceOpen = !_sourceOpen),
              child: Text(reference.savedOffline ? 'Official rules · Offline' : 'Official rules'),
            ),
            Text('${matches.length} ${matches.length == 1 ? 'result' : 'results'}', style: const TextStyle(fontSize: 12)),
          ]),
          if (_sourceOpen) ...<Widget>[
            Text('Wizards of the Coast · Saved ${reference.fetchedAt.toIso8601String().split('T').first}',
              style: const TextStyle(fontSize: 12)),
            Wrap(spacing: 8, children: <Widget>[
              TextButton(onPressed: _openRules, child: const Text('Source')),
              TextButton(
                onPressed: snapshot.connectionState == ConnectionState.done
                  ? () => setState(() { _reference = _load(refresh: true); }) : null,
                child: Text(snapshot.connectionState == ConnectionState.done
                  ? 'Check for updates' : 'Checking for updates…'),
              ),
            ]),
            if (_linkError != null) Text(_linkError!),
          ],
          if (reference.updateFailed)
            const Text('Update unavailable. Showing the saved rules.', style: TextStyle(fontSize: 12)),
        ])),
        if (matches.isEmpty)
          _message(Text(query.length < 2 && !browsing ? 'Enter at least two characters.'
              : 'No matching rules. Try another keyword.'))
        else
          SliverList.builder(
            itemCount: matches.length,
            itemBuilder: (BuildContext context, int index) {
              final RuleParagraph paragraph = matches[index];
              return _resultRow(
                title: paragraph.label ?? paragraph.section ?? 'Rule',
                detail: paragraph.body,
                open: () {
                  final List<RuleParagraph> detail = browsing && paragraph.number != null
                      ? reference.find(paragraph.number!) : matches;
                  Arcane.push<void>(context, _RuleReadingScreen(
                    paragraphs: detail.isEmpty ? <RuleParagraph>[paragraph] : detail,
                    initialIndex: browsing ? 0 : index,
                  ));
                },
              );
            },
          ),
      ]);
    },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    child: CustomScrollView(controller: _scroll, slivers: <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        sliver: SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[_modes(), const SizedBox(height: 8), _query()])),
      ),
      SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 12),
        sliver: _comprehensive ? _rules() : _cards()),
    ]),
  );
}

class _RuleReadingScreen extends StatefulWidget {
  const _RuleReadingScreen({
    required this.paragraphs,
    required this.initialIndex,
  });
  final List<RuleParagraph> paragraphs;
  final int initialIndex;
  @override
  State<_RuleReadingScreen> createState() => _RuleReadingScreenState();
}

class _RuleReadingScreenState extends State<_RuleReadingScreen> {
  late int _index = widget.initialIndex;
  final ScrollController _scroll = ScrollController();

  void _showRule(int index) {
    setState(() => _index = index);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final RuleParagraph paragraph = widget.paragraphs[_index];
    return Scaffold(
      headers: <Widget>[
        Align(alignment: Alignment.centerRight, child: SizedBox.square(
          dimension: 44, child: MergeSemantics(child: Semantics(button: true, child: IconButton(
            key: const ValueKey<String>('rules-reader-close'),
            icon: const Icon(Icons.x, semanticLabel: 'Back to rules'),
            variance: ButtonVariance.ghost,
            onPressed: () => Navigator.pop(context),
          ))),
        )),
      ],
      footers: <Widget>[
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Semantics(
                label: 'Previous rule',
                button: true,
                child: IconButton(
                  icon: const Icon(Icons.arrow_left),
                  onPressed: _index == 0 ? null : () => _showRule(_index - 1),
                ),
              ),
              Text('${_index + 1} / ${widget.paragraphs.length}'),
              Semantics(
                label: 'Next rule',
                button: true,
                child: IconButton(
                  icon: const Icon(Icons.arrow_right),
                  onPressed: _index + 1 == widget.paragraphs.length
                      ? null
                      : () => _showRule(_index + 1),
                ),
              ),
            ],
          ),
        ),
      ],
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (paragraph.section != null)
              Text(
                paragraph.section!,
                style: Theme.of(context).typography.small,
              ),
            if (paragraph.number != null)
              Text(paragraph.label!, style: Theme.of(context).typography.large),
            const SizedBox(height: 12),
            SelectableText(paragraph.body),
          ],
        ),
      ),
    );
  }
}

class CardRulingsScreen extends StatefulWidget {
  const CardRulingsScreen({super.key, required this.card, this.rulingsLoader});
  final MtgCard card;
  final CardRulingsLoader? rulingsLoader;
  @override
  State<CardRulingsScreen> createState() => _CardRulingsScreenState();
}

class _CardRulingsScreenState extends State<CardRulingsScreen> {
  CardCatalog? _ownedCatalog;
  late Future<List<Ruling>> _rulings = _load();
  Future<List<Ruling>> _load() =>
      (widget.rulingsLoader ?? (_ownedCatalog ??= CardCatalog()).rulings)(
        widget.card.id,
      );
  @override
  void dispose() {
    _ownedCatalog?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    headers: <Widget>[
      Align(alignment: Alignment.centerRight, child: SizedBox.square(
        dimension: 44, child: MergeSemantics(child: Semantics(button: true, child: IconButton(
          key: const ValueKey<String>('rulings-reader-close'),
          icon: const Icon(Icons.x, semanticLabel: 'Back to card search'),
          variance: ButtonVariance.ghost,
          onPressed: () => Navigator.pop(context),
        ))),
      )),
    ],
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(widget.card.name, style: Theme.of(context).typography.large),
        const SizedBox(height: 8),
        Text(widget.card.typeLine),
        const SizedBox(height: 16),
        Text('Oracle text', style: Theme.of(context).typography.small),
        const SizedBox(height: 8),
        if (widget.card.oracleText != null)
          SelectableText(widget.card.oracleText!),
        for (final CardFace face
            in widget.card.cardFaces ?? <CardFace>[]) ...<Widget>[
          const SizedBox(height: 16),
          Text(face.name, style: Theme.of(context).typography.large),
          if (face.oracleText != null) SelectableText(face.oracleText!),
        ],
        const SizedBox(height: 20),
        Text('Published rulings', style: Theme.of(context).typography.small),
        const SizedBox(height: 8),
        FutureBuilder<List<Ruling>>(
          future: _rulings,
          builder: (BuildContext context, AsyncSnapshot<List<Ruling>> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const CollectorLoading(label: 'Loading rulings…');
            }
            if (snapshot.hasError) {
              return SecondaryButton(
                onPressed: () => setState(() {
                  _rulings = _load();
                }),
                child: const Text('Could not load rulings. Retry'),
              );
            }
            final List<Ruling> rulings = snapshot.data!;
            if (rulings.isEmpty) {
              return const Text('No published rulings for this card.');
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final Ruling ruling in rulings)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '${ruling.publishedAt.toIso8601String().split('T').first} · ${ruling.source.name}',
                          style: Theme.of(context).typography.small,
                        ),
                        const SizedBox(height: 6),
                        SelectableText(ruling.comment),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    ),
  );
}
