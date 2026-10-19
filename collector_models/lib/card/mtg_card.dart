import 'package:dart_mappable/dart_mappable.dart';
import 'package:scryfall_api/scryfall_api.dart';

import 'scryfall_enum_mapper.dart';
import 'card_prices.dart';

part 'mtg_card.mapper.dart';

@MappableClass(
  includeCustomMappers: <MapperBase<Object>>[
    ScryfallEnumMapper<BorderColor>(BorderColor.values),
    ScryfallEnumMapper<SetType>(SetType.values),
    ScryfallEnumMapper<Rarity>(Rarity.values),
    ScryfallEnumMapper<Finish>(Finish.values),
    ScryfallEnumMapper<Color>(Color.values),
  ],
)
class MTGCard with MTGCardMappable {
  String? id;
  final String name;
  final String setId;
  final String description;
  final String flavorText;
  final double cmc;
  final String typeLine;
  BorderColor? borderColor;
  final Rarity rarity;
  final int quantity;

  final SetType setType;
  final String? manaCost;
  final String? scryfallId;
  final String? oracleId;
  final String? setCode;
  final String? setName;
  final String? collectorNumber;
  final String? language;
  final Finish? finish;
  final List<Color> colors;
  final List<Color> colorIdentity;
  final String? oracleText;
  final String? imageUrl;
  final String? backImageUrl;
  final CardPrices? prices;
  final DateTime? pricesUpdatedAt;
  final Map<String, String> legalities;
  final List<String> keywords;

  MTGCard({
    required this.name,
    required this.setId,
    required this.description,
    this.quantity = 1,
    required this.cmc,
    required this.typeLine,
    required this.flavorText,
    this.borderColor,
    required this.setType,
    required this.rarity,
    required this.manaCost,
    this.scryfallId,
    this.oracleId,
    this.setCode,
    this.setName,
    this.collectorNumber,
    this.language,
    this.finish,
    this.colors = const <Color>[],
    this.colorIdentity = const <Color>[],
    this.oracleText,
    this.imageUrl,
    this.backImageUrl,
    this.prices,
    this.pricesUpdatedAt,
    this.legalities = const <String, String>{},
    this.keywords = const <String>[],
  });

  String? get printingId => scryfallId ?? id?.split('__').first;

  double? unitPrice(CardCurrency currency) =>
      prices?.forFinish(finish, currency);
}
