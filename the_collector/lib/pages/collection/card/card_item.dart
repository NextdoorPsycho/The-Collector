import 'package:arcane/arcane.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:collector_models/card/mtg_card.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/pages/collection/card/card.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/utils/card_catalog.dart';
import 'package:the_collector/utils/crud.dart';

Widget buildCardItem(
  MTGCard card, {
  CollectionStore<MTGCard>? store,
  CardCatalog? catalog,
  bool selecting = false,
  bool selected = false,
  bool enabled = true,
  VoidCallback? onSelect,
}) => Builder(
  builder: (BuildContext context) {
    final CollectionStore<MTGCard> ownerStore = store ?? Crud.card(u);
    final Color muted = Theme.of(context).colorScheme.mutedForeground;
    final double? unitPrice = card.unitPrice(CardCurrency.usd);
    final String value = unitPrice == null
        ? '—'
        : 'USD ${(unitPrice * card.quantity).toStringAsFixed(2)}';
    final String finish = switch (card.finish) {
      sf.Finish.nonfoil => 'Normal',
      sf.Finish.foil => 'Foil',
      sf.Finish.etched => 'Etched',
      sf.Finish.glossy => 'Glossy',
      _ => 'Unknown finish',
    };
    final String details = <String>[
      finish,
      if (card.language != null) card.language!.toUpperCase(),
    ].join(' · ');
    void activate() {
      if (selecting) {
        onSelect?.call();
      } else {
        openCardDetails(context, card: card, store: ownerStore, catalog: catalog);
      }
    }

    final Widget information = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          card.name,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          '${(card.setCode ?? card.setId).toUpperCase()} #${card.collectorNumber ?? "?"}',
          style: TextStyle(fontSize: 12, color: muted),
        ),
        Text(details, style: TextStyle(fontSize: 12, color: muted)),
      ],
    );
    final Widget totals = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Text(
          '${card.quantity} ${card.quantity == 1 ? 'copy' : 'copies'}',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 12, color: muted)),
      ],
    );
    final Widget artwork = SizedBox(
      width: 38,
      height: 53,
      child: card.imageUrl == null
          ? const Center(child: Icon(Icons.cards, size: 20))
          : Image.network(
              card.imageUrl!,
              fit: BoxFit.cover,
              cacheWidth: 114,
              errorBuilder: (
                BuildContext context,
                Object error,
                StackTrace? stack,
              ) => const Center(child: Icon(Icons.cards, size: 20)),
            ),
    );
    return Semantics(
      button: true,
      selected: selecting ? selected : null,
      label: '${card.name}, ${card.quantity} copies, $details, $value',
      onTap: enabled ? activate : null,
      child: ButtonStyleOverride(
        decoration:
            (
              BuildContext context,
              Set<WidgetState> states,
              Decoration decoration,
            ) => BoxDecoration(
              color: selected || states.contains(WidgetState.pressed)
                  ? Theme.of(context).colorScheme.muted
                  : Theme.of(context).colorScheme.background,
              border: states.contains(WidgetState.focused)
                  ? Border.all(color: Theme.of(context).colorScheme.foreground)
                  : null,
            ),
        child: CardButton(
          onPressed: enabled ? activate : null,
          density: ButtonDensity((EdgeInsets padding) => EdgeInsets.zero),
          onLongPressStart: enabled && onSelect != null
              ? (_) => onSelect()
              : null,
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final bool stacked =
                      constraints.maxWidth <
                      250 * MediaQuery.textScalerOf(context).scale(1);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      if (selecting) ...<Widget>[
                        Icon(
                          selected ? Icons.check_square : Icons.square,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                      ],
                      artwork,
                      const SizedBox(width: 10),
                      Expanded(
                        child: stacked
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  information,
                                  const SizedBox(height: 6),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: totals,
                                  ),
                                ],
                              )
                            : information,
                      ),
                      if (!stacked) ...<Widget>[
                        const SizedBox(width: 8),
                        totals,
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  },
);
