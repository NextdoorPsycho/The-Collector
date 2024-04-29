// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'mtg_deck.dart';

class MTGDeckMapper extends ClassMapperBase<MTGDeck> {
  MTGDeckMapper._();

  static MTGDeckMapper? _instance;
  static MTGDeckMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = MTGDeckMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'MTGDeck';

  static String _$name(MTGDeck v) => v.name;
  static const Field<MTGDeck, String> _f$name = Field('name', _$name);
  static List<String> _$cards(MTGDeck v) => v.cards;
  static const Field<MTGDeck, List<String>> _f$cards =
      Field('cards', _$cards, opt: true, def: const []);
  static String? _$id(MTGDeck v) => v.id;
  static const Field<MTGDeck, String> _f$id =
      Field('id', _$id, mode: FieldMode.member);

  @override
  final MappableFields<MTGDeck> fields = const {
    #name: _f$name,
    #cards: _f$cards,
    #id: _f$id,
  };

  static MTGDeck _instantiate(DecodingData data) {
    return MTGDeck(name: data.dec(_f$name), cards: data.dec(_f$cards));
  }

  @override
  final Function instantiate = _instantiate;

  static MTGDeck fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<MTGDeck>(map);
  }

  static MTGDeck fromJson(String json) {
    return ensureInitialized().decodeJson<MTGDeck>(json);
  }
}

mixin MTGDeckMappable {
  String toJson() {
    return MTGDeckMapper.ensureInitialized()
        .encodeJson<MTGDeck>(this as MTGDeck);
  }

  Map<String, dynamic> toMap() {
    return MTGDeckMapper.ensureInitialized()
        .encodeMap<MTGDeck>(this as MTGDeck);
  }

  MTGDeckCopyWith<MTGDeck, MTGDeck, MTGDeck> get copyWith =>
      _MTGDeckCopyWithImpl(this as MTGDeck, $identity, $identity);
  @override
  String toString() {
    return MTGDeckMapper.ensureInitialized().stringifyValue(this as MTGDeck);
  }

  @override
  bool operator ==(Object other) {
    return MTGDeckMapper.ensureInitialized()
        .equalsValue(this as MTGDeck, other);
  }

  @override
  int get hashCode {
    return MTGDeckMapper.ensureInitialized().hashValue(this as MTGDeck);
  }
}

extension MTGDeckValueCopy<$R, $Out> on ObjectCopyWith<$R, MTGDeck, $Out> {
  MTGDeckCopyWith<$R, MTGDeck, $Out> get $asMTGDeck =>
      $base.as((v, t, t2) => _MTGDeckCopyWithImpl(v, t, t2));
}

abstract class MTGDeckCopyWith<$R, $In extends MTGDeck, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>> get cards;
  $R call({String? name, List<String>? cards});
  MTGDeckCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _MTGDeckCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, MTGDeck, $Out>
    implements MTGDeckCopyWith<$R, MTGDeck, $Out> {
  _MTGDeckCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<MTGDeck> $mapper =
      MTGDeckMapper.ensureInitialized();
  @override
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>> get cards =>
      ListCopyWith($value.cards, (v, t) => ObjectCopyWith(v, $identity, t),
          (v) => call(cards: v));
  @override
  $R call({String? name, List<String>? cards}) => $apply(FieldCopyWithData(
      {if (name != null) #name: name, if (cards != null) #cards: cards}));
  @override
  MTGDeck $make(CopyWithData data) => MTGDeck(
      name: data.get(#name, or: $value.name),
      cards: data.get(#cards, or: $value.cards));

  @override
  MTGDeckCopyWith<$R2, MTGDeck, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _MTGDeckCopyWithImpl($value, $cast, t);
}
