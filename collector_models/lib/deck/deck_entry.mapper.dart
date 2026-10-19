// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'deck_entry.dart';

class DeckSectionMapper extends EnumMapper<DeckSection> {
  DeckSectionMapper._();

  static DeckSectionMapper? _instance;
  static DeckSectionMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = DeckSectionMapper._());
    }
    return _instance!;
  }

  static DeckSection fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  DeckSection decode(dynamic value) {
    switch (value) {
      case r'mainboard':
        return DeckSection.mainboard;
      case r'sideboard':
        return DeckSection.sideboard;
      case r'commander':
        return DeckSection.commander;
      case r'maybeboard':
        return DeckSection.maybeboard;
      case r'companion':
        return DeckSection.companion;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(DeckSection self) {
    switch (self) {
      case DeckSection.mainboard:
        return r'mainboard';
      case DeckSection.sideboard:
        return r'sideboard';
      case DeckSection.commander:
        return r'commander';
      case DeckSection.maybeboard:
        return r'maybeboard';
      case DeckSection.companion:
        return r'companion';
    }
  }
}

extension DeckSectionMapperExtension on DeckSection {
  String toValue() {
    DeckSectionMapper.ensureInitialized();
    return MapperContainer.globals.toValue<DeckSection>(this) as String;
  }
}

class DeckEntryMapper extends ClassMapperBase<DeckEntry> {
  DeckEntryMapper._();

  static DeckEntryMapper? _instance;
  static DeckEntryMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = DeckEntryMapper._());
      MapperContainer.globals.useAll(<MapperBase<Object>>[
        ScryfallEnumMapper<Finish>(Finish.values),
      ]);
      DeckSectionMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'DeckEntry';

  static String _$scryfallId(DeckEntry v) => v.scryfallId;
  static const Field<DeckEntry, String> _f$scryfallId = Field(
    'scryfallId',
    _$scryfallId,
  );
  static int _$quantity(DeckEntry v) => v.quantity;
  static const Field<DeckEntry, int> _f$quantity = Field(
    'quantity',
    _$quantity,
    opt: true,
    def: 1,
  );
  static DeckSection _$section(DeckEntry v) => v.section;
  static const Field<DeckEntry, DeckSection> _f$section = Field(
    'section',
    _$section,
    opt: true,
    def: DeckSection.mainboard,
  );
  static Finish? _$finish(DeckEntry v) => v.finish;
  static const Field<DeckEntry, Finish> _f$finish = Field(
    'finish',
    _$finish,
    opt: true,
  );
  static String? _$language(DeckEntry v) => v.language;
  static const Field<DeckEntry, String> _f$language = Field(
    'language',
    _$language,
    opt: true,
  );
  static String? _$condition(DeckEntry v) => v.condition;
  static const Field<DeckEntry, String> _f$condition = Field(
    'condition',
    _$condition,
    opt: true,
  );

  @override
  final MappableFields<DeckEntry> fields = const {
    #scryfallId: _f$scryfallId,
    #quantity: _f$quantity,
    #section: _f$section,
    #finish: _f$finish,
    #language: _f$language,
    #condition: _f$condition,
  };

  static DeckEntry _instantiate(DecodingData data) {
    return DeckEntry(
      scryfallId: data.dec(_f$scryfallId),
      quantity: data.dec(_f$quantity),
      section: data.dec(_f$section),
      finish: data.dec(_f$finish),
      language: data.dec(_f$language),
      condition: data.dec(_f$condition),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static DeckEntry fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<DeckEntry>(map);
  }

  static DeckEntry fromJson(String json) {
    return ensureInitialized().decodeJson<DeckEntry>(json);
  }
}

mixin DeckEntryMappable {
  String toJson() {
    return DeckEntryMapper.ensureInitialized().encodeJson<DeckEntry>(
      this as DeckEntry,
    );
  }

  Map<String, dynamic> toMap() {
    return DeckEntryMapper.ensureInitialized().encodeMap<DeckEntry>(
      this as DeckEntry,
    );
  }

  DeckEntryCopyWith<DeckEntry, DeckEntry, DeckEntry> get copyWith =>
      _DeckEntryCopyWithImpl<DeckEntry, DeckEntry>(
        this as DeckEntry,
        $identity,
        $identity,
      );
  @override
  String toString() {
    return DeckEntryMapper.ensureInitialized().stringifyValue(
      this as DeckEntry,
    );
  }

  @override
  bool operator ==(Object other) {
    return DeckEntryMapper.ensureInitialized().equalsValue(
      this as DeckEntry,
      other,
    );
  }

  @override
  int get hashCode {
    return DeckEntryMapper.ensureInitialized().hashValue(this as DeckEntry);
  }
}

extension DeckEntryValueCopy<$R, $Out> on ObjectCopyWith<$R, DeckEntry, $Out> {
  DeckEntryCopyWith<$R, DeckEntry, $Out> get $asDeckEntry =>
      $base.as((v, t, t2) => _DeckEntryCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class DeckEntryCopyWith<$R, $In extends DeckEntry, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({
    String? scryfallId,
    int? quantity,
    DeckSection? section,
    Finish? finish,
    String? language,
    String? condition,
  });
  DeckEntryCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _DeckEntryCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, DeckEntry, $Out>
    implements DeckEntryCopyWith<$R, DeckEntry, $Out> {
  _DeckEntryCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<DeckEntry> $mapper =
      DeckEntryMapper.ensureInitialized();
  @override
  $R call({
    String? scryfallId,
    int? quantity,
    DeckSection? section,
    Object? finish = $none,
    Object? language = $none,
    Object? condition = $none,
  }) => $apply(
    FieldCopyWithData({
      if (scryfallId != null) #scryfallId: scryfallId,
      if (quantity != null) #quantity: quantity,
      if (section != null) #section: section,
      if (finish != $none) #finish: finish,
      if (language != $none) #language: language,
      if (condition != $none) #condition: condition,
    }),
  );
  @override
  DeckEntry $make(CopyWithData data) => DeckEntry(
    scryfallId: data.get(#scryfallId, or: $value.scryfallId),
    quantity: data.get(#quantity, or: $value.quantity),
    section: data.get(#section, or: $value.section),
    finish: data.get(#finish, or: $value.finish),
    language: data.get(#language, or: $value.language),
    condition: data.get(#condition, or: $value.condition),
  );

  @override
  DeckEntryCopyWith<$R2, DeckEntry, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) => _DeckEntryCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

