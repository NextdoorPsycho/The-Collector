import 'package:the_collector/theme/collector_brand.dart';
import 'package:arcane/arcane.dart';
import 'package:arcane/generated/arcane_shadcn/src/components/overlay/dialog.dart'
    show showDialog;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/pages/collection/card/card.dart';
import 'package:the_collector/pages/collection/card/card_thumbnail.dart';
import 'package:the_collector/pages/collection/deck/deck.dart';
import 'package:the_collector/pages/collection/price_history_plot.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/valuation.dart';
import 'package:the_collector/utils/auth/local_account_data.dart';

typedef _CollectionObservation = ({
  DateTime observedAt,
  double total,
  int pricedCopies,
  int unpricedCopies,
});

_CollectionObservation? _decodeObservation(Map<String, dynamic> data) {
  final Object? at = data['observedAt'];
  final Object? total = data['total'];
  final Object? priced = data['pricedCopies'];
  final Object? unpriced = data['unpricedCopies'];
  if (at is! Timestamp ||
      total is! num ||
      !total.isFinite ||
      total < 0 ||
      priced is! int ||
      priced < 0 ||
      unpriced is! int ||
      unpriced < 0) {
    return null;
  }
  return (
    observedAt: at.toDate(),
    total: total.toDouble(),
    pricedCopies: priced,
    unpricedCopies: unpriced,
  );
}

class CollectionPrices extends StatefulWidget {
  const CollectionPrices({
    super.key,
    this.active = true,
    this.cardsStore,
    this.groupsStore,
    this.catalogFactory,
    this.currentUserId,
    this.cardIds,
  });
  final bool active;
  final CollectionStore<MTGCard>? cardsStore;
  final CollectionStore<MTGDeck>? groupsStore;
  final CardCatalog Function()? catalogFactory;
  final String? Function()? currentUserId;
  final Set<String>? cardIds;
  @override
  State<CollectionPrices> createState() => _CollectionPricesState();
}

enum _ValueView { cards, containers, history }

class _CollectionPricesState extends State<CollectionPrices> {
  late final CollectionStore<MTGCard> _cardsStore =
      widget.cardsStore ?? Crud.card(u);
  late final String _userId = _cardsStore.collection.parent!.id;
  late final CollectionStore<MTGDeck> _groupsStore =
      widget.groupsStore ?? Crud.deck(_userId);
  late final Stream<List<MTGCard>> _cards = _cardsStore.streamAll();
  late final Stream<List<MTGDeck>> _decks = _groupsStore.streamAll();
  late final CollectionReference<Map<String, dynamic>> _history = _cardsStore
      .collection
      .parent!
      .collection('priceHistory');
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _historyStream =
      _history.orderBy('observedAt', descending: true).limit(90).snapshots();
  CardCurrency _currency = CardCurrency.usd;
  Map<String, MtgCard> _printings = <String, MtgCard>{};
  bool _busy = false;
  String? _error;
  bool _historyOpen = false;
  _ValueView _view = _ValueView.cards;
  int _page = 0;

  void _selectView(_ValueView view) => setState(() {
    _view = view;
    _historyOpen = view == _ValueView.history;
    _page = 0;
  });

  Widget _views({required bool hasContainers}) {
    final List<(_ValueView, String)> choices = <(_ValueView, String)>[
      (_ValueView.cards, 'Cards'),
      if (hasContainers) (_ValueView.containers, 'Containers'),
      if (widget.cardIds == null) (_ValueView.history, 'History'),
    ];
    Widget choiceButton((_ValueView, String) choice) => Semantics(
      selected: _view == choice.$1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Button(
          key: choice.$1 == _ValueView.history
              ? const ValueKey<String>('collection-value-history-toggle')
              : ValueKey<String>('value-view-${choice.$1.name}'),
          style: ButtonStyle(
            variance: _view == choice.$1
                ? ButtonVariance.primary
                : ButtonVariance.ghost,
            density: ButtonDensity((EdgeInsets _) => const EdgeInsets.all(8)),
          ),
          onPressed: () => _selectView(choice.$1),
          child: Text(choice.$2, style: const TextStyle(fontSize: 13)),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints bounds) {
        final bool stacked =
            bounds.maxWidth <
            choices.length * 88 * MediaQuery.textScalerOf(context).scale(1);
        return Flex(
          direction: stacked ? Axis.vertical : Axis.horizontal,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: stacked
              ? CrossAxisAlignment.stretch
              : CrossAxisAlignment.center,
          children: <Widget>[
            for (int index = 0; index < choices.length; index++) ...<Widget>[
              if (index > 0) const SizedBox(width: 8, height: 8),
              if (stacked)
                choiceButton(choices[index])
              else
                Expanded(child: choiceButton(choices[index])),
            ],
          ],
        );
      },
    );
  }

