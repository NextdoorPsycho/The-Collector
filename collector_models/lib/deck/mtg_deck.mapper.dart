// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'mtg_deck.dart';

class DeckFormatMapper extends EnumMapper<DeckFormat> {
  DeckFormatMapper._();

  static DeckFormatMapper? _instance;
  static DeckFormatMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = DeckFormatMapper._());
    }
    return _instance!;
  }

  static DeckFormat fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  DeckFormat decode(dynamic value) {
    switch (value) {
      case r'casual':
        return DeckFormat.casual;
      case r'commander':
        return DeckFormat.commander;
      case r'standard':
        return DeckFormat.standard;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(DeckFormat self) {
    switch (self) {
      case DeckFormat.casual:
        return r'casual';
      case DeckFormat.commander:
        return r'commander';
      case DeckFormat.standard:
        return r'standard';
    }
  }
}

extension DeckFormatMapperExtension on DeckFormat {
  String toValue() {
    DeckFormatMapper.ensureInitialized();
    return MapperContainer.globals.toValue<DeckFormat>(this) as String;
  }
}

class CollectionGroupKindMapper extends EnumMapper<CollectionGroupKind> {
  CollectionGroupKindMapper._();

  static CollectionGroupKindMapper? _instance;
  static CollectionGroupKindMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CollectionGroupKindMapper._());
    }
    return _instance!;
  }

  static CollectionGroupKind fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  CollectionGroupKind decode(dynamic value) {
    switch (value) {
      case r'deck':
        return CollectionGroupKind.deck;
      case r'binder':
        return CollectionGroupKind.binder;
      case r'box':
        return CollectionGroupKind.box;
      case r'folder':
        return CollectionGroupKind.folder;
      case r'list':
        return CollectionGroupKind.list;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(CollectionGroupKind self) {
    switch (self) {
      case CollectionGroupKind.deck:
        return r'deck';
      case CollectionGroupKind.binder:
        return r'binder';
      case CollectionGroupKind.box:
        return r'box';
      case CollectionGroupKind.folder:
        return r'folder';
      case CollectionGroupKind.list:
        return r'list';
    }
  }
}

extension CollectionGroupKindMapperExtension on CollectionGroupKind {
  String toValue() {
    CollectionGroupKindMapper.ensureInitialized();
    return MapperContainer.globals.toValue<CollectionGroupKind>(this) as String;
  }
}

class MTGDeckMapper extends ClassMapperBase<MTGDeck> {
  MTGDeckMapper._();

  static MTGDeckMapper? _instance;
  static MTGDeckMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = MTGDeckMapper._());
      DeckEntryMapper.ensureInitialized();
      DeckFormatMapper.ensureInitialized();
      CollectionGroupKindMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'MTGDeck';

  static String _$name(MTGDeck v) => v.name;
  static const Field<MTGDeck, String> _f$name = Field('name', _$name);
  static List<String> _$cards(MTGDeck v) => v.cards;
  static const Field<MTGDeck, List<String>> _f$cards = Field(
    'cards',
    _$cards,
    opt: true,
    def: const <String>[],
  );
  static List<DeckEntry>? _$entries(MTGDeck v) => v.entries;
  static const Field<MTGDeck, List<DeckEntry>> _f$entries = Field(
    'entries',
    _$entries,
    opt: true,
  );
  static DeckFormat _$format(MTGDeck v) => v.format;
  static const Field<MTGDeck, DeckFormat> _f$format = Field(
    'format',
    _$format,
    opt: true,
    def: DeckFormat.casual,
  );
  static CollectionGroupKind _$kind(MTGDeck v) => v.kind;
  static const Field<MTGDeck, CollectionGroupKind> _f$kind = Field(
    'kind',
    _$kind,
    opt: true,
    def: CollectionGroupKind.deck,
  );
  static String? _$parentId(MTGDeck v) => v.parentId;
  static const Field<MTGDeck, String> _f$parentId = Field(
    'parentId',
    _$parentId,
    opt: true,
  );
  static String? _$sourceUrl(MTGDeck v) => v.sourceUrl;
  static const Field<MTGDeck, String> _f$sourceUrl = Field(
    'sourceUrl',
    _$sourceUrl,
    opt: true,
  );
  static String? _$sourceFormat(MTGDeck v) => v.sourceFormat;
  static const Field<MTGDeck, String> _f$sourceFormat = Field(
    'sourceFormat',
    _$sourceFormat,
    opt: true,
  );
  static String? _$id(MTGDeck v) => v.id;
  static const Field<MTGDeck, String> _f$id = Field(
    'id',
    _$id,
    mode: FieldMode.member,
  );

  @override
  final MappableFields<MTGDeck> fields = const {
    #name: _f$name,
    #cards: _f$cards,
    #entries: _f$entries,
    #format: _f$format,
    #kind: _f$kind,
    #parentId: _f$parentId,
    #sourceUrl: _f$sourceUrl,
    #sourceFormat: _f$sourceFormat,
    #id: _f$id,
  };

  static MTGDeck _instantiate(DecodingData data) {
    return MTGDeck(
      name: data.dec(_f$name),
      cards: data.dec(_f$cards),
      entries: data.dec(_f$entries),
      format: data.dec(_f$format),
      kind: data.dec(_f$kind),
      parentId: data.dec(_f$parentId),
      sourceUrl: data.dec(_f$sourceUrl),
      sourceFormat: data.dec(_f$sourceFormat),
    );
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
    return MTGDeckMapper.ensureInitialized().encodeJson<MTGDeck>(
      this as MTGDeck,
    );
  }

  Map<String, dynamic> toMap() {
    return MTGDeckMapper.ensureInitialized().encodeMap<MTGDeck>(
      this as MTGDeck,
    );
  }

  MTGDeckCopyWith<MTGDeck, MTGDeck, MTGDeck> get copyWith =>
      _MTGDeckCopyWithImpl<MTGDeck, MTGDeck>(
        this as MTGDeck,
        $identity,
        $identity,
      );
  @override
  String toString() {
    return MTGDeckMapper.ensureInitialized().stringifyValue(this as MTGDeck);
  }

  @override
  bool operator ==(Object other) {
    return MTGDeckMapper.ensureInitialized().equalsValue(
      this as MTGDeck,
      other,
    );
  }

  @override
  int get hashCode {
    return MTGDeckMapper.ensureInitialized().hashValue(this as MTGDeck);
  }
}

