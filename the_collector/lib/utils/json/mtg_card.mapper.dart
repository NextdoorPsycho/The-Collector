// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'mtg_card.dart';

class MtgCardMapper extends ClassMapperBase<MtgCard> {
  MtgCardMapper._();

  static MtgCardMapper? _instance;
  static MtgCardMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = MtgCardMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'MtgCard';

  static String _$id(MtgCard v) => v.id;
  static const Field<MtgCard, String> _f$id = Field('id', _$id);
  static String _$name(MtgCard v) => v.name;
  static const Field<MtgCard, String> _f$name = Field('name', _$name);
  static String _$set(MtgCard v) => v.set;
  static const Field<MtgCard, String> _f$set = Field('set', _$set);
  static bool? _$foil(MtgCard v) => v.foil;
  static const Field<MtgCard, bool> _f$foil =
      Field('foil', _$foil, opt: true, def: false);
  static String? _$typeLine(MtgCard v) => v.typeLine;
  static const Field<MtgCard, String> _f$typeLine =
      Field('typeLine', _$typeLine, opt: true, def: '');
  static String? _$manaCost(MtgCard v) => v.manaCost;
  static const Field<MtgCard, String> _f$manaCost =
      Field('manaCost', _$manaCost, opt: true, def: '');
  static int? _$power(MtgCard v) => v.power;
  static const Field<MtgCard, int> _f$power =
      Field('power', _$power, opt: true, def: 0);
  static int? _$toughness(MtgCard v) => v.toughness;
  static const Field<MtgCard, int> _f$toughness =
      Field('toughness', _$toughness, opt: true, def: 0);
  static int? _$quantity(MtgCard v) => v.quantity;
  static const Field<MtgCard, int> _f$quantity =
      Field('quantity', _$quantity, opt: true, def: 0);

  @override
  final MappableFields<MtgCard> fields = const {
    #id: _f$id,
    #name: _f$name,
    #set: _f$set,
    #foil: _f$foil,
    #typeLine: _f$typeLine,
    #manaCost: _f$manaCost,
    #power: _f$power,
    #toughness: _f$toughness,
    #quantity: _f$quantity,
  };

  static MtgCard _instantiate(DecodingData data) {
    return MtgCard(
        id: data.dec(_f$id),
        name: data.dec(_f$name),
        set: data.dec(_f$set),
        foil: data.dec(_f$foil),
        typeLine: data.dec(_f$typeLine),
        manaCost: data.dec(_f$manaCost),
        power: data.dec(_f$power),
        toughness: data.dec(_f$toughness),
        quantity: data.dec(_f$quantity));
  }

  @override
  final Function instantiate = _instantiate;

  static MtgCard fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<MtgCard>(map);
  }

  static MtgCard fromJson(String json) {
    return ensureInitialized().decodeJson<MtgCard>(json);
  }
}

mixin MtgCardMappable {
  String toJson() {
    return MtgCardMapper.ensureInitialized()
        .encodeJson<MtgCard>(this as MtgCard);
  }

  Map<String, dynamic> toMap() {
    return MtgCardMapper.ensureInitialized()
        .encodeMap<MtgCard>(this as MtgCard);
  }

  MtgCardCopyWith<MtgCard, MtgCard, MtgCard> get copyWith =>
      _MtgCardCopyWithImpl(this as MtgCard, $identity, $identity);
  @override
  String toString() {
    return MtgCardMapper.ensureInitialized().stringifyValue(this as MtgCard);
  }

  @override
  bool operator ==(Object other) {
    return MtgCardMapper.ensureInitialized()
        .equalsValue(this as MtgCard, other);
  }

  @override
  int get hashCode {
    return MtgCardMapper.ensureInitialized().hashValue(this as MtgCard);
  }
}

extension MtgCardValueCopy<$R, $Out> on ObjectCopyWith<$R, MtgCard, $Out> {
  MtgCardCopyWith<$R, MtgCard, $Out> get $asMtgCard =>
      $base.as((v, t, t2) => _MtgCardCopyWithImpl(v, t, t2));
}

abstract class MtgCardCopyWith<$R, $In extends MtgCard, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call(
      {String? id,
      String? name,
      String? set,
      bool? foil,
      String? typeLine,
      String? manaCost,
      int? power,
      int? toughness,
      int? quantity});
  MtgCardCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _MtgCardCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, MtgCard, $Out>
    implements MtgCardCopyWith<$R, MtgCard, $Out> {
  _MtgCardCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<MtgCard> $mapper =
      MtgCardMapper.ensureInitialized();
  @override
  $R call(
          {String? id,
          String? name,
          String? set,
          Object? foil = $none,
          Object? typeLine = $none,
          Object? manaCost = $none,
          Object? power = $none,
          Object? toughness = $none,
          Object? quantity = $none}) =>
      $apply(FieldCopyWithData({
        if (id != null) #id: id,
        if (name != null) #name: name,
        if (set != null) #set: set,
        if (foil != $none) #foil: foil,
        if (typeLine != $none) #typeLine: typeLine,
        if (manaCost != $none) #manaCost: manaCost,
        if (power != $none) #power: power,
        if (toughness != $none) #toughness: toughness,
        if (quantity != $none) #quantity: quantity
      }));
  @override
  MtgCard $make(CopyWithData data) => MtgCard(
      id: data.get(#id, or: $value.id),
      name: data.get(#name, or: $value.name),
      set: data.get(#set, or: $value.set),
      foil: data.get(#foil, or: $value.foil),
      typeLine: data.get(#typeLine, or: $value.typeLine),
      manaCost: data.get(#manaCost, or: $value.manaCost),
      power: data.get(#power, or: $value.power),
      toughness: data.get(#toughness, or: $value.toughness),
      quantity: data.get(#quantity, or: $value.quantity));

  @override
  MtgCardCopyWith<$R2, MtgCard, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _MtgCardCopyWithImpl($value, $cast, t);
}
