import 'dart:math' as math;

import 'package:arcane/arcane.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/external_links.dart';
import 'package:the_collector/utils/valuation.dart';

typedef _MarketTotal = ({double amount, int priced, int unpriced});
typedef _PricePoint = ({DateTime date, double price});

class CardMarketsPanel extends StatefulWidget {
  const CardMarketsPanel({
    super.key,
    required this.card,
    required this.holdings,
    required this.onRefresh,
    this.printing,
    this.fetchedAt,
    this.refreshing = false,
    this.error,
    this.store,
    this.openLink,
    this.holdingsAvailable = true,
  });

  final MTGCard card;
  final List<MTGCard> holdings;
  final sf.MtgCard? printing;
  final DateTime? fetchedAt;
  final bool refreshing;
  final String? error;
  final VoidCallback onRefresh;
  final CollectionStore<MTGCard>? store;
  final Future<void> Function(Uri)? openLink;
  final bool holdingsAvailable;

  @override
  State<CardMarketsPanel> createState() => _CardMarketsPanelState();
}

class _CardMarketsPanelState extends State<CardMarketsPanel> {
  bool _historyOpen = false;
  CardCurrency _historyCurrency = CardCurrency.usd;
  String? _linkError;
  final Set<String> _opening = <String>{};
  Stream<QuerySnapshot<Map<String, dynamic>>>? _history;

  @override
  void initState() {
    super.initState();
    _setHistory();
  }

