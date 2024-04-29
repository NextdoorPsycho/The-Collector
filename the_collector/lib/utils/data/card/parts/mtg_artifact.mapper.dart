// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'mtg_artifact.dart';

class MTGArtifactCardMapper extends ClassMapperBase<MTGArtifactCard> {
  MTGArtifactCardMapper._();

  static MTGArtifactCardMapper? _instance;
  static MTGArtifactCardMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = MTGArtifactCardMapper._());
      MTGCardMapper.ensureInitialized();
      CardTypeMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'MTGArtifactCard';

  static String _$name(MTGArtifactCard v) => v.name;
  static const Field<MTGArtifactCard, String> _f$name = Field('name', _$name);
  static String _$setId(MTGArtifactCard v) => v.setId;
  static const Field<MTGArtifactCard, String> _f$setId =
      Field('setId', _$setId);
  static String _$description(MTGArtifactCard v) => v.description;
  static const Field<MTGArtifactCard, String> _f$description =
      Field('description', _$description);
  static String _$flavorText(MTGArtifactCard v) => v.flavorText;
  static const Field<MTGArtifactCard, String> _f$flavorText =
      Field('flavorText', _$flavorText);
  static String _$rarity(MTGArtifactCard v) => v.rarity;
  static const Field<MTGArtifactCard, String> _f$rarity =
      Field('rarity', _$rarity);
  static int _$quantity(MTGArtifactCard v) => v.quantity;
  static const Field<MTGArtifactCard, int> _f$quantity =
      Field('quantity', _$quantity, opt: true, def: 1);
  static dynamic _$manaCost(MTGArtifactCard v) => v.manaCost;
  static const Field<MTGArtifactCard, dynamic> _f$manaCost =
      Field('manaCost', _$manaCost);
  static CardType _$cardType(MTGArtifactCard v) => v.cardType;
  static const Field<MTGArtifactCard, CardType> _f$cardType =
      Field('cardType', _$cardType, opt: true, def: CardType.artifact);
  static String? _$id(MTGArtifactCard v) => v.id;
  static const Field<MTGArtifactCard, String> _f$id =
      Field('id', _$id, mode: FieldMode.member);

  @override
  final MappableFields<MTGArtifactCard> fields = const {
    #name: _f$name,
    #setId: _f$setId,
    #description: _f$description,
    #flavorText: _f$flavorText,
    #rarity: _f$rarity,
    #quantity: _f$quantity,
    #manaCost: _f$manaCost,
    #cardType: _f$cardType,
    #id: _f$id,
  };

  static MTGArtifactCard _instantiate(DecodingData data) {
    return MTGArtifactCard(
        name: data.dec(_f$name),
        setId: data.dec(_f$setId),
        description: data.dec(_f$description),
        flavorText: data.dec(_f$flavorText),
        rarity: data.dec(_f$rarity),
        quantity: data.dec(_f$quantity),
        manaCost: data.dec(_f$manaCost),
        cardType: data.dec(_f$cardType));
  }

  @override
  final Function instantiate = _instantiate;

  static MTGArtifactCard fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<MTGArtifactCard>(map);
  }

  static MTGArtifactCard fromJson(String json) {
    return ensureInitialized().decodeJson<MTGArtifactCard>(json);
  }
}

mixin MTGArtifactCardMappable {
  String toJson() {
    return MTGArtifactCardMapper.ensureInitialized()
        .encodeJson<MTGArtifactCard>(this as MTGArtifactCard);
  }

  Map<String, dynamic> toMap() {
    return MTGArtifactCardMapper.ensureInitialized()
        .encodeMap<MTGArtifactCard>(this as MTGArtifactCard);
  }

  MTGArtifactCardCopyWith<MTGArtifactCard, MTGArtifactCard, MTGArtifactCard>
      get copyWith => _MTGArtifactCardCopyWithImpl(
          this as MTGArtifactCard, $identity, $identity);
  @override
  String toString() {
    return MTGArtifactCardMapper.ensureInitialized()
        .stringifyValue(this as MTGArtifactCard);
  }

  @override
  bool operator ==(Object other) {
    return MTGArtifactCardMapper.ensureInitialized()
        .equalsValue(this as MTGArtifactCard, other);
  }

  @override
  int get hashCode {
    return MTGArtifactCardMapper.ensureInitialized()
        .hashValue(this as MTGArtifactCard);
  }
}

extension MTGArtifactCardValueCopy<$R, $Out>
    on ObjectCopyWith<$R, MTGArtifactCard, $Out> {
  MTGArtifactCardCopyWith<$R, MTGArtifactCard, $Out> get $asMTGArtifactCard =>
      $base.as((v, t, t2) => _MTGArtifactCardCopyWithImpl(v, t, t2));
}

abstract class MTGArtifactCardCopyWith<$R, $In extends MTGArtifactCard, $Out>
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
      CardType? cardType});
  MTGArtifactCardCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
      Then<$Out2, $R2> t);
}

class _MTGArtifactCardCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, MTGArtifactCard, $Out>
    implements MTGArtifactCardCopyWith<$R, MTGArtifactCard, $Out> {
  _MTGArtifactCardCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<MTGArtifactCard> $mapper =
      MTGArtifactCardMapper.ensureInitialized();
  @override
  $R call(
          {String? name,
          String? setId,
          String? description,
          String? flavorText,
          String? rarity,
          int? quantity,
          Object? manaCost = $none,
          CardType? cardType}) =>
      $apply(FieldCopyWithData({
        if (name != null) #name: name,
        if (setId != null) #setId: setId,
        if (description != null) #description: description,
        if (flavorText != null) #flavorText: flavorText,
        if (rarity != null) #rarity: rarity,
        if (quantity != null) #quantity: quantity,
        if (manaCost != $none) #manaCost: manaCost,
        if (cardType != null) #cardType: cardType
      }));
  @override
  MTGArtifactCard $make(CopyWithData data) => MTGArtifactCard(
      name: data.get(#name, or: $value.name),
      setId: data.get(#setId, or: $value.setId),
      description: data.get(#description, or: $value.description),
      flavorText: data.get(#flavorText, or: $value.flavorText),
      rarity: data.get(#rarity, or: $value.rarity),
      quantity: data.get(#quantity, or: $value.quantity),
      manaCost: data.get(#manaCost, or: $value.manaCost),
      cardType: data.get(#cardType, or: $value.cardType));

  @override
  MTGArtifactCardCopyWith<$R2, MTGArtifactCard, $Out2> $chain<$R2, $Out2>(
          Then<$Out2, $R2> t) =>
      _MTGArtifactCardCopyWithImpl($value, $cast, t);
}
