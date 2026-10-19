// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'mtg_card.dart';

class MTGCardMapper extends ClassMapperBase<MTGCard> {
  MTGCardMapper._();

  static MTGCardMapper? _instance;
  static MTGCardMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = MTGCardMapper._());
      MapperContainer.globals.useAll(<MapperBase<Object>>[
        ScryfallEnumMapper<BorderColor>(BorderColor.values),
        ScryfallEnumMapper<SetType>(SetType.values),
        ScryfallEnumMapper<Rarity>(Rarity.values),
        ScryfallEnumMapper<Finish>(Finish.values),
        ScryfallEnumMapper<Color>(Color.values),
      ]);
      CardPricesMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'MTGCard';

  static String _$name(MTGCard v) => v.name;
  static const Field<MTGCard, String> _f$name = Field('name', _$name);
  static String _$setId(MTGCard v) => v.setId;
  static const Field<MTGCard, String> _f$setId = Field('setId', _$setId);
  static String _$description(MTGCard v) => v.description;
  static const Field<MTGCard, String> _f$description = Field(
    'description',
    _$description,
  );
  static int _$quantity(MTGCard v) => v.quantity;
  static const Field<MTGCard, int> _f$quantity = Field(
    'quantity',
    _$quantity,
    opt: true,
    def: 1,
  );
  static double _$cmc(MTGCard v) => v.cmc;
  static const Field<MTGCard, double> _f$cmc = Field('cmc', _$cmc);
  static String _$typeLine(MTGCard v) => v.typeLine;
  static const Field<MTGCard, String> _f$typeLine = Field(
    'typeLine',
    _$typeLine,
  );
  static String _$flavorText(MTGCard v) => v.flavorText;
  static const Field<MTGCard, String> _f$flavorText = Field(
    'flavorText',
    _$flavorText,
  );
  static BorderColor? _$borderColor(MTGCard v) => v.borderColor;
  static const Field<MTGCard, BorderColor> _f$borderColor = Field(
    'borderColor',
    _$borderColor,
    opt: true,
  );
  static SetType _$setType(MTGCard v) => v.setType;
  static const Field<MTGCard, SetType> _f$setType = Field('setType', _$setType);
  static Rarity _$rarity(MTGCard v) => v.rarity;
  static const Field<MTGCard, Rarity> _f$rarity = Field('rarity', _$rarity);
  static String? _$manaCost(MTGCard v) => v.manaCost;
  static const Field<MTGCard, String> _f$manaCost = Field(
    'manaCost',
    _$manaCost,
  );
  static String? _$scryfallId(MTGCard v) => v.scryfallId;
  static const Field<MTGCard, String> _f$scryfallId = Field(
    'scryfallId',
    _$scryfallId,
    opt: true,
  );
  static String? _$oracleId(MTGCard v) => v.oracleId;
  static const Field<MTGCard, String> _f$oracleId = Field(
    'oracleId',
    _$oracleId,
    opt: true,
  );
  static String? _$setCode(MTGCard v) => v.setCode;
  static const Field<MTGCard, String> _f$setCode = Field(
    'setCode',
    _$setCode,
    opt: true,
  );
  static String? _$setName(MTGCard v) => v.setName;
  static const Field<MTGCard, String> _f$setName = Field(
    'setName',
    _$setName,
    opt: true,
  );
  static String? _$collectorNumber(MTGCard v) => v.collectorNumber;
  static const Field<MTGCard, String> _f$collectorNumber = Field(
    'collectorNumber',
    _$collectorNumber,
    opt: true,
  );
  static String? _$language(MTGCard v) => v.language;
  static const Field<MTGCard, String> _f$language = Field(
    'language',
    _$language,
    opt: true,
  );
  static Finish? _$finish(MTGCard v) => v.finish;
  static const Field<MTGCard, Finish> _f$finish = Field(
    'finish',
    _$finish,
    opt: true,
  );
  static List<Color> _$colors(MTGCard v) => v.colors;
  static const Field<MTGCard, List<Color>> _f$colors = Field(
    'colors',
    _$colors,
    opt: true,
    def: const <Color>[],
  );
  static List<Color> _$colorIdentity(MTGCard v) => v.colorIdentity;
  static const Field<MTGCard, List<Color>> _f$colorIdentity = Field(
    'colorIdentity',
    _$colorIdentity,
    opt: true,
    def: const <Color>[],
  );
  static String? _$oracleText(MTGCard v) => v.oracleText;
  static const Field<MTGCard, String> _f$oracleText = Field(
    'oracleText',
    _$oracleText,
    opt: true,
  );
  static String? _$imageUrl(MTGCard v) => v.imageUrl;
  static const Field<MTGCard, String> _f$imageUrl = Field(
    'imageUrl',
    _$imageUrl,
    opt: true,
  );
  static String? _$backImageUrl(MTGCard v) => v.backImageUrl;
  static const Field<MTGCard, String> _f$backImageUrl = Field(
    'backImageUrl',
    _$backImageUrl,
    opt: true,
  );
  static CardPrices? _$prices(MTGCard v) => v.prices;
  static const Field<MTGCard, CardPrices> _f$prices = Field(
    'prices',
    _$prices,
    opt: true,
  );
  static DateTime? _$pricesUpdatedAt(MTGCard v) => v.pricesUpdatedAt;
  static const Field<MTGCard, DateTime> _f$pricesUpdatedAt = Field(
    'pricesUpdatedAt',
    _$pricesUpdatedAt,
    opt: true,
  );
  static Map<String, String> _$legalities(MTGCard v) => v.legalities;
  static const Field<MTGCard, Map<String, String>> _f$legalities = Field(
    'legalities',
    _$legalities,
    opt: true,
    def: const <String, String>{},
  );
  static List<String> _$keywords(MTGCard v) => v.keywords;
  static const Field<MTGCard, List<String>> _f$keywords = Field(
    'keywords',
    _$keywords,
    opt: true,
    def: const <String>[],
  );
  static String? _$id(MTGCard v) => v.id;
  static const Field<MTGCard, String> _f$id = Field(
    'id',
    _$id,
    mode: FieldMode.member,
  );

  @override
  final MappableFields<MTGCard> fields = const {
    #name: _f$name,
    #setId: _f$setId,
    #description: _f$description,
    #quantity: _f$quantity,
    #cmc: _f$cmc,
    #typeLine: _f$typeLine,
    #flavorText: _f$flavorText,
    #borderColor: _f$borderColor,
    #setType: _f$setType,
    #rarity: _f$rarity,
    #manaCost: _f$manaCost,
    #scryfallId: _f$scryfallId,
    #oracleId: _f$oracleId,
    #setCode: _f$setCode,
    #setName: _f$setName,
    #collectorNumber: _f$collectorNumber,
    #language: _f$language,
    #finish: _f$finish,
    #colors: _f$colors,
    #colorIdentity: _f$colorIdentity,
    #oracleText: _f$oracleText,
    #imageUrl: _f$imageUrl,
    #backImageUrl: _f$backImageUrl,
    #prices: _f$prices,
    #pricesUpdatedAt: _f$pricesUpdatedAt,
    #legalities: _f$legalities,
    #keywords: _f$keywords,
    #id: _f$id,
  };

  static MTGCard _instantiate(DecodingData data) {
    return MTGCard(
      name: data.dec(_f$name),
      setId: data.dec(_f$setId),
      description: data.dec(_f$description),
      quantity: data.dec(_f$quantity),
      cmc: data.dec(_f$cmc),
      typeLine: data.dec(_f$typeLine),
      flavorText: data.dec(_f$flavorText),
      borderColor: data.dec(_f$borderColor),
      setType: data.dec(_f$setType),
      rarity: data.dec(_f$rarity),
      manaCost: data.dec(_f$manaCost),
      scryfallId: data.dec(_f$scryfallId),
      oracleId: data.dec(_f$oracleId),
      setCode: data.dec(_f$setCode),
      setName: data.dec(_f$setName),
      collectorNumber: data.dec(_f$collectorNumber),
      language: data.dec(_f$language),
      finish: data.dec(_f$finish),
      colors: data.dec(_f$colors),
      colorIdentity: data.dec(_f$colorIdentity),
      oracleText: data.dec(_f$oracleText),
      imageUrl: data.dec(_f$imageUrl),
      backImageUrl: data.dec(_f$backImageUrl),
      prices: data.dec(_f$prices),
      pricesUpdatedAt: data.dec(_f$pricesUpdatedAt),
      legalities: data.dec(_f$legalities),
      keywords: data.dec(_f$keywords),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static MTGCard fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<MTGCard>(map);
  }

  static MTGCard fromJson(String json) {
    return ensureInitialized().decodeJson<MTGCard>(json);
  }
}

