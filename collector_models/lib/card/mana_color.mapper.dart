// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'mana_color.dart';

class ManaColorMapper extends EnumMapper<ManaColor> {
  ManaColorMapper._();

  static ManaColorMapper? _instance;
  static ManaColorMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ManaColorMapper._());
    }
    return _instance!;
  }

  static ManaColor fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  ManaColor decode(dynamic value) {
    switch (value) {
      case r'white':
        return ManaColor.white;
      case r'blue':
        return ManaColor.blue;
      case r'black':
        return ManaColor.black;
      case r'red':
        return ManaColor.red;
      case r'green':
        return ManaColor.green;
      case r'colorless':
        return ManaColor.colorless;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(ManaColor self) {
    switch (self) {
      case ManaColor.white:
        return r'white';
      case ManaColor.blue:
        return r'blue';
      case ManaColor.black:
        return r'black';
      case ManaColor.red:
        return r'red';
      case ManaColor.green:
        return r'green';
      case ManaColor.colorless:
        return r'colorless';
    }
  }
}

extension ManaColorMapperExtension on ManaColor {
  String toValue() {
    ManaColorMapper.ensureInitialized();
    return MapperContainer.globals.toValue<ManaColor>(this) as String;
  }
}

