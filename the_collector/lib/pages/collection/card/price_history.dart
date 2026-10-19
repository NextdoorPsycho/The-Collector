import 'package:the_collector/theme/collector_brand.dart';
import 'package:arcane/arcane.dart';
import 'package:the_collector/theme/collector_navigation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/valuation.dart';
import 'package:the_collector/pages/collection/card/card_thumbnail.dart';

class PriceHistoryScreen extends StatefulWidget {
  const PriceHistoryScreen({super.key, required this.card, this.store});
  final MTGCard card;
  final CollectionStore<MTGCard>? store;
  @override
  State<PriceHistoryScreen> createState() => _PriceHistoryScreenState();
}

class _PriceHistoryScreenState extends State<PriceHistoryScreen> {
  CardCurrency _currency = CardCurrency.usd;
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _history =
      (widget.store ?? Crud.card(u)).collection
          .doc(widget.card.id!)
          .collection('priceObservations')
          .orderBy('observedAt', descending: true)
          .limit(90)
          .snapshots();

  Widget _status(String title, String helper) => Semantics(
    liveRegion: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(helper, style: const TextStyle(fontSize: 12)).muted(),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    headers: <Widget>[
      if (!usesSwipeBack)
        AppBar(
          leading: <Widget>[
            IconButton(
              icon: const Icon(Icons.arrow_left, semanticLabel: 'Back'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
    ],
    child: ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        const Text('Price history').muted(),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            CardThumbnail(card: widget.card),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    widget.card.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.card.setCode?.toUpperCase() ?? "Set unknown"} #${widget.card.collectorNumber ?? "?"} · ${widget.card.finish == sf.Finish.nonfoil ? "Normal" : widget.card.finish?.name ?? "Finish unspecified"}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            const Text(
              'Scryfall · Per copy',
              style: TextStyle(fontSize: 12),
            ).muted(),
            Semantics(
              key: const ValueKey<String>('history-currency'),
              label: 'Price currency',
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Selector<CardCurrency>(
                  value: _currency,
                  values: CardCurrency.values,
                  labelBuilder: (CardCurrency currency) =>
                      currency.name.toUpperCase(),
                  onChanged: (CardCurrency? currency) {
                    if (currency != null) setState(() => _currency = currency);
                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _history,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
              ) {
                if (snapshot.hasError) {
                  return _status(
                    'History unavailable',
                    'Check your connection and reopen.',
                  );
                }
                if (!snapshot.hasData) {
                  return const CollectorLoading(
                    label: 'Loading price history…',
                  );
                }
                final List<QueryDocumentSnapshot<Map<String, dynamic>>>
                records = snapshot.data!.docs;
                if (records.isEmpty) {
                  return _status(
                    'No recorded prices',
                    'Refresh Value to record a quote.',
                  );
                }
                final List<double> known = records
                    .map(
                      (QueryDocumentSnapshot<Map<String, dynamic>> record) =>
                          _price(record),
                    )
                    .whereType<double>()
                    .toList();
                final double? change = known.length >= 2
                    ? known.first - known.last
                    : null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (change != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Change (${known.length} dates): ${change >= 0 ? "+" : ""}${formatValue(change, _currency)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    for (final QueryDocumentSnapshot<Map<String, dynamic>>
                        record
                        in records)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 24,
                          runSpacing: 4,
                          children: <Widget>[
                            Text(
                              _date(record),
                              style: const TextStyle(fontSize: 12),
                            ),
                            Text(
                              _price(record) == null
                                  ? 'No quote'
                                  : formatValue(_price(record)!, _currency),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: record.id == records.first.id
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
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

  double? _price(QueryDocumentSnapshot<Map<String, dynamic>> record) {
    final Object? value = record.data()['prices'];
    if (value is! Map<String, dynamic>) return null;
    try {
      final CardPrices prices = CardPricesMapper.fromMap(value);
      return prices.forFinish(widget.card.finish, _currency);
    } catch (_) {
      return null;
    }
  }

  String _date(QueryDocumentSnapshot<Map<String, dynamic>> record) {
    final Object? value = record.data()['observedAt'];
    if (value is! Timestamp) return 'Saving observation…';
    return value.toDate().toLocal().toString().split(' ').first;
  }
}
