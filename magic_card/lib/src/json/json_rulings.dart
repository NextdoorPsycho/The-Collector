//Garnerd from here:
//https://scryfall.com/docs/api/bulk-data
// https://data.scryfall.io/rulings/rulings-20240413210024.json
// 20240413210024 this is extrapolated from the date: 	2024-04-13 21:00 UTC  (YYYY-MM-DD HH:MM UTC)

import 'dart:convert';
import 'dart:io';

class CardRuling {
  final String object;
  final String oracleId;
  final String source;
  final DateTime publishedAt;
  final String comment;

  CardRuling({
    required this.object,
    required this.oracleId,
    required this.source,
    required this.publishedAt,
    required this.comment,
  });

  factory CardRuling.fromJson(Map<String, dynamic> json) {
    return CardRuling(
      object: json['object'],
      oracleId: json['oracle_id'],
      source: json['source'],
      publishedAt: DateTime.parse(json['published_at']),
      comment: json['comment'],
    );
  }
}

class RulingDatabase {
  List<CardRuling> rulings = [];

  Future<void> loadRulings(String filePath) async {
    var file = File(filePath);
    var content = await file.readAsString();
    var jsonList = json.decode(content) as List;
    rulings = jsonList.map((json) => CardRuling.fromJson(json)).toList();
  }

  List<String> searchComments(String keyword) {
    var matchedRulings = rulings
        .where((ruling) =>
            ruling.comment.toLowerCase().contains(keyword.toLowerCase()))
        .toList();
    return matchedRulings
        .map((ruling) => ruling.oracleId)
        .toSet()
        .toList(); // Use a Set to avoid duplicate IDs
  }
}
