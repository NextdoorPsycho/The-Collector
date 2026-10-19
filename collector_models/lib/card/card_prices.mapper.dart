// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'card_prices.dart';

class CardCurrencyMapper extends EnumMapper<CardCurrency> {
  CardCurrencyMapper._();

  static CardCurrencyMapper? _instance;
  static CardCurrencyMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CardCurrencyMapper._());
    }
    return _instance!;
  }

  static CardCurrency fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  CardCurrency decode(dynamic value) {
    switch (value) {
      case r'usd':
        return CardCurrency.usd;
      case r'eur':
        return CardCurrency.eur;
      case r'tix':
        return CardCurrency.tix;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(CardCurrency self) {
    switch (self) {
      case CardCurrency.usd:
        return r'usd';
      case CardCurrency.eur:
        return r'eur';
      case CardCurrency.tix:
        return r'tix';
    }
  }
}

extension CardCurrencyMapperExtension on CardCurrency {
  String toValue() {
    CardCurrencyMapper.ensureInitialized();
    return MapperContainer.globals.toValue<CardCurrency>(this) as String;
  }
}

class CardPricesMapper extends ClassMapperBase<CardPrices> {
  CardPricesMapper._();

  static CardPricesMapper? _instance;
  static CardPricesMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CardPricesMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'CardPrices';

  static double? _$usd(CardPrices v) => v.usd;
  static const Field<CardPrices, double> _f$usd = Field(
    'usd',
    _$usd,
    opt: true,
  );
  static double? _$usdFoil(CardPrices v) => v.usdFoil;
  static const Field<CardPrices, double> _f$usdFoil = Field(
    'usdFoil',
    _$usdFoil,
    opt: true,
  );
  static double? _$usdEtched(CardPrices v) => v.usdEtched;
  static const Field<CardPrices, double> _f$usdEtched = Field(
    'usdEtched',
    _$usdEtched,
    opt: true,
  );
  static double? _$eur(CardPrices v) => v.eur;
  static const Field<CardPrices, double> _f$eur = Field(
    'eur',
    _$eur,
    opt: true,
  );
  static double? _$eurFoil(CardPrices v) => v.eurFoil;
  static const Field<CardPrices, double> _f$eurFoil = Field(
    'eurFoil',
    _$eurFoil,
    opt: true,
  );
  static double? _$tix(CardPrices v) => v.tix;
  static const Field<CardPrices, double> _f$tix = Field(
    'tix',
    _$tix,
    opt: true,
  );

  @override
  final MappableFields<CardPrices> fields = const {
    #usd: _f$usd,
    #usdFoil: _f$usdFoil,
    #usdEtched: _f$usdEtched,
    #eur: _f$eur,
    #eurFoil: _f$eurFoil,
    #tix: _f$tix,
  };

  static CardPrices _instantiate(DecodingData data) {
    return CardPrices(
      usd: data.dec(_f$usd),
      usdFoil: data.dec(_f$usdFoil),
      usdEtched: data.dec(_f$usdEtched),
      eur: data.dec(_f$eur),
      eurFoil: data.dec(_f$eurFoil),
      tix: data.dec(_f$tix),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static CardPrices fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<CardPrices>(map);
  }

  static CardPrices fromJson(String json) {
    return ensureInitialized().decodeJson<CardPrices>(json);
  }
}

mixin CardPricesMappable {
  String toJson() {
    return CardPricesMapper.ensureInitialized().encodeJson<CardPrices>(
      this as CardPrices,
    );
  }

  Map<String, dynamic> toMap() {
    return CardPricesMapper.ensureInitialized().encodeMap<CardPrices>(
      this as CardPrices,
    );
  }

  CardPricesCopyWith<CardPrices, CardPrices, CardPrices> get copyWith =>
      _CardPricesCopyWithImpl<CardPrices, CardPrices>(
        this as CardPrices,
        $identity,
        $identity,
      );
  @override
  String toString() {
    return CardPricesMapper.ensureInitialized().stringifyValue(
      this as CardPrices,
    );
  }

  @override
  bool operator ==(Object other) {
    return CardPricesMapper.ensureInitialized().equalsValue(
      this as CardPrices,
      other,
    );
  }

  @override
  int get hashCode {
    return CardPricesMapper.ensureInitialized().hashValue(this as CardPrices);
  }
}

extension CardPricesValueCopy<$R, $Out>
    on ObjectCopyWith<$R, CardPrices, $Out> {
  CardPricesCopyWith<$R, CardPrices, $Out> get $asCardPrices =>
      $base.as((v, t, t2) => _CardPricesCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class CardPricesCopyWith<$R, $In extends CardPrices, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({
    double? usd,
    double? usdFoil,
    double? usdEtched,
    double? eur,
    double? eurFoil,
    double? tix,
  });
  CardPricesCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _CardPricesCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, CardPrices, $Out>
    implements CardPricesCopyWith<$R, CardPrices, $Out> {
  _CardPricesCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<CardPrices> $mapper =
      CardPricesMapper.ensureInitialized();
  @override
  $R call({
    Object? usd = $none,
    Object? usdFoil = $none,
    Object? usdEtched = $none,
    Object? eur = $none,
    Object? eurFoil = $none,
    Object? tix = $none,
  }) => $apply(
    FieldCopyWithData({
      if (usd != $none) #usd: usd,
      if (usdFoil != $none) #usdFoil: usdFoil,
      if (usdEtched != $none) #usdEtched: usdEtched,
      if (eur != $none) #eur: eur,
      if (eurFoil != $none) #eurFoil: eurFoil,
      if (tix != $none) #tix: tix,
    }),
  );
  @override
  CardPrices $make(CopyWithData data) => CardPrices(
    usd: data.get(#usd, or: $value.usd),
    usdFoil: data.get(#usdFoil, or: $value.usdFoil),
    usdEtched: data.get(#usdEtched, or: $value.usdEtched),
    eur: data.get(#eur, or: $value.eur),
    eurFoil: data.get(#eurFoil, or: $value.eurFoil),
    tix: data.get(#tix, or: $value.tix),
  );

  @override
  CardPricesCopyWith<$R2, CardPrices, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) => _CardPricesCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