mixin MTGCardMappable {
  String toJson() {
    return MTGCardMapper.ensureInitialized().encodeJson<MTGCard>(
      this as MTGCard,
    );
  }

  Map<String, dynamic> toMap() {
    return MTGCardMapper.ensureInitialized().encodeMap<MTGCard>(
      this as MTGCard,
    );
  }

  MTGCardCopyWith<MTGCard, MTGCard, MTGCard> get copyWith =>
      _MTGCardCopyWithImpl<MTGCard, MTGCard>(
        this as MTGCard,
        $identity,
        $identity,
      );
  @override
  String toString() {
    return MTGCardMapper.ensureInitialized().stringifyValue(this as MTGCard);
  }

  @override
  bool operator ==(Object other) {
    return MTGCardMapper.ensureInitialized().equalsValue(
      this as MTGCard,
      other,
    );
  }

  @override
  int get hashCode {
    return MTGCardMapper.ensureInitialized().hashValue(this as MTGCard);
  }
}

extension MTGCardValueCopy<$R, $Out> on ObjectCopyWith<$R, MTGCard, $Out> {
  MTGCardCopyWith<$R, MTGCard, $Out> get $asMTGCard =>
      $base.as((v, t, t2) => _MTGCardCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class MTGCardCopyWith<$R, $In extends MTGCard, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, Color, ObjectCopyWith<$R, Color, Color>> get colors;
  ListCopyWith<$R, Color, ObjectCopyWith<$R, Color, Color>> get colorIdentity;
  CardPricesCopyWith<$R, CardPrices, CardPrices>? get prices;
  MapCopyWith<$R, String, String, ObjectCopyWith<$R, String, String>>
  get legalities;
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>> get keywords;
  $R call({
    String? name,
    String? setId,
    String? description,
    int? quantity,
    double? cmc,
    String? typeLine,
    String? flavorText,
    BorderColor? borderColor,
    SetType? setType,
    Rarity? rarity,
    String? manaCost,
    String? scryfallId,
    String? oracleId,
    String? setCode,
    String? setName,
    String? collectorNumber,
    String? language,
    Finish? finish,
    List<Color>? colors,
    List<Color>? colorIdentity,
    String? oracleText,
    String? imageUrl,
    String? backImageUrl,
    CardPrices? prices,
    DateTime? pricesUpdatedAt,
    Map<String, String>? legalities,
    List<String>? keywords,
  });
  MTGCardCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _MTGCardCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, MTGCard, $Out>
    implements MTGCardCopyWith<$R, MTGCard, $Out> {
  _MTGCardCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<MTGCard> $mapper =
      MTGCardMapper.ensureInitialized();
  @override
  ListCopyWith<$R, Color, ObjectCopyWith<$R, Color, Color>> get colors =>
      ListCopyWith(
        $value.colors,
        (v, t) => ObjectCopyWith(v, $identity, t),
        (v) => call(colors: v),
      );
  @override
  ListCopyWith<$R, Color, ObjectCopyWith<$R, Color, Color>> get colorIdentity =>
      ListCopyWith(
        $value.colorIdentity,
        (v, t) => ObjectCopyWith(v, $identity, t),
        (v) => call(colorIdentity: v),
      );
  @override
  CardPricesCopyWith<$R, CardPrices, CardPrices>? get prices =>
      $value.prices?.copyWith.$chain((v) => call(prices: v));
  @override
  MapCopyWith<$R, String, String, ObjectCopyWith<$R, String, String>>
  get legalities => MapCopyWith(
    $value.legalities,
    (v, t) => ObjectCopyWith(v, $identity, t),
    (v) => call(legalities: v),
  );
  @override
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>> get keywords =>
      ListCopyWith(
        $value.keywords,
        (v, t) => ObjectCopyWith(v, $identity, t),
        (v) => call(keywords: v),
      );
  @override
  $R call({
    String? name,
    String? setId,
    String? description,
    int? quantity,
    double? cmc,
    String? typeLine,
    String? flavorText,
    Object? borderColor = $none,
    SetType? setType,
    Rarity? rarity,
    Object? manaCost = $none,
    Object? scryfallId = $none,
    Object? oracleId = $none,
    Object? setCode = $none,
    Object? setName = $none,
    Object? collectorNumber = $none,
    Object? language = $none,
    Object? finish = $none,
    List<Color>? colors,
    List<Color>? colorIdentity,
    Object? oracleText = $none,
    Object? imageUrl = $none,
    Object? backImageUrl = $none,
    Object? prices = $none,
    Object? pricesUpdatedAt = $none,
    Map<String, String>? legalities,
    List<String>? keywords,
  }) => $apply(
    FieldCopyWithData({
      if (name != null) #name: name,
      if (setId != null) #setId: setId,
      if (description != null) #description: description,
      if (quantity != null) #quantity: quantity,
      if (cmc != null) #cmc: cmc,
      if (typeLine != null) #typeLine: typeLine,
      if (flavorText != null) #flavorText: flavorText,
      if (borderColor != $none) #borderColor: borderColor,
      if (setType != null) #setType: setType,
      if (rarity != null) #rarity: rarity,
      if (manaCost != $none) #manaCost: manaCost,
      if (scryfallId != $none) #scryfallId: scryfallId,
      if (oracleId != $none) #oracleId: oracleId,
      if (setCode != $none) #setCode: setCode,
      if (setName != $none) #setName: setName,
      if (collectorNumber != $none) #collectorNumber: collectorNumber,
      if (language != $none) #language: language,
      if (finish != $none) #finish: finish,
      if (colors != null) #colors: colors,
      if (colorIdentity != null) #colorIdentity: colorIdentity,
      if (oracleText != $none) #oracleText: oracleText,
      if (imageUrl != $none) #imageUrl: imageUrl,
      if (backImageUrl != $none) #backImageUrl: backImageUrl,
      if (prices != $none) #prices: prices,
      if (pricesUpdatedAt != $none) #pricesUpdatedAt: pricesUpdatedAt,
      if (legalities != null) #legalities: legalities,
      if (keywords != null) #keywords: keywords,
    }),
  );
  @override
  MTGCard $make(CopyWithData data) => MTGCard(
    name: data.get(#name, or: $value.name),
    setId: data.get(#setId, or: $value.setId),
    description: data.get(#description, or: $value.description),
    quantity: data.get(#quantity, or: $value.quantity),
    cmc: data.get(#cmc, or: $value.cmc),
    typeLine: data.get(#typeLine, or: $value.typeLine),
    flavorText: data.get(#flavorText, or: $value.flavorText),
    borderColor: data.get(#borderColor, or: $value.borderColor),
    setType: data.get(#setType, or: $value.setType),
    rarity: data.get(#rarity, or: $value.rarity),
    manaCost: data.get(#manaCost, or: $value.manaCost),
    scryfallId: data.get(#scryfallId, or: $value.scryfallId),
    oracleId: data.get(#oracleId, or: $value.oracleId),
    setCode: data.get(#setCode, or: $value.setCode),
    setName: data.get(#setName, or: $value.setName),
    collectorNumber: data.get(#collectorNumber, or: $value.collectorNumber),
    language: data.get(#language, or: $value.language),
    finish: data.get(#finish, or: $value.finish),
    colors: data.get(#colors, or: $value.colors),
    colorIdentity: data.get(#colorIdentity, or: $value.colorIdentity),
    oracleText: data.get(#oracleText, or: $value.oracleText),
    imageUrl: data.get(#imageUrl, or: $value.imageUrl),
    backImageUrl: data.get(#backImageUrl, or: $value.backImageUrl),
    prices: data.get(#prices, or: $value.prices),
    pricesUpdatedAt: data.get(#pricesUpdatedAt, or: $value.pricesUpdatedAt),
    legalities: data.get(#legalities, or: $value.legalities),
    keywords: data.get(#keywords, or: $value.keywords),
  );

  @override
  MTGCardCopyWith<$R2, MTGCard, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _MTGCardCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

