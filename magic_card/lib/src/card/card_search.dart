import 'package:fast_log/fast_log.dart';
import 'package:scryfall_api/scryfall_api.dart';

class CardSearch {
  static final ScryfallApiClient _apiClient = ScryfallApiClient();

  static Future<List<MtgCard>> searchCardsByStrings(
      List<String> strings) async {
    List<MtgCard> candidateCards = [];

    for (String s in strings) {
      List<MtgCard> matchingCards = await _searchByString(s);
      candidateCards.addAll(matchingCards);
    }

    candidateCards = candidateCards.toSet().toList();
    candidateCards.sort((a, b) =>
        _getMatchScore(b, strings).compareTo(_getMatchScore(a, strings)));

    return candidateCards;
  }

  static Future<MtgCard?> searchMostConfidentCard(List<String> strings) async {
    final candidateCards = await searchCardsByStrings(strings);
    return candidateCards.isNotEmpty ? candidateCards.first : null;
  }

  static Future<MtgCard?> getCardByID(String id) async {
    try {
      final card = await _apiClient.getCardById(id);
      return card;
    } catch (e) {
      info('Error getting card by ID: $e');
      return null;
    }
  }

  static Future<List<MtgCard>> _searchByString(String query) async {
    try {
      final searchResult = await _apiClient.searchCards(query);
      info('Search result: $searchResult');
      return searchResult.data ?? [];
    } catch (e) {
      info('Error searching cards: $e');
      return [];
    }
  }

  static int _getMatchScore(MtgCard card, List<String> strings) {
    int score = 0;

    for (String s in strings) {
      final lowerQuery = s.toLowerCase();

      if (card.name.toLowerCase().contains(lowerQuery)) {
        score += 5;
      }
      if (card.typeLine.toLowerCase().contains(lowerQuery)) {
        score += 4;
      }
      if (card.oracleText?.toLowerCase().contains(lowerQuery) ?? false) {
        score += 3;
      }
      if (card.flavorText?.toLowerCase().contains(lowerQuery) ?? false) {
        score += 2;
      }
      if (card.artist?.toLowerCase().contains(lowerQuery) ?? false) {
        score += 1;
      }
      if (card.toughness?.toLowerCase().contains(lowerQuery) ?? false) {
        score += 1;
      }
      if (card.power?.toLowerCase().contains(lowerQuery) ?? false) {
        score += 1;
      }
    }

    return score;
  }
}
