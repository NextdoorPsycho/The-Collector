import 'package:arcane/arcane.dart';
import 'package:the_collector/theme/collector_navigation.dart';
import 'package:arcane/generated/arcane_shadcn/src/components/overlay/dialog.dart'
    show showDialog;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:magic_card/magic_card.dart';
import 'package:collector_models/deck/deck_entry.dart';
import 'package:collector_models/deck/mtg_deck.dart';
import 'package:flutter/services.dart';
import 'package:the_collector/utils/collection_organization.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/collection_ingestion.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:the_collector/utils/card_insights.dart';
import 'package:the_collector/utils/valuation.dart';

import 'card_markets_panel.dart';
import 'card_add_dialog.dart';

enum _CardView { details, organize, printings, add, actions, rulings, quantity }

Future<void> openCardDetails(
  BuildContext context, {
  required MTGCard card,
  CollectionStore<MTGCard>? store,
  CardCatalog? catalog,
  CollectionStore<MTGDeck>? groups,
}) async {
  final bool fullPhone = MediaQuery.sizeOf(context).shortestSide < 600;
  await Sheet(
    barrierColor: fullPhone ? Theme.of(context).colorScheme.background : null,
    builder: (BuildContext context) {
      final Size viewport = MediaQuery.sizeOf(context);
      return SizedBox(
        height: viewport.height * (fullPhone ? 1 : .88),
        child: CardFlyoutScreen(
          card: card,
          store: store,
          catalog: catalog,
          groups: groups,
        ),
      );
    },
  ).open<void>(context);
}

class CardFlyoutScreen extends StatefulWidget {
  final MTGCard card;
  final CollectionStore<MTGCard>? store;
  final CardCatalog? catalog;
  final CollectionStore<MTGDeck>? groups;
  const CardFlyoutScreen({
    super.key,
    required this.card,
    this.store,
    this.catalog,
    this.groups,
  });
  @override
  State<CardFlyoutScreen> createState() => _CardFlyoutScreenState();
}

class _CardFlyoutScreenState extends State<CardFlyoutScreen> {
  late final CollectionStore<MTGCard> _store =
      widget.store ?? Crud.card(FirebaseAuth.instance.currentUser!.uid);
  late MTGCard _selected = widget.card;
  late String? _id = _inventoryId(widget.card);
  late Stream<MTGCard?> _card = _id == null
      ? Stream<MTGCard?>.value(null)
      : _store.streamOrNull(_id!);
  late final Stream<List<MTGCard>> _inventory = _store.streamAll();
  List<MTGCard> _inventoryCards = <MTGCard>[];
  late final CardCatalog _catalog = widget.catalog ?? CardCatalog();
  late final CollectionStore<MTGDeck> _groups =
      widget.groups ??
      CollectionStore<MTGDeck>(
        collection: _store.collection.parent!.collection('decks'),
        toMap: (MTGDeck group) => group.toMap(),
        fromMap: (String id, Map<String, Object?> data) =>
            MTGDeckMapper.fromMap(data)..id = id,
      );
  late final Stream<List<MTGDeck>> _memberships = _groups.streamAll();
  MTGCard? _metadata;
  sf.MtgCard? _printing;
  final Map<String, sf.MtgCard> _freshPrintings = <String, sf.MtgCard>{};
  final Map<String, DateTime> _quoteDates = <String, DateTime>{};
  int _metadataRequest = 0;
  int _tab = 0;
  bool _refreshing = false;
  String? _marketError;
  bool _busy = false;
  bool _back = false;
  bool _foil = true;
  bool _legalitiesOpen = false;
  String? _error;
  _CardView _view = _CardView.details;
  MTGCard? _organizationCard;
  MTGDeck? _organizationGroup;
  Future<List<sf.Ruling>>? _rulings;
  final TextEditingController _copies = TextEditingController();
  final FocusNode _shortcuts = FocusNode(debugLabel: 'Card dossier');

  String? _inventoryId(MTGCard card) {
    if (card.id != null) return card.id;
    try {
      return CollectionIngestion.inventoryId(card);
    } on ArgumentError {
      return null;
    }
  }

