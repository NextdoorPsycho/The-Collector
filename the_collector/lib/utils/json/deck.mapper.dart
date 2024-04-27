// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'deck.dart';

class DeckMapper extends ClassMapperBase<Deck> {
  DeckMapper._();

  static DeckMapper? _instance;
  static DeckMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = DeckMapper._());
      MtgCardMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'Deck';

  static String _$name(Deck v) => v.name;
  static const Field<Deck, String> _f$name = Field('name', _$name);
  static List<MtgCard> _$cards(Deck v) => v.cards;
  static const Field<Deck, List<MtgCard>> _f$cards =
      Field('cards', _$cards, opt: true, def: const []);
  static String? _$id(Deck v) => v.id;
  static const Field<Deck, String> _f$id =
      Field('id', _$id, mode: FieldMode.member);
  static bool? _$exists(Deck v) => v.exists;
  static const Field<Deck, bool> _f$exists =
      Field('exists', _$exists, mode: FieldMode.member);

  @override
  final MappableFields<Deck> fields = const {
    #name: _f$name,
    #cards: _f$cards,
    #id: _f$id,
    #exists: _f$exists,
  };

  static Deck _instantiate(DecodingData data) {
    return Deck(name: data.dec(_f$name), cards: data.dec(_f$cards));
  }

  @override
  final Function instantiate = _instantiate;

  static Deck fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Deck>(map);
  }

  static Deck fromJson(String json) {
    return ensureInitialized().decodeJson<Deck>(json);
  }
}

mixin DeckMappable {
  String toJson() {
    return DeckMapper.ensureInitialized().encodeJson<Deck>(this as Deck);
  }

  Map<String, dynamic> toMap() {
    return DeckMapper.ensureInitialized().encodeMap<Deck>(this as Deck);
  }

  DeckCopyWith<Deck, Deck, Deck> get copyWith =>
      _DeckCopyWithImpl(this as Deck, $identity, $identity);
  @override
  String toString() {
    return DeckMapper.ensureInitialized().stringifyValue(this as Deck);
  }

  @override
  bool operator ==(Object other) {
    return DeckMapper.ensureInitialized().equalsValue(this as Deck, other);
  }

  @override
  int get hashCode {
    return DeckMapper.ensureInitialized().hashValue(this as Deck);
  }
}

extension DeckValueCopy<$R, $Out> on ObjectCopyWith<$R, Deck, $Out> {
  DeckCopyWith<$R, Deck, $Out> get $asDeck =>
      $base.as((v, t, t2) => _DeckCopyWithImpl(v, t, t2));
}

abstract class DeckCopyWith<$R, $In extends Deck, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, MtgCard, MtgCardCopyWith<$R, MtgCard, MtgCard>> get cards;
  $R call({String? name, List<MtgCard>? cards});
  DeckCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _DeckCopyWithImpl<$R, $Out> extends ClassCopyWithBase<$R, Deck, $Out>
    implements DeckCopyWith<$R, Deck, $Out> {
  _DeckCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<Deck> $mapper = DeckMapper.ensureInitialized();
  @override
  ListCopyWith<$R, MtgCard, MtgCardCopyWith<$R, MtgCard, MtgCard>> get cards =>
      ListCopyWith(
          $value.cards, (v, t) => v.copyWith.$chain(t), (v) => call(cards: v));
  @override
  $R call({String? name, List<MtgCard>? cards}) => $apply(FieldCopyWithData(
      {if (name != null) #name: name, if (cards != null) #cards: cards}));
  @override
  Deck $make(CopyWithData data) => Deck(
      name: data.get(#name, or: $value.name),
      cards: data.get(#cards, or: $value.cards));

  @override
  DeckCopyWith<$R2, Deck, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _DeckCopyWithImpl($value, $cast, t);
}
