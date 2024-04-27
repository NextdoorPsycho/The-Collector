// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'user_manager.dart';

class UserManagerMapper extends ClassMapperBase<UserManager> {
  UserManagerMapper._();

  static UserManagerMapper? _instance;
  static UserManagerMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = UserManagerMapper._());
      DeckMapper.ensureInitialized();
      MtgCardMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'UserManager';

  static bool _$adminStatus(UserManager v) => v.adminStatus;
  static const Field<UserManager, bool> _f$adminStatus =
      Field('adminStatus', _$adminStatus, opt: true, def: false);
  static List<Deck> _$decks(UserManager v) => v.decks;
  static const Field<UserManager, List<Deck>> _f$decks =
      Field('decks', _$decks, opt: true, def: const []);
  static Deck? _$deckById(UserManager v) => v.deckById;
  static const Field<UserManager, Deck> _f$deckById =
      Field('deckById', _$deckById, opt: true);
  static bool _$theme(UserManager v) => v.theme;
  static const Field<UserManager, bool> _f$theme =
      Field('theme', _$theme, opt: true, def: false);
  static List<MtgCard> _$collection(UserManager v) => v.collection;
  static const Field<UserManager, List<MtgCard>> _f$collection =
      Field('collection', _$collection, opt: true, def: const []);

  @override
  final MappableFields<UserManager> fields = const {
    #adminStatus: _f$adminStatus,
    #decks: _f$decks,
    #deckById: _f$deckById,
    #theme: _f$theme,
    #collection: _f$collection,
  };

  static UserManager _instantiate(DecodingData data) {
    return UserManager(
        adminStatus: data.dec(_f$adminStatus),
        decks: data.dec(_f$decks),
        deckById: data.dec(_f$deckById),
        theme: data.dec(_f$theme),
        collection: data.dec(_f$collection));
  }

  @override
  final Function instantiate = _instantiate;

  static UserManager fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<UserManager>(map);
  }

  static UserManager fromJson(String json) {
    return ensureInitialized().decodeJson<UserManager>(json);
  }
}

mixin UserManagerMappable {
  String toJson() {
    return UserManagerMapper.ensureInitialized()
        .encodeJson<UserManager>(this as UserManager);
  }

  Map<String, dynamic> toMap() {
    return UserManagerMapper.ensureInitialized()
        .encodeMap<UserManager>(this as UserManager);
  }

  UserManagerCopyWith<UserManager, UserManager, UserManager> get copyWith =>
      _UserManagerCopyWithImpl(this as UserManager, $identity, $identity);
  @override
  String toString() {
    return UserManagerMapper.ensureInitialized()
        .stringifyValue(this as UserManager);
  }

  @override
  bool operator ==(Object other) {
    return UserManagerMapper.ensureInitialized()
        .equalsValue(this as UserManager, other);
  }

  @override
  int get hashCode {
    return UserManagerMapper.ensureInitialized().hashValue(this as UserManager);
  }
}

extension UserManagerValueCopy<$R, $Out>
    on ObjectCopyWith<$R, UserManager, $Out> {
  UserManagerCopyWith<$R, UserManager, $Out> get $asUserManager =>
      $base.as((v, t, t2) => _UserManagerCopyWithImpl(v, t, t2));
}

abstract class UserManagerCopyWith<$R, $In extends UserManager, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, Deck, DeckCopyWith<$R, Deck, Deck>> get decks;
  DeckCopyWith<$R, Deck, Deck>? get deckById;
  ListCopyWith<$R, MtgCard, MtgCardCopyWith<$R, MtgCard, MtgCard>>
      get collection;
  $R call(
      {bool? adminStatus,
      List<Deck>? decks,
      Deck? deckById,
      bool? theme,
      List<MtgCard>? collection});
  UserManagerCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _UserManagerCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, UserManager, $Out>
    implements UserManagerCopyWith<$R, UserManager, $Out> {
  _UserManagerCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<UserManager> $mapper =
      UserManagerMapper.ensureInitialized();
  @override
  ListCopyWith<$R, Deck, DeckCopyWith<$R, Deck, Deck>> get decks =>
      ListCopyWith(
          $value.decks, (v, t) => v.copyWith.$chain(t), (v) => call(decks: v));
  @override
  DeckCopyWith<$R, Deck, Deck>? get deckById =>
      $value.deckById?.copyWith.$chain((v) => call(deckById: v));
  @override
  ListCopyWith<$R, MtgCard, MtgCardCopyWith<$R, MtgCard, MtgCard>>
      get collection => ListCopyWith($value.collection,
          (v, t) => v.copyWith.$chain(t), (v) => call(collection: v));
  @override
  $R call(
          {bool? adminStatus,
          List<Deck>? decks,
          Object? deckById = $none,
          bool? theme,
          List<MtgCard>? collection}) =>
      $apply(FieldCopyWithData({
        if (adminStatus != null) #adminStatus: adminStatus,
        if (decks != null) #decks: decks,
        if (deckById != $none) #deckById: deckById,
        if (theme != null) #theme: theme,
        if (collection != null) #collection: collection
      }));
  @override
  UserManager $make(CopyWithData data) => UserManager(
      adminStatus: data.get(#adminStatus, or: $value.adminStatus),
      decks: data.get(#decks, or: $value.decks),
      deckById: data.get(#deckById, or: $value.deckById),
      theme: data.get(#theme, or: $value.theme),
      collection: data.get(#collection, or: $value.collection));

  @override
  UserManagerCopyWith<$R2, UserManager, $Out2> $chain<$R2, $Out2>(
          Then<$Out2, $R2> t) =>
      _UserManagerCopyWithImpl($value, $cast, t);
}