  void _returnToCard() {
    if (_busy) return;
    _shortcuts.requestFocus();
    setState(() {
      _view = _CardView.details;
      _error = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _loadMetadata();
  }

  @override
  void dispose() {
    _copies.dispose();
    _shortcuts.dispose();
    if (widget.catalog == null) {
      _catalog.close();
    }
    super.dispose();
  }

  Future<void> _loadMetadata() async {
    final String? printingId = _selected.printingId;
    if (printingId == null) {
      return;
    }
    final int request = ++_metadataRequest;
    try {
      final Map<String, sf.MtgCard> cards = await _catalog.printings(<String>[
        printingId,
      ]);
      final sf.MtgCard? card = cards[printingId];
      final sf.Finish? finish = card?.finishes
          .where((sf.Finish finish) => finish != sf.Finish.unknown)
          .firstOrNull;
      if (mounted &&
          request == _metadataRequest &&
          card != null &&
          finish != null) {
        setState(() {
          _printing = card;
          _metadata = cardFromScryfall(card, finish: finish);
          _marketError = null;
          _freshPrintings[card.id] = card;
          _quoteDates.putIfAbsent(card.id, () => DateTime.now().toUtc());
        });
      }
    } catch (_) {
      if (mounted && request == _metadataRequest) {
        setState(() => _marketError = 'Offline · showing saved details');
      }
    }
  }

  MTGCard _withQuote(MTGCard card) {
    final sf.MtgCard? fresh = _freshPrintings[card.printingId];
    if (fresh == null) return card;
    return card.copyWith(
      oracleId: card.oracleId ?? fresh.oracleId,
      prices: CardPrices.fromScryfall(fresh.prices),
      pricesUpdatedAt: _quoteDates[fresh.id],
    )..id = card.id;
  }

  Future<void> _refreshMarkets() async {
    if (_refreshing) return;
    final int request = _metadataRequest;
    final CardHoldings owned = CardHoldings(
      selected: _withQuote(_selected),
      inventory: _inventoryCards,
    );
    final Set<String> ids = <String>{
      if (_selected.printingId != null) _selected.printingId!,
      ...owned.cards.map((MTGCard card) => card.printingId).whereType<String>(),
    };
    setState(() {
      _refreshing = true;
      _marketError = null;
      _view = _CardView.details;
    });
    try {
      _catalog.invalidatePrintings(ids);
      final Map<String, sf.MtgCard> found = await _catalog.printings(ids);
      if (!mounted || request != _metadataRequest) return;
      setState(() {
        final DateTime now = DateTime.now().toUtc();
        _freshPrintings.addAll(found);
        for (final String id in found.keys) {
          _quoteDates[id] = now;
        }
        _printing = found[_selected.printingId] ?? _printing;
        final sf.MtgCard? current = found[_selected.printingId];
        final sf.Finish? finish = current?.finishes
            .where((sf.Finish finish) => finish != sf.Finish.unknown)
            .firstOrNull;
        if (current != null && finish != null) {
          _metadata = cardFromScryfall(current, finish: finish);
        }
        if (found.length < ids.length) {
          _marketError = 'Some quotes are unavailable';
        }
      });
    } catch (_) {
      if (mounted && request == _metadataRequest) {
        setState(() => _marketError = 'Could not refresh · saved quotes shown');
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _selectOwnedCard(MTGCard card) {
    if (_busy || card.id == null || card.id == _id) return;
    setState(() {
      _selected = card;
      _id = card.id!;
      _card = _store.streamOrNull(_id!);
      _metadata = null;
      _printing = _freshPrintings[card.printingId];
      _back = false;
      _tab = 0;
      _error = null;
      _marketError = null;
    });
    _loadMetadata();
  }

  Future<void> _changeQuantity(int delta, MTGCard saved) async {
    if (delta < 0 && saved.quantity <= 1) {
      await _confirmDelete(saved);
      return;
    }
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final DocumentReference<MTGCard> reference = _store.collection.doc(_id!);
      final bool deleted = await reference.firestore.runTransaction<bool>((
        Transaction transaction,
      ) async {
        final DocumentSnapshot<MTGCard> snapshot = await transaction.get(
          reference,
        );
        final MTGCard? card = snapshot.data();
        if (card == null) {
          throw StateError('Card no longer exists.');
        }
        if (delta < 0 && card.quantity <= 1) {
          throw StateError('Confirm deletion of the last copy.');
        }
        transaction.update(reference, <String, Object?>{
          'quantity': card.quantity + delta,
        });
        return false;
      });
      if (deleted && mounted) {
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not update quantity. Check your connection and retry.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _confirmDelete(MTGCard saved) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => ArcaneDialog(
        title: const Text('Delete Printing'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Remove all ${saved.quantity} copies of ${saved.name} from your collection? Deck assignments stay unchanged.',
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlineButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                PrimaryButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _store.delete(_id!);
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not delete this printing. Retry.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _artworkFallback(MTGCard saved, String status) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.image),
            const SizedBox(height: 8),
            Text(
              status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _artwork(String image, MTGCard saved) => InteractiveViewer(
    minScale: 1,
    maxScale: 3,
    child: CardEffects(
      foil:
          _foil &&
          (saved.finish == sf.Finish.foil || saved.finish == sf.Finish.etched),
      parallax: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Image.network(
          image,
          fit: BoxFit.contain,
          frameBuilder:
              (
                BuildContext context,
                Widget child,
                int? frame,
                bool synchronous,
              ) => frame == null && !synchronous
              ? _artworkFallback(saved, 'Loading artwork…')
              : child,
          errorBuilder: (
            BuildContext context,
            Object error,
            StackTrace? stack,
          ) => _artworkFallback(saved, 'Artwork unavailable'),
        ),
      ),
    ),
  );

  void _openArtwork(String image, MTGCard saved) => Arcane.push(
    context,
    Scaffold(
      headers: <Widget>[
        if (!usesSwipeBack)
          AppBar(
            title: Text(saved.name),
            leading: <Widget>[
              Semantics(
                label: 'Back to card details',
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_left),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ),
            ],
          ),
      ],
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: AspectRatio(
              aspectRatio: 5 / 7,
              child: _artwork(image, saved),
            ),
          ),
        ),
      ),
    ),
  );

  void _organize(MTGCard saved, {MTGDeck? group}) => setState(() {
    _organizationCard = saved;
    _organizationGroup = group;
    _view = _CardView.organize;
  });

  void _rules(MTGCard metadata) => setState(() {
    _rulings = metadata.printingId == null
        ? Future<List<sf.Ruling>>.value(<sf.Ruling>[])
        : _catalog.rulings(metadata.printingId!);
    _view = _CardView.rulings;
  });

  String _finish(MTGCard card) => switch (card.finish) {
    sf.Finish.nonfoil => 'Normal',
    sf.Finish.foil => 'Foil',
    sf.Finish.etched => 'Etched',
    sf.Finish.glossy => 'Glossy',
    _ => 'Finish unknown',
  };

  String _printingLabel(MTGCard card) =>
      '${card.setCode?.toUpperCase() ?? card.setId} #${card.collectorNumber ?? "?"}';

  Widget _action(String label, VoidCallback? onPressed) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
    child: OutlineButton(
      onPressed: onPressed,
      density: ButtonDensity((EdgeInsets padding) => const EdgeInsets.all(8)),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12),
      ),
    ),
  );

  Widget _quantity(MTGCard saved) => Row(
    children: <Widget>[
      const Expanded(child: Text('Quantity', style: TextStyle(fontSize: 12))),
      Semantics(
        label: 'Remove one copy',
        child: SizedBox(
          width: 44,
          height: 44,
          child: IconButton(
            icon: const Icon(Icons.minus),
            onPressed: _busy ? null : () => _changeQuantity(-1, saved),
          ),
        ),
      ),
      Semantics(
        label: 'Edit owned quantity',
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          child: TextButton(
            density: ButtonDensity(
              (EdgeInsets padding) => const EdgeInsets.all(8),
            ),
            onPressed: _busy
                ? null
                : () => setState(() {
                    _copies.text = '${saved.quantity}';
                    _view = _CardView.quantity;
                  }),
            child: Text(
              '${saved.quantity}',
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ),
      ),
      Semantics(
        label: 'Add one copy',
        child: SizedBox(
          width: 44,
          height: 44,
          child: IconButton(
            icon: const Icon(Icons.plus),
            onPressed: _busy ? null : () => _changeQuantity(1, saved),
          ),
        ),
      ),
    ],
  );

  Widget _identity(
    MTGCard saved,
    MTGCard metadata,
    CardHoldings owned, {
    required bool totalsAvailable,
    required bool isOwned,
  }) {
    final String? front = saved.imageUrl ?? metadata.imageUrl;
    final String? back = saved.backImageUrl ?? metadata.backImageUrl;
    final String? image = _back ? back : front;
    final MTGCard quoted = _withQuote(saved);
    final double? usd = quoted.unitPrice(CardCurrency.usd);
    final double? eur = quoted.unitPrice(CardCurrency.eur);
    final double? price = usd ?? eur;
    final CardCurrency currency = usd == null
        ? CardCurrency.eur
        : CardCurrency.usd;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                saved.name,
                key: const ValueKey<String>('card-detail-name'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (Navigator.canPop(context))
              SizedBox(
                width: 44,
                height: 44,
                child: IconButton(
                  key: const ValueKey<String>('card-detail-close'),
                  icon: const Icon(
                    Icons.x,
                    size: 18,
                    semanticLabel: 'Close card',
                  ),
                  onPressed: _busy ? null : () => Navigator.maybePop(context),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              key: const ValueKey<String>('card-detail-artwork'),
              width: 74,
              height: 104,
              child: image == null
                  ? _artworkFallback(saved, 'Artwork unavailable')
                  : Semantics(
                      label: 'View Artwork',
                      child: GhostButton(
                        density: ButtonDensity(
                          (EdgeInsets padding) => EdgeInsets.zero,
                        ),
                        onPressed: () => _openArtwork(image, saved),
                        child: IgnorePointer(child: _artwork(image, saved)),
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    metadata.setName ?? _printingLabel(metadata),
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    _printingLabel(metadata),
                    style: const TextStyle(fontSize: 12),
                  ).muted(),
                  Text(
                    '${saved.language?.toUpperCase() ?? metadata.language?.toUpperCase() ?? "?"} · ${_finish(saved)}',
                    style: const TextStyle(fontSize: 12),
                  ).muted(),
                  const SizedBox(height: 8),
                  Text(
                    price != null && price.isFinite && price >= 0
                        ? formatValue(price, currency)
                        : 'No quote',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    totalsAvailable
                        ? 'Per copy · ${owned.copies} owned'
                        : 'Per copy',
                    style: const TextStyle(fontSize: 11),
                  ).muted(),
                ],
              ),
            ),
          ],
        ),
        if (isOwned)
          _quantity(saved)
        else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _action(
              'Add copies',
              () => setState(() => _view = _CardView.add),
            ),
          ),
      ],
    );
  }

  Widget _tabs() {
    final bool stacked = MediaQuery.textScalerOf(context).scale(12) > 19;
    return Flex(
      direction: stacked ? Axis.vertical : Axis.horizontal,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: stacked
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.center,
      children: <Widget>[
        for (final (int index, String label) in <String>[
          'Card',
          'Value',
          'Locations',
        ].indexed) ...<Widget>[
          if (index > 0) const SizedBox(width: 4, height: 4),
          if (stacked)
            _tabButton(index, label)
          else
            Expanded(child: _tabButton(index, label)),
        ],
      ],
    );
  }

  Widget _tabButton(int index, String label) => Semantics(
    selected: _tab == index,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: _tab == index
          ? PrimaryButton(
              onPressed: () {},
              density: ButtonDensity(
                (EdgeInsets padding) =>
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              ),
              child: Text(label, style: const TextStyle(fontSize: 12)),
            )
          : GhostButton(
              onPressed: () => setState(() => _tab = index),
              density: ButtonDensity(
                (EdgeInsets padding) =>
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              ),
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
    ),
  );

  Widget _overview(
    MTGCard metadata,
    MTGCard saved,
    CardHoldings owned, {
    required bool totalsAvailable,
  }) {
    final Valuation value = owned.value(CardCurrency.usd);
    final String printings =
        '${owned.printingCount} ${owned.printingCount == 1 ? "printing" : "printings"}';
    final String? power = _printing?.power;
    final String? toughness = _printing?.toughness;
    final Map<String, String> legalities = _printing == null
        ? metadata.legalities
        : _printing!.legalities.toJson().map(
            (String key, Object? value) =>
                MapEntry<String, String>(key, '$value'),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (totalsAvailable)
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${owned.copies} owned',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                value.pricedCopies == 0
                    ? 'No estimate'
                    : formatValue(value.total, CardCurrency.usd),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        if (totalsAvailable)
          Text(
            value.unpricedCopies > 0
                ? '$printings · ${value.unpricedCopies} unpriced'
                : '$printings · TCGplayer estimate',
            style: const TextStyle(fontSize: 11),
          ).muted(),
        const SizedBox(height: 14),
        Text(
          metadata.typeLine,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          <String>[
            if (metadata.manaCost?.isNotEmpty ?? false) metadata.manaCost!,
            'Mana value ${metadata.cmc % 1 == 0 ? metadata.cmc.toInt() : metadata.cmc}',
            metadata.rarity.name,
            if (power != null && toughness != null) '$power/$toughness',
            if (_printing?.loyalty != null) 'Loyalty ${_printing!.loyalty}',
          ].join(' · '),
          style: const TextStyle(fontSize: 12),
        ).muted(),
        const SizedBox(height: 10),
        Text(
          metadata.oracleText ?? metadata.description,
          style: const TextStyle(fontSize: 13, height: 1.4),
        ),
        if (metadata.flavorText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              metadata.flavorText,
              style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
            ).muted(),
          ),
        if (metadata.keywords.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              metadata.keywords.join(' · '),
              style: const TextStyle(fontSize: 12),
            ).muted(),
          ),
        if (_printing?.artist != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              'Illustrated by ${_printing!.artist}',
              style: const TextStyle(fontSize: 11),
            ).muted(),
          ),
        if (_legalitiesOpen && legalities.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: <Widget>[
                for (final MapEntry<String, String> entry in legalities.entries)
                  Text(
                    '${entry.key} · ${entry.value.replaceAll("_", " ")}',
                    style: const TextStyle(fontSize: 11),
                  ).muted(),
              ],
            ),
          ),
        Wrap(
          spacing: 8,
          children: <Widget>[
            TextButton(
              onPressed: () => _rules(metadata),
              child: const Text('Rulings'),
            ),
            if (legalities.isNotEmpty)
              TextButton(
                onPressed: () =>
                    setState(() => _legalitiesOpen = !_legalitiesOpen),
                child: Text(_legalitiesOpen ? 'Hide legality' : 'Legality'),
              ),
            if (saved.backImageUrl != null || metadata.backImageUrl != null)
              TextButton(
                onPressed: () => setState(() => _back = !_back),
                child: Text(_back ? 'Show Front' : 'Show Back'),
              ),
            if (saved.finish == sf.Finish.foil ||
                saved.finish == sf.Finish.etched)
              TextButton(
                onPressed: () => setState(() => _foil = !_foil),
                child: Text(_foil ? 'Foil Effect On' : 'Foil Effect Off'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _owned(
    MTGCard saved,
    CardHoldings owned,
    List<MTGDeck> groups, {
    required bool groupsFailed,
  }) {
    final List<CardGroupHolding> memberships = cardGroupHoldings(owned, groups);
    return Column(
      key: const ValueKey<String>('card-owned-printings'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final MTGCard card in owned.cards)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: CardButton(
              onPressed: _busy ? null : () => _selectOwnedCard(card),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _printingLabel(card),
                          style: const TextStyle(fontSize: 13),
                        ),
                        Text(
                          '${_finish(card)} · ${card.language?.toUpperCase() ?? "?"}',
                          style: const TextStyle(fontSize: 11),
                        ).muted(),
                      ],
                    ),
                  ),
                  Text(
                    '${card.quantity}×',
                    style: const TextStyle(fontSize: 15),
                  ),
                  if (card.id == _id)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.check, size: 16),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        const Text(
          'Containers',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        if (groupsFailed) const Text('Containers unavailable').muted(),
        if (!groupsFailed && memberships.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Not assigned', style: TextStyle(fontSize: 12)),
          ),
        for (final CardGroupHolding membership in memberships)
          TextButton(
            key: ValueKey<String>('card-membership-${membership.group.id}'),
            onPressed: _busy
                ? null
                : () {
                    final MTGCard member = owned.cards.firstWhere(
                      (MTGCard card) => membership.group.effectiveEntries.any(
                        (DeckEntry entry) => _matches(entry, card),
                      ),
                      orElse: () => saved,
                    );
                    _organize(member, group: membership.group);
                  },
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    membership.group.name,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                Text(
                  '${membership.copies}× · ${membership.group.kind.name}',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _content(
    MTGCard saved,
    List<MTGCard> inventory,
    List<MTGDeck> groups, {
    required bool groupsFailed,
    required bool inventoryFailed,
    required bool inventoryAvailable,
    required bool isOwned,
  }) {
    final MTGCard metadata = _metadata ?? saved;
    final CardHoldings owned = CardHoldings(
      selected: _withQuote(saved),
      inventory: inventory.map(_withQuote),
    );
    final List<CardGroupHolding> locations = cardGroupHoldings(owned, groups);
    final Widget panel = switch (_tab) {
      1 => CardMarketsPanel(
        card: _withQuote(saved),
        holdings: owned.cards,
        holdingsAvailable: inventoryAvailable,
        printing: _printing,
        fetchedAt: _quoteDates[saved.printingId],
        refreshing: _refreshing,
        error: _marketError,
        onRefresh: _refreshMarkets,
        store: isOwned ? _store : null,
      ),
      2 =>
        inventoryAvailable
            ? _owned(saved, owned, groups, groupsFailed: groupsFailed)
            : const Text('Owned copies unavailable'),
      _ => _overview(
        metadata,
        saved,
        owned,
        totalsAvailable: inventoryAvailable,
      ),
    };
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints bounds) {
        final bool accessible =
            MediaQuery.textScalerOf(context).scale(14) > 20 ||
            bounds.maxHeight < 420;
        final List<Widget> actions = <Widget>[
          if (isOwned)
            _action('Organize', _busy ? null : () => _organize(saved)),
          _action(
            'Printings',
            _busy ? null : () => setState(() => _view = _CardView.printings),
          ),
          _action(
            'More',
            _busy ? null : () => setState(() => _view = _CardView.actions),
          ),
        ];
        final Widget footer = Flex(
          direction: accessible ? Axis.vertical : Axis.horizontal,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: accessible
              ? CrossAxisAlignment.stretch
              : CrossAxisAlignment.center,
          children: <Widget>[
            for (int index = 0; index < actions.length; index++) ...<Widget>[
              if (index > 0) const SizedBox(width: 6, height: 6),
              if (accessible)
                actions[index]
              else
                Expanded(child: actions[index]),
            ],
          ],
        );
        final List<Widget> header = <Widget>[
          _identity(
            saved,
            metadata,
            owned,
            totalsAvailable: inventoryAvailable,
            isOwned: isOwned,
          ),
          if (_tab == 0 && inventoryAvailable)
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                child: TextButton(
                  onPressed: () => setState(() => _tab = 2),
                  child: Text(
                    groupsFailed
                        ? 'Locations unavailable'
                        : locations.isEmpty
                        ? 'Not assigned'
                        : locations.length == 1
                        ? 'In ${locations.single.group.name}'
                        : '${locations.length} containers',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          if (_error != null)
            Text(_error!, style: const TextStyle(fontSize: 12)),
          if (inventoryFailed)
            const Text(
              'Owned totals unavailable',
              style: TextStyle(fontSize: 12),
            ),
          if (_marketError != null && _tab != 1)
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _marketError!,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                _action('Retry', _loadMetadata),
              ],
            ),
          _tabs(),
          const SizedBox(height: 12),
        ];
        if (accessible) {
          return ListView(
            key: const ValueKey<String>('card-details-scroll'),
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              ...header,
              panel,
              const SizedBox(height: 12),
              footer,
            ],
          );
        }
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ...header,
              Expanded(
                child: SingleChildScrollView(
                  key: ValueKey<int>(_tab),
                  child: panel,
                ),
              ),
              const SizedBox(height: 10),
              footer,
            ],
          ),
        );
      },
    );
  }

  Future<void> _saveQuantity(MTGCard saved) async {
    final int? quantity = int.tryParse(_copies.text.trim());
    if (quantity == null || quantity < 0 || quantity > 1000000) {
      setState(() => _error = 'Enter 0 to 1000000 copies');
      return;
    }
    if (quantity == 0) {
      await _confirmDelete(saved);
      return;
    }
    if (_busy || _id == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _store.txn(
        _id!,
        (MTGCard card) => card.copyWith(quantity: quantity)..id = card.id,
      );
      if (mounted) {
        _shortcuts.requestFocus();
        setState(() => _view = _CardView.details);
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not update quantity. Retry.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _selectedPrinting(PrintingSelection selection) {
    final MTGCard card = selection.card;
    _shortcuts.requestFocus();
    setState(() {
      _selected = card;
      _id = _inventoryId(card);
      _card = _id == null
          ? Stream<MTGCard?>.value(null)
          : _store.streamOrNull(_id!);
      _metadataRequest++;
      _metadata = card;
      _printing = selection.printing;
      if (selection.printing case final sf.MtgCard printing) {
        _freshPrintings[printing.id] = printing;
        _quoteDates[printing.id] = DateTime.now().toUtc();
      }
      _back = false;
      _tab = 0;
      _view = _CardView.details;
      _error = null;
      _marketError = null;
    });
    _loadMetadata();
  }

  Widget _editorFrame(String title, Widget body) => Padding(
    padding: EdgeInsets.fromLTRB(
      12,
      12,
      12,
      12 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _action('Done', _busy ? null : _returnToCard),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(child: body),
      ],
    ),
  );

  Widget? _editor(MTGCard saved, {required bool isOwned}) {
    switch (_view) {
      case _CardView.details:
        return null;
      case _CardView.organize:
        return _CardOrganizationEditor(
          card: _organizationCard ?? saved,
          groups: _groups,
          initialGroup: _organizationGroup,
          onClose: _returnToCard,
        );
      case _CardView.printings:
      case _CardView.add:
        final bool adding = _view == _CardView.add;
        return CardPrintingSelector(
          catalog: _catalog,
          addToCollection: adding,
          printingOnly: !adding,
          ingestion: CollectionIngestion(
            firestore: _store.collection.firestore,
          ),
          userId: _store.collection.parent!.id,
          groups: adding ? _memberships : null,
          initialQuery: '!"${saved.name.replaceAll('"', '\\"')}"',
          initialPrinting: _printing,
          initialFinish: saved.finish ?? sf.Finish.nonfoil,
          confirmLabel: adding ? 'Add copies' : 'View printing',
          onCancel: _returnToCard,
          onSelected: _selectedPrinting,
        );
      case _CardView.actions:
        final MTGCard metadata = _metadata ?? saved;
        final String? image = _back
            ? saved.backImageUrl ?? metadata.backImageUrl
            : saved.imageUrl ?? metadata.imageUrl;
        return _editorFrame(
          'Actions',
          ListView(
            children: <Widget>[
              _action(
                'Add copies',
                () => setState(() => _view = _CardView.add),
              ),
              const SizedBox(height: 8),
              _action(
                'Artwork',
                image == null
                    ? () {
                        _returnToCard();
                        _loadMetadata();
                      }
                    : () => _openArtwork(image, saved),
              ),
              const SizedBox(height: 8),
              _action('Rulings', () => _rules(metadata)),
              if (isOwned) ...<Widget>[
                const SizedBox(height: 24),
                _action(
                  'Delete Printing',
                  _busy ? null : () => _confirmDelete(saved),
                ),
              ],
            ],
          ),
        );
      case _CardView.rulings:
        return _editorFrame(
          'Rulings',
          FutureBuilder<List<sf.Ruling>>(
            future: _rulings,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<List<sf.Ruling>> snapshot,
                ) {
                  if (snapshot.hasError) {
                    return Column(
                      children: <Widget>[
                        const Text('Rulings unavailable'),
                        _action('Retry', () => _rules(_metadata ?? saved)),
                      ],
                    );
                  }
                  if (!snapshot.hasData) return const Text('Loading rulings…');
                  if (snapshot.data!.isEmpty) return const Text('No rulings');
                  return ListView(
                    children: <Widget>[
                      for (final sf.Ruling ruling in snapshot.data!)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                ruling.publishedAt
                                    .toIso8601String()
                                    .split('T')
                                    .first,
                                style: const TextStyle(fontSize: 12),
                              ).muted(),
                              const SizedBox(height: 4),
                              SelectableText(
                                ruling.comment,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
          ),
        );
      case _CardView.quantity:
        return _editorFrame(
          'Owned copies',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: ListView(
                  children: <Widget>[
                    Text(saved.name, style: const TextStyle(fontSize: 14)),
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey<String>('owned-quantity'),
                      controller: _copies,
                      semanticLabel: 'Owned copies',
                      keyboardType: TextInputType.number,
                      enabled: !_busy,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (String _) => _saveQuantity(saved),
                    ),
                    if (_error != null) Text(_error!),
                  ],
                ),
              ),
              _action(
                'Save quantity',
                _busy ? null : () => _saveQuantity(saved),
              ),
            ],
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (_view != _CardView.details) {
          _returnToCard();
        } else if (!_busy) {
          Navigator.maybePop(context);
        }
      },
    },
    child: Focus(
      focusNode: _shortcuts,
      autofocus: true,
      child: Scaffold(
        child: SafeArea(
          top: !context.inSheet,
          child: StreamBuilder<MTGCard?>(
            key: ValueKey<String?>(_id),
            stream: _card,
            builder: (BuildContext context, AsyncSnapshot<MTGCard?> snapshot) {
              if (snapshot.hasError) {
                return const Center(child: Text('Could not load card.'));
              }
              return StreamBuilder<List<MTGCard>>(
                stream: _inventory,
                builder:
                    (
                      BuildContext context,
                      AsyncSnapshot<List<MTGCard>> inventory,
                    ) {
                      _inventoryCards = inventory.data ?? <MTGCard>[];
                      final MTGCard? owned =
                          (inventory.hasError || _id == null
                              ? null
                              : _inventoryCards
                                    .where((MTGCard card) => card.id == _id)
                                    .firstOrNull) ??
                          snapshot.data;
                      final MTGCard saved = owned ?? _selected;
                      final Widget? editor = _editor(
                        saved,
                        isOwned: owned != null,
                      );
                      if (editor != null) return editor;
                      return StreamBuilder<List<MTGDeck>>(
                        stream: _memberships,
                        builder:
                            (
                              BuildContext context,
                              AsyncSnapshot<List<MTGDeck>> groups,
                            ) => _content(
                              saved,
                              _inventoryCards,
                              groups.data ?? <MTGDeck>[],
                              groupsFailed: groups.hasError,
                              inventoryFailed: inventory.hasError,
                              inventoryAvailable:
                                  inventory.hasData && !inventory.hasError,
                              isOwned: owned != null,
                            ),
                      );
                    },
              );
            },
          ),
        ),
      ),
    ),
  );
}

