// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'mtg_land.dart';

class MTGLandCardMapper extends ClassMapperBase<MTGLandCard> {
  MTGLandCardMapper._();

  static MTGLandCardMapper? _instance;
  static MTGLandCardMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = MTGLandCardMapper._());
      MTGCardMapper.ensureInitialized();
      CardTypeMapper.ensureInitialized();
      ManaColorMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'MTGLandCard';

  static String _$name(MTGLandCard v) => v.name;
  static const Field<MTGLandCard, String> _f$name = Field('name', _$name);
  static String _$setId(MTGLandCard v) => v.setId;
  static const Field<MTGLandCard, String> _f$setId = Field('setId', _$setId);
  static String _$description(MTGLandCard v) => v.description;
  static const Field<MTGLandCard, String> _f$description =
      Field('description', _$description);
  static String _$flavorText(MTGLandCard v) => v.flavorText;
  static const Field<MTGLandCard, String> _f$flavorText =
      Field('flavorText', _$flavorText);
  static String _$rarity(MTGLandCard v) => v.rarity;
  static const Field<MTGLandCard, String> _f$rarity = Field('rarity', _$rarity);
  static dynamic _$manaCost(MTGLandCard v) => v.manaCost;
  static const Field<MTGLandCard, dynamic> _f$manaCost =
      Field('manaCost', _$manaCost);
  static int _$quantity(MTGLandCard v) => v.quantity;
  static const Field<MTGLandCard, int> _f$quantity =
      Field('quantity', _$quantity, opt: true, def: 1);
  static CardType _$cardType(MTGLandCard v) => v.cardType;
  static const Field<MTGLandCard, CardType> _f$cardType =
      Field('cardType', _$cardType, opt: true, def: CardType.land);
  static ManaColor _$manaColor(MTGLandCard v) => v.manaColor;
  static const Field<MTGLandCard, ManaColor> _f$manaColor =
      Field('manaColor', _$manaColor);
  static int _$manaValue(MTGLandCard v) => v.manaValue;
  static const Field<MTGLandCard, int> _f$manaValue =
      Field('manaValue', _$manaValue);
  static String? _$id(MTGLandCard v) => v.id;
  static const Field<MTGLandCard, String> _f$id =
      Field('id', _$id, mode: FieldMode.member);

  @override
  final MappableFields<MTGLandCard> fields = const {
    #name: _f$name,
    #setId: _f$setId,
    #description: _f$description,
    #flavorText: _f$flavorText,
    #rarity: _f$rarity,
    #manaCost: _f$manaCost,
    #quantity: _f$quantity,
    #cardType: _f$cardType,
    #manaColor: _f$manaColor,
    #manaValue: _f$manaValue,
    #id: _f$id,
  };

  static MTGLandCard _instantiate(DecodingData data) {
    return MTGLandCard(
        name: data.dec(_f$name),
        setId: data.dec(_f$setId),
        description: data.dec(_f$description),
        flavorText: data.dec(_f$flavorText),
        rarity: data.dec(_f$rarity),
        manaCost: data.dec(_f$manaCost),
        quantity: data.dec(_f$quantity),
        cardType: data.dec(_f$cardType),
        manaColor: data.dec(_f$manaColor),
        manaValue: data.dec(_f$manaValue));
  }

  @override
  final Function instantiate = _instantiate;

  static MTGLandCard fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<MTGLandCard>(map);
  }

  static MTGLandCard fromJson(String json) {
    return ensureInitialized().decodeJson<MTGLandCard>(json);
  }
}

mixin MTGLandCardMappable {
  String toJson() {
    return MTGLandCardMapper.ensureInitialized()
        .encodeJson<MTGLandCard>(this as MTGLandCard);
  }

  Map<String, dynamic> toMap() {
    return MTGLandCardMapper.ensureInitialized()
        .encodeMap<MTGLandCard>(this as MTGLandCard);
  }

  MTGLandCardCopyWith<MTGLandCard, MTGLandCard, MTGLandCard> get copyWith =>
      _MTGLandCardCopyWithImpl(this as MTGLandCard, $identity, $identity);
  @override
  String toString() {
    return MTGLandCardMapper.ensureInitialized()
        .stringifyValue(this as MTGLandCard);
  }

  @override
  bool operator ==(Object other) {
    return MTGLandCardMapper.ensureInitialized()
        .equalsValue(this as MTGLandCard, other);
  }

  @override
  int get hashCode {
    return MTGLandCardMapper.ensureInitialized().hashValue(this as MTGLandCard);
  }
}

extension MTGLandCardValueCopy<$R, $Out>
    on ObjectCopyWith<$R, MTGLandCard, $Out> {
  MTGLandCardCopyWith<$R, MTGLandCard, $Out> get $asMTGLandCard =>
      $base.as((v, t, t2) => _MTGLandCardCopyWithImpl(v, t, t2));
}

abstract class MTGLandCardCopyWith<$R, $In extends MTGLandCard, $Out>
    implements MTGCardCopyWith<$R, $In, $Out> {
  @override
  $R call(
      {String? name,
      String? setId,
      String? description,
      String? flavorText,
      String? rarity,
      dynamic manaCost,
      int? quantity,
      CardType? cardType,
      ManaColor? manaColor,
      int? manaValue});
  MTGLandCardCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _MTGLandCardCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, MTGLandCard, $Out>
    implements MTGLandCardCopyWith<$R, MTGLandCard, $Out> {
  _MTGLandCardCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<MTGLandCard> $mapper =
      MTGLandCardMapper.ensureInitialized();
  @override
  $R call(
          {String? name,
          String? setId,
          String? description,
          String? flavorText,
          String? rarity,
          Object? manaCost = $none,
          int? quantity,
          CardType? cardType,
          ManaColor? manaColor,
          int? manaValue}) =>
      $apply(FieldCopyWithData({
        if (name != null) #name: name,
        if (setId != null) #setId: setId,
        if (description != null) #description: description,
        if (flavorText != null) #flavorText: flavorText,
        if (rarity != null) #rarity: rarity,
        if (manaCost != $none) #manaCost: manaCost,
        if (quantity != null) #quantity: quantity,
        if (cardType != null) #cardType: cardType,
        if (manaColor != null) #manaColor: manaColor,
        if (manaValue != null) #manaValue: manaValue
      }));
  @override
  MTGLandCard $make(CopyWithData data) => MTGLandCard(
      name: data.get(#name, or: $value.name),
      setId: data.get(#setId, or: $value.setId),
      description: data.get(#description, or: $value.description),
      flavorText: data.get(#flavorText, or: $value.flavorText),
      rarity: data.get(#rarity, or: $value.rarity),
      manaCost: data.get(#manaCost, or: $value.manaCost),
      quantity: data.get(#quantity, or: $value.quantity),
      cardType: data.get(#cardType, or: $value.cardType),
      manaColor: data.get(#manaColor, or: $value.manaColor),
      manaValue: data.get(#manaValue, or: $value.manaValue));

  @override
  MTGLandCardCopyWith<$R2, MTGLandCard, $Out2> $chain<$R2, $Out2>(
          Then<$Out2, $R2> t) =>
      _MTGLandCardCopyWithImpl($value, $cast, t);
}
