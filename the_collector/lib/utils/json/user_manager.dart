import 'package:dart_mappable/dart_mappable.dart';
import 'package:the_collector/utils/json/deck.dart';
import 'package:the_collector/utils/json/mtg_card.dart';

part 'user_manager.mapper.dart';

@MappableClass()
class UserManager with UserManagerMappable {
  final bool adminStatus;
  final List<Deck> decks;
  final Deck? deckById;
  final bool theme;
  final List<MtgCard> collection;

  UserManager({
    this.adminStatus = false,
    this.decks = const [],
    this.deckById,
    this.theme = false, // assuming false = light theme
    this.collection = const [],
  });
}
