// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'mtg_creature.dart';

class MTGCreatureCardMapper extends ClassMapperBase<MTGCreatureCard> {
  MTGCreatureCardMapper._();

  static MTGCreatureCardMapper? _instance;
  static MTGCreatureCardMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = MTGCreatureCardMapper._());
      MTGCardMapper.ensureInitialized();
      CardTypeMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'MTGCreatureCard';

  static String _$name(MTGCreatureCard v) => v.name;
  static const Field<MTGCreatureCard, String> _f$name = Field('name', _$name);
  static String _$setId(MTGCreatureCard v) => v.setId;
  static const Field<MTGCreatureCard, String> _f$setId =
      Field('setId', _$setId);
  static String _$description(MTGCreatureCard v) => v.description;
  static const Field<MTGCreatureCard, String> _f$description =
      Field('description', _$description);
  static String _$flavorText(MTGCreatureCard v) => v.flavorText;
  static const Field<MTGCreatureCard, String> _f$flavorText =
      Field('flavorText', _$flavorText);
  static String _$rarity(MTGCreatureCard v) => v.rarity;
  static const Field<MTGCreatureCard, String> _f$rarity =
      Field('rarity', _$rarity);
  static int _$quantity(MTGCreatureCard v) => v.quantity;
  static const Field<MTGCreatureCard, int> _f$quantity =
      Field('quantity', _$quantity, opt: true, def: 1);
  static dynamic _$manaCost(MTGCreatureCard v) => v.manaCost;
  static const Field<MTGCreatureCard, dynamic> _f$manaCost =
      Field('manaCost', _$manaCost);
  static int _$power(MTGCreatureCard v) => v.power;
  static const Field<MTGCreatureCard, int> _f$power = Field('power', _$power);
  static CardType _$cardType(MTGCreatureCard v) => v.cardType;
  static const Field<MTGCreatureCard, CardType> _f$cardType =
      Field('cardType', _$cardType, opt: true, def: CardType.creature);
  static int _$toughness(MTGCreatureCard v) => v.toughness;
  static const Field<MTGCreatureCard, int> _f$toughness =
      Field('toughness', _$toughness);
  static String? _$id(MTGCreatureCard v) => v.id;
  static const Field<MTGCreatureCard, String> _f$id =
      Field('id', _$id, mode: FieldMode.member);

  @override
  final MappableFields<MTGCreatureCard> fields = const {
    #name: _f$name,
    #setId: _f$setId,
    #description: _f$description,
    #flavorText: _f$flavorText,
    #rarity: _f$rarity,
    #quantity: _f$quantity,
    #manaCost: _f$manaCost,
    #power: _f$power,
    #cardType: _f$cardType,
    #toughness: _f$toughness,
    #id: _f$id,
  };

  static MTGCreatureCard _instantiate(DecodingData data) {
    return MTGCreatureCard(
        name: data.dec(_f$name),
        setId: data.dec(_f$setId),
        description: data.dec(_f$description),
        flavorText: data.dec(_f$flavorText),
        rarity: data.dec(_f$rarity),
        quantity: data.dec(_f$quantity),
        manaCost: data.dec(_f$manaCost),
        power: data.dec(_f$power),
        cardType: data.dec(_f$cardType),
        toughness: data.dec(_f$toughness));
  }

  @override
  final Function instantiate = _instantiate;

  static MTGCreatureCard fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<MTGCreatureCard>(map);
  }

  static MTGCreatureCard fromJson(String json) {
    return ensureInitialized().decodeJson<MTGCreatureCard>(json);
  }
}

mixin MTGCreatureCardMappable {
  String toJson() {
    return MTGCreatureCardMapper.ensureInitialized()
        .encodeJson<MTGCreatureCard>(this as MTGCreatureCard);
  }

  Map<String, dynamic> toMap() {
    return MTGCreatureCardMapper.ensureInitialized()
        .encodeMap<MTGCreatureCard>(this as MTGCreatureCard);
  }

  MTGCreatureCardCopyWith<MTGCreatureCard, MTGCreatureCard, MTGCreatureCard>
      get copyWith => _MTGCreatureCardCopyWithImpl(
          this as MTGCreatureCard, $identity, $identity);
  @override
  String toString() {
    return MTGCreatureCardMapper.ensureInitialized()
        .stringifyValue(this as MTGCreatureCard);
  }

  @override
  bool operator ==(Object other) {
    return MTGCreatureCardMapper.ensureInitialized()
        .equalsValue(this as MTGCreatureCard, other);
  }

  @override
  int get hashCode {
    return MTGCreatureCardMapper.ensureInitialized()
        .hashValue(this as MTGCreatureCard);
  }
}

extension MTGCreatureCardValueCopy<$R, $Out>
    on ObjectCopyWith<$R, MTGCreatureCard, $Out> {
  MTGCreatureCardCopyWith<$R, MTGCreatureCard, $Out> get $asMTGCreatureCard =>
      $base.as((v, t, t2) => _MTGCreatureCardCopyWithImpl(v, t, t2));
}

abstract class MTGCreatureCardCopyWith<$R, $In extends MTGCreatureCard, $Out>
    implements MTGCardCopyWith<$R, $In, $Out> {
  @override
  $R call(
      {String? name,
      String? setId,
      String? description,
      String? flavorText,
      String? rarity,
      int? quantity,
      dynamic manaCost,
      int? power,
      CardType? cardType,
      int? toughness});
  MTGCreatureCardCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
      Then<$Out2, $R2> t);
}

class _MTGCreatureCardCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, MTGCreatureCard, $Out>
    implements MTGCreatureCardCopyWith<$R, MTGCreatureCard, $Out> {
  _MTGCreatureCardCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<MTGCreatureCard> $mapper =
      MTGCreatureCardMapper.ensureInitialized();
  @override
  $R call(
          {String? name,
          String? setId,
          String? description,
          String? flavorText,
          String? rarity,
          int? quantity,
          Object? manaCost = $none,
          int? power,
          CardType? cardType,
          int? toughness}) =>
      $apply(FieldCopyWithData({
        if (name != null) #name: name,
        if (setId != null) #setId: setId,
        if (description != null) #description: description,
        if (flavorText != null) #flavorText: flavorText,
        if (rarity != null) #rarity: rarity,
        if (quantity != null) #quantity: quantity,
        if (manaCost != $none) #manaCost: manaCost,
        if (power != null) #power: power,
        if (cardType != null) #cardType: cardType,
        if (toughness != null) #toughness: toughness
      }));
  @override
  MTGCreatureCard $make(CopyWithData data) => MTGCreatureCard(
      name: data.get(#name, or: $value.name),
      setId: data.get(#setId, or: $value.setId),
      description: data.get(#description, or: $value.description),
      flavorText: data.get(#flavorText, or: $value.flavorText),
      rarity: data.get(#rarity, or: $value.rarity),
      quantity: data.get(#quantity, or: $value.quantity),
      manaCost: data.get(#manaCost, or: $value.manaCost),
      power: data.get(#power, or: $value.power),
      cardType: data.get(#cardType, or: $value.cardType),
      toughness: data.get(#toughness, or: $value.toughness));

  @override
  MTGCreatureCardCopyWith<$R2, MTGCreatureCard, $Out2> $chain<$R2, $Out2>(
          Then<$Out2, $R2> t) =>
      _MTGCreatureCardCopyWithImpl($value, $cast, t);
}
