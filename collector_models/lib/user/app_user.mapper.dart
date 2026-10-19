// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'app_user.dart';

class AppUserMapper extends ClassMapperBase<AppUser> {
  AppUserMapper._();

  static AppUserMapper? _instance;
  static AppUserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = AppUserMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'AppUser';

  static bool _$theme(AppUser v) => v.theme;
  static const Field<AppUser, bool> _f$theme = Field(
    'theme',
    _$theme,
    opt: true,
    def: false,
  );
  static bool _$showCommander(AppUser v) => v.showCommander;
  static const Field<AppUser, bool> _f$showCommander = Field(
    'showCommander',
    _$showCommander,
    opt: true,
    def: false,
  );
  static String? _$id(AppUser v) => v.id;
  static const Field<AppUser, String> _f$id = Field(
    'id',
    _$id,
    mode: FieldMode.member,
  );

  @override
  final MappableFields<AppUser> fields = const {
    #theme: _f$theme,
    #showCommander: _f$showCommander,
    #id: _f$id,
  };

  static AppUser _instantiate(DecodingData data) {
    return AppUser(
      theme: data.dec(_f$theme),
      showCommander: data.dec(_f$showCommander),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static AppUser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<AppUser>(map);
  }

  static AppUser fromJson(String json) {
    return ensureInitialized().decodeJson<AppUser>(json);
  }
}

mixin AppUserMappable {
  String toJson() {
    return AppUserMapper.ensureInitialized().encodeJson<AppUser>(
      this as AppUser,
    );
  }

  Map<String, dynamic> toMap() {
    return AppUserMapper.ensureInitialized().encodeMap<AppUser>(
      this as AppUser,
    );
  }

  AppUserCopyWith<AppUser, AppUser, AppUser> get copyWith =>
      _AppUserCopyWithImpl<AppUser, AppUser>(
        this as AppUser,
        $identity,
        $identity,
      );
  @override
  String toString() {
    return AppUserMapper.ensureInitialized().stringifyValue(this as AppUser);
  }

  @override
  bool operator ==(Object other) {
    return AppUserMapper.ensureInitialized().equalsValue(
      this as AppUser,
      other,
    );
  }

  @override
  int get hashCode {
    return AppUserMapper.ensureInitialized().hashValue(this as AppUser);
  }
}

extension AppUserValueCopy<$R, $Out> on ObjectCopyWith<$R, AppUser, $Out> {
  AppUserCopyWith<$R, AppUser, $Out> get $asAppUser =>
      $base.as((v, t, t2) => _AppUserCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class AppUserCopyWith<$R, $In extends AppUser, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({bool? theme, bool? showCommander});
  AppUserCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _AppUserCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, AppUser, $Out>
    implements AppUserCopyWith<$R, AppUser, $Out> {
  _AppUserCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<AppUser> $mapper =
      AppUserMapper.ensureInitialized();
  @override
  $R call({bool? theme, bool? showCommander}) => $apply(
    FieldCopyWithData({
      if (theme != null) #theme: theme,
      if (showCommander != null) #showCommander: showCommander,
    }),
  );
  @override
  AppUser $make(CopyWithData data) => AppUser(
    theme: data.get(#theme, or: $value.theme),
    showCommander: data.get(#showCommander, or: $value.showCommander),
  );

  @override
  AppUserCopyWith<$R2, AppUser, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _AppUserCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

