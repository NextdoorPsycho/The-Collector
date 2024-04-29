// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
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
      case 'white':
        return ManaColor.white;
      case 'blue':
        return ManaColor.blue;
      case 'black':
        return ManaColor.black;
      case 'red':
        return ManaColor.red;
      case 'green':
        return ManaColor.green;
      case 'colorless':
        return ManaColor.colorless;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(ManaColor self) {
    switch (self) {
      case ManaColor.white:
        return 'white';
      case ManaColor.blue:
        return 'blue';
      case ManaColor.black:
        return 'black';
      case ManaColor.red:
        return 'red';
      case ManaColor.green:
        return 'green';
      case ManaColor.colorless:
        return 'colorless';
    }
  }
}

extension ManaColorMapperExtension on ManaColor {
  String toValue() {
    ManaColorMapper.ensureInitialized();
    return MapperContainer.globals.toValue<ManaColor>(this) as String;
  }
}
