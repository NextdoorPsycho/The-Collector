import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/scryfall_request_scheduler.dart';

class CardCatalog {
  CardCatalog({ScryfallApiClient? client})
    : _client =
          client ??
          ScryfallApiClient(
            httpClient: ScryfallHttpClient(),
            userAgent: 'TheCollector/1.0',
          );

  final ScryfallApiClient _client;
  final Map<String, MtgCard> _cards = <String, MtgCard>{};

  void close() => _client.close();

  void invalidatePrintings(Iterable<String> ids) {
    for (final String id in ids) {
      _cards.remove(id);
    }
  }

  Future<PaginableList<MtgCard>> search(
    String query, {
    int page = 1,
    bool allPrintings = false,
  }) async {
    try {
      final PaginableList<MtgCard> result = await _client.searchCards(
        query.trim(),
        page: page,
        rollupMode: allPrintings ? RollupMode.prints : null,
        includeMultilingual: allPrintings,
        includeVariations: allPrintings,
      );
      for (final MtgCard card in result.data) {
        _cards[card.id] = card;
      }
      return result;
    } on ScryfallException catch (error) {
      if (error.status != 404) rethrow;
      return PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);
    }
  }

  Future<Map<String, MtgCard>> printings(Iterable<String> ids) async {
    final List<String> unique = ids.toSet().toList();
    final List<String> missing = unique
        .where((String id) => !_cards.containsKey(id))
        .toList();
    for (int offset = 0; offset < missing.length; offset += 75) {
      final List<String> chunk = missing.skip(offset).take(75).toList();
      final CardList result = await _client.getCardsByIdentifiers(
        chunk.map((String id) => CardIdentifierId(id)).toList(),
      );
      for (final MtgCard card in result.data) {
        _cards[card.id] = card;
      }
    }
    return <String, MtgCard>{
      for (final String id in unique)
        if (_cards[id] case final MtgCard card) id: card,
    };
  }

  Future<List<Ruling>> rulings(String id) async {
    final PaginableList<Ruling> result = await _client.getRulingsById(id);
    return result.data;
  }
}
