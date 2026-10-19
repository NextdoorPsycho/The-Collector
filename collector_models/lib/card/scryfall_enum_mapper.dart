import 'package:dart_mappable/dart_mappable.dart';

class ScryfallEnumMapper<T extends Enum> extends EnumMapper<T> {
  const ScryfallEnumMapper(this.values);

  final List<T> values;

  @override
  T decode(Object value) {
    for (final T candidate in values) {
      if (candidate.name == value) return candidate;
    }
    throw MapperException.unknownEnumValue(value);
  }

  @override
  String encode(T value) => value.name;
}
