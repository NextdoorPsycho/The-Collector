//Garnerd from here:
//https://scryfall.com/docs/api/bulk-data
//https://data.scryfall.io/all-cards/all-cards-20240413211922.json
// 20240413211922 this is extrapolated from the date: 	2024-04-13 21:19 UTC  (YYYY-MM-DD HH:MM UTC)

class Card {
  final String object;
  final String id;
  final String oracleId;
  final List<int> multiverseIds;
  final int mtgoId;
  final int mtgoFoilId;
  final int tcgplayerId;
  final int cardmarketId;
  final String name;
  final String lang;
  final DateTime releasedAt;
  final String uri;
  final String scryfallUri;
  final String layout;
  final bool highresImage;
  final String imageStatus;
  final Map<String, String> imageUris;
  final String manaCost;
  final double cmc;
  final String typeLine;
  final String oracleText;
  final String power;
  final String toughness;
  final List<String> colors;
  final List<String> colorIdentity;
  final List<String> keywords;
  final Map<String, String> legalities;
  final List<String> games;
  final bool reserved;
  final bool foil;
  final bool nonfoil;
  final List<String> finishes;
  final bool oversized;
  final bool promo;
  final bool reprint;
  final bool variation;
  final String setId;
  final String set;
  final String setName;
  final String setType;
  final String setUri;
  final String setSearchUri;
  final String scryfallSetUri;
  final String rulingsUri;
  final String printsSearchUri;
  final String collectorNumber;
  final bool digital;
  final String rarity;
  final String flavorText;
  final String cardBackId;
  final String artist;
  final List<String> artistIds;
  final String illustrationId;
  final String borderColor;
  final String frame;
  final bool fullArt;
  final bool textless;
  final bool booster;
  final bool storySpotlight;
  final int edhrecRank;
  final int pennyRank;
  final Map<String, String?> prices;
  final Map<String, String> relatedUris;
  final Map<String, String> purchaseUris;

  Card({
    required this.object,
    required this.id,
    required this.oracleId,
    required this.multiverseIds,
    required this.mtgoId,
    required this.mtgoFoilId,
    required this.tcgplayerId,
    required this.cardmarketId,
    required this.name,
    required this.lang,
    required this.releasedAt,
    required this.uri,
    required this.scryfallUri,
    required this.layout,
    required this.highresImage,
    required this.imageStatus,
    required this.imageUris,
    required this.manaCost,
    required this.cmc,
    required this.typeLine,
    required this.oracleText,
    required this.power,
    required this.toughness,
    required this.colors,
    required this.colorIdentity,
    required this.keywords,
    required this.legalities,
    required this.games,
    required this.reserved,
    required this.foil,
    required this.nonfoil,
    required this.finishes,
    required this.oversized,
    required this.promo,
    required this.reprint,
    required this.variation,
    required this.setId,
    required this.set,
    required this.setName,
    required this.setType,
    required this.setUri,
    required this.setSearchUri,
    required this.scryfallSetUri,
    required this.rulingsUri,
    required this.printsSearchUri,
    required this.collectorNumber,
    required this.digital,
    required this.rarity,
    required this.flavorText,
    required this.cardBackId,
    required this.artist,
    required this.artistIds,
    required this.illustrationId,
    required this.borderColor,
    required this.frame,
    required this.fullArt,
    required this.textless,
    required this.booster,
    required this.storySpotlight,
    required this.edhrecRank,
    required this.pennyRank,
    required this.prices,
    required this.relatedUris,
    required this.purchaseUris,
  });

  factory Card.fromJson(Map<String, dynamic> json) {
    return Card(
      object: json['object'],
      id: json['id'],
      oracleId: json['oracle_id'],
      multiverseIds: List<int>.from(json['multiverse_ids']),
      mtgoId: json['mtgo_id'],
      mtgoFoilId: json['mtgo_foil_id'],
      tcgplayerId: json['tcgplayer_id'],
      cardmarketId: json['cardmarket_id'],
      name: json['name'],
      lang: json['lang'],
      releasedAt: DateTime.parse(json['released_at']),
      uri: json['uri'],
      scryfallUri: json['scryfall_uri'],
      layout: json['layout'],
      highresImage: json['highres_image'],
      imageStatus: json['image_status'],
      imageUris: Map<String, String>.from(json['image_uris']),
      manaCost: json['mana_cost'],
      cmc: json['cmc'].toDouble(),
      typeLine: json['type_line'],
      oracleText: json['oracle_text'],
      power: json['power'],
      toughness: json['toughness'],
      colors: List<String>.from(json['colors']),
      colorIdentity: List<String>.from(json['color_identity']),
      keywords: List<String>.from(json['keywords']),
      legalities: Map<String, String>.from(json['legalities']),
      games: List<String>.from(json['games']),
      reserved: json['reserved'],
      foil: json['foil'],
      nonfoil: json['nonfoil'],
      finishes: List<String>.from(json['finishes']),
      oversized: json['oversized'],
      promo: json['promo'],
      reprint: json['reprint'],
      variation: json['variation'],
      setId: json['set_id'],
      set: json['set'],
      setName: json['set_name'],
      setType: json['set_type'],
      setUri: json['set_uri'],
      setSearchUri: json['set_search_uri'],
      scryfallSetUri: json['scryfall_set_uri'],
      rulingsUri: json['rulings_uri'],
      printsSearchUri: json['prints_search_uri'],
      collectorNumber: json['collector_number'],
      digital: json['digital'],
      rarity: json['rarity'],
      flavorText: json['flavor_text'],
      cardBackId: json['card_back_id'],
      artist: json['artist'],
      artistIds: List<String>.from(json['artist_ids']),
      illustrationId: json['illustration_id'],
      borderColor: json['border_color'],
      frame: json['frame'],
      fullArt: json['full_art'],
      textless: json['textless'],
      booster: json['booster'],
      storySpotlight: json['story_spotlight'],
      edhrecRank: json['edhrec_rank'],
      pennyRank: json['penny_rank'],
      prices: Map<String, String?>.from(json['prices']),
      relatedUris: Map<String, String>.from(json['related_uris']),
      purchaseUris: Map<String, String>.from(json['purchase_uris']),
    );
  }
}
