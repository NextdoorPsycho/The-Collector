import 'package:dart_mappable/dart_mappable.dart';
import 'package:scryfall_api/scryfall_api.dart';

import '../card/scryfall_enum_mapper.dart';

part 'deck_entry.mapper.dart';

@MappableEnum()
enum DeckSection { mainboard, sideboard, commander, maybeboard, companion }

@MappableClass(
  includeCustomMappers: <MapperBase<Object>>[
    ScryfallEnumMapper<Finish>(Finish.values),
  ],
)
class DeckEntry with DeckEntryMappable {
  final String scryfallId;
  final int quantity;
  final DeckSection section;
  final Finish? finish;
  final String? language;
  final String? condition;

  const DeckEntry({
    required this.scryfallId,
    this.quantity = 1,
    this.section = DeckSection.mainboard,
    this.finish,
    this.language,
    this.condition,
  });

  String get cardId => finish == null || finish == Finish.nonfoil
      ? scryfallId
      : '${scryfallId}__${finish!.name}';
}
