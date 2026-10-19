import 'package:dart_mappable/dart_mappable.dart';
import 'package:scryfall_api/scryfall_api.dart';

part 'card_prices.mapper.dart';

@MappableEnum()
enum CardCurrency { usd, eur, tix }

@MappableClass()
class CardPrices with CardPricesMappable {
  final double? usd;
  final double? usdFoil;
  final double? usdEtched;
  final double? eur;
  final double? eurFoil;
  final double? tix;

  const CardPrices({
    this.usd,
    this.usdFoil,
    this.usdEtched,
    this.eur,
    this.eurFoil,
    this.tix,
  });

  factory CardPrices.fromScryfall(Prices prices) => CardPrices(
    usd: _parse(prices.usd),
    usdFoil: _parse(prices.usdFoil),
    usdEtched: _parse(prices.usdEtched),
    eur: _parse(prices.eur),
    eurFoil: _parse(prices.eurFoil),
    tix: _parse(prices.tix),
  );

  static double? _parse(String? value) {
    final double? parsed = value == null ? null : double.tryParse(value);
    return parsed != null && parsed.isFinite && parsed >= 0 ? parsed : null;
  }

  double? forFinish(Finish? finish, CardCurrency currency) =>
      switch (currency) {
        CardCurrency.usd => switch (finish) {
          Finish.nonfoil => usd,
          Finish.foil => usdFoil,
          Finish.etched => usdEtched,
          _ => null,
        },
        CardCurrency.eur => switch (finish) {
          Finish.nonfoil => eur,
          Finish.foil => eurFoil,
          _ => null,
        },
        CardCurrency.tix => tix,
      };
}
