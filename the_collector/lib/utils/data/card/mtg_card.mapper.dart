// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'mtg_card.dart';

class MTGCardMapper extends ClassMapperBase<MTGCard> {
  MTGCardMapper._();

  static MTGCardMapper? _instance;
  static MTGCardMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = MTGCardMapper._());
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
  static const Field<MTGCard, String> _f$description =
      Field('description', _$description);
  static int _$quantity(MTGCard v) => v.quantity;
  static const Field<MTGCard, int> _f$quantity =
      Field('quantity', _$quantity, opt: true, def: 1);
  static double _$cmc(MTGCard v) => v.cmc;
  static const Field<MTGCard, double> _f$cmc = Field('cmc', _$cmc);
  static String _$typeLine(MTGCard v) => v.typeLine;
  static const Field<MTGCard, String> _f$typeLine =
      Field('typeLine', _$typeLine);
  static String _$flavorText(MTGCard v) => v.flavorText;
  static const Field<MTGCard, String> _f$flavorText =
      Field('flavorText', _$flavorText);
  static BorderColor? _$borderColor(MTGCard v) => v.borderColor;
  static const Field<MTGCard, BorderColor> _f$borderColor =
      Field('borderColor', _$borderColor, opt: true);
  static SetType _$setType(MTGCard v) => v.setType;
  static const Field<MTGCard, SetType> _f$setType = Field('setType', _$setType);
  static Rarity _$rarity(MTGCard v) => v.rarity;
  static const Field<MTGCard, Rarity> _f$rarity = Field('rarity', _$rarity);
  static dynamic _$manaCost(MTGCard v) => v.manaCost;
  static const Field<MTGCard, dynamic> _f$manaCost =
      Field('manaCost', _$manaCost);
  static String? _$id(MTGCard v) => v.id;
  static const Field<MTGCard, String> _f$id =
      Field('id', _$id, mode: FieldMode.member);

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
        manaCost: data.dec(_f$manaCost));
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
    return MTGCardMapper.ensureInitialized()
        .encodeJson<MTGCard>(this as MTGCard);
  }

  Map<String, dynamic> toMap() {
    return MTGCardMapper.ensureInitialized()
        .encodeMap<MTGCard>(this as MTGCard);
  }

  MTGCardCopyWith<MTGCard, MTGCard, MTGCard> get copyWith =>
      _MTGCardCopyWithImpl(this as MTGCard, $identity, $identity);
  @override
  String toString() {
    return MTGCardMapper.ensureInitialized().stringifyValue(this as MTGCard);
  }

  @override
  bool operator ==(Object other) {
    return MTGCardMapper.ensureInitialized()
        .equalsValue(this as MTGCard, other);
  }

  @override
  int get hashCode {
    return MTGCardMapper.ensureInitialized().hashValue(this as MTGCard);
  }
}

extension MTGCardValueCopy<$R, $Out> on ObjectCopyWith<$R, MTGCard, $Out> {
  MTGCardCopyWith<$R, MTGCard, $Out> get $asMTGCard =>
      $base.as((v, t, t2) => _MTGCardCopyWithImpl(v, t, t2));
}

abstract class MTGCardCopyWith<$R, $In extends MTGCard, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call(
      {String? name,
      String? setId,
      String? description,
      int? quantity,
      double? cmc,
      String? typeLine,
      String? flavorText,
      BorderColor? borderColor,
      SetType? setType,
      Rarity? rarity,
      dynamic manaCost});
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
  $R call(
          {String? name,
          String? setId,
          String? description,
          int? quantity,
          double? cmc,
          String? typeLine,
          String? flavorText,
          Object? borderColor = $none,
          SetType? setType,
          Rarity? rarity,
          Object? manaCost = $none}) =>
      $apply(FieldCopyWithData({
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
        if (manaCost != $none) #manaCost: manaCost
      }));
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
      manaCost: data.get(#manaCost, or: $value.manaCost));

  @override
  MTGCardCopyWith<$R2, MTGCard, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _MTGCardCopyWithImpl($value, $cast, t);
}