bool _matches(DeckEntry entry, MTGCard card) =>
    entry.scryfallId == card.printingId &&
    entry.finish == card.finish &&
    entry.language?.toLowerCase() == card.language?.toLowerCase();

class _CardOrganizationEditor extends StatefulWidget {
  final MTGCard card;
  final CollectionStore<MTGDeck> groups;
  final MTGDeck? initialGroup;
  final VoidCallback onClose;
  const _CardOrganizationEditor({
    required this.card,
    required this.groups,
    this.initialGroup,
    required this.onClose,
  });
  @override
  State<_CardOrganizationEditor> createState() =>
      _CardOrganizationEditorState();
}

class _CardOrganizationEditorState extends State<_CardOrganizationEditor> {
  late final CollectionOrganization _organization = CollectionOrganization(
    groups: widget.groups,
  );
  late final Stream<List<MTGDeck>> _groups = widget.groups.streamAll();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _quantity = TextEditingController(text: '1');
  final FocusNode _shortcuts = FocusNode();
  MTGDeck? _selected;
  CollectionGroupKind _kind = CollectionGroupKind.deck;
  DeckSection _section = DeckSection.mainboard;
  bool _creating = false;
  bool _saving = false;
  String? _createdId;
  String? _createOperationId;
  bool _creationStarted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final MTGDeck? group = widget.initialGroup;
    if (group != null) {
      _selected = group;
      _section =
          group.effectiveEntries
              .where((DeckEntry entry) => _matches(entry, widget.card))
              .firstOrNull
              ?.section ??
          DeckSection.mainboard;
      _quantity.text = '${_copies(group)}';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _quantity.dispose();
    _shortcuts.dispose();
    super.dispose();
  }

