import 'dart:convert';

import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_artwork_matcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';

ScanCrop liveHistoricalScene() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":599,"height":837,"rectified":false,"sourceCorners":[{"x":0.5560641288757324,"y":0.4502313733100891},{"x":0.8156411647796631,"y":0.44444555044174194},{"x":0.8935714960098267,"y":0.6120189130306244},{"x":0.530440092086792,"y":0.6040480136871338}],"warnings":["orientation_ensemble","geometry_adjusted","incomplete_card"],"lines":[{"text":"Enchanament","confidence":1,"bounds":{"height":0.05079147411701501,"width":0.2863897450764974,"x":0.10006877765789236,"y":0.4918381417941904},"glyphHeight":0.031819375137579056,"alternatives":["Enchanument","Enchanment"]},{"text":"1; Prevent all damage against you","confidence":1,"bounds":{"height":0.05830223520501987,"width":0.6636041259765625,"x":0.16479494347408433,"y":0.5982769918464639},"glyphHeight":0.03313994092202846,"alternatives":["1: Prevent all damage against you","1 ; Prevent all damage against you"]},{"text":"from one blue source. If a source","confidence":1,"bounds":{"height":0.053300864372162304,"width":0.6565478515625001,"x":0.15848238623682714,"y":0.6317566817390691},"glyphHeight":0.03324597283439383,"alternatives":["from on blue source. If a source","from one blue source. Ifa source"]},{"text":"deals damage to you more than","confidence":1,"bounds":{"height":0.05859852064765436,"width":0.6204975891113282,"x":0.16118027497289517,"y":0.6650547872364727},"glyphHeight":0.036658515722503476,"alternatives":["deal damage to you more than","deals damage to you more han"]},{"text":"Illus. Pete Venters","confidence":1,"bounds":{"height":0.03629655542123289,"width":0.3087492370605469,"x":0.10238837431267735,"y":0.856663966389648},"glyphHeight":0.0296385158524613,"alternatives":["flus. Pete Venters","Ilus. Pete Venters"]},{"text":"once in a turn, you may pay 1","confidence":1,"bounds":{"height":0.046113822573707185,"width":0.5921138000488282,"x":0.15881627067218498,"y":0.7060325189919769},"glyphHeight":0.0329452997592843,"alternatives":[]},{"text":"each time to prevent the damage.","confidence":1,"bounds":{"height":0.054007652827671615,"width":0.6564992777506511,"x":0.1618762552796857,"y":0.7329671316229992},"glyphHeight":0.03230187642125537,"alternatives":[]},{"text":"lllus. Pete Venters","confidence":1,"bounds":{"height":0.03575237364996048,"width":0.30931386311848963,"x":0.10193033389121343,"y":0.8586266138030492},"glyphHeight":0.02747378134343044,"alternatives":[]},{"text":"© 1995 Wizards of the Coast, Inc. All rights reserved.","confidence":1,"bounds":{"height":0.028396341914222342,"width":0.5177172851562499,"x":0.10277301092483607,"y":0.8866897882227653},"glyphHeight":0.01800094811520648,"alternatives":[]},{"text":"Enchantment","confidence":1,"bounds":{"height":0.0459550585065569,"width":0.2766445968704351,"x":0.10599314118936874,"y":0.4962225790909143},"glyphHeight":0.027540674707476672,"alternatives":["Enchantmenr","Enchartment"]}]}''',
  ) as Map<Object?, Object?>,
);

class HistoricalSceneCard extends Fake implements MtgCard {
  @override
  List<Game> get games => const <Game>[Game.paper];
  @override
  String get id => 'historical-blue';
  @override
  String get name => 'Circle of Protection: Blue';
  @override
  String get set => 'ice';
  @override
  String get collectorNumber => '13';
  @override
  String? get printedName => null;
  @override
  List<CardFace>? get cardFaces => null;
  @override
  Language get lang => Language.english;
  @override
  String? get artist => 'Pete Venters';
  @override
  DateTime get releasedAt => DateTime(1995, 6, 3);
  @override
  String get typeLine => 'Enchantment';
  @override
  String? get oracleText =>
      '{1}: The next time a blue source of your choice would deal damage to you this turn, prevent that damage.';
  @override
  String? get printedText => null;
  @override
  String? get flavorText => null;
  @override
  String? get illustrationId => null;
}

class _HistoricalCatalog implements ScanCatalog {
  final MtgCard card = HistoricalSceneCard();
  @override
  Future<MtgCard?> exactPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  }) async => null;
  @override
  Future<MtgCard?> fuzzyName(String name) async => null;
  @override
  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[card], hasMore: false);
  @override
  Future<PaginableList<MtgCard>> rulesKeywordCards(
    List<String> keywords, {
    String? phrase,
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[card], hasMore: false);
  @override
  Future<PaginableList<MtgCard>> rulesTextPrintings(
    String phrase, {
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
    int page = 1,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);
}

class _NoArtwork implements ScanArtworkMatcher {
  @override
  Future<Map<String, double>> compare(
    ScanCrop crop,
    List<MtgCard> candidates, {
    bool reliableBodyFallback = false,
  }) async => <String, double>{};
}

Future<ScanResolution> resolveHistoricalScene(ScanCrop crop) => ScanResolver(
  catalog: _HistoricalCatalog(),
  artwork: _NoArtwork(),
).resolve(crop);