extension MTGDeckValueCopy<$R, $Out> on ObjectCopyWith<$R, MTGDeck, $Out> {
  MTGDeckCopyWith<$R, MTGDeck, $Out> get $asMTGDeck =>
      $base.as((v, t, t2) => _MTGDeckCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class MTGDeckCopyWith<$R, $In extends MTGDeck, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, String, ObjectCopyWith<$R, String, String>> get cards;
  ListCopyWith<$R, DeckEntry, DeckEntryCopyWith<$R, DeckEntry, DeckEntry>>?
  get entries;
  $R call({
    String? name,
    List<String>? cards,
    List<DeckEntry>? entries,
    DeckFormat? format,
    CollectionGroupKind? kind,
    String? parentId,
    String? sourceUrl,
    String? sourceFormat,
  });
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
      ListCopyWith(
        $value.cards,
        (v, t) => ObjectCopyWith(v, $identity, t),
        (v) => call(cards: v),
      );
  @override
  ListCopyWith<$R, DeckEntry, DeckEntryCopyWith<$R, DeckEntry, DeckEntry>>?
  get entries => $value.entries != null
      ? ListCopyWith(
          $value.entries!,
          (v, t) => v.copyWith.$chain(t),
          (v) => call(entries: v),
        )
      : null;
  @override
  $R call({
    String? name,
    List<String>? cards,
    Object? entries = $none,
    DeckFormat? format,
    CollectionGroupKind? kind,
    Object? parentId = $none,
    Object? sourceUrl = $none,
    Object? sourceFormat = $none,
  }) => $apply(
    FieldCopyWithData({
      if (name != null) #name: name,
      if (cards != null) #cards: cards,
      if (entries != $none) #entries: entries,
      if (format != null) #format: format,
      if (kind != null) #kind: kind,
      if (parentId != $none) #parentId: parentId,
      if (sourceUrl != $none) #sourceUrl: sourceUrl,
      if (sourceFormat != $none) #sourceFormat: sourceFormat,
    }),
  );
  @override
  MTGDeck $make(CopyWithData data) => MTGDeck(
    name: data.get(#name, or: $value.name),
    cards: data.get(#cards, or: $value.cards),
    entries: data.get(#entries, or: $value.entries),
    format: data.get(#format, or: $value.format),
    kind: data.get(#kind, or: $value.kind),
    parentId: data.get(#parentId, or: $value.parentId),
    sourceUrl: data.get(#sourceUrl, or: $value.sourceUrl),
    sourceFormat: data.get(#sourceFormat, or: $value.sourceFormat),
  );

  @override
  MTGDeckCopyWith<$R2, MTGDeck, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _MTGDeckCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