  void _select(MTGDeck group) {
    setState(() {
      _selected = group;
      _creating = false;
      _createdId = null;
      _createOperationId = null;
      _creationStarted = false;
      _section = DeckSection.mainboard;
      final int copies = _copies(group);
      _quantity.text = '${copies == 0 ? 1 : copies}';
      _error = null;
    });
    _shortcuts.requestFocus();
  }

  int _copies(MTGDeck group) => group.effectiveEntries
      .where(
        (DeckEntry entry) =>
            _matches(entry, widget.card) && entry.section == _section,
      )
      .fold<int>(0, (int sum, DeckEntry entry) => sum + entry.quantity);

  Widget _groupChoice(MTGDeck group) {
    final int copies = group.effectiveEntries
        .where((DeckEntry entry) => _matches(entry, widget.card))
        .fold<int>(0, (int sum, DeckEntry entry) => sum + entry.quantity);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Tile(
        key: ValueKey<String>('organize-group-${group.id}'),
        onPressed: () => _select(group),
        contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        title: Text(group.name),
        subtitle: Text(group.kind.name),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Semantics(
              label: '$copies copies in this group',
              child: Text('$copies×', style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.caret_right, size: 16),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    _shortcuts.requestFocus();
    final int? copies = int.tryParse(_quantity.text.trim());
    if (copies == null ||
        copies < 0 ||
        copies > 1000000 ||
        (_creating && _name.text.trim().isEmpty)) {
      setState(
        () => _error =
            'Enter a name and a whole number of copies from 0 to 1000000.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      if (_creating) {
        _creationStarted = true;
      }
    });
    try {
      final String id;
      if (_creating) {
        _createdId ??= await _organization.createGroup(
          name: _name.text,
          kind: _kind,
          operationId: _createOperationId,
        );
        id = _createdId!;
      } else {
        id = _selected!.id!;
      }
      await _organization.setCardMembership(
        card: widget.card,
        groupId: id,
        quantity: copies,
        section: _section,
      );
      if (mounted) {
        widget.onClose();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not save organization. Retry. Your owned count is unchanged.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Widget _editor() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      if (_creating) ...<Widget>[
        TextField(
          controller: _name,
          placeholder: const Text('Name'),
          enabled: !_saving && !_creationStarted,
          onChanged: (String value) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Selector<CollectionGroupKind>(
          value: _kind,
          values: CollectionGroupKind.values,
          labelBuilder: (CollectionGroupKind kind) => kind.name,
          onChanged: _saving || _creationStarted
              ? null
              : (CollectionGroupKind? kind) =>
                    setState(() => _kind = kind ?? _kind),
        ),
      ],
      const SizedBox(height: 12),
      if ((_selected?.kind ?? _kind) == CollectionGroupKind.deck) ...<Widget>[
        Selector<DeckSection>(
          value: _section,
          values: DeckSection.values,
          labelBuilder: (DeckSection section) => section.name,
          onChanged: _saving
              ? null
              : (DeckSection? section) => setState(() {
                  _section = section ?? _section;
                  _quantity.text = _selected == null
                      ? '1'
                      : '${_copies(_selected!)}';
                }),
        ),
        const SizedBox(height: 8),
      ],
      const Text('Copies in this group', style: TextStyle(fontSize: 12)),
      TextField(
        key: const ValueKey<String>('group-copies'),
        semanticLabel: 'Copies in this container',
        controller: _quantity,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        onSubmitted: (String _) => _save(),
        enabled: !_saving,
      ),
      const SizedBox(height: 8),
      const Text(
        '0 removes this membership. Owned quantity stays unchanged.',
        style: TextStyle(fontSize: 12),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!_saving) {
            widget.onClose();
          }
        },
      },
      child: Focus(
        focusNode: _shortcuts,
        autofocus: true,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            12,
            12,
            12,
            12 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SizedBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text(
                  'Organize',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                if (_selected != null) ...<Widget>[
                  Row(
                    key: const ValueKey<String>('organization-destination'),
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          _selected!.name,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        density: ButtonDensity(
                          (EdgeInsets padding) => const EdgeInsets.all(8),
                        ),
                        onPressed: _saving
                            ? null
                            : () => setState(() => _selected = null),
                        child: const Text(
                          'Change',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                Expanded(
                  child: SingleChildScrollView(
                    child: _creating || _selected != null
                        ? _editor()
                        : StreamBuilder<List<MTGDeck>>(
                            stream: _groups,
                            builder:
                                (
                                  BuildContext context,
                                  AsyncSnapshot<List<MTGDeck>> snapshot,
                                ) {
                                  if (snapshot.hasError) {
                                    return const Text(
                                      'Could not load groups. Close and retry.',
                                    );
                                  }
                                  if (!snapshot.hasData) {
                                    return const Text('Loading groups…');
                                  }
                                  final List<MTGDeck> groups = snapshot.data!;
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: <Widget>[
                                      if (groups.isEmpty)
                                        const Text('No groups yet.'),
                                      for (final MTGDeck group in groups)
                                        _groupChoice(group),
                                    ],
                                  );
                                },
                          ),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    TextButton(
                      density: ButtonDensity(
                        (EdgeInsets padding) => const EdgeInsets.all(8),
                      ),
                      onPressed: _saving ? null : widget.onClose,
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    if (_selected != null || _creating)
                      PrimaryButton(
                        key: const ValueKey<String>('organization-save'),
                        density: ButtonDensity(
                          (EdgeInsets padding) => const EdgeInsets.all(8),
                        ),
                        onPressed: _saving ? null : _save,
                        child: Text(
                          _saving ? 'Saving…' : 'Save',
                          style: const TextStyle(fontSize: 12),
                        ),
                      )
                    else
                      PrimaryButton(
                        onPressed: () => setState(() {
                          _creating = true;
                          _createOperationId = widget.groups.collection
                              .doc()
                              .id;
                          _creationStarted = false;
                          _quantity.text = '1';
                        }),
                        child: const Text('New group'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
