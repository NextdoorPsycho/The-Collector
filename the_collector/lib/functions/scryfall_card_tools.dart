import 'package:fast_log/fast_log.dart';
import 'package:scryfall_api/scryfall_api.dart';

class Scryfall {
  final ScryfallApiClient _apiClient;

  Scryfall(this._apiClient);

  Future<MtgCard?> getCardByStrings(List<String> strings) async {
    List<MtgCard> candidateCards = await _searchCards(strings);
    return _selectBestMatchingCard(candidateCards, strings);
  }

  Future<MtgCard?> getCardByID(String id) async {
    try {
      final card = await _apiClient.getCardById(id);
      return card;
    } catch (e) {
      info('Error getting card by ID: $e');
      return null;
    }
  }

  Future<List<MtgCard>> _searchCards(List<String> strings) async {
    List<MtgCard> candidateCards = [];

    for (String s in strings) {
      List<MtgCard> matchingCards = await _searchByString(s);
      candidateCards.addAll(matchingCards);
    }

    return candidateCards;
  }

  Future<List<MtgCard>> _searchByString(String query) async {
    try {
      final searchResult = await _apiClient.searchCards(query);
      info('Search result: $searchResult');
      return searchResult.data ?? [];
    } catch (e) {
      info('Error searching cards: $e');
      return [];
    }
  }

  MtgCard? _selectBestMatchingCard(
      List<MtgCard> candidateCards, List<String> strings) {
    if (candidateCards.isEmpty) {
      return null;
    }

    candidateCards.sort((a, b) =>
        _getMatchScore(b, strings).compareTo(_getMatchScore(a, strings)));
    return candidateCards.first;
  }

  int _getMatchScore(MtgCard card, List<String> strings) {
    int score = 0;

    for (String s in strings) {
      if (card.name.toLowerCase().contains(s.toLowerCase())) {
        score += 3;
      }
      if (card.typeLine.toLowerCase().contains(s.toLowerCase())) {
        score += 2;
      }
      if (card.oracleText?.toLowerCase().contains(s.toLowerCase()) ?? false) {
        score += 1;
      }
    }

    return score;
  }
}