  Widget _pages(int count) {
    final int pages = (count / 4).ceil();
    final int page = _page.clamp(0, (pages - 1).clamp(0, 1000000));
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        SizedBox.square(
          dimension: 44,
          child: IconButton(
            key: const ValueKey<String>('value-previous-page'),
            icon: const Icon(Icons.caret_left, semanticLabel: 'Previous'),
            onPressed: page == 0
                ? null
                : () => setState(() => _page = page - 1),
          ),
        ),
        Text('${page + 1} / $pages', style: const TextStyle(fontSize: 12)),
        SizedBox.square(
          dimension: 44,
          child: IconButton(
            key: const ValueKey<String>('value-next-page'),
            icon: const Icon(Icons.caret_right, semanticLabel: 'Next'),
            onPressed: page + 1 >= pages
                ? null
                : () => setState(() => _page = page + 1),
          ),
        ),
      ],
    );
  }

  Iterable<T> _pageItems<T>(List<T> items) => items
      .skip(_page.clamp(0, ((items.length - 1) ~/ 4).clamp(0, 1000000)) * 4)
      .take(4);

  Widget _fact(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.mutedForeground,
          ),
        ),
        const SizedBox(height: 3),
        Text(value, style: const TextStyle(fontSize: 14)),
      ],
    ),
  );

  Future<void> _details(List<DateTime> dates) => showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => ArcaneDialog(
      title: const Text(
        'Price details',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight:
              (MediaQuery.sizeOf(dialogContext).height -
                  MediaQuery.viewInsetsOf(dialogContext).bottom -
                  MediaQuery.paddingOf(dialogContext).vertical) *
              .55,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _fact('Source', 'Scryfall'),
                    _fact('Matched by', 'Printing and finish'),
                    _fact(
                      'Not included',
                      'Condition adjustments · unpriced copies',
                    ),
                    _fact(
                      'Oldest saved quote',
                      dates.isEmpty
                          ? 'Not refreshed'
                          : dates.first
                                .toLocal()
                                .toIso8601String()
                                .split('T')
                                .first,
                    ),
                    _fact(
                      'History',
                      'Daily snapshots after refresh, including cards added or removed.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlineButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    ),
  );

  void _requireCapturedOwner() {
    final String? currentUserId = widget.currentUserId != null
        ? widget.currentUserId!()
        : FirebaseAuth.instance.currentUser?.uid;
    if (!mounted || currentUserId != _userId) {
      throw StateError('The account changed while refreshing prices.');
    }
    LocalAccountData.requireWritable(_userId);
  }

  Future<void> _commit(WriteBatch batch) async {
    _requireCapturedOwner();
    await LocalAccountData.mutate<void>(_userId, batch.commit);
    _requireCapturedOwner();
  }

  Future<List<MTGCard>> _currentCards() async {
    _requireCapturedOwner();
    final QuerySnapshot<MTGCard> snapshot = await _cardsStore.collection.get();
    _requireCapturedOwner();
    return snapshot.docs
        .map((QueryDocumentSnapshot<MTGCard> document) => document.data())
        .toList();
  }

  Widget _estimate(
    String title,
    String detail,
    String amount, {
    VoidCallback? onPressed,
    Widget? leading,
  }) {
    final Widget content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool stacked = MediaQuery.textScalerOf(context).scale(14) > 23;
        final Widget identity = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              detail,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.mutedForeground,
              ),
            ),
            if (stacked) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                amount,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        );
        return Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[leading, const SizedBox(width: 8)],
            Expanded(child: identity),
            if (!stacked) ...<Widget>[
              const SizedBox(width: 12),
              Text(
                amount,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        );
      },
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: onPressed == null
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: content,
            )
          : Button(
              style: ButtonStyle.ghost(
                density: ButtonDensity(
                  (EdgeInsets padding) =>
                      const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
              onPressed: onPressed,
              child: content,
            ),
    );
  }

  Widget _cardValue(MTGCard card) => _estimate(
    card.name,
    <String>[
      '${card.quantity}×',
      if (card.setCode != null) card.setCode!.toUpperCase(),
      if (card.collectorNumber != null) '#${card.collectorNumber}',
      if (card.finish != null)
        card.finish == Finish.nonfoil ? 'Normal' : card.finish!.name,
    ].join(' · '),
    formatValue(card.unitPrice(_currency)! * card.quantity, _currency),
    onPressed: card.id == null
        ? null
        : () => openCardDetails(
            context,
            card: card,
            store: _cardsStore,
            groups: _groupsStore,
          ),
    leading: CardThumbnail(card: card, width: 30),
  );

  Future<void> _refresh(List<MTGCard> cards, List<MTGDeck> decks) async {
    if (_busy ||
        cards.isEmpty &&
            decks.every((MTGDeck deck) => deck.effectiveEntries.isEmpty)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    CardCatalog? catalog;
    try {
      _requireCapturedOwner();
      catalog = widget.catalogFactory?.call() ?? CardCatalog();
      final Map<String, MtgCard> printings = await catalog.printings(<String>[
        for (final MTGCard card in cards)
          if (card.printingId != null) card.printingId!,
        for (final MTGDeck deck in decks)
          for (final DeckEntry entry in deck.effectiveEntries) entry.scryfallId,
      ]);
      final List<MTGCard> currentCards = await _currentCards();
      final DateTime now = DateTime.now().toUtc();
      final String day = now.toIso8601String().split('T').first;
      WriteBatch batch = _cardsStore.collection.firestore.batch();
      int writes = 0;
      for (final MTGCard card in currentCards) {
        if (widget.cardIds != null && !widget.cardIds!.contains(card.id)) {
          continue;
        }
        final MtgCard? printing = printings[card.printingId];
        if (printing == null) {
          continue;
        }
        final CardPrices prices = CardPrices.fromScryfall(printing.prices);
        batch.update(_cardsStore.collection.doc(card.id!), <String, Object?>{
          'prices': prices.toMap(),
          'pricesUpdatedAt': now.toIso8601String(),
        });
        batch.set(
          _cardsStore.collection
              .doc(card.id!)
              .collection('priceObservations')
              .doc(day),
          <String, Object?>{
            'prices': prices.toMap(),
            'observedAt': Timestamp.fromDate(now),
            'source': 'Scryfall',
          },
        );
        writes += 2;
        if (writes == 400) {
          await _commit(batch);
          batch = _cardsStore.collection.firestore.batch();
          writes = 0;
        }
      }
      if (writes > 0) await _commit(batch);
      if (widget.cardIds != null) {
        if (mounted) setState(() => _printings = printings);
        return;
      }
      final List<MTGCard> observedCards = await _currentCards();
      final DateTime observedAt = DateTime.now().toUtc();
      final String observedDay = observedAt.toIso8601String().split('T').first;
      final WriteBatch observations = _cardsStore.collection.firestore.batch();
      for (final CardCurrency currency in <CardCurrency>[
        CardCurrency.usd,
        CardCurrency.eur,
      ]) {
        final Valuation value = valueCollection(observedCards, currency);
        observations.set(
          _history.doc('${observedDay}_${currency.name}'),
          <String, Object?>{
            'observedAt': Timestamp.fromDate(observedAt),
            'currency': currency.name,
            'total': value.total,
            'pricedCopies': value.pricedCopies,
            'unpricedCopies': value.unpricedCopies,
            'source': 'Scryfall',
          },
        );
      }
      await _commit(observations);
      if (mounted) setState(() => _printings = printings);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not refresh all prices. Saved prices remain available. Try again.',
        );
      }
    } finally {
      catalog?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<MTGCard>>(
    stream: widget.active ? _cards : null,
    builder:
        (
          BuildContext context,
          AsyncSnapshot<List<MTGCard>> cardsSnapshot,
        ) => StreamBuilder<List<MTGDeck>>(
          stream: widget.active ? _decks : null,
          builder: (BuildContext context, AsyncSnapshot<List<MTGDeck>> decksSnapshot) {
            final List<MTGCard> cards = (cardsSnapshot.data ?? <MTGCard>[])
                .where(
                  (MTGCard card) =>
                      widget.cardIds == null ||
                      widget.cardIds!.contains(card.id),
                )
                .toList();
            final List<MTGDeck> decks = widget.cardIds == null
                ? decksSnapshot.data ?? <MTGDeck>[]
                : <MTGDeck>[];
            final bool empty =
                cards.isEmpty &&
                decks.every((MTGDeck deck) => deck.effectiveEntries.isEmpty);
            final Valuation value = valueCollection(cards, _currency);
            final Map<String, CardPrices> savedPrices = savedPricesByPrinting(
              cards,
            );
            final List<MTGCard> ranked =
                cards
                    .where((MTGCard card) => card.unitPrice(_currency) != null)
                    .toList()
                  ..sort(
                    (MTGCard a, MTGCard b) =>
                        (b.unitPrice(_currency)! * b.quantity).compareTo(
                          a.unitPrice(_currency)! * a.quantity,
                        ),
                  );
            final List<DateTime> dates =
                cards
                    .map((MTGCard card) => card.pricesUpdatedAt)
                    .whereType<DateTime>()
                    .toList()
                  ..sort();
            return Scaffold(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          widget.cardIds == null
                              ? 'Collection estimate'
                              : 'Filtered cards',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      TextButton(
                        onPressed: () => _details(dates),
                        child: const Text(
                          'Price details',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      if (cardsSnapshot.hasData)
                        Semantics(
                          label: value.pricedCopies == 0 && cards.isNotEmpty
                              ? 'No prices yet'
                              : formatValue(value.total, _currency),
                          excludeSemantics: true,
                          child: Text(
                            value.pricedCopies == 0 && cards.isNotEmpty
                                ? 'No prices yet'
                                : value.total.toStringAsFixed(2),
                            key: const ValueKey<String>(
                              'collection-value-total',
                            ),
                            style: const TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      Semantics(
                        label: 'Value currency',
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                          child: Selector<CardCurrency>(
                            key: const ValueKey<String>(
                              'collection-value-currency',
                            ),
                            value: _currency,
                            values: const <CardCurrency>[
                              CardCurrency.usd,
                              CardCurrency.eur,
                            ],
                            labelBuilder: (CardCurrency currency) =>
                                currency.name.toUpperCase(),
                            onChanged: _busy
                                ? null
                                : (CardCurrency? currency) {
                                    if (currency != null) {
                                      setState(() => _currency = currency);
                                    }
                                  },
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (cardsSnapshot.hasData)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          '${value.pricedCopies} priced · ${value.unpricedCopies} missing',
                          style: const TextStyle(fontSize: 12),
                        ),
                        if (value.pricedCopies + value.unpricedCopies >
                            0) ...<Widget>[
                          const SizedBox(height: 8),
                          Semantics(
                            label:
                                '${value.pricedCopies} of ${value.pricedCopies + value.unpricedCopies} copies have a price',
                            child: ExcludeSemantics(
                              child: SizedBox(
                                height: 4,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: <Widget>[
                                    ColoredBox(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .border,
                                    ),
                                    FractionallySizedBox(
                                      alignment: Alignment.centerLeft,
                                      widthFactor:
                                          value.pricedCopies /
                                          (value.pricedCopies +
                                              value.unpricedCopies),
                                      child: ColoredBox(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .foreground,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  if (empty && cardsSnapshot.hasData && decksSnapshot.hasData)
                    const Text(
                      'Add cards to see collection and container estimates.',
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 44),
                        child: PrimaryButton(
                          density: ButtonDensity(
                            (EdgeInsets _) => const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                          ),
                          onPressed:
                              _busy ||
                                  !cardsSnapshot.hasData ||
                                  !decksSnapshot.hasData ||
                                  empty
                              ? null
                              : () => _refresh(cards, decks),
                          child: Text(
                            _busy ? 'Refreshing prices…' : 'Refresh prices',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                      Text(
                        dates.isEmpty
                            ? 'Scryfall · Not refreshed'
                            : 'Scryfall · ${dates.last.toLocal().toIso8601String().split("T").first}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  if (cardsSnapshot.hasError || decksSnapshot.hasError)
                    const Text(
                      'Could not load your collection. Check your connection.',
                    ),
                  if ((!cardsSnapshot.hasData || !decksSnapshot.hasData) &&
                      !cardsSnapshot.hasError &&
                      !decksSnapshot.hasError)
                    const CollectorLoading(label: 'Loading saved prices…'),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!),
                    ),
                  const SizedBox(height: 12),
                  _views(hasContainers: decks.isNotEmpty),
                  if (_view == _ValueView.cards) ...<Widget>[
                    if (ranked.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          'No priced cards',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    for (final MTGCard card in _pageItems(ranked))
                      _cardValue(card),
                    if (ranked.length > 4) _pages(ranked.length),
                  ],
                  if (_view == _ValueView.containers) ...<Widget>[
                    for (final MTGDeck deck in _pageItems(decks))
                      Builder(
                        builder: (BuildContext context) {
                          final Valuation deckValue = valueDeck(
                            deck,
                            _printings,
                            _currency,
                            savedPrices: savedPrices,
                          );
                          return _estimate(
                            '${groupKindLabel(deck.kind)} · ${deck.name}',
                            '${deckValue.pricedCopies} priced · ${deckValue.unpricedCopies} unpriced copies',
                            formatValue(deckValue.total, _currency),
                            onPressed: deck.id == null
                                ? null
                                : () => Arcane.push(
                                    context,
                                    DeckFlyoutScreen(
                                      deck: deck,
                                      store: _groupsStore,
                                      inventory: _cardsStore,
                                    ),
                                  ),
                          );
                        },
                      ),
                    if (decks.length > 4) _pages(decks.length),
                  ],
                  if (widget.cardIds == null)
                    Offstage(
                      key: const ValueKey<String>(
                        'collection-price-history-shell',
                      ),
                      offstage: !_historyOpen,
                      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        key: const ValueKey<String>('collection-price-history'),
                        stream: widget.active ? _historyStream : null,
                        builder:
                            (
                              BuildContext context,
                              AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>>
                              snapshot,
                            ) {
                              if (snapshot.hasError) {
                                return const Text(
                                  'Could not load price history.',
                                );
                              }
                              if (!snapshot.hasData) {
                                return const CollectorLoading(
                                  label: 'Loading price history…',
                                );
                              }
                              final List<_CollectionObservation> records =
                                  <_CollectionObservation>[];
                              bool invalid = false;
                              for (final QueryDocumentSnapshot<
                                    Map<String, dynamic>
                                  >
                                  document
                                  in snapshot.data!.docs) {
                                final Map<String, dynamic> data = document
                                    .data();
                                if (data['currency'] != _currency.name) {
                                  continue;
                                }
                                final _CollectionObservation? observation =
                                    _decodeObservation(data);
                                if (observation == null) {
                                  invalid = true;
                                } else {
                                  records.add(observation);
                                }
                              }
                              if (records.isEmpty) {
                                return Text(
                                  invalid
                                      ? 'Saved observations could not be read. Refresh prices to record a new observation.'
                                      : 'Refresh prices to record your first observation.',
                                );
                              }
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  if (records.length >= 2) ...<Widget>[
                                    const SizedBox(height: 12),
                                    PriceHistoryPlot(
                                      key: const ValueKey<String>(
                                        'collection-value-chart',
                                      ),
                                      points: <PriceHistoryPoint>[
                                        for (final _CollectionObservation record
                                            in records)
                                          (
                                            date: record.observedAt,
                                            total: record.total,
                                          ),
                                      ],
                                      currency: _currency,
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                  if (invalid)
                                    const Text(
                                      'Some saved observations could not be read.',
                                    ),
                                  for (final _CollectionObservation record
                                      in _pageItems(records))
                                    _estimate(
                                      record.observedAt
                                          .toLocal()
                                          .toString()
                                          .split(' ')
                                          .first,
                                      '${record.pricedCopies} priced · ${record.unpricedCopies} unpriced',
                                      formatValue(record.total, _currency),
                                    ),
                                  if (records.length > 4)
                                    _pages(records.length),
                                ],
                              );
                            },
                      ),
                    ),
                ],
              ),
            );
          },
        ),
  );
}
