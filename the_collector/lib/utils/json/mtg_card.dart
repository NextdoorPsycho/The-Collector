import 'package:dart_mappable/dart_mappable.dart';

part 'mtg_card.mapper.dart';

@MappableClass()
class MtgCard with MtgCardMappable {
  final String id;
  final String name;
  final String set;
  final bool? foil;
  final String? typeLine;
  final String? manaCost;
  final int? power;
  final int? toughness;
  final int? quantity;

  MtgCard({
    required this.id,
    required this.name,
    required this.set,
    this.foil = false,
    this.typeLine = '',
    this.manaCost = '',
    this.power = 0,
    this.toughness = 0,
    this.quantity = 0,
  });
}