  @override
  void didUpdateWidget(CardMarketsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.card.id != widget.card.id ||
        oldWidget.store != widget.store) {
      _setHistory();
      _linkError = null;
    }
  }

  void _setHistory() {
    final String? id = widget.card.id;
    _history = id == null
        ? null
        : widget.store?.collection
              .doc(id)
              .collection('priceObservations')
              .orderBy('observedAt', descending: true)
              .limit(30)
              .snapshots();
  }

  double? _valid(double? value) =>
      value != null && value.isFinite && value >= 0 ? value : null;

  _MarketTotal _total(CardCurrency currency) {
    double amount = 0;
    int priced = 0;
    int unpriced = 0;
    final Set<String> seen = <String>{};
    for (final MTGCard card in widget.holdings) {
      final String identity =
          card.id ?? '${card.printingId}|${card.finish?.name}|${card.language}';
      if (card.quantity <= 0 || !seen.add(identity)) continue;
      final double? price = _valid(card.unitPrice(currency));
      final double? subtotal = price == null ? null : price * card.quantity;
      if (subtotal == null ||
          !subtotal.isFinite ||
          !(amount + subtotal).isFinite) {
        unpriced += card.quantity;
      } else {
        amount += subtotal;
        priced += card.quantity;
      }
    }
    return (amount: amount, priced: priced, unpriced: unpriced);
  }

  Uri? _marketLink(String market) {
    final Uri? uri = widget.printing?.purchaseUris?[market];
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      return null;
    }
    final String domain = switch (market) {
      'tcgplayer' => 'tcgplayer.com',
      'cardmarket' => 'cardmarket.com',
      'cardhoarder' => 'cardhoarder.com',
      _ => '',
    };
    final String host = uri.host.toLowerCase();
    return domain.isNotEmpty && (host == domain || host.endsWith('.$domain'))
        ? uri
        : null;
  }

  Future<void> _openMarket(String market, String label, Uri uri) async {
    if (_opening.contains(market)) return;
    setState(() {
      _opening.add(market);
      _linkError = null;
    });
    try {
      await (widget.openLink ?? openCollectorLink)(uri);
    } catch (_) {
      if (mounted) setState(() => _linkError = 'Could not open $label.');
    } finally {
      if (mounted) setState(() => _opening.remove(market));
    }
  }

  Widget _marketName(String market, String label) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        _marketLinkButton(market, label),
      ],
    );
  }

  Widget _marketLinkButton(String market, String label) {
    final Uri? link = _marketLink(market);
    return SizedBox(
      width: 44,
      height: 44,
      child: link == null
          ? null
          : IconButton(
              key: ValueKey<String>('card-market-link-$market'),
              icon: Icon(
                Icons.arrow_square_out,
                size: 17,
                semanticLabel: 'Open $label',
              ),
              onPressed: _opening.contains(market)
                  ? null
                  : () => _openMarket(market, label, link),
            ),
    );
  }

  Widget _cashMarket(String market, String label, CardCurrency currency) {
    final double? price = _valid(widget.card.unitPrice(currency));
    final _MarketTotal total = _total(currency);
    final Widget quote = _amount(
      price == null ? 'No quote' : formatValue(price, currency),
      'Per copy',
    );
    final Widget owned = _amount(
      !widget.holdingsAvailable
          ? 'Unavailable'
          : total.priced == 0
          ? 'No total'
          : formatValue(total.amount, currency),
      !widget.holdingsAvailable
          ? 'Owned total'
          : total.unpriced == 0
          ? '${total.priced} owned'
          : '${total.priced} priced · ${total.unpriced} unpriced',
    );
    return Padding(
      key: ValueKey<String>('card-market-${currency.name}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool stacked =
              constraints.maxWidth < 260 ||
              MediaQuery.textScalerOf(context).scale(13) > 19;
          return stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _marketName(market, label),
                    quote,
                    const SizedBox(height: 8),
                    owned,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            label,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          quote,
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: owned),
                    _marketLinkButton(market, label),
                  ],
                );
        },
      ),
    );
  }

  Widget _amount(String amount, String caption) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        amount,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 2),
      Text(caption, style: const TextStyle(fontSize: 11)).muted(),
    ],
  );

  Widget _digitalMarket() {
    final double? price = _valid(widget.card.prices?.tix);
    return Padding(
      key: const ValueKey<String>('card-market-tix'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 4,
              children: <Widget>[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Cardhoarder',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Text(
                      'Digital reference',
                      style: TextStyle(fontSize: 11),
                    ).muted(),
                  ],
                ),
                Text(
                  price == null
                      ? 'No quote'
                      : formatValue(price, CardCurrency.tix),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          _marketLinkButton('cardhoarder', 'Cardhoarder'),
        ],
      ),
    );
  }

  List<_PricePoint> _points(QuerySnapshot<Map<String, dynamic>> snapshot) {
    final List<_PricePoint> points = <_PricePoint>[];
    for (final QueryDocumentSnapshot<Map<String, dynamic>> record
        in snapshot.docs) {
      final Map<String, dynamic> data = record.data();
      final Object? date = data['observedAt'];
      final Object? rawPrices = data['prices'];
      if (date is! Timestamp || rawPrices is! Map<String, dynamic>) continue;
      try {
        final CardPrices prices = CardPricesMapper.fromMap(rawPrices);
        final double? price = _valid(
          prices.forFinish(widget.card.finish, _historyCurrency),
        );
        if (price != null) points.add((date: date.toDate(), price: price));
      } catch (_) {
        continue;
      }
    }
    points.sort((_PricePoint a, _PricePoint b) => a.date.compareTo(b.date));
    return points;
  }

  Widget _historyPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: TextButton(
          key: const ValueKey<String>('card-market-history-toggle'),
          onPressed: () => setState(() => _historyOpen = !_historyOpen),
          child: Row(
            children: <Widget>[
              const Expanded(
                child: Text('History', style: TextStyle(fontSize: 13)),
              ),
              Icon(_historyOpen ? Icons.caret_up : Icons.caret_down, size: 16),
            ],
          ),
        ),
      ),
      if (_historyOpen) ...<Widget>[
        Wrap(
          spacing: 8,
          children: <Widget>[
            for (final CardCurrency currency in <CardCurrency>[
              CardCurrency.usd,
              CardCurrency.eur,
            ])
              Semantics(
                selected: _historyCurrency == currency,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  child: TextButton(
                    key: ValueKey<String>(
                      'card-market-history-${currency.name}',
                    ),
                    onPressed: () =>
                        setState(() => _historyCurrency = currency),
                    child: Text(
                      currency.name.toUpperCase(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: _historyCurrency == currency
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _history,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
              ) {
                if (snapshot.hasError) {
                  return const Text('History unavailable').muted();
                }
                if (!snapshot.hasData) {
                  return const Text('Loading history…').muted();
                }
                final List<_PricePoint> points = _points(snapshot.data!);
                if (points.isEmpty) {
                  return const Text('No recorded prices').muted();
                }
                final double change = points.last.price - points.first.price;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      '${points.length} ${points.length == 1 ? "observation" : "observations"} · Per copy',
                      style: const TextStyle(fontSize: 11),
                    ).muted(),
                    if (points.length > 1) ...<Widget>[
                      const SizedBox(height: 8),
                      Semantics(
                        label:
                            'Per-copy price from ${formatValue(points.first.price, _historyCurrency)} to ${formatValue(points.last.price, _historyCurrency)}',
                        child: SizedBox(
                          height: 64,
                          child: CustomPaint(
                            key: const ValueKey<String>(
                              'card-market-history-plot',
                            ),
                            painter: _CardPricePainter(
                              points,
                              Theme.of(context).colorScheme.foreground,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    Wrap(
                      spacing: 16,
                      runSpacing: 4,
                      alignment: WrapAlignment.spaceBetween,
                      children: <Widget>[
                        Text(
                          points.length == 1
                              ? _date(points.last.date)
                              : '${_date(points.first.date)} – ${_date(points.last.date)}',
                          style: const TextStyle(fontSize: 11),
                        ).muted(),
                        Text(
                          points.length == 1
                              ? formatValue(points.last.price, _historyCurrency)
                              : '${change >= 0 ? "+" : "−"}${formatValue(change.abs(), _historyCurrency)}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
        ),
      ],
    ],
  );

  static String _date(DateTime date) =>
      date.toLocal().toIso8601String().split('T').first;

  @override
  Widget build(BuildContext context) {
    final DateTime? dated = widget.fetchedAt ?? widget.card.pricesUpdatedAt;
    final String freshness = dated == null
        ? 'Date unavailable'
        : '${widget.fetchedAt == null ? "Cached" : "Fetched"} ${_date(dated)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'This printing · Scryfall',
                    style: TextStyle(fontSize: 11),
                  ).muted(),
                  Text(freshness, style: const TextStyle(fontSize: 11)).muted(),
                ],
              ),
            ),
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                key: const ValueKey<String>('card-market-refresh'),
                icon: Icon(
                  Icons.arrow_clockwise,
                  semanticLabel: widget.refreshing
                      ? 'Refreshing prices'
                      : 'Refresh prices',
                  size: 18,
                ),
                onPressed: widget.refreshing ? null : widget.onRefresh,
              ),
            ),
          ],
        ),
        if (widget.error != null)
          Text(widget.error!, style: const TextStyle(fontSize: 12)),
        if (_linkError != null)
          Text(_linkError!, style: const TextStyle(fontSize: 12)),
        _cashMarket('tcgplayer', 'TCGplayer', CardCurrency.usd),
        _cashMarket('cardmarket', 'Cardmarket', CardCurrency.eur),
        _digitalMarket(),
        if (_history != null) _historyPanel(),
      ],
    );
  }
}

class _CardPricePainter extends CustomPainter {
  const _CardPricePainter(this.points, this.ink);
  final List<_PricePoint> points;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final double low = points
        .map((_PricePoint point) => point.price)
        .reduce(math.min);
    final double high = points
        .map((_PricePoint point) => point.price)
        .reduce(math.max);
    final int first = points.first.date.millisecondsSinceEpoch;
    final int span = points.last.date.millisecondsSinceEpoch - first;
    final Path line = Path();
    for (int index = 0; index < points.length; index++) {
      final _PricePoint point = points[index];
      final double x = span == 0
          ? index / (points.length - 1)
          : (point.date.millisecondsSinceEpoch - first) / span;
      final double y = high == low ? .5 : (point.price - low) / (high - low);
      final Offset offset = Offset(
        3 + x * (size.width - 6),
        3 + (1 - y) * (size.height - 6),
      );
      if (index == 0) {
        line.moveTo(offset.dx, offset.dy);
      } else {
        line.lineTo(offset.dx, offset.dy);
      }
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = ink
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CardPricePainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.ink != ink;
}
