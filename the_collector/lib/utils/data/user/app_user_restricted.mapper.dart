// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'app_user_restricted.dart';

class AppUserRestrictedMapper extends ClassMapperBase<AppUserRestricted> {
  AppUserRestrictedMapper._();

  static AppUserRestrictedMapper? _instance;
  static AppUserRestrictedMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = AppUserRestrictedMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'AppUserRestricted';

  static bool _$admin(AppUserRestricted v) => v.admin;
  static const Field<AppUserRestricted, bool> _f$admin =
      Field('admin', _$admin, opt: true, def: false);
  static String? _$id(AppUserRestricted v) => v.id;
  static const Field<AppUserRestricted, String> _f$id =
      Field('id', _$id, mode: FieldMode.member);

  @override
  final MappableFields<AppUserRestricted> fields = const {
    #admin: _f$admin,
    #id: _f$id,
  };

  static AppUserRestricted _instantiate(DecodingData data) {
    return AppUserRestricted(admin: data.dec(_f$admin));
  }

  @override
  final Function instantiate = _instantiate;

  static AppUserRestricted fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<AppUserRestricted>(map);
  }

  static AppUserRestricted fromJson(String json) {
    return ensureInitialized().decodeJson<AppUserRestricted>(json);
  }
}

mixin AppUserRestrictedMappable {
  String toJson() {
    return AppUserRestrictedMapper.ensureInitialized()
        .encodeJson<AppUserRestricted>(this as AppUserRestricted);
  }

  Map<String, dynamic> toMap() {
    return AppUserRestrictedMapper.ensureInitialized()
        .encodeMap<AppUserRestricted>(this as AppUserRestricted);
  }

  AppUserRestrictedCopyWith<AppUserRestricted, AppUserRestricted,
          AppUserRestricted>
      get copyWith => _AppUserRestrictedCopyWithImpl(
          this as AppUserRestricted, $identity, $identity);
  @override
  String toString() {
    return AppUserRestrictedMapper.ensureInitialized()
        .stringifyValue(this as AppUserRestricted);
  }

  @override
  bool operator ==(Object other) {
    return AppUserRestrictedMapper.ensureInitialized()
        .equalsValue(this as AppUserRestricted, other);
  }

  @override
  int get hashCode {
    return AppUserRestrictedMapper.ensureInitialized()
        .hashValue(this as AppUserRestricted);
  }
}

extension AppUserRestrictedValueCopy<$R, $Out>
    on ObjectCopyWith<$R, AppUserRestricted, $Out> {
  AppUserRestrictedCopyWith<$R, AppUserRestricted, $Out>
      get $asAppUserRestricted =>
          $base.as((v, t, t2) => _AppUserRestrictedCopyWithImpl(v, t, t2));
}

abstract class AppUserRestrictedCopyWith<$R, $In extends AppUserRestricted,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  $R call({bool? admin});
  AppUserRestrictedCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
      Then<$Out2, $R2> t);
}

class _AppUserRestrictedCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, AppUserRestricted, $Out>
    implements AppUserRestrictedCopyWith<$R, AppUserRestricted, $Out> {
  _AppUserRestrictedCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<AppUserRestricted> $mapper =
      AppUserRestrictedMapper.ensureInitialized();
  @override
  $R call({bool? admin}) =>
      $apply(FieldCopyWithData({if (admin != null) #admin: admin}));
  @override
  AppUserRestricted $make(CopyWithData data) =>
      AppUserRestricted(admin: data.get(#admin, or: $value.admin));

  @override
  AppUserRestrictedCopyWith<$R2, AppUserRestricted, $Out2> $chain<$R2, $Out2>(
          Then<$Out2, $R2> t) =>
      _AppUserRestrictedCopyWithImpl($value, $cast, t);
}
