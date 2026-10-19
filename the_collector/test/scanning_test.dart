import 'dart:async';
import 'dart:convert';

import 'helpers/live_historical_scene.dart';

import 'package:the_collector/utils/scanning/scan_artwork_matcher.dart';
import 'package:the_collector/utils/scanning/scan_symbol_matcher.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_name_index.dart';
import 'package:the_collector/utils/scanning/scryfall_request_scheduler.dart';

class _Card extends Fake implements MtgCard {
  @override
  final String id;
  @override
  final String name;
  @override
  String? get printedName => null;
  @override
  List<CardFace>? get cardFaces => null;

  @override
  final String set;
  @override
  final String collectorNumber;
  @override
  final Language lang;
  @override
  final String? oracleText;
  @override
  final String? flavorText;
  @override
  final String? artist;
  @override
  final DateTime releasedAt;
  @override
  final String? illustrationId;
  @override
  String? get printedText => null;
  @override
  final String typeLine;
  @override
  final List<Game> games;
  @override
  final Rarity rarity;

  _Card(
    this.id,
    this.name, {
    this.set = 'mom',
    this.collectorNumber = '123',
    this.lang = Language.english,
    this.oracleText,
    this.flavorText,
    this.artist,
    DateTime? releasedAt,
    this.illustrationId,
    this.typeLine = 'Instant',
    this.games = const <Game>[Game.paper],
    this.rarity = Rarity.common,
  }) : releasedAt = releasedAt ?? DateTime(2020);
}

class _Catalog implements ScanCatalog {
  MtgCard? exact;
  MtgCard? fuzzy;
  List<MtgCard> cards = <MtgCard>[];
  final Map<String, List<MtgCard>> namedCards = <String, List<MtgCard>>{};
  final Map<String, List<MtgCard>> scopedCards = <String, List<MtgCard>>{};
  final Map<String, bool> namedHasMore = <String, bool>{};
  final Map<String, Object> namedFailures = <String, Object>{};
  List<MtgCard> bodyCards = <MtgCard>[];
  List<MtgCard> keywordCards = <MtgCard>[];
  List<MtgCard>? phraseCards;
  Object? keywordFailure;
  final List<String> calls = <String>[];
  Object? failure;
  bool hasMore = false;

  @override
  Future<PaginableList<MtgCard>> rulesKeywordCards(
    List<String> keywords, {
    String? phrase,
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
  }) async {
    calls.add(
      'keywords:${keywords.join(',')}/$setCode/$collectorNumber/$language/$typeLine${phrase == null ? '' : '/$phrase'}',
    );
    if (keywordFailure != null) throw keywordFailure!;
    return PaginableList<MtgCard>(
      data: phrase == null ? keywordCards : phraseCards ?? keywordCards,
      hasMore: hasMore,
    );
  }

  @override
  Future<PaginableList<MtgCard>> rulesTextPrintings(
    String phrase, {
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
    int page = 1,
  }) async {
    calls.add(
      'body:$phrase/$setCode/$collectorNumber/$language/$typeLine/$page',
    );
    return PaginableList<MtgCard>(data: bodyCards, hasMore: hasMore);
  }

  @override
  Future<MtgCard?> exactPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  }) async {
    calls.add('$setCode/$collectorNumber/$language');
    if (failure != null) throw failure!;
    return exact;
  }

  @override
  Future<MtgCard?> fuzzyName(String name) async {
    calls.add('fuzzy:$name');
    if (failure != null) throw failure!;
    return fuzzy;
  }

  @override
  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) async {
    calls.add('printings:$name/$setCode/$language/$page');
    if (namedFailures.containsKey(name)) throw namedFailures[name]!;
    if (failure != null) throw failure!;
    return PaginableList<MtgCard>(
      data: scopedCards['$name/$setCode'] ?? namedCards[name] ?? cards,
      hasMore: namedHasMore[name] ?? hasMore,
    );
  }
}

class _NameIndex implements ScanNameIndex {
  final Map<String, ScanNameMatch> matches = <String, ScanNameMatch>{};
  final List<String> calls = <String>[];
  Object? failure;

  @override
  Future<ScanNameMatch?> match(String observed) async {
    calls.add(observed);
    if (failure != null) throw failure!;
    return matches[observed];
  }
}

class _BulkCatalog extends ScryfallScanCatalog {
  _BulkCatalog(this.delegate);

  final _Catalog delegate;

  @override
  Future<Map<String, MtgCard>> exactPrintings(List<ScanHints> hints) async =>
      <String, MtgCard>{
        for (final ScanHints hint in hints)
          if (hint.setCode != null &&
              hint.collectorNumber != null &&
              delegate.exact != null)
            '${hint.setCode}/${hint.collectorNumber}/${hint.language ?? 'en'}':
                delegate.exact!,
      };

  @override
  Future<MtgCard?> exactPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  }) => delegate.exactPrinting(setCode, collectorNumber, language: language);

  @override
  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) => delegate.printings(
    name,
    setCode: setCode,
    language: language,
    page: page,
  );

  @override
  Future<PaginableList<MtgCard>> rulesTextPrintings(
    String phrase, {
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
    int page = 1,
  }) => delegate.rulesTextPrintings(
    phrase,
    setCode: setCode,
    collectorNumber: collectorNumber,
    language: language,
    typeLine: typeLine,
    page: page,
  );
}

class _Artwork implements ScanArtworkMatcher {
  int calls = 0;
  @override
  Future<Map<String, double>> compare(
    ScanCrop crop,
    List<MtgCard> candidates, {
    bool reliableBodyFallback = false,
  }) async {
    calls++;
    return <String, double>{for (final MtgCard card in candidates) card.id: .2};
  }
}

class _BodyArtwork implements ScanArtworkMatcher {
  int calls = 0;
  List<String> comparedIds = <String>[];
  bool bodyFallback = false;

  @override
  Future<Map<String, double>> compare(
    ScanCrop crop,
    List<MtgCard> candidates, {
    bool reliableBodyFallback = false,
  }) async {
    calls++;
    comparedIds = candidates.map((MtgCard card) => card.id).toList();
    bodyFallback = reliableBodyFallback;
    return <String, double>{'red': .8, 'blue': .1};
  }
}

class _Symbol implements ScanSymbolMatcher {
  int calls = 0;
  @override
  Future<Map<String, double>> compare(
    ScanCrop crop,
    List<MtgCard> candidates,
  ) async {
    calls++;
    return <String, double>{'edition-a': .7, 'edition-b': .1};
  }
}

class _ControlledVisualMatcher
    implements ScanArtworkMatcher, ScanSymbolMatcher {
  final Completer<Map<String, double>> result =
      Completer<Map<String, double>>();
  final Completer<void> started = Completer<void>();
  List<String> ids = <String>[];

  @override
  Future<Map<String, double>> compare(
    ScanCrop crop,
    List<MtgCard> candidates, {
    bool reliableBodyFallback = false,
  }) {
    ids = candidates.map((MtgCard card) => card.id).toList();
    started.complete();
    return result.future;
  }
}

ScanTextLine _line(String text, double y) => ScanTextLine(
  text: text,
  confidence: 0.97,
  bounds: ScanBounds(0.1, y, 0.7, 0.025),
);

ScanCrop _crop(List<ScanTextLine> lines) => ScanCrop(
  imagePath: '/local/card.jpg',
  width: 745,
  height: 1040,
  rectified: true,
  sourceCorners: const <ScanPoint>[
    ScanPoint(0, 0),
    ScanPoint(1, 0),
    ScanPoint(1, 1),
    ScanPoint(0, 1),
  ],
  lines: lines,
);

const String _numericReviewOracle =
    'Choose up to one target artifact or creature card in your graveyard. '
    'You get {E}{E} (two energy counters). Then you may pay an amount of '
    '{E} equal to that card mana value. If you do, return it from your '
    'graveyard to the battlefield.';

ScanTextLine _reviewFooter(
  String text, {
  double confidence = .3,
  double y = .92,
}) => ScanTextLine(
  text: text,
  confidence: confidence,
  bounds: ScanBounds(.03, y, .18, .02),
);

ScanCrop _numericReviewCrop({
  String title = 'Jolted Awake',
  double titleConfidence = .97,
  double typeConfidence = .97,
  bool body = true,
  String firstRule = 'Choose up to one target artifact or',
  List<ScanTextLine>? footer,
}) => _crop(<ScanTextLine>[
  ScanTextLine(
    text: title,
    confidence: titleConfidence,
    bounds: const ScanBounds(.1, .04, .7, .025),
  ),
  ScanTextLine(
    text: 'Sorcery',
    confidence: typeConfidence,
    bounds: const ScanBounds(.05, .58, .17, .025),
  ),
  if (body) ...<ScanTextLine>[
    _line(firstRule, .646),
    _line('creature card in your graveyard. You', .683),
    _line('get 4 4 (two energy counters). Then you', .719),
    _line('may pay an amount of 4 equal to that card mana value.', .755),
    _line('If you do, return it from your graveyard to the battlefield.', .79),
  ],
  ...(footer ??
      <ScanTextLine>[_reviewFooter('C 0500'), _reviewFooter('MH3 EN', y: .95)]),
]);

_Card _numericReviewCard(
  String id,
  String number, {
  String set = 'mh3',
  String? illustration = 'shared-art',
}) => _Card(
  id,
  'Jolted Awake',
  set: set,
  collectorNumber: number,
  typeLine: 'Sorcery',
  oracleText: _numericReviewOracle,
  illustrationId: illustration,
);

ScanCrop _sceneCollectorCrop({
  String token = 'C 07B2',
  bool guide = true,
  double confidence = 1,
  double titleConfidence = .97,
  bool body = true,
  String firstRule = 'Choose up to one target artifact or',
  List<ScanTextLine> extra = const <ScanTextLine>[],
}) {
  final ScanCrop base = _numericReviewCrop(
    title: 'Fixture Spell',
    titleConfidence: titleConfidence,
    body: body,
    firstRule: firstRule,
    footer: <ScanTextLine>[
      ScanTextLine(
        text: token,
        confidence: confidence,
        bounds: const ScanBounds(.03, .91, .18, .02),
        sceneFooterGuide: guide,
      ),
      ...extra,
    ],
  );
  return ScanCrop(
    imagePath: base.imagePath,
    width: base.width,
    height: base.height,
    rectified: base.rectified,
    sourceCorners: base.sourceCorners,
    lines: base.lines,
    warnings: const <String>['border_recovered'],
  );
}

_Card _sceneCollectorCard(
  String id,
  String number, {
  String set = 'tst',
  String? illustration = 'shared-art',
  String name = 'Fixture Spell',
  Rarity rarity = Rarity.common,
}) => _Card(
  id,
  name,
  set: set,
  collectorNumber: number,
  typeLine: 'Sorcery',
  oracleText: _numericReviewOracle,
  illustrationId: illustration,
  rarity: rarity,
);

ScanCrop _mistakenBoltFooter({
  String set = '2X2',
  double footerConfidence = .3000000119,
}) => _crop(<ScanTextLine>[
  const ScanTextLine(
    text: 'Lightning Bolt',
    confidence: 1,
    bounds: ScanBounds(.1, .05, .7, .025),
  ),
  _line('Instant', .49),
  _line('Lightning Bolt deals 3 damage to any target.', .61),
  ScanTextLine(
    text: '177/331',
    confidence: footerConfidence,
    bounds: const ScanBounds(.1, .88, .3, .025),
  ),
  ScanTextLine(
    text: '$set EN',
    confidence: footerConfidence,
    bounds: const ScanBounds(.1, .93, .3, .025),
  ),
]);

ScanCrop _partial(List<ScanTextLine> lines) => ScanCrop(
  imagePath: '',
  width: 993,
  height: 1865,
  rectified: false,
  sourceCorners: const <ScanPoint>[
    ScanPoint(0, 0),
    ScanPoint(1, 0),
    ScanPoint(1, 1),
    ScanPoint(0, 1),
  ],
  warnings: const <String>[
    'partial_card',
    'incomplete_card',
    'no_card_rectangle',
  ],
  lines: lines,
);

ScanCrop _basicLandRecoveryCrop({
  List<String> warnings = const <String>['partial_card', 'basic_land_outline'],
  String number = '2527254',
  List<ScanTextLine> extraLines = const <ScanTextLine>[],
}) => ScanCrop(
  imagePath: '/local/basic-land.jpg',
  width: 1440,
  height: 2000,
  rectified: true,
  sourceCorners: const <ScanPoint>[
    ScanPoint(.12, .32),
    ScanPoint(.32, .33),
    ScanPoint(.30, .82),
    ScanPoint(.10, .81),
  ],
  warnings: warnings,
  lines: <ScanTextLine>[
    const ScanTextLine(
      text: 'Snow-Covered Swamp',
      confidence: 1,
      bounds: ScanBounds(.07, .04, .72, .03),
    ),
    const ScanTextLine(
      text: 'Basic Snow Land',
      confidence: 1,
      bounds: ScanBounds(.06, .839, .35, .031),
    ),
    ScanTextLine(
      text: number,
      confidence: 1,
      bounds: const ScanBounds(.06, .92, .24, .02),
    ),
    const ScanTextLine(
      text: 'MHI • EN Mike Linn',
      confidence: 1,
      bounds: ScanBounds(.06, .945, .46, .02),
    ),
    ...extraLines,
  ],
);

ScanCrop _historicalBodyCrop({List<ScanTextLine>? footer}) => ScanCrop(
  imagePath: '/local/observed-card.jpg',
  width: 1913,
  height: 2671,
  rectified: true,
  sourceCorners: const <ScanPoint>[
    ScanPoint(.528, .437),
    ScanPoint(.743, .434),
    ScanPoint(.829, .561),
    ScanPoint(.540, .565),
  ],
  warnings: const <String>[
    'incomplete_card',
    'orientation_ensemble',
    'geometry_adjusted',
  ],
  lines: <ScanTextLine>[
    _line('Enchantment', .545),
    _line('1: Prevent all damage against you', .646),
    _line('from one blue source. If a source', .681),
    _line('deals damage to you more than', .716),
    _line('once in a turn, you may pay 1', .756),
    _line('each time to prevent the damage.', .784),
    ...(footer ??
        <ScanTextLine>[
          _line('Illus. Pete Venters', .919),
          _line('© 1995 Wizards of the Coast, Inc. All rights reserved.', .950),
        ]),
  ],
);

_Card _bodyPrinting(
  String id, {
  String name = 'Circle of Protection: Blue',
  String set = '8ed',
  String artist = 'Greg Hildebrandt & Tim Hildebrandt',
  int year = 2003,
  String? illustration,
}) => _Card(
  id,
  name,
  set: set,
  typeLine: 'Enchantment',
  artist: artist,
  releasedAt: DateTime(year),
  illustrationId: illustration ?? id,
  oracleText: '{1}: The next time a blue source of your choice would deal damage to you this turn, prevent that damage.',
);

ScanCrop _final4Circle() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"/local/observed-card.jpg","width":1899,"height":2652,"rectified":true,"warnings":["incomplete_card","orientation_ensemble","geometry_adjusted"],"sharpness":0.8813630127710205,"sourceCorners":[{"x":0.575305163860321,"y":0.4507896304130554},{"x":0.7966911196708679,"y":0.45515769720077515},{"x":0.854987382888794,"y":0.5929323136806488},{"x":0.5576722025871277,"y":0.5870903730392456}],"lines":[{"text":"Enchanement","confidence":1.0,"alternatives":["Enchanment","Enchaement"],"glyphHeight":0.02976598512748072,"bounds":{"x":0.029654180368134164,"y":0.5401152179616883,"width":0.309871826171875,"height":0.035734593778354196}},{"text":"1; Prevent all damage against you","confidence":1.0,"alternatives":["1: Prevent all damage against you","1 ; Prevent all damage against you"],"glyphHeight":0.03758212886719201,"bounds":{"x":0.09894691874842053,"y":0.6452701129368913,"width":0.787919343647204,"height":0.044522494032731785}},{"text":"from one blue source. If a source","confidence":1.0,"alternatives":["from on blue source. If a source","from one lue source. If a source"],"glyphHeight":0.03772201144557814,"bounds":{"x":0.09317904978734125,"y":0.685357050434796,"width":0.7690130293996711,"height":0.0398821248188278}},{"text":"deals damage to you more than","confidence":1.0,"alternatives":["deal damage to you more than","deals damage to you more han"],"glyphHeight":0.04166666666666663,"bounds":{"x":0.08720929901807573,"y":0.7249999999813989,"width":0.7267441920230264,"height":0.04166666666666663}},{"text":"once in a turn, you may pay.-","confidence":1.0,"alternatives":["once in a turn, you may pay.","once in a turn, you may pay. -"],"glyphHeight":0.03730775284824129,"bounds":{"x":0.09315166189956352,"y":0.7641716178526136,"width":0.6858665707236843,"height":0.03914081924461488}},{"text":"each time to prevent the damage.","confidence":1.0,"alternatives":["each time to prevent the damage","ach time to prevent the damage."],"glyphHeight":0.036610008421413105,"bounds":{"x":0.09304354166347306,"y":0.798847657758235,"width":0.7734193821957237,"height":0.04114900419255363}},{"text":"Ilfus. Pete Venters","confidence":1.0,"alternatives":[],"glyphHeight":0.030271146764707324,"bounds":{"x":0.03197673988054431,"y":0.9374371852729009,"width":0.34302326403166117,"height":0.030271148202407314}},{"text":"© 1995 Wizards of the Coast, Inc. All rights reserved.","confidence":1.0,"alternatives":[],"glyphHeight":0.020686617596259036,"bounds":{"x":0.03286405204387836,"y":0.9660467576181648,"width":0.5883283434416119,"height":0.027908542767241994}},{"text":"once in a turn, you may","confidence":1.0,"alternatives":[],"glyphHeight":0.03557841719538907,"bounds":{"x":0.09304719233465826,"y":0.7645476471635354,"width":0.5479260540317178,"height":0.04165781146680301}},{"text":"each time to prévent the","confidence":1.0,"alternatives":[],"glyphHeight":0.0403055418086919,"bounds":{"x":0.0922530007857686,"y":0.7970930091640951,"width":0.5570136406660852,"height":0.04326090845568428}},{"text":"Illus. Pete","confidence":1.0,"alternatives":[],"glyphHeight":0.032742257096857186,"bounds":{"x":0.029192454837837625,"y":0.9363266915250494,"width":0.19500074787818883,"height":0.033156629221566425}},{"text":"Venters","confidence":1.0,"alternatives":[],"glyphHeight":0.02719335484514196,"bounds":{"x":0.22019140227253947,"y":0.9409434015311389,"width":0.1559005206456848,"height":0.027520815092941815}},{"text":"Enchantment","confidence":1.0,"alternatives":["Enchantment"],"glyphHeight":null,"bounds":{"x":0.029654581051127626,"y":0.5401152035780122,"width":0.30981626172806326,"height":0.03573356196284294}}]}''',
  ) as Map<Object?, Object?>,
);

ScanCrop _final4Nevermore() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"/local/observed-card.jpg","width":2515,"height":3513,"rectified":true,"warnings":["geometry_adjusted"],"sharpness":0.8323807485700743,"sourceCorners":[{"x":0.2409072369337082,"y":0.49379491806030273},{"x":0.5038254261016846,"y":0.5013433694839478},{"x":0.5296821594238281,"y":0.7067863941192627},{"x":0.1301061362028122,"y":0.69146928191185}],"lines":[{"text":"Never","confidence":1.0,"alternatives":["Neve","Nevr"],"glyphHeight":0.027269382679448492,"bounds":{"x":0.08055488741880881,"y":0.06542526381511837,"width":0.1551847594341527,"height":0.03733622464661435}},{"text":"Enchantment","confidence":1.0,"alternatives":["Enchantmen","Enchantent"],"glyphHeight":0.02478847907501361,"bounds":{"x":0.08378792551509248,"y":0.5849494853146537,"width":0.2948642360766097,"height":0.03552611931251004}},{"text":"As Nevermore enters the battlefield,","confidence":1.0,"alternatives":["As Nevermore enter the battlefield,","As Nevermore enters the battlefield"],"glyphHeight":0.03778636116255561,"bounds":{"x":0.0845527155249008,"y":0.6523097034140004,"width":0.8572954381023946,"height":0.04708108049804127}},{"text":"name a nonland card.","confidence":1.0,"alternatives":["name a noland card.","name a nonland card"],"glyphHeight":0.03461082572565965,"bounds":{"x":0.08215964826888363,"y":0.6852398548282744,"width":0.531860545632949,"height":0.04776619100814927}},{"text":"The named card can't be cast.","confidence":1.0,"alternatives":["The named card can't be cast","The named card can't becast."],"glyphHeight":0.03611636830934725,"bounds":{"x":0.08266481446152438,"y":0.7351937655545986,"width":0.7252145351779858,"height":0.04260371582170208}},{"text":"«By the law of Avacyn, the following","confidence":1.0,"alternatives":["«By the law of Avacy, the following","«By the law of Avacyn the following"],"glyphHeight":0.04510558847039604,"bounds":{"x":0.08187148335444808,"y":0.7843651100354064,"width":0.7913002293136427,"height":0.05968288189318616}},{"text":"thoughts, words, and deeds are","confidence":1.0,"alternatives":["thoughts, words and deeds are","thoughts, words, and deed are"],"glyphHeight":0.04237929188530962,"bounds":{"x":0.0822875623174856,"y":0.8278869922797605,"width":0.6525996804047844,"height":0.051632672192091}},{"text":"henceforth disallowed.\"","confidence":1.0,"alternatives":[],"glyphHeight":0.0419507304394075,"bounds":{"x":0.0809546646420745,"y":0.8602267424519187,"width":0.5137747808556489,"height":0.045313192002008715}},{"text":"-Jason A. Engle","confidence":1.0,"alternatives":[],"glyphHeight":0.023450514125643005,"bounds":{"x":0.12904034047720161,"y":0.935216856239503,"width":0.23891088731338186,"height":0.023450514125643005}},{"text":"IM & © 1993-2011 Wizards of the Coast LLC 25/264","confidence":1.0,"alternatives":[],"glyphHeight":0.019624453668727677,"bounds":{"x":0.06179488767612807,"y":0.9547452479891054,"width":0.5767089649679551,"height":0.03111435312926206}},{"text":"a cala call","confidence":1.0,"alternatives":[],"glyphHeight":0.013649289099526073,"bounds":{"x":0.33312500309790455,"y":0.7600000000810889,"width":0.2870833268666909,"height":0.013649289099526073}},{"text":"«By the law of Avacyn, th","confidence":1.0,"alternatives":[],"glyphHeight":0.04469904087324186,"bounds":{"x":0.08102563726679633,"y":0.7814373147076149,"width":0.5689743627332037,"height":0.06186498343662063}},{"text":"thoughts, words, and deeds","confidence":1.0,"alternatives":[],"glyphHeight":0.03729665280520691,"bounds":{"x":0.08422841668248343,"y":0.8297561637344076,"width":0.5654387233892688,"height":0.044840025698404166}},{"text":"henceforth disallowedạẠạ","confidence":1.0,"alternatives":[],"glyphHeight":0.03611648927789618,"bounds":{"x":0.08647793581723949,"y":0.8639661157733146,"width":0.5023453094557037,"height":0.03966325226553243}},{"text":"~Jason A. Engle","confidence":1.0,"alternatives":[],"glyphHeight":0.021743954561996598,"bounds":{"x":0.10419057330634532,"y":0.9314470996920013,"width":0.2620810399137091,"height":0.027633764257928222}}]}''',
  ) as Map<Object?, Object?>,
);

_Card _nevermorePrinting({String type = 'Enchantment', String? rules}) => _Card(
  'nevermore',
  'Nevermore',
  typeLine: type,
  artist: 'Jason A. Engle',
  releasedAt: DateTime(2011, 9, 30),
  oracleText: rules ?? "As this enchantment enters, choose a nonland card name.\nSpells with the chosen name can't be cast.",
  flavorText: '"By the law of Avacyn, the following thoughts, words, and deeds are henceforth disallowed."',
);

ScanCrop _changedCrop(
  ScanCrop original,
  List<ScanTextLine> lines, {
  bool? rectified,
}) => ScanCrop(
  imagePath: original.imagePath,
  width: original.width,
  height: original.height,
  rectified: rectified ?? original.rectified,
  sourceCorners: original.sourceCorners,
  warnings: original.warnings,
  lines: lines,
);

ScanTextLine _changedLine(
  ScanTextLine line,
  String text, {
  double? confidence,
  ScanBounds? bounds,
}) => ScanTextLine(
  text: text,
  confidence: confidence ?? line.confidence,
  glyphHeight: line.textHeight,
  bounds: bounds ?? line.bounds,
);

ScanCrop _final5TitlelessNevermore() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"/local/observed-titleless-card.jpg","width":2363,"height":3301,"rectified":true,"warnings":["incomplete_card","orientation_ensemble","geometry_adjusted"],"sharpness":0.8414651279251035,"sourceCorners":[{"x":0.24087904393672943,"y":0.4990139603614807},{"x":0.5001259446144104,"y":0.4988778233528137},{"x":0.5243744850158691,"y":0.7044861316680908},{"x":0.13639390468597412,"y":0.6887986958026886}],"lines":[{"text":"Enchantment","confidence":1.0,"alternatives":["Enchantmen","Enchantmet"],"glyphHeight":0.029513527597153085,"bounds":{"x":0.07683706572839069,"y":0.5761347502869965,"width":0.31488571554271094,"height":0.045404915951151814}},{"text":"As Nevermore enters the battlefield,","confidence":1.0,"alternatives":["As Nevermore enters the battlefield","As Nevermore enter the battlefield,"],"glyphHeight":0.04209943977516781,"bounds":{"x":0.0750548037608145,"y":0.6397778914449976,"width":0.8847952647459286,"height":0.07335087980089006}},{"text":"name a nonland card.","confidence":1.0,"alternatives":["name a noland card.","name anonland card."],"glyphHeight":0.033167310674982055,"bounds":{"x":0.07577555027900904,"y":0.6844183232741038,"width":0.5551180508737837,"height":0.05315260075569728}},{"text":"The named card can't be cast.","confidence":1.0,"alternatives":["The named card can't be cast","The named card can't becast."],"glyphHeight":0.035834384609631516,"bounds":{"x":0.07794736542436699,"y":0.7347289211882027,"width":0.7469119928815038,"height":0.0509591752438745}},{"text":"«By the law of Avacyn, the following","confidence":1.0,"alternatives":["«By the law of Avacy, the following","«By the law of Avacyn the following"],"glyphHeight":0.04438869076027807,"bounds":{"x":0.07704834413613947,"y":0.7855536927723922,"width":0.8128146253866593,"height":0.06700081366037036}},{"text":"thoughts, words, and deeds are","confidence":1.0,"alternatives":["thoughts, words, and deed are","thoughts, words and deeds are"],"glyphHeight":0.042706415363904925,"bounds":{"x":0.07571097232857438,"y":0.8289138589292119,"width":0.6758644375099143,"height":0.05920445045364908}},{"text":"henceforth disallowediạ","confidence":1.0,"alternatives":[],"glyphHeight":0.037117216380665605,"bounds":{"x":0.07798773453675846,"y":0.8658188770232601,"width":0.5309702297152601,"height":0.0465454355362923}},{"text":"Jason A. Engle","confidence":1.0,"alternatives":[],"glyphHeight":0.02727797732613459,"bounds":{"x":0.05353829579550126,"y":0.9385260061361498,"width":0.32639187523959656,"height":0.03266701236847908}},{"text":"VM & © 1993-2011 Wizards of the Coast LLC 25/264","confidence":1.0,"alternatives":[],"glyphHeight":0.021070656078148314,"bounds":{"x":0.051667610377995686,"y":0.9621571298410255,"width":0.6043320605799227,"height":0.032004790536818935}},{"text":"cara can","confidence":1.0,"alternatives":[],"glyphHeight":0.018202247139188454,"bounds":{"x":0.3977470937257824,"y":0.7600000000217932,"width":0.21351744035879774,"height":0.018202247139188454}},{"text":"T","confidence":1.0,"alternatives":[],"glyphHeight":0.01617977514606741,"bounds":{"x":0.6131540699642244,"y":0.7600000002759103,"width":0.02267441811660928,"height":0.0161797745942469}},{"text":"«By the law of Avacyn, t","confidence":1.0,"alternatives":[],"glyphHeight":0.04549414163564089,"bounds":{"x":0.07652615466939199,"y":0.7820461971993571,"width":0.5734738453306081,"height":0.07550017311230715}},{"text":"thoughts, words, and deed","confidence":1.0,"alternatives":[],"glyphHeight":0.04623331632433574,"bounds":{"x":0.07492346631990048,"y":0.827657193064991,"width":0.5750765336800996,"height":0.060400424448008506}},{"text":"henceforth disallowed.\"","confidence":1.0,"alternatives":[],"glyphHeight":0.04489191042167122,"bounds":{"x":0.07680548197166824,"y":0.8642550792436894,"width":0.5338879466056823,"height":0.0499212707980754}}]}''',
  ) as Map<Object?, Object?>,
);

ScanCrop _phone6LiveNevermore() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":1000,"height":1400,"rectified":true,"warnings":["incomplete_card"],"sourceCorners":[{"x":0.23873642107741908,"y":0.49952327206395575},{"x":0.500964072304219,"y":0.503880227704905},{"x":0.5271768798377365,"y":0.7048556884648278},{"x":0.13133378828749992,"y":0.6901251864457503}],"lines":[{"text":"Enchantment","confidence":1.0,"alternatives":["Enchantmen","Enchantmet"],"glyphHeight":0.03256056384742699,"bounds":{"x":0.08445665335919185,"y":0.5829406663325497,"width":0.30898478924203987,"height":0.04892221984372647}},{"text":"As Nevermore enters the battlefield,","confidence":1.0,"alternatives":["As Nevermore enter the battlefield,","As Nevermore enters the battlefield"],"glyphHeight":0.04012408055922302,"bounds":{"x":0.08500260383624837,"y":0.6519063948382368,"width":0.857539016356583,"height":0.06083534461508988}},{"text":"henceforth disallowedại","confidence":1.0,"alternatives":["henceforth disallowediại","henceforth disallowedẠại"],"glyphHeight":0.042336153529912525,"bounds":{"x":0.08532998740472085,"y":0.8646826237093795,"width":0.5163322003027008,"height":0.049080759766017446}},{"text":"I & © 1993-2011 Wizards of the Coast LLC 25/264","confidence":1.0,"alternatives":["# & © 1993-2011 Wizards of the Coast LLC 25/264","I & © 1993-2011 Wizards of the Coast LLC 25/264"],"glyphHeight":0.022483642571217263,"bounds":{"x":0.0648507758549594,"y":0.9574669889017674,"width":0.5883298788693353,"height":0.032923920744868385}},{"text":"name a nonland card.","confidence":1.0,"alternatives":[],"glyphHeight":0.03799094074103547,"bounds":{"x":0.08495720808510702,"y":0.7,"width":0.5420409527021586,"height":0.045355731293765376}},{"text":"The named card can't be cast.","confidence":1.0,"alternatives":[],"glyphHeight":0.03837895473954879,"bounds":{"x":0.09097010732128111,"y":0.7367289668727508,"width":0.7264347666317655,"height":0.05150511518437812}},{"text":"\"By the law of Avacyn, the following","confidence":1.0,"alternatives":[],"glyphHeight":0.045777615230651936,"bounds":{"x":0.09183497469775005,"y":0.7919306991196314,"width":0.7884750628389444,"height":0.0600396440384236}},{"text":"thoughts, words, and deeds are","confidence":1.0,"alternatives":[],"glyphHeight":0.04323877805770701,"bounds":{"x":0.08526171485311172,"y":0.8301615390570807,"width":0.6609018332360127,"height":0.05345058035343252}},{"text":"henceforth disallowediạẠại","confidence":1.0,"alternatives":[],"glyphHeight":0.042069608151481454,"bounds":{"x":0.08532654900756494,"y":0.8655985468284634,"width":0.5163383877154478,"height":0.04881105118609492}},{"text":"~Jason A. Engle","confidence":1.0,"alternatives":[],"glyphHeight":0.023093860331659156,"bounds":{"x":0.10948473961446353,"y":0.9350328494901222,"width":0.26897189215696143,"height":0.0290217602506597}},{"text":"M & © 1993-2011 Wizards of the Coast 1LC 25/264","confidence":1.0,"alternatives":[],"glyphHeight":0.021538640147465204,"bounds":{"x":0.07173428361720384,"y":0.9577744130848711,"width":0.5780805869610449,"height":0.03185118411449678}}]}''',
  ) as Map<Object?, Object?>,
);

void main() {
  test('physical scanner excludes digital-only exact and ordinary candidates from injected catalogs', () async {
    final _Card digital = _Card(
      'digital',
      'Lightning Bolt',
      games: const <Game>[Game.arena],
    );
    final _Catalog catalog = _Catalog()
      ..exact = digital
      ..cards = <MtgCard>[digital];
    final ScanResolver resolver = ScanResolver(catalog: catalog);
    final ScanCrop crop = _crop(<ScanTextLine>[
      _line('Lightning Bolt', .05),
      _line('123', .93),
      _line('MOM EN', .96),
    ]);
    final ScanResolution exact = await resolver.resolve(crop);
    expect(exact.status, ScanResolutionStatus.noMatch);
    expect(exact.candidates, isEmpty);
    expect(hasExactPrintingEvidence(crop, exact), isFalse);
    catalog.exact = null;
    final ScanResolution ordinary = await resolver.resolve(
      _crop(<ScanTextLine>[_line('Lightning Bolt', .05)]),
    );
    expect(ordinary.candidates, isEmpty);
  });

  test('conflicting raw and enhanced title reads keep a plausible printing for manual review without exact proof', () async {
    final _Card card = _Card(
      'bolt',
      'Lightning Bolt',
      oracleText: 'Lightning Bolt deals 3 damage to any target.',
    );
    final _Catalog catalog = _Catalog()..exact = card;
    final ScanCrop clean = _crop(<ScanTextLine>[
      _line('Lightning Bolt', .04),
      _line('Instant', .50),
      _line('Lightning Bolt deals 3 damage to any target.', .63),
      _line('123', .85),
      _line('MOM EN', .92),
    ]);
    final ScanResolver resolver = ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
      symbols: _Symbol(),
    );
    final ScanResolution positive = await resolver.resolve(clean);
    expect(hasExactPrintingEvidence(clean, positive), isTrue);
    final ScanCrop conflict = ScanCrop(
      imagePath: clean.imagePath,
      width: clean.width,
      height: clean.height,
      rectified: clean.rectified,
      sourceCorners: clean.sourceCorners,
      warnings: const <String>['lighting_title_conflict'],
      lines: <ScanTextLine>[
        clean.lines.first,
        const ScanTextLine(
          text: 'Lava Spike',
          confidence: .99,
          glyphHeight: .025,
          bounds: ScanBounds(.1, .04, .7, .025),
        ),
        ...clean.lines.skip(1),
      ],
    );
    final ScanResolution result = await resolver.resolve(conflict);
    expect(result.candidates.single.card.id, 'bolt');
    expect(
      result.hints.names,
      containsAll(<String>['Lightning Bolt', 'Lava Spike']),
    );
    expect(
      conflict.lines.take(2).map((ScanTextLine line) => line.text),
      <String>['Lightning Bolt', 'Lava Spike'],
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(result.historicalBodyIdentityProof, isNull);
    expect(hasExactPrintingEvidence(conflict, result), isFalse);
    expect(ScanHints.observedBodySelfReference(conflict), isNull);
    expect(
      hasExactPrintingEvidence(clean, await resolver.resolve(clean)),
      isTrue,
    );
  });

  test('lighting title ambiguity blocks preserved saved self-reference and historical identity proofs', () async {
    ScanCrop conflict(ScanCrop crop) => ScanCrop(
      imagePath: crop.imagePath,
      width: crop.width,
      height: crop.height,
      rectified: crop.rectified,
      sourceCorners: crop.sourceCorners,
      lines: crop.lines,
      warnings: <String>[...crop.warnings, 'lighting_title_conflict'],
    );
    final ScanCrop self = _final5TitlelessNevermore();
    final _Catalog selfCatalog = _Catalog()
      ..namedCards['Nevermore'] = <MtgCard>[_nevermorePrinting()];
    final ScanResolution selfResolution = await ScanResolver(
      catalog: selfCatalog,
      artwork: _Artwork(),
    ).resolve(self);
    expect(
      verifiedSavedSelfReferenceIdentity(self, selfResolution),
      'Nevermore',
    );
    expect(ScanHints.observedSavedBodySelfReference(conflict(self)), isNull);
    expect(
      verifiedSavedSelfReferenceIdentity(conflict(self), selfResolution),
      isNull,
    );
    expect(selfResolution.candidates, isNotEmpty);
    expect(
      verifiedSavedSelfReferenceIdentity(self, selfResolution),
      'Nevermore',
    );

    final ScanCrop historical = _final4Circle();
    final _Card modern = _bodyPrinting('modern');
    final _Card ice = _bodyPrinting(
      'ice',
      set: 'ice',
      artist: 'Pete Venters',
      year: 1995,
    );
    final _Catalog historicalCatalog = _Catalog()
      ..keywordCards = <MtgCard>[modern]
      ..namedCards[modern.name] = <MtgCard>[modern, ice];
    final ScanResolution historicalResolution = await ScanResolver(
      catalog: historicalCatalog,
      artwork: _Artwork(),
    ).resolve(historical);
    expect(
      verifiedHistoricalBodyIdentity(historical, historicalResolution),
      modern.name,
    );
    expect(
      verifiedHistoricalBodyIdentity(
        conflict(historical),
        historicalResolution,
      ),
      isNull,
    );
    expect(historicalResolution.candidates, isNotEmpty);
    expect(
      verifiedHistoricalBodyIdentity(historical, historicalResolution),
      modern.name,
    );
  });
  test('eligible conflicting set or language pairs cannot grant exact footer authority', () async {
    ScanTextLine footer(String text, double y, {double confidence = .8}) =>
        ScanTextLine(
          text: text,
          confidence: confidence,
          bounds: ScanBounds(.1, y, .35, .025),
        );
    final _Card card = _Card(
      'bolt',
      'Lightning Bolt',
      set: 'mh3',
      collectorNumber: '123',
    );
    ScanResolution exact(ScanCrop crop) => ScanResolution(
      status: ScanResolutionStatus.exactPrinting,
      hints: ScanHints.fromCrop(crop),
      candidates: <ScanCandidate>[
        ScanCandidate(card, const <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.footerMatch,
          ScanEvidence.collectorNumberMatch,
          ScanEvidence.languageMatch,
        }),
      ],
    );
    for (final List<ScanTextLine> codes in <List<ScanTextLine>>[
      <ScanTextLine>[footer('MH3 EN', .92), footer('MH1 EN', .94)],
      <ScanTextLine>[footer('MH3 EN', .92), footer('MH3 FR', .94)],
      <ScanTextLine>[footer('MH3 EN MH1 EN', .92)],
      <ScanTextLine>[
        footer('MH3 EN', .90),
        footer('MH1', .925),
        footer('EN', .95),
      ],
    ]) {
      final ScanCrop crop = _crop(<ScanTextLine>[
        _line('Lightning Bolt', .04),
        _line('Instant', .49),
        footer('0123 R', .87),
        ...codes,
      ]);
      final ScanHints hints = ScanHints.fromCrop(crop);
      expect(hints.setCode, isNull);
      expect(hints.language, isNull);
      expect(hints.collectorNumber, '0123');
      expect(hasExactPrintingEvidence(crop, exact(crop)), isFalse);
      final _Catalog catalog = _Catalog()..cards = <MtgCard>[card];
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(crop);
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(catalog.calls.single, 'printings:Lightning Bolt/null/null/1');
      expect(
        crop.lines.map((ScanTextLine line) => line.text),
        containsAll(codes.map((ScanTextLine line) => line.text)),
      );
    }
    for (final List<ScanTextLine> codes in <List<ScanTextLine>>[
      <ScanTextLine>[footer('MH3 EN', .92), footer('mh3 • en', .94)],
      <ScanTextLine>[
        footer('MH3 EN', .92),
        footer('MH1 FR', .94, confidence: .3),
      ],
      <ScanTextLine>[
        footer('MH3 EN', .90),
        footer('MH3', .925),
        footer('EN', .95),
      ],
    ]) {
      final ScanCrop crop = _crop(<ScanTextLine>[
        _line('Lightning Bolt', .04),
        footer('0123 R', .87),
        ...codes,
      ]);
      expect(ScanHints.fromCrop(crop).setCode, 'mh3');
      expect(ScanHints.fromCrop(crop).language, 'en');
      expect(hasExactPrintingEvidence(crop, exact(crop)), isTrue);
    }
    final ScanHints partial = ScanHints.fromCrop(
      _partial(<ScanTextLine>[
        footer('0123 R', .87, confidence: .9),
        footer('MH3', .90, confidence: .9),
        footer('EN', .925, confidence: .9),
      ]),
    );
    expect(partial.setCode, 'mh3');
    expect(partial.language, 'en');
    final ScanHints partialConflict = ScanHints.fromCrop(
      _partial(<ScanTextLine>[
        footer('0123 R', .86, confidence: .9),
        footer('MH3', .89, confidence: .9),
        footer('EN', .912, confidence: .9),
        footer('MH1', .94, confidence: .9),
        footer('EN', .962, confidence: .9),
      ]),
    );
    expect(partialConflict.setCode, isNull);
    expect(partialConflict.language, isNull);
  });

  test('numeric ambiguity uses the authoritative footer floor even without a readable set', () {
    ScanTextLine number(String text) => ScanTextLine(
      text: text,
      confidence: .8,
      bounds: const ScanBounds(.1, .90, .2, .025),
    );
    for (final bool code in <bool>[true, false]) {
      final ScanHints conflict = ScanHints.fromCrop(
        _crop(<ScanTextLine>[
          number('0123 C'),
          number('0128 C'),
          if (code) _line('MH3 EN', .94),
        ]),
      );
      expect(conflict.collectorNumber, isNull);
      final ScanHints duplicate = ScanHints.fromCrop(
        _crop(<ScanTextLine>[
          number('0123 C'),
          number('123 C'),
          if (code) _line('MH3 EN', .94),
        ]),
      );
      expect(duplicate.collectorNumber, anyOf('0123', '123'));
    }
  });

  test('weak modern footer remains raw text and cannot constrain authoritative hints or join a strong companion', () {
    final ScanCrop swamp = _crop(<ScanTextLine>[
      _line('Snow-Covered Swamp', .04),
      _line('Basic Snow Land', .839),
      _line('252/254', .944),
      const ScanTextLine(
        text: 'MHT • EN TITUS LUNTER',
        confidence: .3,
        bounds: ScanBounds(.034, .949, .326, .025),
      ),
    ]);
    final ScanHints swampHints = ScanHints.fromCrop(swamp);
    expect(swampHints.collectorNumber, '252');
    expect(swampHints.setCode, isNull);
    expect(swampHints.language, isNull);
    expect(swamp.lines.last.text, 'MHT • EN TITUS LUNTER');
    final ScanHints jolted = ScanHints.fromCrop(
      _crop(<ScanTextLine>[
        _line('Jolted Awake', .04),
        _line('Sorcery', .58),
        const ScanTextLine(
          text: 'C 0500',
          confidence: .3,
          bounds: ScanBounds(.03, .978, .111, .02),
        ),
      ]),
    );
    expect(jolted.collectorNumber, isNull);
    for (final bool weakSet in <bool>[true, false]) {
      final ScanHints joined = ScanHints.fromCrop(
        _crop(<ScanTextLine>[
          ScanTextLine(
            text: 'MH3',
            confidence: weakSet ? .3 : 1,
            bounds: const ScanBounds(.1, .92, .15, .02),
          ),
          ScanTextLine(
            text: 'EN',
            confidence: weakSet ? 1 : .3,
            bounds: const ScanBounds(.1, .94, .1, .02),
          ),
        ]),
      );
      expect(joined.setCode, isNull);
      expect(joined.language, isNull);
    }
    for (final double confidence in <double>[.749, .75]) {
      final ScanHints hints = ScanHints.fromCrop(
        _crop(<ScanTextLine>[
          ScanTextLine(
            text: 'C 0509',
            confidence: confidence,
            bounds: const ScanBounds(.03, .92, .15, .02),
          ),
          ScanTextLine(
            text: 'MH3 EN',
            confidence: confidence,
            bounds: const ScanBounds(.03, .95, .18, .02),
          ),
        ]),
      );
      expect(hints.collectorNumber, confidence >= .75 ? '0509' : null);
      expect(hints.setCode, confidence >= .75 ? 'mh3' : null);
    }
  });

  test('complete weak rarity footer orders review prints but clipped conflicting or unsupported glyphs cannot', () async {
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _Card(
          'normal',
          'Jolted Awake',
          set: 'mh3',
          collectorNumber: '33',
          typeLine: 'Sorcery',
        ),
        _Card(
          'foil',
          'Jolted Awake',
          set: 'mh3',
          collectorNumber: '509',
          typeLine: 'Sorcery',
        ),
      ];
    ScanTextLine number(String value, {double y = .93}) => ScanTextLine(
      text: value,
      confidence: .3,
      bounds: ScanBounds(.03, y, .15, .02),
    );
    final ScanTextLine set = number('MH3 EN', y: .96);
    for (final double y in <double>[.873, .93]) {
      final ScanCrop crop = _crop(<ScanTextLine>[
        _line('Jolted Awake', .04),
        _line('Sorcery', .58),
        number('C 0509', y: y),
        set,
      ]);
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(crop);
      expect(result.candidates.first.card.id, 'foil');
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(result.hints.setCode, isNull);
      expect(result.hints.collectorNumber, isNull);
      expect(result.candidates.first.score, result.candidates.last.score);
      expect(
        result.candidates.first.evidence,
        isNot(contains(ScanEvidence.collectorNumberMatch)),
      );
      expect(
        result.candidates.first.evidence,
        isNot(contains(ScanEvidence.footerMatch)),
      );
      expect(hasExactPrintingEvidence(crop, result), isFalse);
    }
    for (final List<ScanTextLine> footer in <List<ScanTextLine>>[
      <ScanTextLine>[number('C 0509', y: .978), set],
      <ScanTextLine>[number('0509')],
      <ScanTextLine>[number('C 0500'), set],
      <ScanTextLine>[
        const ScanTextLine(
          text: '4',
          confidence: 1,
          bounds: ScanBounds(.577, .763, .044, .033),
        ),
        set,
      ],
    ]) {
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(
            _crop(<ScanTextLine>[
              _line('Jolted Awake', .04),
              _line('Sorcery', .58),
              ...footer,
            ]),
          );
      expect(result.candidates.first.card.id, 'normal');
      expect(result.candidates.first.hasContradiction, isFalse);
      expect(result.hints.collectorNumber, isNull);
    }
  });

  test('weak numeric alternatives may rank only a sole observed valid printing on a complete exact-name page', () async {
    final _Card normal = _Card(
      'normal',
      'Jolted Awake',
      set: 'mh3',
      collectorNumber: '33',
      typeLine: 'Sorcery',
    );
    final _Card foil = _Card(
      'foil',
      'Jolted Awake',
      set: 'mh3',
      collectorNumber: '509',
      typeLine: 'Sorcery',
    );
    final _Catalog catalog = _Catalog()..cards = <MtgCard>[normal, foil];
    ScanCrop readings(
      List<String> numbers, {
      String title = 'Jolted Awake',
      bool strongWrong = false,
    }) => _crop(<ScanTextLine>[
      _line(title, .04),
      _line('Sorcery', .58),
      for (int index = 0; index < numbers.length; index++)
        ScanTextLine(
          text: 'C ${numbers[index]}',
          confidence: strongWrong && index == 0 ? 1 : .3,
          bounds: ScanBounds(.03, .87 + index * .025, .15, .02),
        ),
      const ScanTextLine(
        text: 'MH3 EN',
        confidence: .3,
        bounds: ScanBounds(.03, .96, .18, .02),
      ),
    ]);
    final ScanResolver resolver = ScanResolver(catalog: catalog);
    final ScanCrop crop = readings(<String>['0500', '0509']);
    final ScanResolution valid = await resolver.resolve(crop);
    expect(valid.candidates.first.card.id, 'foil');
    expect(valid.status, ScanResolutionStatus.needsReview);
    expect(valid.hints.collectorNumber, isNull);
    expect(
      valid.candidates.first.evidence,
      isNot(contains(ScanEvidence.collectorNumberMatch)),
    );
    expect(
      valid.candidates.first.evidence,
      isNot(contains(ScanEvidence.footerMatch)),
    );
    expect(
      crop.lines.map((ScanTextLine line) => line.text),
      containsAll(<String>['C 0500', 'C 0509']),
    );
    expect(hasExactPrintingEvidence(crop, valid), isFalse);
    for (final List<String> numbers in <List<String>>[
      <String>['0033', '0509'],
      <String>['0500', '5050'],
    ]) {
      final ScanResolution ambiguous = await resolver.resolve(
        readings(numbers),
      );
      expect(ambiguous.candidates.first.card.id, 'normal');
      expect(ambiguous.status, ScanResolutionStatus.needsReview);
      expect(ambiguous.candidates, hasLength(2));
    }
    catalog.hasMore = true;
    final ScanResolution incomplete = await resolver.resolve(crop);
    expect(incomplete.candidates.first.card.id, 'normal');
    expect(incomplete.hasMore, isTrue);
    catalog.hasMore = false;
    final ScanResolution laterPage = await resolver.resolve(crop, page: 2);
    expect(laterPage.candidates.first.card.id, 'normal');
    expect(laterPage.page, 2);
    catalog.cards = <MtgCard>[
      normal,
      foil,
      _Card(
        'other',
        'Other Card',
        set: 'mh3',
        collectorNumber: '509',
        typeLine: 'Sorcery',
      ),
    ];
    final ScanResolution mixed = await resolver.resolve(crop);
    expect(mixed.candidates.first.card.id, 'normal');
    catalog.cards = <MtgCard>[normal, foil];
    catalog.scopedCards['Jolt Awake/null'] = <MtgCard>[];
    catalog.fuzzy = normal;
    final ScanResolution fuzzy = await resolver.resolve(
      readings(<String>['0500', '0509'], title: 'Jolt Awake'),
    );
    expect(fuzzy.candidates.first.card.id, 'normal');
    expect(fuzzy.candidates.first.evidence, contains(ScanEvidence.fuzzyName));
    expect(fuzzy.hints.names, <String>['Jolt Awake']);
    final ScanResolution contradicted = await resolver.resolve(
      readings(<String>['0500', '0509'], strongWrong: true),
    );
    expect(contradicted.hints.collectorNumber, '0500');
    expect(
      contradicted.candidates.every(
        (ScanCandidate candidate) => candidate.hasContradiction,
      ),
      isTrue,
    );
    expect(contradicted.status, ScanResolutionStatus.needsReview);
  });

  test(
    'name prewarming leaves custom catalogs and injected indexes untouched',
    () async {
      final _Catalog catalog = _Catalog();
      final _NameIndex index = _NameIndex()
        ..failure = StateError('custom index must not be warmed');
      int callerOwnedWork = 0;
      await ScanResolver(catalog: catalog).warmNames();
      await ScanResolver(catalog: catalog, nameIndex: index).warmNames();
      final ScryfallScanNameIndex injected = ScryfallScanNameIndex(
        loader: () async {
          callerOwnedWork++;
          return <String>['Cooperation'];
        },
        readCache: () async {
          callerOwnedWork++;
          return null;
        },
      );
      try {
        await ScanResolver(catalog: catalog, nameIndex: injected).warmNames();
        expect(catalog.calls, isEmpty);
        expect(index.calls, isEmpty);
        expect(callerOwnedWork, 0);
      } finally {
        injected.close();
      }
    },
  );

  test(
    'cold Scryfall name index does not block literal title printing lookup',
    () async {
      final Completer<List<String>> loaded = Completer<List<String>>();
      int loads = 0;
      final ScryfallScanNameIndex index = ScryfallScanNameIndex(
        loader: () {
          loads++;
          return loaded.future;
        },
        readCache: () async => null,
        writeCache: (String _) async {},
      );
      addTearDown(() async {
        if (!loaded.isCompleted) loaded.complete(<String>['Lightning Bolt']);
        await index.warm();
        index.close();
      });
      final _Catalog catalog = _Catalog()
        ..namedCards['Lightning Bolt'] = <MtgCard>[
          _Card('bolt', 'Lightning Bolt'),
        ];
      final ScanCrop crop = _crop(<ScanTextLine>[_line('Lightning Bolt', .04)]);
      final ScanResolution result = await ScanResolver(
        catalog: catalog,
        nameIndex: index,
      ).resolve(crop).timeout(const Duration(seconds: 2));
      expect(loaded.isCompleted, isFalse);
      expect(loads, 1);
      expect(catalog.calls, <String>['printings:Lightning Bolt/null/null/1']);
      expect(result.candidates.single.card.id, 'bolt');
      expect(result.hints.names, <String>['Lightning Bolt']);
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(hasExactPrintingEvidence(crop, result), isFalse);
    },
  );

  test('already-ready Scryfall index keeps canonical fuzzy ranking and exact-proof restrictions', () async {
    final ScryfallScanNameIndex index = ScryfallScanNameIndex(
      loader: () async => <String>['Cooperation'],
      readCache: () async => null,
      writeCache: (String _) async {},
    );
    addTearDown(index.close);
    await index.warm();
    final _Catalog catalog = _Catalog()
      ..namedCards['Cooperation'] = <MtgCard>[
        _Card(
          'ice',
          'Cooperation',
          set: 'ice',
          collectorNumber: '18',
          typeLine: 'Enchantment — Aura',
          oracleText: 'Target creature gains banding.',
        ),
      ];
    final ScanCrop crop = _crop(<ScanTextLine>[
      _line('Cooperarion', .04),
      _line('Enchant Creature', .55),
      _line('Target creature gains banding.', .67),
    ]);
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      nameIndex: index,
    ).resolve(crop);
    expect(catalog.calls, <String>['printings:Cooperation/null/null/1']);
    expect(result.candidates.single.card.id, 'ice');
    expect(result.hints.names, <String>['Cooperarion']);
    expect(result.candidates.single.evidence, contains(ScanEvidence.fuzzyName));
    expect(
      result.candidates.single.evidence,
      isNot(contains(ScanEvidence.nameMatch)),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(crop.lines.first.text, 'Cooperarion');
  });

  test('expired or failed Scryfall index cannot supply a canonical identity or stall fallback', () async {
    DateTime now = DateTime.utc(2026, 10, 12);
    int loads = 0;
    final Completer<List<String>> refresh = Completer<List<String>>();
    final ScryfallScanNameIndex index = ScryfallScanNameIndex(
      clock: () => now,
      loader: () {
        loads++;
        return loads == 1
            ? Future<List<String>>.value(<String>['Cooperation'])
            : refresh.future;
      },
      readCache: () async => null,
      writeCache: (String _) async {},
    );
    addTearDown(() async {
      if (!refresh.isCompleted) {
        refresh.completeError(StateError('refresh unavailable'));
      }
      await index.warm();
      index.close();
    });
    await index.warm();
    now = now.add(ScryfallScanNameIndex.cacheLifetime);
    final _Catalog catalog = _Catalog()
      ..namedCards['Cooperation'] = <MtgCard>[_Card('ice', 'Cooperation')]
      ..namedCards['Lightning Bolt'] = <MtgCard>[
        _Card('bolt', 'Lightning Bolt'),
      ];
    final ScanResolver resolver = ScanResolver(
      catalog: catalog,
      nameIndex: index,
    );
    final ScanCrop damaged = _crop(<ScanTextLine>[_line('Cooperarion', .04)]);
    final ScanResolution absent = await resolver
        .resolve(damaged)
        .timeout(const Duration(seconds: 2));
    expect(absent.status, ScanResolutionStatus.noMatch);
    expect(absent.hints.names, <String>['Cooperarion']);
    expect(catalog.calls, isNot(contains('printings:Cooperation/null/null/1')));
    expect(refresh.isCompleted, isFalse);
    refresh.completeError(StateError('refresh unavailable'));
    await index.warm();
    final ScanResolution literal = await resolver
        .resolve(_crop(<ScanTextLine>[_line('Lightning Bolt', .04)]))
        .timeout(const Duration(seconds: 2));
    expect(literal.candidates.single.card.id, 'bolt');
    expect(index.matchReady('Cooperarion'), isNull);
    expect(loads, 2);
  });

  test('unique local OCR name correction uses one complete printing query and keeps original fuzzy evidence', () async {
    final _Card card = _Card(
      'ice',
      'Cooperation',
      set: 'ice',
      collectorNumber: '18',
      typeLine: 'Enchantment — Aura',
      oracleText: 'Target creature gains banding.',
    );
    final _Catalog catalog = _Catalog()
      ..namedCards['Cooperation'] = <MtgCard>[card];
    final _NameIndex index = _NameIndex()
      ..matches['Cooperarion'] = const ScanNameMatch(
        canonicalName: 'Cooperation',
        exact: false,
      );
    final ScanCrop crop = _crop(<ScanTextLine>[
      _line('Cooperarion', .04),
      _line('Enchant Creature', .55),
      _line('Target creature gains banding.', .67),
    ]);
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      nameIndex: index,
    ).resolve(crop);
    expect(index.calls, <String>['Cooperarion']);
    expect(catalog.calls, <String>['printings:Cooperation/null/null/1']);
    expect(result.candidates.single.card.id, 'ice');
    expect(result.hints.names, <String>['Cooperarion']);
    expect(result.candidates.single.evidence, contains(ScanEvidence.fuzzyName));
    expect(
      result.candidates.single.evidence,
      isNot(contains(ScanEvidence.nameMatch)),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(crop.lines.first.text, 'Cooperarion');
  });

  test('all literal OCR titles are indexed before failed network queries and conflicting local identities decline', () async {
    final _Catalog catalog = _Catalog()
      ..namedCards['Cooperation'] = <MtgCard>[
        _Card(
          'ice',
          'Cooperation',
          set: 'ice',
          typeLine: 'Enchantment',
          oracleText: 'Target creature gains banding.',
        ),
      ];
    final _NameIndex index = _NameIndex()
      ..matches['Cooperarion'] = const ScanNameMatch(
        canonicalName: 'Cooperation',
        exact: false,
      );
    final ScanCrop crop = _crop(<ScanTextLine>[
      _line('Unreadable Title', .03),
      _line('Cooperarion', .08),
      _line('Enchantment', .55),
      _line('Target creature gains banding.', .67),
    ]);
    final ScanResolution resolved = await ScanResolver(
      catalog: catalog,
      nameIndex: index,
    ).resolve(crop);
    expect(resolved.candidates.single.card.id, 'ice');
    expect(catalog.calls, <String>['printings:Cooperation/null/null/1']);
    expect(
      resolved.hints.names,
      containsAll(<String>['Unreadable Title', 'Cooperarion']),
    );
    index.matches['Unreadable Title'] = const ScanNameMatch(
      canonicalName: 'Different Card',
      exact: false,
    );
    catalog.namedCards['Unreadable Title'] = <MtgCard>[
      _Card(
        'original',
        'Unreadable Title',
        typeLine: 'Enchantment',
        oracleText: 'Target creature gains banding.',
      ),
    ];
    catalog.calls.clear();
    final ScanResolution ambiguous = await ScanResolver(
      catalog: catalog,
      nameIndex: index,
    ).resolve(crop);
    expect(ambiguous.candidates.single.card.id, 'original');
    expect(catalog.calls, <String>['printings:Unreadable Title/null/null/1']);
  });

  test('local name index failures mixed incomplete and contradicted discoveries fall back without changing hints', () async {
    const String body = 'Target creature gains banding and deals 3 damage.';
    final _Card fallback = _Card(
      'observed',
      'Cooperarion',
      typeLine: 'Enchantment',
      oracleText: body,
    );
    final _Card corrected = _Card(
      'corrected',
      'Cooperation',
      typeLine: 'Enchantment',
      oracleText: body,
    );
    final ScanCrop crop = _crop(<ScanTextLine>[
      _line('Cooperarion', .04),
      _line('Enchantment', .55),
      _line(body, .67),
    ]);
    for (final String scenario in <String>[
      'null',
      'index error',
      'query error',
      'incomplete',
      'mixed',
      'contradiction',
    ]) {
      final _Catalog catalog = _Catalog()
        ..namedCards['Cooperarion'] = <MtgCard>[fallback]
        ..namedCards['Cooperation'] = <MtgCard>[corrected];
      final _NameIndex index = _NameIndex();
      if (scenario != 'null') {
        index.matches['Cooperarion'] = const ScanNameMatch(
          canonicalName: 'Cooperation',
          exact: false,
        );
      }
      if (scenario == 'index error') {
        index.failure = StateError('offline name catalog');
      }
      if (scenario == 'query error') {
        catalog.namedFailures['Cooperation'] = StateError(
          'optional query failed',
        );
      }
      if (scenario == 'incomplete') catalog.namedHasMore['Cooperation'] = true;
      if (scenario == 'mixed') {
        catalog.namedCards['Cooperation'] = <MtgCard>[
          corrected,
          _Card('mixed', 'Other Card'),
        ];
      }
      if (scenario == 'contradiction') {
        catalog.namedCards['Cooperation'] = <MtgCard>[
          _Card(
            'bad',
            'Cooperation',
            typeLine: 'Enchantment',
            oracleText: 'Target creature gains banding and deals 4 damage.',
          ),
        ];
      }
      final ScanResolution result = await ScanResolver(
        catalog: catalog,
        nameIndex: index,
      ).resolve(crop);
      expect(result.candidates.single.card.id, 'observed', reason: scenario);
      expect(result.hints.names, <String>['Cooperarion']);
      expect(catalog.calls.last, 'printings:Cooperarion/null/null/1');
    }
  });

  test('local name discovery respects explicit names pages and original set number language constraints', () async {
    final _NameIndex index = _NameIndex()
      ..matches['Cooperarion'] = const ScanNameMatch(
        canonicalName: 'Cooperation',
        exact: false,
      );
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[_Card('original', 'Cooperarion')];
    final ScanResolver resolver = ScanResolver(
      catalog: catalog,
      nameIndex: index,
    );
    final ScanCrop crop = _crop(<ScanTextLine>[
      _line('Cooperarion', .04),
      _line('Instant', .55),
    ]);
    await resolver.resolve(crop, name: 'Manual Card');
    expect(index.calls, isEmpty);
    expect(catalog.calls.first, 'printings:Manual Card/null/null/1');
    catalog.calls.clear();
    await resolver.resolve(crop, page: 2);
    expect(index.calls, isEmpty);
    expect(catalog.calls.first, 'printings:Cooperarion/null/null/2');
    catalog.calls.clear();
    catalog.cards = <MtgCard>[
      _Card(
        'printing',
        'Cooperation',
        set: 'ice',
        collectorNumber: '18',
        lang: Language.french,
      ),
    ];
    final ScanResolution constrained = await resolver.resolve(
      crop,
      setCode: 'ice',
      collectorNumber: '18',
      language: 'fr',
    );
    expect(catalog.calls, <String>[
      'ice/18/fr',
      'printings:Cooperation/ice/fr/1',
    ]);
    expect(constrained.hints.setCode, 'ice');
    expect(constrained.hints.collectorNumber, '18');
    expect(constrained.hints.language, 'fr');
    expect(constrained.hints.names, <String>['Cooperarion']);
    expect(
      constrained.candidates.single.evidence,
      contains(ScanEvidence.fuzzyName),
    );
    expect(constrained.status, ScanResolutionStatus.needsReview);
    expect(resolver.nameIndex, same(index));
    expect(ScanResolver(catalog: _Catalog()).nameIndex, isNull);
  });

  test('independent artwork and symbol refinements overlap and preserve both distances', () async {
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _Card('first', 'Visual Spell'),
        _Card('second', 'Visual Spell'),
      ];
    final _ControlledVisualMatcher artwork = _ControlledVisualMatcher();
    final _ControlledVisualMatcher symbols = _ControlledVisualMatcher();
    bool finished = false;
    final Future<ScanResolution> result =
        ScanResolver(catalog: catalog, artwork: artwork, symbols: symbols)
            .resolve(
              _crop(<ScanTextLine>[
                _line('Visual Spell', .04),
                _line('Instant', .54),
              ]),
            )
            .whenComplete(() => finished = true);
    await Future.wait<void>(<Future<void>>[
      artwork.started.future,
      symbols.started.future,
    ]).timeout(const Duration(seconds: 2));
    expect(artwork.ids, <String>['first', 'second']);
    expect(symbols.ids, artwork.ids);
    symbols.result.complete(<String, double>{'first': .7, 'second': .1});
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    artwork.result.complete(<String, double>{'first': .2, 'second': .2});
    final ScanResolution resolved = await result;
    expect(resolved.candidates.first.card.id, 'second');
    expect(resolved.candidates.first.artworkDistance, .2);
    expect(resolved.candidates.first.symbolDistance, .1);
    expect(
      resolved.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.artworkCompared,
        ScanEvidence.symbolCompared,
      ]),
    );
  });

  test('optional visual failure drains its independent refinement and preserves textual results', () async {
    for (final bool failArtwork in <bool>[true, false]) {
      final _Catalog catalog = _Catalog()
        ..cards = <MtgCard>[_Card('first', 'Visual Spell')];
      final _ControlledVisualMatcher artwork = _ControlledVisualMatcher();
      final _ControlledVisualMatcher symbols = _ControlledVisualMatcher();
      bool finished = false;
      final Future<ScanResolution> result =
          ScanResolver(catalog: catalog, artwork: artwork, symbols: symbols)
              .resolve(
                _crop(<ScanTextLine>[
                  _line('Visual Spell', .04),
                  _line('Instant', .54),
                ]),
              )
              .whenComplete(() => finished = true);
      await Future.wait<void>(<Future<void>>[
        artwork.started.future,
        symbols.started.future,
      ]).timeout(const Duration(seconds: 2));
      (failArtwork ? artwork : symbols).result.completeError(
        StateError('optional comparison failed'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      (failArtwork ? symbols : artwork).result.complete(<String, double>{
        'first': .2,
      });
      final ScanResolution resolved = await result;
      expect(resolved.candidates.single.card.id, 'first');
      expect(resolved.candidates.single.hasContradiction, isFalse);
      expect(
        resolved.candidates.single.evidence,
        contains(ScanEvidence.nameMatch),
      );
      expect(
        resolved.candidates.single.evidence,
        contains(
          failArtwork
              ? ScanEvidence.symbolCompared
              : ScanEvidence.artworkCompared,
        ),
      );
      expect(
        resolved.candidates.single.evidence,
        isNot(
          contains(
            failArtwork
                ? ScanEvidence.artworkCompared
                : ScanEvidence.symbolCompared,
          ),
        ),
      );
    }
  });

  test('one uncertain numeric substitution suggests only review of shared-art prints with strong saved identity proof', () async {
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _numericReviewCard('normal', '33'),
        _numericReviewCard('alternate', '392'),
        _numericReviewCard('foil', '509'),
      ];
    final ScanCrop crop = _numericReviewCrop(
      footer: <ScanTextLine>[
        _reviewFooter('C 0500', y: .876),
        _reviewFooter('C 0580', y: .876),
        _reviewFooter('MH3 EN', y: .95),
      ],
    );
    expect(hasVerifiedSavedVisualLayout(crop), isTrue);
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(crop);
    expect(result.candidates.first.card.id, 'foil');
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(result.hints.collectorNumber, isNull);
    expect(
      result.candidates.first.evidence,
      contains(ScanEvidence.collectorNumberSimilar),
    );
    expect(
      result.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
        ScanEvidence.rulesTextMatch,
      ]),
    );
    expect(
      result.candidates.first.evidence,
      isNot(contains(ScanEvidence.collectorNumberMatch)),
    );
    expect(
      result.candidates.first.evidence,
      isNot(contains(ScanEvidence.footerMatch)),
    );
    expect(
      result.candidates
          .map((ScanCandidate candidate) => candidate.score)
          .toSet(),
      hasLength(1),
    );
    expect(
      crop.lines.map((ScanTextLine line) => line.text),
      containsAll(<String>['C 0500', 'C 0580']),
    );
    expect(
      crop.lines.map((ScanTextLine line) => line.text),
      isNot(contains('C 0509')),
    );
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    final ScanCandidate plain = ScanCandidate(
      result.candidates.first.card,
      <ScanEvidence>{...result.candidates.first.evidence}
        ..remove(ScanEvidence.collectorNumberSimilar),
    );
    expect(plain.score, result.candidates.first.score);
    final ScanResolution exactWeak = await ScanResolver(catalog: catalog)
        .resolve(
          _numericReviewCrop(
            footer: <ScanTextLine>[
              _reviewFooter('C 0509'),
              _reviewFooter('MH3 EN', y: .95),
            ],
          ),
        );
    expect(exactWeak.candidates.first.card.id, 'foil');
    expect(
      exactWeak.candidates.any(
        (ScanCandidate candidate) =>
            candidate.evidence.contains(ScanEvidence.collectorNumberSimilar),
      ),
      isFalse,
    );
    final ScanCrop strong = _numericReviewCrop(
      footer: <ScanTextLine>[
        _reviewFooter('C 0509', confidence: .97),
        _reviewFooter('MH3 EN', confidence: .97, y: .95),
      ],
    );
    catalog.exact = catalog.cards.last;
    final ScanResolution authoritative = await ScanResolver(catalog: catalog)
        .resolve(strong);
    expect(hasExactPrintingEvidence(strong, authoritative), isTrue);
    final ScanResolution markedSimilar = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(authoritative.candidates.single.card, <ScanEvidence>{
          ...authoritative.candidates.single.evidence,
          ScanEvidence.collectorNumberSimilar,
        }),
      ],
      hints: authoritative.hints,
      status: ScanResolutionStatus.exactPrinting,
    );
    expect(hasExactPrintingEvidence(strong, markedSimilar), isFalse);
  });

  test('nearest numeric review ranking rejects ambiguous catalog metadata and incomplete searches', () async {
    final _Card normal = _numericReviewCard('normal', '33');
    final _Card foil = _numericReviewCard('foil', '509');
    final List<List<MtgCard>> alternatives = <List<MtgCard>>[
      <MtgCard>[normal, _numericReviewCard('other-near', '501'), foil],
      <MtgCard>[normal, foil, _numericReviewCard('same-number', '509')],
      <MtgCard>[
        normal,
        _numericReviewCard('different-art', '509', illustration: 'other-art'),
      ],
      <MtgCard>[
        normal,
        _numericReviewCard('different-set', '509', set: 'other'),
      ],
      <MtgCard>[
        _numericReviewCard('unknown-art', '33', illustration: null),
        _numericReviewCard('foil', '509', illustration: null),
      ],
      <MtgCard>[normal, _numericReviewCard('not-near', '599')],
      <MtgCard>[
        normal,
        foil,
        _Card(
          'other-name',
          'Other Card',
          set: 'mh3',
          collectorNumber: '500',
          illustrationId: 'shared-art',
        ),
      ],
    ];
    for (final List<MtgCard> cards in alternatives) {
      final _Catalog catalog = _Catalog()..cards = cards;
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(_numericReviewCrop());
      expect(
        result.candidates.any(
          (ScanCandidate candidate) =>
              candidate.evidence.contains(ScanEvidence.collectorNumberSimilar),
        ),
        isFalse,
        reason: cards.map((MtgCard card) => card.id).join(','),
      );
      expect(result.candidates.first.card.id, cards.first.id);
      expect(hasExactPrintingEvidence(_numericReviewCrop(), result), isFalse);
    }
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[normal, foil]
      ..hasMore = true;
    final ScanResolver resolver = ScanResolver(catalog: catalog);
    final ScanResolution incomplete = await resolver.resolve(
      _numericReviewCrop(),
    );
    expect(incomplete.hasMore, isTrue);
    expect(incomplete.candidates.first.card.id, 'normal');
    catalog.hasMore = false;
    final ScanResolution later = await resolver.resolve(
      _numericReviewCrop(),
      page: 2,
    );
    expect(later.candidates.first.card.id, 'normal');
    for (final ScanResolution result in <ScanResolution>[incomplete, later]) {
      expect(
        result.candidates.any(
          (ScanCandidate candidate) =>
              candidate.evidence.contains(ScanEvidence.collectorNumberSimilar),
        ),
        isFalse,
      );
    }
  });

  test('literal scene alphanumeric footer compares formatted candidates only for review', () async {
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _sceneCollectorCard('ordinary', '735'),
        _sceneCollectorCard('near', '712'),
      ];
    final ScanCrop crop = _sceneCollectorCrop();
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(crop);
    expect(result.candidates.first.card.id, 'near');
    expect(result.hints.collectorNumber, isNull);
    expect(result.hints.setCode, isNull);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(
      result.candidates.first.evidence,
      contains(ScanEvidence.collectorNumberSimilar),
    );
    expect(
      result.candidates
          .map((ScanCandidate candidate) => candidate.score)
          .toSet(),
      hasLength(1),
    );
    expect(
      crop.lines.any(
        (ScanTextLine line) =>
            line.text == 'C 07B2' &&
            line.confidence == 1 &&
            line.sceneFooterGuide,
      ),
      isTrue,
    );
    expect(
      crop.lines.map((ScanTextLine line) => line.text),
      isNot(contains('C 0712')),
    );
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(verifiedLiveHistoricalBodyIdentity(crop, result), isNull);
    final ScanTextLine decoded = ScanTextLine.fromMap(<Object?, Object?>{
      'text': 'C 07B2',
      'confidence': 1,
      'bounds': <Object?, Object?>{
        'x': .03,
        'y': .91,
        'width': .18,
        'height': .02,
      },
      'sceneFooterGuide': true,
    });
    expect(decoded.sceneFooterGuide, isTrue);
    expect(decoded.text, 'C 07B2');
  });

  test('scene collector similarity rejects unverified source, real identifiers, conflicts and overrides', () async {
    final List<MtgCard> defaults = <MtgCard>[
      _sceneCollectorCard('ordinary', '735'),
      _sceneCollectorCard('near', '712'),
    ];
    bool similar(ScanResolution result) => result.candidates.any(
      (ScanCandidate candidate) =>
          candidate.evidence.contains(ScanEvidence.collectorNumberSimilar),
    );
    for (final ScanCrop crop in <ScanCrop>[
      _sceneCollectorCrop(guide: false),
      _sceneCollectorCrop(confidence: .84),
      _sceneCollectorCrop(titleConfidence: .5),
      _sceneCollectorCrop(body: false),
      _sceneCollectorCrop(firstRule: 'Choose up to 3 target artifact or'),
      _sceneCollectorCrop(token: 'C B712'),
      _sceneCollectorCrop(
        extra: const <ScanTextLine>[
          ScanTextLine(
            text: 'C 07D2',
            confidence: 1,
            bounds: ScanBounds(.03, .94, .18, .02),
            sceneFooterGuide: true,
          ),
        ],
      ),
      _sceneCollectorCrop(extra: <ScanTextLine>[_reviewFooter('C 0735')]),
      _sceneCollectorCrop(
        extra: <ScanTextLine>[_reviewFooter('C 0735', confidence: .97)],
      ),
    ]) {
      expect(
        similar(
          await ScanResolver(catalog: _Catalog()..cards = defaults)
              .resolve(crop),
        ),
        isFalse,
      );
    }
    for (final List<MtgCard> cards in <List<MtgCard>>[
      <MtgCard>[...defaults, _sceneCollectorCard('also-near', '702')],
      <MtgCard>[...defaults, _sceneCollectorCard('actual-alpha', '7B2')],
      <MtgCard>[...defaults, _sceneCollectorCard('duplicate', '712')],
      <MtgCard>[
        defaults.first,
        _sceneCollectorCard('different-set', '712', set: 'other'),
      ],
      <MtgCard>[
        defaults.first,
        _sceneCollectorCard('different-art', '712', illustration: 'other'),
      ],
      <MtgCard>[
        _sceneCollectorCard('missing-art', '735', illustration: null),
        _sceneCollectorCard('missing-art-near', '712', illustration: null),
      ],
      <MtgCard>[
        defaults.first,
        _sceneCollectorCard('wrong-rarity', '712', rarity: Rarity.rare),
      ],
      <MtgCard>[
        defaults.first,
        _sceneCollectorCard('wrong-name', '712', name: 'Other Spell'),
      ],
    ]) {
      expect(
        similar(
          await ScanResolver(catalog: _Catalog()..cards = cards)
              .resolve(_sceneCollectorCrop()),
        ),
        isFalse,
      );
    }
    final _Catalog incomplete = _Catalog()
      ..cards = defaults
      ..hasMore = true;
    expect(
      similar(
        await ScanResolver(catalog: incomplete).resolve(_sceneCollectorCrop()),
      ),
      isFalse,
    );
    final ScanResolver resolver = ScanResolver(
      catalog: _Catalog()..cards = defaults,
    );
    for (final String override in <String>[
      'name',
      'set',
      'number',
      'language',
      'page',
    ]) {
      expect(
        similar(
          await resolver.resolve(
            _sceneCollectorCrop(),
            name: override == 'name' ? 'Fixture Spell' : null,
            setCode: override == 'set' ? 'tst' : null,
            collectorNumber: override == 'number' ? '999' : null,
            language: override == 'language' ? 'en' : null,
            page: override == 'page' ? 2 : 1,
          ),
        ),
        isFalse,
      );
    }
  });

  test('nearest numeric review ranking cannot rescue weak identity malformed footer or strong contradictions', () async {
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _numericReviewCard('normal', '33'),
        _numericReviewCard('foil', '509'),
      ];
    final ScanCrop full = _numericReviewCrop();
    final List<ScanCrop> unsupported = <ScanCrop>[
      _numericReviewCrop(titleConfidence: .5),
      _numericReviewCrop(title: ''),
      _numericReviewCrop(typeConfidence: .5),
      _numericReviewCrop(body: false),
      _numericReviewCrop(firstRule: 'Choose up to 3 target artifact or'),
      _numericReviewCrop(footer: <ScanTextLine>[_reviewFooter('0500')]),
      _numericReviewCrop(
        footer: <ScanTextLine>[
          _reviewFooter('9050 %'),
          _reviewFooter('MH3 EN', y: .95),
        ],
      ),
      _numericReviewCrop(
        footer: <ScanTextLine>[
          _reviewFooter('C 5000'),
          _reviewFooter('MH3 EN', y: .95),
        ],
      ),
      _numericReviewCrop(
        footer: <ScanTextLine>[
          _reviewFooter('C 0500', y: .978),
          _reviewFooter('MH3 EN', y: .95),
        ],
      ),
      _numericReviewCrop(
        footer: <ScanTextLine>[
          _reviewFooter('C 0500', confidence: .8),
          _reviewFooter('MH3 EN', y: .95),
        ],
      ),
      _numericReviewCrop(
        footer: <ScanTextLine>[
          _reviewFooter('C 0500', confidence: .8),
          _reviewFooter('C 0580', confidence: .8, y: .89),
          _reviewFooter('MH3 EN', y: .95),
        ],
      ),
      _numericReviewCrop(
        footer: <ScanTextLine>[
          _reviewFooter('C 0500'),
          _reviewFooter('MH3 EN', confidence: .8, y: .95),
          _reviewFooter('MH3 FR', confidence: .8, y: .89),
        ],
      ),
      _numericReviewCrop(
        footer: <ScanTextLine>[
          _reviewFooter('C 0033'),
          _reviewFooter('C 0509', y: .89),
          _reviewFooter('MH3 EN', y: .95),
        ],
      ),
      ScanCrop(
        imagePath: '',
        width: full.width,
        height: full.height,
        rectified: full.rectified,
        sourceCorners: full.sourceCorners,
        lines: full.lines,
      ),
    ];
    for (int index = 0; index < unsupported.length; index++) {
      final ScanCrop crop = unsupported[index];
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(crop);
      expect(
        result.candidates.any(
          (ScanCandidate candidate) =>
              candidate.evidence.contains(ScanEvidence.collectorNumberSimilar),
        ),
        isFalse,
        reason: 'unsupported source $index',
      );
      expect(hasExactPrintingEvidence(crop, result), isFalse);
    }
    catalog.scopedCards['Jolt Awake/null'] = <MtgCard>[];
    catalog.fuzzy = catalog.cards.first;
    final ScanResolution fuzzy = await ScanResolver(catalog: catalog)
        .resolve(_numericReviewCrop(title: 'Jolt Awake'));
    expect(fuzzy.candidates.first.evidence, contains(ScanEvidence.fuzzyName));
    expect(
      fuzzy.candidates.any(
        (ScanCandidate candidate) =>
            candidate.evidence.contains(ScanEvidence.collectorNumberSimilar),
      ),
      isFalse,
    );
  });

  test('literal energy counter explanation corroborates repeated OCR glyphs without changing raw rules or numeric conflicts', () async {
    const String name = 'Energy Test';
    const String oracle =
        'You get {E}{E} (two energy counters). Then you may pay an amount of {E} equal to a card mana value.';
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _Card('energy', name, oracleText: oracle, typeLine: 'Sorcery'),
      ];
    final ScanCrop crop = _crop(<ScanTextLine>[
      _line(name, .04),
      _line('Sorcery', .55),
      _line('You get 44 (two energy counters).', .61),
      _line('Then you may pay an amount of 4 equal to a card mana value.', .66),
    ]);
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(crop);
    expect(
      result.candidates.single.evidence,
      contains(ScanEvidence.rulesTextMatch),
    );
    expect(
      result.candidates.single.evidence,
      isNot(contains(ScanEvidence.rulesTextMismatch)),
    );
    expect(
      result.hints.rulesText,
      contains('You get 44 (two energy counters).'),
    );
    expect(
      result.hints.rulesText,
      contains('Then you may pay an amount of 4 equal to a card mana value.'),
    );
    final ScanResolution spaced = await ScanResolver(catalog: catalog).resolve(
      _crop(<ScanTextLine>[
        _line(name, .04),
        _line('Sorcery', .55),
        _line('You get 4 4 (two energy counters). Then you', .61),
      ]),
    );
    expect(
      spaced.candidates.single.evidence,
      contains(ScanEvidence.rulesTextMatch),
    );
    expect(
      spaced.candidates.single.evidence,
      isNot(contains(ScanEvidence.rulesTextMismatch)),
    );
    expect(
      spaced.hints.rulesText,
      contains('You get 4 4 (two energy counters). Then you'),
    );
    for (final List<String> lines in <List<String>>[
      <String>['You get 444 (two energy counters).'],
      <String>['You get 46 (two energy counters).'],
      <String>['You get 4 6 (two energy counters).'],
      <String>['You get 4 4 4 (two energy counters).'],
      <String>['You get 44 counters.'],
      <String>[
        'You get 44 (two energy counters).',
        'Then you may pay 4 equal to a card mana value.',
      ],
    ]) {
      final ScanResolution negative = await ScanResolver(catalog: catalog)
          .resolve(
            _crop(<ScanTextLine>[
              _line(name, .04),
              _line('Sorcery', .55),
              for (int index = 0; index < lines.length; index++)
                _line(lines[index], .61 + index * .05),
            ]),
          );
      expect(
        negative.candidates.single.evidence,
        contains(ScanEvidence.rulesTextMismatch),
        reason: lines.join(' '),
      );
    }
    catalog.cards = <MtgCard>[
      _Card(
        'damage',
        name,
        typeLine: 'Sorcery',
        oracleText: 'This deals 3 damage to any target.',
      ),
    ];
    final ScanResolution damage = await ScanResolver(catalog: catalog).resolve(
      _crop(<ScanTextLine>[
        _line(name, .04),
        _line('Sorcery', .55),
        _line('This deals 44 damage to any target.', .61),
      ]),
    );
    expect(
      damage.candidates.single.evidence,
      contains(ScanEvidence.rulesTextMismatch),
    );
  });

  test('border recovery permits only verified saved visuals and cannot replace historical or live proof', () {
    final ScanCrop original = _historicalBodyCrop();
    ScanCrop repaired(
      List<String> warnings, {
      bool live = false,
      List<ScanPoint>? corners,
      List<ScanTextLine>? lines,
    }) => ScanCrop(
      imagePath: live ? '' : original.imagePath,
      width: original.width,
      height: original.height,
      rectified: true,
      sourceCorners: corners ?? original.sourceCorners,
      warnings: warnings,
      lines:
          lines ??
          original.lines
              .map(
                (ScanTextLine line) => ScanTextLine(
                  text: line.text,
                  confidence: line.confidence,
                  bounds: line.bounds,
                  glyphHeight: line.bounds.height,
                ),
              )
              .toList(),
    );
    final ScanCrop border = repaired(const <String>['border_recovered']);
    expect(hasVerifiedSavedVisualLayout(border), isTrue);
    expect(hasVerifiedSavedBodyLayout(border), isFalse);
    final ScanCrop complete = repaired(<String>[
      ...original.warnings,
      'border_recovered',
    ]);
    expect(hasVerifiedSavedVisualLayout(complete), isTrue);
    expect(hasVerifiedSavedBodyLayout(complete), isTrue);
    expect(
      hasVerifiedSavedVisualLayout(
        repaired(const <String>['border_recovered', 'unknown_repair']),
      ),
      isFalse,
    );
    expect(
      hasVerifiedSavedVisualLayout(
        repaired(
          const <String>['border_recovered'],
          lines: <ScanTextLine>[_line('Enchantment', .55)],
        ),
      ),
      isFalse,
    );
    expect(
      hasVerifiedSavedVisualLayout(
        repaired(
          const <String>['border_recovered'],
          corners: const <ScanPoint>[
            ScanPoint(.2, .2),
            ScanPoint(.2, .2),
            ScanPoint(.8, .8),
            ScanPoint(.2, .8),
          ],
        ),
      ),
      isFalse,
    );
    final ScanCrop live = repaired(const <String>[], live: true);
    expect(hasVerifiedLiveBodyLayout(live), isTrue);
    final ScanCrop liveBorder = repaired(const <String>[
      'border_recovered',
    ], live: true);
    expect(hasVerifiedLiveBodyLayout(liveBorder), isFalse);

    final _Card card = _Card(
      'ice',
      'Circle of Protection: Blue',
      set: 'ice',
      collectorNumber: '13',
      artist: 'Pete Venters',
      releasedAt: DateTime(1995),
      typeLine: 'Enchantment',
      oracleText: '{1}: The next time a blue source of your choice would deal damage to you this turn, prevent that damage.',
    );
    final ScanResolution resolution = ScanResolution(
      status: ScanResolutionStatus.needsReview,
      hints: ScanHints.fromCrop(border),
      candidates: <ScanCandidate>[
        ScanCandidate(card, const <ScanEvidence>{
          ScanEvidence.rulesKeywordMatch,
          ScanEvidence.typeLineMatch,
          ScanEvidence.illustratorMatch,
          ScanEvidence.copyrightYearMatch,
        }),
      ],
    );
    expect(verifiedHistoricalBodyIdentity(border, resolution), isNull);
    expect(verifiedLiveHistoricalBodyIdentity(liveBorder, resolution), isNull);
    final ScanCrop footer = repaired(
      const <String>['border_recovered'],
      lines: <ScanTextLine>[
        _line('Circle of Protection: Blue', .04),
        ...original.lines,
        _line('13 C', .88),
        _line('ICE EN', .92),
      ],
    );
    final ScanResolution exact = ScanResolution(
      status: ScanResolutionStatus.exactPrinting,
      hints: ScanHints.fromCrop(footer),
      candidates: <ScanCandidate>[
        ScanCandidate(card, const <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.footerMatch,
          ScanEvidence.collectorNumberMatch,
          ScanEvidence.languageMatch,
        }),
      ],
    );
    expect(
      hasExactPrintingEvidence(
        repaired(const <String>[], lines: footer.lines),
        exact,
      ),
      isTrue,
    );
    expect(hasExactPrintingEvidence(footer, exact), isFalse);
  });

  test('failed basic-land set searches retain literal contradictions during review-only visual recovery', () async {
    const String title = 'Snow-Covered Swamp';
    final _Catalog catalog = _Catalog()
      ..scopedCards['$title/mhi'] = <MtgCard>[]
      ..cards = <MtgCard>[
        _Card(
          'digital',
          title,
          set: 'pana',
          collectorNumber: '259',
          typeLine: 'Basic Snow Land — Swamp',
          games: const <Game>[Game.arena],
        ),
        _Card(
          'red',
          title,
          set: 'csp',
          collectorNumber: '149',
          typeLine: 'Basic Snow Land — Swamp',
        ),
        _Card(
          'blue',
          title,
          set: 'mh1',
          collectorNumber: '252',
          typeLine: 'Basic Snow Land — Swamp',
        ),
      ];
    final _BodyArtwork artwork = _BodyArtwork();
    final ScanCrop crop = _basicLandRecoveryCrop(
      extraLines: const <ScanTextLine>[
        ScanTextLine(
          text: 'Swamp',
          confidence: 1,
          bounds: ScanBounds(.63, .835, .20, .03),
        ),
      ],
    );
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: artwork,
      symbols: _Symbol(),
    ).resolve(crop);
    expect(catalog.calls, <String>[
      'printings:$title/mhi/en/1',
      'printings:$title/null/en/1',
    ]);
    expect(result.hints.setCode, 'mhi');
    expect(result.hints.collectorNumber, isNull);
    expect(result.candidates.first.card.id, 'blue');
    expect(artwork.comparedIds, <String>['red', 'blue']);
    expect(artwork.bodyFallback, isTrue);
    expect(result.status, ScanResolutionStatus.needsReview);
    for (final ScanCandidate candidate in result.candidates) {
      expect(candidate.hasContradiction, isTrue);
      expect(
        candidate.evidence,
        containsAll(<ScanEvidence>[
          ScanEvidence.nameMatch,
          ScanEvidence.typeLineMatch,
          ScanEvidence.printingMismatch,
          ScanEvidence.artworkCompared,
        ]),
      );
      expect(
        candidate.evidence,
        isNot(contains(ScanEvidence.collectorNumberMatch)),
      );
    }
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(verifiedLiveHistoricalBodyIdentity(crop, result), isNull);
  });

  test('basic-land recovery cannot bypass manual selection, pagination or incomplete identity lists', () async {
    const String title = 'Snow-Covered Swamp';
    _Catalog catalog() => _Catalog()
      ..scopedCards['$title/mhi'] = <MtgCard>[]
      ..cards = <MtgCard>[
        _Card(
          'blue',
          title,
          set: 'mh1',
          collectorNumber: '252',
          typeLine: 'Basic Snow Land — Swamp',
        ),
      ];
    final ScanCrop crop = _basicLandRecoveryCrop();
    for (final String selection in <String>[
      'name',
      'set',
      'number',
      'language',
      'page',
    ]) {
      final _Catalog selected = catalog();
      await ScanResolver(catalog: selected).resolve(
        crop,
        name: selection == 'name' ? title : null,
        setCode: selection == 'set' ? 'mhi' : null,
        collectorNumber: selection == 'number' ? '999' : null,
        language: selection == 'language' ? 'en' : null,
        page: selection == 'page' ? 2 : 1,
      );
      expect(selected.calls, isNot(contains('printings:$title/null/en/1')));
    }
    for (final _Catalog invalid in <_Catalog>[
      catalog()..hasMore = true,
      catalog()
        ..cards.add(
          _Card(
            'foreign',
            'Snow-Covered Island',
            typeLine: 'Basic Snow Land — Island',
          ),
        ),
      catalog()
        ..cards = <MtgCard>[
          _Card('wrong-type', title, typeLine: 'Creature — Swamp'),
        ],
      catalog()
        ..cards = <MtgCard>[
          _Card(
            'wrong-language',
            title,
            lang: Language.german,
            typeLine: 'Basic Snow Land — Swamp',
          ),
        ],
      catalog()
        ..cards = <MtgCard>[
          _Card(
            'digital-only',
            title,
            typeLine: 'Basic Snow Land — Swamp',
            games: const <Game>[Game.arena],
          ),
        ],
      catalog()
        ..cards = <MtgCard>[
          _Card(
            'set-present',
            title,
            set: 'mhi',
            typeLine: 'Basic Snow Land — Swamp',
          ),
        ],
      catalog()
        ..cards = List<MtgCard>.generate(
          97,
          (int index) => _Card(
            'many-$index',
            title,
            typeLine: 'Basic Snow Land — Swamp',
            illustrationId: 'same-art',
          ),
        ),
      catalog()
        ..cards = List<MtgCard>.generate(
          33,
          (int index) => _Card(
            'many-$index',
            title,
            typeLine: 'Basic Snow Land — Swamp',
            illustrationId: 'art-$index',
          ),
        ),
    ]) {
      final _BodyArtwork artwork = _BodyArtwork();
      final ScanResolution result = await ScanResolver(
        catalog: invalid,
        artwork: artwork,
      ).resolve(crop);
      expect(result.status, ScanResolutionStatus.noMatch);
      expect(artwork.calls, 0);
    }
    final _Catalog missingProvenance = catalog();
    await ScanResolver(
      catalog: missingProvenance,
    ).resolve(_basicLandRecoveryCrop(warnings: const <String>['partial_card']));
    expect(
      missingProvenance.calls,
      isNot(contains('printings:$title/null/en/1')),
    );
    final _Catalog numbered = catalog();
    await ScanResolver(catalog: numbered)
        .resolve(_basicLandRecoveryCrop(number: '252/254'));
    expect(numbered.calls, isNot(contains('printings:$title/null/en/1')));

    final _Catalog conflicting = catalog();
    await ScanResolver(catalog: conflicting).resolve(
      _basicLandRecoveryCrop(
        extraLines: const <ScanTextLine>[
          ScanTextLine(
            text: 'ICE EN',
            confidence: 1,
            bounds: ScanBounds(.06, .90, .25, .02),
          ),
        ],
      ),
    );
    expect(conflicting.calls, isNot(contains('printings:$title/null/en/1')));

    final _Catalog bodyConflict = catalog()
      ..cards = <MtgCard>[
        _Card(
          'blue',
          title,
          set: 'mh1',
          collectorNumber: '252',
          typeLine: 'Basic Snow Land — Swamp',
          oracleText: '{T}: Add {B}.',
        ),
      ];
    final _BodyArtwork artwork = _BodyArtwork();
    final ScanResolution rejected =
        await ScanResolver(catalog: bodyConflict, artwork: artwork).resolve(
          _basicLandRecoveryCrop(
            extraLines: const <ScanTextLine>[
              ScanTextLine(
                text: 'Draw three cards.',
                confidence: 1,
                bounds: ScanBounds(.1, .60, .60, .025),
              ),
            ],
          ),
        );
    expect(rejected.status, ScanResolutionStatus.noMatch);
    expect(artwork.calls, 0);
  });

  test(
    'complete bodyless basic-land outlines allow only saved visual ranking',
    () {
      final ScanCrop crop = ScanCrop(
        imagePath: '/local/basic-land.jpg',
        width: 1440,
        height: 2000,
        rectified: true,
        sourceCorners: const <ScanPoint>[
          ScanPoint(.12, .32),
          ScanPoint(.32, .33),
          ScanPoint(.30, .82),
          ScanPoint(.10, .81),
        ],
        warnings: const <String>['partial_card', 'basic_land_outline'],
        lines: const <ScanTextLine>[
          ScanTextLine(
            text: 'Snow-Covered Swamp',
            confidence: 1,
            bounds: ScanBounds(.07, .04, .72, .03),
          ),
          ScanTextLine(
            text: 'Basic Snow Land',
            confidence: 1,
            bounds: ScanBounds(.06, .839, .35, .031),
          ),
          ScanTextLine(
            text: '2527254',
            confidence: 1,
            bounds: ScanBounds(.06, .92, .24, .02),
          ),
          ScanTextLine(
            text: 'MHI • EN Mike Linn',
            confidence: 1,
            bounds: ScanBounds(.06, .945, .46, .02),
          ),
        ],
      );
      expect(hasVerifiedSavedVisualLayout(crop), isTrue);
      expect(hasVerifiedSavedBodyLayout(crop), isFalse);
      expect(hasVerifiedLiveBodyLayout(crop), isFalse);
      final ScanHints hints = ScanHints.fromCrop(crop);
      expect(hints.collectorNumber, isNull);
      expect(hints.setCode, isNot('mh1'));
      final ScanResolution suggestion = ScanResolution(
        status: ScanResolutionStatus.needsReview,
        hints: hints,
        candidates: <ScanCandidate>[
          ScanCandidate(
            _Card(
              'swamp',
              'Snow-Covered Swamp',
              set: 'mh1',
              collectorNumber: '252',
              typeLine: 'Basic Snow Land — Swamp',
            ),
            const <ScanEvidence>{
              ScanEvidence.nameMatch,
              ScanEvidence.typeLineMatch,
              ScanEvidence.artworkCompared,
            },
          ),
        ],
      );
      expect(hasExactPrintingEvidence(crop, suggestion), isFalse);
    },
  );

  test(
    'bodyless basic-land visual ranking rejects incomplete or unproven layouts',
    () {
      const List<ScanPoint> validCorners = <ScanPoint>[
        ScanPoint(.12, .32),
        ScanPoint(.32, .33),
        ScanPoint(.30, .82),
        ScanPoint(.10, .81),
      ];
      const List<ScanTextLine> validLines = <ScanTextLine>[
        ScanTextLine(
          text: 'Snow-Covered Swamp',
          confidence: 1,
          bounds: ScanBounds(.07, .04, .72, .03),
        ),
        ScanTextLine(
          text: 'Basic Snow Land',
          confidence: 1,
          bounds: ScanBounds(.06, .839, .35, .031),
        ),
        ScanTextLine(
          text: 'MHI • EN Mike Linn',
          confidence: 1,
          bounds: ScanBounds(.06, .945, .46, .02),
        ),
      ];
      ScanCrop crop({
        String path = '/local/basic-land.jpg',
        int width = 1440,
        int height = 2000,
        bool rectified = true,
        List<ScanPoint> corners = validCorners,
        List<ScanTextLine> lines = validLines,
        List<String> warnings = const <String>[
          'partial_card',
          'basic_land_outline',
        ],
      }) => ScanCrop(
        imagePath: path,
        width: width,
        height: height,
        rectified: rectified,
        sourceCorners: corners,
        warnings: warnings,
        lines: lines,
      );
      for (final ScanCrop invalid in <ScanCrop>[
        crop(path: ''),
        crop(width: 399),
        crop(height: 1000),
        crop(rectified: false),
        crop(warnings: const <String>['partial_card']),
        crop(
          warnings: const <String>[
            'partial_card',
            'basic_land_outline',
            'incomplete_card',
          ],
        ),
        crop(
          warnings: const <String>[
            'partial_card',
            'basic_land_outline',
            'no_card_rectangle',
          ],
        ),
        crop(warnings: const <String>['basic_land_outline', 'unknown_repair']),
        crop(
          corners: const <ScanPoint>[
            ScanPoint(.12, .32),
            ScanPoint(.32, .33),
            ScanPoint(.12, .32),
            ScanPoint(.10, .81),
          ],
        ),
        crop(
          corners: const <ScanPoint>[
            ScanPoint(double.nan, .32),
            ScanPoint(.32, .33),
            ScanPoint(.30, .82),
            ScanPoint(.10, .81),
          ],
        ),
        crop(lines: validLines.take(2).toList()),
        crop(
          lines: <ScanTextLine>[
            ...validLines.take(2),
            const ScanTextLine(
              text: '7',
              confidence: 1,
              bounds: ScanBounds(.06, .945, .20, .02),
            ),
          ],
        ),
        ...List<ScanCrop>.generate(
          validLines.length,
          (int index) => crop(
            lines: List<ScanTextLine>.generate(validLines.length, (int row) {
              final ScanTextLine line = validLines[row];
              return ScanTextLine(
                text: line.text,
                confidence: row == index ? .89 : line.confidence,
                bounds: line.bounds,
              );
            }),
          ),
        ),
        crop(
          lines: <ScanTextLine>[
            validLines.first,
            const ScanTextLine(
              text: 'Basic Land costs less to cast',
              confidence: 1,
              bounds: ScanBounds(.06, .839, .60, .031),
            ),
            validLines.last,
          ],
        ),
        crop(
          lines: <ScanTextLine>[
            validLines.first,
            validLines[1],
            const ScanTextLine(
              text: 'MHI EN',
              confidence: 1,
              bounds: ScanBounds(.06, .70, .46, .02),
            ),
          ],
        ),
      ]) {
        expect(hasVerifiedSavedVisualLayout(invalid), isFalse);
      }
    },
  );

  test('observed narrow modern and legacy type lines and bottom basic lands remain literal type evidence', () {
    for (final (String, ScanBounds, String) observation
        in <(String, ScanBounds, String)>[
          ('Sorcery', const ScanBounds(.047, .5807, .1708, .0377), 'sorcery'),
          (
            'Enchant Creature',
            const ScanBounds(.10, .55, .34, .025),
            'enchantment',
          ),
          ('Summon Wizard', const ScanBounds(.10, .55, .34, .025), 'creature'),
          (
            'Basic Snow Land',
            const ScanBounds(.0603, .8392, .3513, .031),
            'land',
          ),
        ]) {
      final ScanHints hints = ScanHints.fromCrop(
        _crop(<ScanTextLine>[
          ScanTextLine(
            text: observation.$1,
            confidence: 1,
            bounds: observation.$2,
          ),
        ]),
      );
      expect(hints.typeLine, observation.$3, reason: observation.$1);
      expect(hints.rulesText, isNot(contains(observation.$1)));
    }
    for (final String text in <String>[
      'Target creature gains banding',
      'Enchant creature whenever you draw a card',
      'Basic Land costs less to cast',
      'Sorcery spells you cast cost less',
    ]) {
      expect(observedCardType(text), isNull, reason: text);
    }
    expect(
      ScanHints.fromCrop(
        _crop(<ScanTextLine>[
          _line('Enchant Creature', .04),
          _line('Basic Snow Land', .96),
        ]),
      ).typeLine,
      isNull,
    );
  });

  test('gameplay energy glyph cannot become a collector hint without actual footer context', () {
    final ScanCrop crop = _crop(const <ScanTextLine>[
      ScanTextLine(
        text: 'Jolted Awake',
        confidence: 1,
        bounds: ScanBounds(.0492, .032, .3262, .0423),
      ),
      ScanTextLine(
        text: 'Sorcery',
        confidence: 1,
        bounds: ScanBounds(.0473, .5807, .1708, .0377),
      ),
      ScanTextLine(
        text: '4',
        confidence: 1,
        bounds: ScanBounds(.5773, .763, .0444, .0332),
      ),
    ]);
    final ScanHints hints = ScanHints.fromCrop(crop);
    expect(hints.names, <String>['Jolted Awake']);
    expect(hints.typeLine, 'sorcery');
    expect(hints.collectorNumber, isNull);
    expect(
      ScanHints.fromCrop(_crop(<ScanTextLine>[_line('4', .90)]))
          .collectorNumber,
      isNull,
    );
    expect(
      ScanHints.fromCrop(
        _crop(<ScanTextLine>[_line('4', .90), _line('MH3 EN', .93)]),
      ).collectorNumber,
      '4',
    );
    expect(
      ScanHints.fromCrop(_crop(<ScanTextLine>[_line('4 C', .90)]))
          .collectorNumber,
      '4',
    );
    expect(
      ScanHints.fromCrop(_crop(<ScanTextLine>[_line('0509', .92)]))
          .collectorNumber,
      '0509',
    );
  });

  test('legacy Enchant Creature supports actual observed title without fabricating printing proof', () async {
    final _Catalog catalog = _Catalog()
      ..namedCards['Cooperation'] = <MtgCard>[
        _Card(
          'cooperation',
          'Cooperation',
          set: 'ice',
          collectorNumber: '18',
          typeLine: 'Enchantment — Aura',
          oracleText: 'Enchant creature\nEnchanted creature has banding.',
        ),
      ];
    final ScanCrop crop = _crop(<ScanTextLine>[
      _line('Cooperation', .05),
      _line('Enchant Creature', .55),
      _line('Target creature gains banding.', .65),
    ]);
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(crop);
    expect(result.candidates.single.card.id, 'cooperation');
    expect(
      result.candidates.single.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
      ]),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(result.hints.names, <String>['Cooperation']);
    expect(result.hints.setCode, isNull);
    expect(result.hints.collectorNumber, isNull);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
  });

  test('weak literal artist and year order print suggestions but cannot become strong identity proof', () async {
    final _Catalog catalog = _Catalog()
      ..namedCards['Circle of Protection: Blue'] = <MtgCard>[
        _Card(
          'eight',
          'Circle of Protection: Blue',
          set: '8ed',
          collectorNumber: '11',
          artist: 'Greg Hildebrandt & Tim Hildebrandt',
          releasedAt: DateTime(2003),
          typeLine: 'Enchantment',
        ),
        _Card(
          'ice',
          'Circle of Protection: Blue',
          set: 'ice',
          collectorNumber: '13',
          artist: 'Pete Venters',
          releasedAt: DateTime(1995),
          typeLine: 'Enchantment',
        ),
      ];
    final ScanCrop crop = _crop(<ScanTextLine>[
      _line('Circle of Protection: Blue', .04),
      const ScanTextLine(
        text: 'Illus. Pete Venters',
        confidence: .5,
        bounds: ScanBounds(.1013, .8843, .3017, .0272),
      ),
      const ScanTextLine(
        text: '© 1995 Wizards of the Coast, Inc. All rights reserved',
        confidence: .5,
        bounds: ScanBounds(.0991, .9114, .5065, .0181),
      ),
    ]);
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(crop);
    expect(result.candidates.first.card.id, 'ice');
    expect(result.candidates.first.score, result.candidates.last.score);
    expect(
      result.candidates.first.evidence,
      isNot(contains(ScanEvidence.illustratorMatch)),
    );
    expect(
      result.candidates.first.evidence,
      isNot(contains(ScanEvidence.copyrightYearMatch)),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(verifiedHistoricalBodyIdentity(crop, result), isNull);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    for (final String text in <String>[
      'Phil Foglio',
      'Illus. Pete Venters blue',
      '© not1995',
    ]) {
      final ScanResolution malformed = await ScanResolver(catalog: catalog)
          .resolve(
            _crop(<ScanTextLine>[
              _line('Circle of Protection: Blue', .04),
              ScanTextLine(
                text: text,
                confidence: .5,
                bounds: const ScanBounds(.1, .90, .35, .03),
              ),
            ]),
          );
      expect(malformed.candidates.first.card.id, 'eight', reason: text);
      expect(
        malformed.candidates.first.evidence,
        isNot(contains(ScanEvidence.illustratorMatch)),
      );
    }
  });

  test('fuzzy title with actual four-keyword rules expands printings and keeps weak artist ranking separate from confirmation', () async {
    const String rules =
        '{1}: The next time a blue source of your choice would deal damage to you this turn, prevent that damage.';
    final _Card representative = _Card(
      'eight',
      'Circle of Protection: Blue',
      set: '8ed',
      collectorNumber: '11',
      artist: 'Greg Hildebrandt & Tim Hildebrandt',
      releasedAt: DateTime(2003),
      typeLine: 'Enchantment',
      oracleText: rules,
    );
    final _Card ice = _Card(
      'ice',
      'Circle of Protection: Blue',
      set: 'ice',
      collectorNumber: '13',
      artist: 'Pete Venters',
      releasedAt: DateTime(1995),
      typeLine: 'Enchantment',
      oracleText: rules,
    );
    final _Catalog catalog = _Catalog()
      ..keywordCards = <MtgCard>[representative]
      ..namedCards['Circle of Protection: Blue'] = <MtgCard>[
        representative,
        ice,
      ];
    final ScanCrop crop = _crop(<ScanTextLine>[
      const ScanTextLine(
        text: 'Crele of Proceerion: Blue',
        confidence: .5,
        bounds: ScanBounds(.0948, .0419, .5647, .0348),
      ),
      _line('1; Prevent all damage against you', .6422),
      _line('from one blue source. If a source', .6746),
      _line('deals damage to you more than', .7026),
      _line('once in a turn, you may pay. 1', .7370),
      _line('each time to prévent the damage,', .7636),
      const ScanTextLine(
        text: 'Illus. Pete Venters',
        confidence: .5,
        bounds: ScanBounds(.1013, .8843, .3017, .0272),
      ),
      const ScanTextLine(
        text: '© 1995 Wizards of the Coast, Inc. All rights reserved',
        confidence: .5,
        bounds: ScanBounds(.0991, .9114, .5065, .0181),
      ),
    ]);
    final ScanResolver resolver = ScanResolver(catalog: catalog);
    final ScanResolution result = await resolver.resolve(crop);
    expect(
      result.candidates.map((ScanCandidate value) => value.card.id),
      <String>['ice', 'eight'],
    );
    expect(
      catalog.calls.where(
        (String call) =>
            call == 'printings:Circle of Protection: Blue/null/null/1',
      ),
      hasLength(1),
    );
    expect(
      result.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.fuzzyName,
        ScanEvidence.rulesKeywordMatch,
      ]),
    );
    expect(
      result.candidates.first.evidence,
      isNot(contains(ScanEvidence.nameMatch)),
    );
    expect(
      result.candidates.first.evidence,
      isNot(contains(ScanEvidence.illustratorMatch)),
    );
    expect(
      result.candidates.first.evidence,
      isNot(contains(ScanEvidence.copyrightYearMatch)),
    );
    expect(result.hints.names, <String>['Crele of Proceerion: Blue']);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);

    catalog.calls.clear();
    catalog.namedCards['Circle of Protection: Blue'] = <MtgCard>[
      for (int index = 0; index < 40; index++)
        _Card(
          'print-$index',
          'Circle of Protection: Blue',
          collectorNumber: '$index',
          typeLine: 'Enchantment',
          oracleText: rules,
        ),
    ];
    final ScanResolution bounded = await resolver.resolve(crop);
    expect(bounded.candidates, hasLength(32));
    expect(bounded.hasMore, isTrue);
    expect(bounded.status, ScanResolutionStatus.needsReview);
    expect(
      catalog.calls.where(
        (String call) =>
            call == 'printings:Circle of Protection: Blue/null/null/1',
      ),
      hasLength(1),
    );
  });

  test(
    'artist-only footer or quoted flavor cannot discover a card identity',
    () async {
      final _Catalog catalog = _Catalog();
      for (final List<ScanTextLine> lines in <List<ScanTextLine>>[
        <ScanTextLine>[
          _line('Illus. Phil Foglio', .90),
          _line('© 1995 Wizards of the Coast', .94),
        ],
        <ScanTextLine>[
          _line('"Prevent all damage from a blue source"', .65),
          _line('Illus. Pete Venters', .90),
          _line('© 1995 Wizards of the Coast', .94),
        ],
      ]) {
        final ScanResolution result = await ScanResolver(catalog: catalog)
            .resolve(_crop(lines));
        expect(result.status, ScanResolutionStatus.noMatch);
        expect(result.candidates, isEmpty);
        expect(catalog.calls, isEmpty);
      }
    },
  );
  test('actual titleless live self-reference proves identity with literal rules and full artist/year footer only', () async {
    final ScanCrop crop = _phone6LiveNevermore();
    final _Catalog catalog = _Catalog()
      ..namedCards['Nevermore'] = <MtgCard>[_nevermorePrinting()];
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
    ).resolve(crop);
    expect(hasVerifiedLiveBodyLayout(crop), isTrue);
    expect(ScanHints.fromCrop(crop).names, isEmpty);
    expect(ScanHints.observedLiveBodySelfReference(crop), 'Nevermore');
    expect(ScanHints.observedSavedBodySelfReference(crop), isNull);
    expect(result.hints.names, isEmpty);
    expect(
      result.candidates.single.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.typeLineMatch,
        ScanEvidence.rulesTextMatch,
        ScanEvidence.illustratorMatch,
        ScanEvidence.copyrightYearMatch,
      ]),
    );
    expect(
      result.candidates.single.evidence,
      isNot(contains(ScanEvidence.nameMatch)),
    );
    expect(result.historicalBodyIdentityProof?.name, 'Nevermore');
    expect(verifiedLiveHistoricalBodyIdentity(crop, result), 'Nevermore');
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(catalog.calls, <String>['printings:Nevermore/null/null/1']);
    final List<ScanTextLine> repeated = <ScanTextLine>[
      ...crop.lines,
      crop.lines.first,
      crop.lines.first,
    ];
    expect(
      ScanHints.observedLiveBodySelfReference(_changedCrop(crop, repeated)),
      'Nevermore',
    );
    final ScanResolution stale = ScanResolution(
      candidates: result.candidates,
      hints: result.hints,
      status: result.status,
      historicalBodyIdentityProof: result.historicalBodyIdentityProof,
    );
    final List<ScanTextLine> changed = List<ScanTextLine>.of(crop.lines);
    changed[1] = _changedLine(
      changed[1],
      'As Another Enchantment enters the battlefield,',
    );
    expect(
      verifiedLiveHistoricalBodyIdentity(_changedCrop(crop, changed), stale),
      isNull,
    );
    final ScanCrop changedQuote = _changedCrop(
      crop,
      <ScanTextLine>[
        for (final ScanTextLine line in crop.lines)
          if (line.text == 'thoughts, words, and deeds are')
            _changedLine(line, 'Destroy target nonartifact creature.')
          else
            line,
      ],
    );
    expect(ScanHints.fromCrop(changedQuote).rulesText, result.hints.rulesText);
    expect(
      ScanHints.fromCrop(changedQuote).postQuoteText,
      contains('Destroy target nonartifact creature.'),
    );
    expect(verifiedLiveHistoricalBodyIdentity(changedQuote, stale), isNull);
  });

  test('live literal self-reference rejects flavor alternatives missing footer mixed rows and contradictory catalog evidence', () async {
    for (final String variant in <String>[
      'quote',
      'alternativeOnly',
      'confidence',
      'glyph',
      'oneBody',
      'mixedColumns',
      'wrongBody',
      'wrongType',
      'missingArtist',
      'wrongArtist',
      'missingYear',
      'wrongYear',
      'ambiguous',
      'incomplete',
      'overBudget',
      'manual',
      'savedPixels',
    ]) {
      final ScanCrop actual = _phone6LiveNevermore();
      final List<ScanTextLine> lines = List<ScanTextLine>.of(actual.lines);
      if (variant == 'quote') {
        lines[1] = _changedLine(
          lines[1],
          '"As Nevermore enters the battlefield,"',
        );
      }
      if (variant == 'alternativeOnly') {
        final ScanTextLine row = lines[1];
        lines[1] = ScanTextLine(
          text: 'As this enters the battlefield,',
          confidence: row.confidence,
          alternatives: <String>[row.text],
          glyphHeight: row.glyphHeight,
          bounds: row.bounds,
        );
      }
      if (variant == 'confidence') {
        lines[1] = _changedLine(lines[1], lines[1].text, confidence: .89);
      }
      if (variant == 'glyph') {
        lines[1] = ScanTextLine(
          text: lines[1].text,
          confidence: 1,
          bounds: lines[1].bounds,
        );
      }
      if (variant == 'oneBody') {
        lines.removeWhere(
          (ScanTextLine row) =>
              row.text == 'name a nonland card.' ||
              row.text == "The named card can't be cast.",
        );
      }
      if (variant == 'mixedColumns') {
        lines[5] = _changedLine(
          lines[5],
          lines[5].text,
          bounds: ScanBounds(.80, .7367, .19, .05),
        );
      }
      if (variant == 'wrongBody') {
        lines[5] = _changedLine(
          lines[5],
          'Destroy target nonartifact creature.',
        );
      }
      if (variant == 'wrongType') lines[0] = _changedLine(lines[0], 'Sorcery');
      if (variant == 'missingArtist') {
        lines.removeWhere((ScanTextLine row) => row.text.contains('Jason'));
      }
      if (variant == 'wrongArtist') {
        lines[9] = _changedLine(lines[9], '~Pete Venters');
      }
      if (variant == 'missingYear') {
        lines.removeWhere((ScanTextLine row) => row.text.contains('2011'));
      }
      if (variant == 'wrongYear') {
        for (int index = 0; index < lines.length; index++) {
          lines[index] = _changedLine(
            lines[index],
            lines[index].text.replaceAll('2011', '2012'),
          );
        }
      }
      final ScanCrop crop = ScanCrop(
        imagePath: variant == 'savedPixels' ? '/local/saved.jpg' : '',
        width: actual.width,
        height: actual.height,
        rectified: actual.rectified,
        sourceCorners: actual.sourceCorners,
        warnings: actual.warnings,
        lines: lines,
      );
      final _Card expected = _nevermorePrinting();
      final _Catalog catalog = _Catalog()
        ..namedCards['Nevermore'] = <MtgCard>[
          expected,
          if (variant == 'ambiguous')
            _Card(
              'other',
              'Other enchantment',
              typeLine: expected.typeLine,
              artist: expected.artist,
              releasedAt: expected.releasedAt,
              oracleText: expected.oracleText,
              flavorText: expected.flavorText,
            ),
          if (variant == 'overBudget') ...List<MtgCard>.filled(96, expected),
        ]
        ..namedHasMore['Nevermore'] = variant == 'incomplete';
      final ScanResolution result = await ScanResolver(
        catalog: catalog,
        artwork: _Artwork(),
      ).resolve(crop, name: variant == 'manual' ? 'Manual title' : null);
      expect(
        verifiedLiveHistoricalBodyIdentity(crop, result),
        isNull,
        reason: variant,
      );
      expect(result.historicalBodyIdentityProof, isNull, reason: variant);
      expect(
        result.hints.names,
        variant == 'manual' ? <String>['Manual title'] : isEmpty,
        reason: variant,
      );
      expect(hasExactPrintingEvidence(crop, result), isFalse, reason: variant);
    }
  });

  test('actual titleless repaired photo resolves its literal self-name only with exact artist and copyright end year', () async {
    final ScanCrop crop = _final5TitlelessNevermore();
    final _Catalog catalog = _Catalog()
      ..namedCards['Nevermore'] = <MtgCard>[_nevermorePrinting()];
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
    ).resolve(crop);
    expect(ScanHints.fromCrop(crop).names, isEmpty);
    expect(ScanHints.observedBodySelfReference(crop), isNull);
    expect(ScanHints.observedSavedBodySelfReference(crop), 'Nevermore');
    expect(crop.lines[1].bounds.height, greaterThan(.06));
    expect(crop.lines[1].glyphHeight, lessThan(.05));
    expect(result.candidates.single.card.name, 'Nevermore');
    expect(
      result.candidates.single.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
        ScanEvidence.rulesTextMatch,
        ScanEvidence.illustratorMatch,
        ScanEvidence.copyrightYearMatch,
      ]),
    );
    expect(verifiedSavedSelfReferenceIdentity(crop, result), 'Nevermore');
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(catalog.calls.first, 'printings:Nevermore/null/null/1');
    expect(crop.lines.first.text, 'Enchantment');
  });

  test('titleless self-reference rejects desk, quote, missing real glyph, wrong body, type, artist and year', () async {
    for (final String variant in <String>[
      'desk',
      'quote',
      'glyph',
      'oneBody',
      'wrongBody',
      'wrongType',
      'wrongArtist',
      'wrongYear',
      'copyrightStart',
      'manual',
    ]) {
      final ScanCrop actual = _final5TitlelessNevermore();
      final List<ScanTextLine> lines = List<ScanTextLine>.of(actual.lines);
      if (variant == 'quote') {
        lines[1] = _changedLine(
          lines[1],
          '"As Nevermore enters the battlefield,"',
        );
      }
      if (variant == 'glyph') {
        lines[1] = ScanTextLine(
          text: lines[1].text,
          confidence: lines[1].confidence,
          bounds: lines[1].bounds,
        );
      }
      if (variant == 'oneBody') lines.removeRange(2, 4);
      if (variant == 'wrongBody') {
        lines[3] = _changedLine(
          lines[3],
          'Destroy target nonartifact creature.',
        );
      }
      if (variant == 'wrongType') lines[0] = _changedLine(lines[0], 'Sorcery');
      if (variant == 'wrongArtist') {
        lines[7] = _changedLine(lines[7], 'Pete Venters');
      }
      if (variant == 'wrongYear') {
        lines[8] = _changedLine(
          lines[8],
          lines[8].text.replaceAll('2011', '2012'),
        );
      }
      final ScanCrop crop = _changedCrop(
        actual,
        lines,
        rectified: variant == 'desk' ? false : null,
      );
      final _Card card = variant == 'copyrightStart'
          ? _Card(
              'nevermore',
              'Nevermore',
              typeLine: 'Enchantment',
              artist: 'Jason A. Engle',
              releasedAt: DateTime(1993),
              oracleText: _nevermorePrinting().oracleText,
              flavorText: _nevermorePrinting().flavorText,
            )
          : _nevermorePrinting();
      final _Catalog catalog = _Catalog()
        ..namedCards['Nevermore'] = <MtgCard>[card];
      final ScanResolution result = await ScanResolver(
        catalog: catalog,
        artwork: _Artwork(),
      ).resolve(crop, name: variant == 'manual' ? 'Other card' : null);
      expect(
        verifiedSavedSelfReferenceIdentity(crop, result),
        isNull,
        reason: variant,
      );
      expect(result.candidates, isEmpty, reason: variant);
      expect(result.status, ScanResolutionStatus.noMatch, reason: variant);
    }
  });

  test('titleless self-reference proof cannot survive stale rules, conflicting printing, or competing supported identities', () async {
    final ScanCrop crop = _final5TitlelessNevermore();
    final _Catalog catalog = _Catalog()
      ..namedCards['Nevermore'] = <MtgCard>[_nevermorePrinting()];
    final ScanResolution resolved = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
    ).resolve(crop);
    final List<ScanTextLine> changed = List<ScanTextLine>.of(crop.lines);
    changed[3] = _changedLine(
      changed[3],
      'Destroy target nonartifact creature.',
    );
    expect(
      verifiedSavedSelfReferenceIdentity(_changedCrop(crop, changed), resolved),
      isNull,
    );
    final ScanCrop changedQuote = _changedCrop(
      crop,
      <ScanTextLine>[
        for (final ScanTextLine line in crop.lines)
          if (line.text == 'thoughts, words, and deeds are')
            _changedLine(line, 'Destroy target nonartifact creature.')
          else
            line,
      ],
    );
    expect(ScanHints.fromCrop(changedQuote).rulesText, resolved.hints.rulesText);
    expect(
      ScanHints.fromCrop(changedQuote).postQuoteText,
      contains('Destroy target nonartifact creature.'),
    );
    expect(verifiedSavedSelfReferenceIdentity(changedQuote, resolved), isNull);
    for (final String variant in <String>['printing', 'competing']) {
      final ScanCandidate original = resolved.candidates.single;
      final ScanResolution invalid = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(original.card, <ScanEvidence>{
            ...original.evidence,
            if (variant == 'printing') ScanEvidence.printingMismatch,
          }),
          if (variant == 'competing')
            ScanCandidate(
              _Card(
                'other',
                'Other enchantment',
                artist: 'Jason A. Engle',
                releasedAt: DateTime(2011),
                typeLine: 'Enchantment',
              ),
              original.evidence,
            ),
        ],
        hints: resolved.hints,
        status: ScanResolutionStatus.needsReview,
      );
      expect(
        verifiedSavedSelfReferenceIdentity(crop, invalid),
        isNull,
        reason: variant,
      );
    }
  });

  test('actual clipped title falls back to its literal body self-reference only after every title result contradicts', () async {
    final ScanCrop crop = _final4Nevermore();
    final _Card wrong = _Card(
      'never',
      'Never',
      typeLine: 'Sorcery',
      oracleText: 'Destroy target creature.',
    );
    final _Catalog catalog = _Catalog()
      ..namedCards['Never'] = <MtgCard>[wrong]
      ..namedCards['Nevermore'] = <MtgCard>[_nevermorePrinting()];
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
    ).resolve(crop);
    expect(ScanHints.observedBodySelfReference(crop), 'Nevermore');
    expect(ScanHints.fromCrop(crop).names, <String>['Never']);
    expect(result.hints.names, <String>['Never', 'Nevermore']);
    expect(result.candidates.single.card.name, 'Nevermore');
    expect(result.candidates.single.hasContradiction, isFalse);
    expect(
      result.candidates.single.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
        ScanEvidence.rulesTextMatch,
      ]),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(crop.lines.first.text, 'Never');
    expect(
      catalog.calls.where((String call) => call.startsWith('printings:')),
      <String>[
        'printings:Never/null/null/1',
        'printings:Nevermore/null/null/1',
      ],
    );
  });

  test('literal self-reference cannot override a supported title or a manual query', () async {
    for (final bool manual in <bool>[false, true]) {
      final _Card title = manual
          ? _Card('never', 'Never', oracleText: 'Destroy target creature.')
          : _Card(
              'never',
              'Never',
              typeLine: 'Enchantment',
              oracleText: _nevermorePrinting().oracleText,
              flavorText: _nevermorePrinting().flavorText,
            );
      final _Catalog catalog = _Catalog()
        ..namedCards['Never'] = <MtgCard>[title]
        ..namedCards['Nevermore'] = <MtgCard>[_nevermorePrinting()];
      final ScanResolution result = await ScanResolver(
        catalog: catalog,
        artwork: _Artwork(),
      ).resolve(_final4Nevermore(), name: manual ? 'Never' : null);
      expect(result.candidates.single.card.id, 'never');
      expect(catalog.calls, isNot(contains('printings:Nevermore/null/null/1')));
    }
  });

  test('clipped title resolves from literal self-reference without flavor evidence', () async {
    final ScanCrop actual = _final4Nevermore();
    final ScanCrop crop = _changedCrop(actual, actual.lines.take(5).toList());
    final _Catalog catalog = _Catalog()
      ..namedCards['Never'] = <MtgCard>[
        _Card(
          'never',
          'Never',
          typeLine: 'Sorcery',
          oracleText: 'Destroy target creature.',
        ),
      ]
      ..namedCards['Nevermore'] = <MtgCard>[_nevermorePrinting()];
    final ScanHints observed = ScanHints.fromCrop(crop);
    expect(observed.names, <String>['Never']);
    expect(observed.rulesText, <String>[
      'As Nevermore enters the battlefield,',
      'name a nonland card.',
      "The named card can't be cast.",
    ]);
    expect(ScanResolver.rulesSearchPhrase(observed.rulesText), isNull);
    expect(ScanHints.observedBodySelfReference(crop), 'Nevermore');

    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
    ).resolve(crop);

    expect(result.hints.names, <String>['Never', 'Nevermore']);
    expect(result.candidates.single.card.id, 'nevermore');
    expect(result.candidates.single.hasContradiction, isFalse);
    expect(
      result.candidates.single.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
        ScanEvidence.rulesTextMatch,
      ]),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(catalog.calls, <String>[
      'printings:Never/null/null/1',
      'printings:Nevermore/null/null/1',
    ]);
  });

  test('self-reference without flavor evidence rejects wrong type and contradictory rules', () async {
    final ScanCrop actual = _final4Nevermore();
    final ScanCrop crop = _changedCrop(actual, actual.lines.take(5).toList());
    for (final String variant in <String>['type', 'rules']) {
      final _Catalog catalog = _Catalog()
        ..namedCards['Never'] = <MtgCard>[
          _Card('never', 'Never', oracleText: 'Destroy target creature.'),
        ]
        ..namedCards['Nevermore'] = <MtgCard>[
          _nevermorePrinting(
            type: variant == 'type' ? 'Sorcery' : 'Enchantment',
            rules: variant == 'rules'
                ? 'Destroy target nonartifact creature.'
                : null,
          ),
        ];

      final ScanResolution result = await ScanResolver(
        catalog: catalog,
        artwork: _Artwork(),
      ).resolve(crop);

      expect(result.candidates.single.card.id, 'never', reason: variant);
      expect(
        result.candidates.single.evidence,
        contains(ScanEvidence.rulesTextMismatch),
        reason: variant,
      );
      expect(
        result.candidates.single.hasContradiction,
        isTrue,
        reason: variant,
      );
      expect(result.status, ScanResolutionStatus.needsReview, reason: variant);
      expect(hasExactPrintingEvidence(crop, result), isFalse, reason: variant);
      expect(catalog.calls, <String>[
        'printings:Never/null/null/1',
        'printings:Nevermore/null/null/1',
      ], reason: variant);
    }
  });

  test('body self-reference requires actual card type, independent rules, and a compatible observed title prefix', () {
    final ScanCrop actual = _final4Nevermore();
    for (final String variant in <String>[
      'unrelatedTitle',
      'differentFullTitle',
      'quotedSelf',
      'differentName',
      'desk',
      'noType',
      'noBody',
      'weakBody',
    ]) {
      final List<ScanTextLine> lines = List<ScanTextLine>.of(actual.lines);
      if (variant == 'unrelatedTitle') {
        lines[0] = _changedLine(lines[0], 'Lightning Bolt');
      }
      if (variant == 'differentFullTitle') {
        lines[0] = _changedLine(lines[0], 'Never // Return');
      }
      if (variant == 'quotedSelf') {
        lines[2] = _changedLine(
          lines[2],
          '"As Nevermore enters the battlefield,"',
        );
      }
      if (variant == 'differentName') {
        lines[2] = _changedLine(
          lines[2],
          'As Mirkwood Bats enters the battlefield,',
        );
      }
      if (variant == 'noType') lines.removeAt(1);
      if (variant == 'noBody') lines.removeRange(2, 5);
      if (variant == 'weakBody') {
        lines[3] = _changedLine(lines[3], lines[3].text, confidence: .60);
      }
      final ScanCrop crop = _changedCrop(
        actual,
        lines,
        rectified: variant == 'desk' ? false : null,
      );
      expect(
        ScanHints.observedBodySelfReference(crop),
        isNull,
        reason: variant,
      );
      expect(
        ScanHints.fromCrop(crop).names,
        isNot(contains('Nevermore')),
        reason: variant,
      );
    }
  });

  test(
    'self-reference lookup still rejects wrong type and contradictory rules',
    () async {
      for (final String variant in <String>['type', 'rules']) {
        final _Catalog catalog = _Catalog()
          ..namedCards['Never'] = <MtgCard>[
            _Card('never', 'Never', oracleText: 'Destroy target creature.'),
          ]
          ..namedCards['Nevermore'] = <MtgCard>[
            _nevermorePrinting(
              type: variant == 'type' ? 'Sorcery' : 'Enchantment',
              rules: variant == 'rules'
                  ? 'Destroy target nonartifact creature.'
                  : null,
            ),
          ];
        final ScanResolution result = await ScanResolver(
          catalog: catalog,
          artwork: _Artwork(),
        ).resolve(_final4Nevermore());
        expect(result.candidates.single.card.id, 'never', reason: variant);
        expect(result.candidates.single.hasContradiction, isTrue);
        expect(result.status, ScanResolutionStatus.needsReview);
      }
    },
  );

  test('actual adjacent split illustrator credit supports historical identity without fuzzy artist recovery', () async {
    final _Card modern = _bodyPrinting('modern');
    final _Card ice = _bodyPrinting(
      'ice',
      set: 'ice',
      artist: 'Pete Venters',
      year: 1995,
    );
    final ScanCrop crop = _final4Circle();
    final _Catalog catalog = _Catalog()
      ..keywordCards = <MtgCard>[modern]
      ..namedCards[modern.name] = <MtgCard>[modern, ice];
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
    ).resolve(crop);
    expect(result.candidates.first.card.id, 'ice');
    expect(
      result.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.illustratorMatch,
        ScanEvidence.copyrightYearMatch,
      ]),
    );
    expect(result.historicalBodyIdentityProof, isNotNull);
    expect(verifiedHistoricalBodyIdentity(crop, result), modern.name);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(
      crop.lines,
      contains(
        isA<ScanTextLine>().having(
          (ScanTextLine line) => line.text,
          'text',
          'Ilfus. Pete Venters',
        ),
      ),
    );
  });

  test('split artist fragments require adjacent same-row high-confidence literal footer text', () async {
    final _Card ice = _bodyPrinting(
      'ice',
      set: 'ice',
      artist: 'Pete Venters',
      year: 1995,
    );
    for (final String variant in <String>[
      'missing',
      'gap',
      'row',
      'weak',
      'wrongSurname',
    ]) {
      final ScanCrop actual = _final4Circle();
      final List<ScanTextLine> lines = List<ScanTextLine>.of(actual.lines);
      final int index = lines.indexWhere(
        (ScanTextLine line) => line.text == 'Venters',
      );
      final ScanTextLine surname = lines[index];
      if (variant == 'missing') lines.removeAt(index);
      if (variant == 'gap') {
        lines[index] = _changedLine(
          surname,
          surname.text,
          bounds: ScanBounds(
            .50,
            surname.bounds.y,
            surname.bounds.width,
            surname.bounds.height,
          ),
        );
      }
      if (variant == 'row') {
        lines[index] = _changedLine(
          surname,
          surname.text,
          bounds: ScanBounds(
            surname.bounds.x,
            .88,
            surname.bounds.width,
            surname.bounds.height,
          ),
        );
      }
      if (variant == 'weak') {
        lines[index] = _changedLine(surname, surname.text, confidence: .50);
      }
      if (variant == 'wrongSurname') {
        lines[index] = _changedLine(surname, 'Willich');
      }
      final ScanCrop crop = _changedCrop(actual, lines);
      final _Catalog catalog = _Catalog()
        ..keywordCards = <MtgCard>[ice]
        ..namedCards[ice.name] = <MtgCard>[ice];
      final ScanResolution result = await ScanResolver(
        catalog: catalog,
        artwork: _Artwork(),
      ).resolve(crop);
      expect(
        result.candidates.single.evidence,
        isNot(contains(ScanEvidence.illustratorMatch)),
        reason: variant,
      );
      expect(result.historicalBodyIdentityProof, isNull, reason: variant);
    }
  });

  test('historical body identity expands representative cards into printings and ranks the observed illustrator and year', () async {
    final _Card modern = _bodyPrinting('modern');
    final _Card ice = _bodyPrinting(
      'ice',
      set: 'ice',
      artist: 'Pete Venters',
      year: 1995,
    );
    final _Card fourth = _bodyPrinting(
      'fourth',
      set: '4ed',
      artist: 'Dameon Willich',
      year: 1995,
    );
    final _Card rune = _bodyPrinting('rune', name: 'Rune of Protection: Blue');
    final _Card sphere = _bodyPrinting('sphere', name: 'Sphere of Reason');
    final _Catalog catalog = _Catalog()
      ..keywordCards = <MtgCard>[modern, rune, sphere]
      ..namedCards[modern.name] = <MtgCard>[modern, fourth, ice]
      ..namedCards[rune.name] = <MtgCard>[rune]
      ..namedCards[sphere.name] = <MtgCard>[sphere];
    final _BodyArtwork artwork = _BodyArtwork();
    final ScanCrop crop = _historicalBodyCrop();
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: artwork,
      symbols: _Symbol(),
    ).resolve(crop);
    expect(
      catalog.calls,
      contains('printings:Circle of Protection: Blue/null/null/1'),
    );
    expect(
      catalog.calls.where((String call) => call.startsWith('printings:')),
      hasLength(3),
    );
    expect(result.candidates.first.card.id, 'ice');
    expect(
      result.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.illustratorMatch,
        ScanEvidence.copyrightYearMatch,
      ]),
    );
    expect(result.candidates.first.hasContradiction, isFalse);
    expect(
      result.candidates.map((ScanCandidate candidate) => candidate.card.id),
      containsAll(<String>['modern', 'fourth', 'ice', 'rune', 'sphere']),
    );
    expect(artwork.comparedIds, contains('ice'));
    expect(artwork.bodyFallback, isTrue);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(result.hasMore, isFalse);
  });

  test('actual titleless live type-band read proves one historical identity without a photo or printing confirmation', () async {
    final ScanCrop crop = liveHistoricalScene();
    final _Card ice = _bodyPrinting(
      'ice',
      set: 'ice',
      artist: 'Pete Venters',
      year: 1995,
    );
    final _Catalog catalog = _Catalog()
      ..keywordCards = <MtgCard>[ice]
      ..namedCards[ice.name] = <MtgCard>[ice];
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
    ).resolve(crop);
    expect(crop.imagePath, isEmpty);
    expect(crop.rectified, isFalse);
    expect(hasVerifiedLiveBodyLayout(crop), isTrue);
    expect(result.hints.names, isEmpty);
    expect(result.hints.typeLine, 'enchantment');
    expect(
      result.historicalBodyIdentityProof?.name,
      ice.name,
      reason:
          '${result.candidates.map((ScanCandidate candidate) => candidate.evidence).toList()} ${result.hints.rulesText}',
    );
    expect(verifiedLiveHistoricalBodyIdentity(crop, result), ice.name);
    expect(verifiedHistoricalBodyIdentity(crop, result), isNull);
    expect(
      result.candidates.single.evidence,
      isNot(contains(ScanEvidence.nameMatch)),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    final ScanResolution clipped = ScanResolution(
      candidates: result.candidates,
      hints: result.hints,
      status: result.status,
      hasMore: true,
      historicalBodyIdentityProof: result.historicalBodyIdentityProof,
    );
    expect(verifiedLiveHistoricalBodyIdentity(crop, clipped), ice.name);
    expect(
      verifiedLiveHistoricalBodyIdentity(
        crop,
        ScanResolution(
          candidates: result.candidates,
          hints: result.hints,
          status: result.status,
          hasMore: true,
        ),
      ),
      isNull,
    );
  });

  test('live historical identity rejects missing native layout or exact footer and incomplete discovery', () async {
    final ScanCrop actual = liveHistoricalScene();
    final _Card ice = _bodyPrinting(
      'ice',
      set: 'ice',
      artist: 'Pete Venters',
      year: 1995,
    );
    Future<ScanResolution> resolve(
      ScanCrop crop, {
      bool more = false,
      MtgCard? competing,
    }) {
      final _Catalog catalog = _Catalog()
        ..hasMore = more
        ..keywordCards = <MtgCard>[ice, ?competing]
        ..namedCards[ice.name] = <MtgCard>[ice];
      if (competing != null) {
        catalog.namedCards[competing.name] = <MtgCard>[competing];
      }
      return ScanResolver(catalog: catalog, artwork: _Artwork()).resolve(crop);
    }

    final ScanResolution valid = await resolve(actual);
    for (final String variant in <String>[
      'typeWeak',
      'typeMissing',
      'glyphMissing',
      'glyphNaN',
      'glyphNegative',
      'artistGlyphNaN',
      'yearGlyphNegative',
      'twoRules',
      'artistWrong',
      'artistMissing',
      'artistWeak',
      'yearWrong',
      'yearMissing',
      'yearRange',
      'desk',
      'foreignTitle',
      'quote',
    ]) {
      final List<ScanTextLine> lines = actual.lines
          .where(
            (ScanTextLine line) =>
                !(variant == 'typeMissing' && line.text == 'Enchantment') &&
                !(variant == 'artistMissing' && line.text.contains('Pete')) &&
                !(variant == 'yearMissing' && line.text.contains('©')) &&
                !(variant == 'twoRules' &&
                    line.bounds.y > .65 &&
                    line.bounds.y < .82),
          )
          .map(
            (ScanTextLine line) => ScanTextLine(
              text: variant == 'artistWrong' && line.text.contains('Pete')
                  ? line.text.replaceAll('Venters', 'Venrers')
                  : variant == 'yearWrong' && line.text.contains('©')
                  ? line.text.replaceAll('1995', '1996')
                  : variant == 'yearRange' && line.text.contains('©')
                  ? line.text.replaceAll('1995', '1995-2020')
                  : line.text,
              confidence:
                  ((variant == 'typeWeak' && line.text == 'Enchantment') ||
                      (variant == 'artistWeak' && line.text.contains('Pete')))
                  ? .89
                  : line.confidence,
              bounds: line.bounds,
              glyphHeight:
                  variant == 'glyphMissing' && line.text == 'Enchantment'
                  ? null
                  : ((variant == 'glyphNaN' && line.text == 'Enchantment') ||
                        (variant == 'artistGlyphNaN' &&
                            line.text.contains('Pete')))
                  ? double.nan
                  : ((variant == 'glyphNegative' &&
                            line.text == 'Enchantment') ||
                        (variant == 'yearGlyphNegative' &&
                            line.text.contains('©')))
                  ? -.01
                  : line.glyphHeight,
              alternatives: const <String>[],
            ),
          )
          .toList();
      if (variant == 'foreignTitle') {
        lines.add(
          const ScanTextLine(
            text: 'Lightning Bolt',
            confidence: 1,
            bounds: ScanBounds(.1, .04, .5, .03),
            glyphHeight: .025,
          ),
        );
      }
      if (variant == 'quote') {
        lines.add(
          const ScanTextLine(
            text: '"Prevent all damage against you',
            confidence: 1,
            bounds: ScanBounds(.1, .58, .7, .03),
            glyphHeight: .025,
          ),
        );
      }
      final ScanCrop crop = ScanCrop(
        imagePath: '',
        width: actual.width,
        height: actual.height,
        rectified: false,
        sourceCorners: actual.sourceCorners,
        warnings: variant == 'desk'
            ? const <String>['no_card_rectangle']
            : actual.warnings,
        lines: lines,
      );
      final ScanResolution result = await resolve(crop);
      expect(result.historicalBodyIdentityProof, isNull, reason: variant);
      expect(
        verifiedLiveHistoricalBodyIdentity(crop, valid),
        isNull,
        reason: 'stale $variant',
      );
    }
    expect(
      (await resolve(actual, more: true)).historicalBodyIdentityProof,
      isNull,
    );
    final _Card competing = _bodyPrinting(
      'other',
      name: 'Other Protection',
      artist: 'Pete Venters',
      year: 1995,
    );
    expect(
      (await resolve(actual, competing: competing)).historicalBodyIdentityProof,
      isNull,
    );
    final ScanCrop crossed = ScanCrop(
      imagePath: '',
      width: actual.width,
      height: actual.height,
      rectified: false,
      sourceCorners: <ScanPoint>[
        actual.sourceCorners[0],
        actual.sourceCorners[2],
        actual.sourceCorners[1],
        actual.sourceCorners[3],
      ],
      lines: actual.lines,
      warnings: actual.warnings,
    );
    expect(verifiedLiveHistoricalBodyIdentity(crossed, valid), isNull);
  });

  test('actual fllus footer label preserves exact illustrator proof for a complete historical identity search', () async {
    final ScanCrop actual = ScanCrop.fromMap(
      jsonDecode(
        r'''{"imagePath":"/local/observed-card.jpg","width":2527,"height":3529,"rectified":true,"warnings":["incomplete_card","orientation_ensemble","geometry_adjusted"],"sharpness":0.8725426917589308,"sourceCorners":[{"x":0.551675021648407,"y":0.44282591342926025},{"x":0.8202775120735168,"y":0.44309020042419434},{"x":0.9034780859947205,"y":0.6166174709796906},{"x":0.5225793719291687,"y":0.6095852255821228}],"lines":[{"text":"Enchantment","confidence":1.0,"alternatives":["Enchan ment","Enchantmentt"],"glyphHeight":0.02422433998852669,"bounds":{"x":0.11806962550038695,"y":0.512219675634731,"width":0.2544879913330078,"height":0.03514303364091831}},{"text":"1: Prevent all damage against you","confidence":1.0,"alternatives":["1 : Prevent all damage against you","1 Prevent all damage against you"],"glyphHeight":0.029711688140876175,"bounds":{"x":0.17315962028097112,"y":0.6017819254871224,"width":0.6331245325788667,"height":0.04944749351263722}},{"text":"from one blue source. If a source","confidence":1.0,"alternatives":["from one blue source. If'a source","from on blue source. If a source"],"glyphHeight":0.03290999611264448,"bounds":{"x":0.16159618360200614,"y":0.6362306033660672,"width":0.6322630387318285,"height":0.04337103306065204}},{"text":"deals damage to you more than","confidence":1.0,"alternatives":["deal damage to you more than","deals damage to you more han"],"glyphHeight":0.03200476921963286,"bounds":{"x":0.1653309059038165,"y":0.6666715222803117,"width":0.5920651592785799,"height":0.04375258059407083}},{"text":"once in a turn, you may pay 1","confidence":1.0,"alternatives":["once in a turn, you may pay","once n a turn, you may pay 1"],"glyphHeight":0.028722039018643793,"bounds":{"x":0.16581570890135702,"y":0.7041475790870707,"width":0.5607205161565467,"height":0.035378960239313195}},{"text":"each time to prevent the damage.","confidence":1.0,"alternatives":["each time to prevent the damage","each time to prévent the damage."],"glyphHeight":0.02999727458554288,"bounds":{"x":0.16761221814096824,"y":0.7294049355617733,"width":0.6285396044767355,"height":0.04320516181059664}},{"text":"lllus. Pete Venrers","confidence":1.0,"alternatives":[],"glyphHeight":0.02582327720967544,"bounds":{"x":0.11251894615158636,"y":0.84493984294008,"width":0.2879798502861699,"height":0.03231363044594817}},{"text":"© 1995 Wizards of the Coast, Inc. All rights reserved.","confidence":1.0,"alternatives":[],"glyphHeight":0.018741859510071315,"bounds":{"x":0.11278261576429788,"y":0.8714170641911473,"width":0.49099190627472306,"height":0.02809063965419555}},{"text":"fllus. Pete Venters","confidence":1.0,"alternatives":[],"glyphHeight":0.028091197044451583,"bounds":{"x":0.1129260090120421,"y":0.8434563792482335,"width":0.2871874769818754,"height":0.03093731214415352}}]}''',
      ) as Map<String, Object?>,
    );
    final _Card modern = _bodyPrinting('modern');
    final _Card ice = _Card(
      'ice',
      modern.name,
      set: 'ice',
      collectorNumber: '13',
      artist: 'Pete Venters',
      releasedAt: DateTime(1995, 6, 3),
      typeLine: 'Enchantment',
      oracleText: modern.oracleText,
    );
    final _Catalog catalog = _Catalog()
      ..keywordCards = <MtgCard>[
        modern,
        _bodyPrinting('rune', name: 'Rune of Protection: Blue'),
        _bodyPrinting('sphere', name: 'Sphere of Reason'),
      ]
      ..namedCards[modern.name] = <MtgCard>[modern, ice];
    Future<ScanResolution> resolve(ScanCrop crop) => ScanResolver(
      catalog: catalog,
      artwork: _BodyArtwork(),
      symbols: _Symbol(),
    ).resolve(crop);
    final ScanResolution result = await resolve(actual);
    expect(result.candidates.first.card.id, 'ice');
    expect(
      result.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.illustratorMatch,
        ScanEvidence.copyrightYearMatch,
        ScanEvidence.rulesKeywordMatch,
        ScanEvidence.typeLineMatch,
      ]),
    );
    expect(result.historicalBodyIdentityProof?.name, modern.name);
    expect(verifiedHistoricalBodyIdentity(actual, result), modern.name);
    expect(result.hints.rulesText, isNot(contains('fllus. Pete Venters')));
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(actual, result), isFalse);
    final ScanTextLine footer = actual.lines.singleWhere(
      (ScanTextLine line) => line.text == 'fllus. Pete Venters',
    );
    for (final ScanTextLine invalid in <ScanTextLine>[
      ScanTextLine(
        text: 'fllus. Pete Venters',
        confidence: footer.confidence,
        glyphHeight: footer.glyphHeight,
        bounds: ScanBounds(
          footer.bounds.x,
          .4,
          footer.bounds.width,
          footer.bounds.height,
        ),
      ),
      ScanTextLine(
        text: 'Pete Venters',
        confidence: footer.confidence,
        glyphHeight: footer.glyphHeight,
        bounds: footer.bounds,
      ),
      ScanTextLine(
        text: 'fllus. Pete Venrers',
        confidence: footer.confidence,
        glyphHeight: footer.glyphHeight,
        bounds: footer.bounds,
      ),
      ScanTextLine(
        text: 'fllus. Pete Venters',
        confidence: .8,
        glyphHeight: footer.glyphHeight,
        bounds: footer.bounds,
      ),
      ScanTextLine(
        text: 'fllus. Pete Venters',
        confidence: footer.confidence,
        glyphHeight: footer.glyphHeight,
        bounds: ScanBounds(
          footer.bounds.x,
          footer.bounds.y,
          footer.bounds.width,
          .08,
        ),
      ),
      ScanTextLine(
        text: 'flus. Pete Venters',
        confidence: footer.confidence,
        glyphHeight: footer.glyphHeight,
        bounds: footer.bounds,
      ),
    ]) {
      final ScanCrop unsupported = ScanCrop(
        imagePath: actual.imagePath,
        width: actual.width,
        height: actual.height,
        rectified: actual.rectified,
        sourceCorners: actual.sourceCorners,
        warnings: actual.warnings,
        lines: <ScanTextLine>[
          ...actual.lines.where(
            (ScanTextLine line) => !line.text.contains('Pete'),
          ),
          invalid,
        ],
      );
      final ScanResolution negative = await resolve(unsupported);
      expect(
        negative.candidates.every(
          (ScanCandidate candidate) =>
              !candidate.evidence.contains(ScanEvidence.illustratorMatch),
        ),
        isTrue,
        reason: invalid.text,
      );
      expect(verifiedHistoricalBodyIdentity(unsupported, negative), isNull);
      expect(hasExactPrintingEvidence(unsupported, negative), isFalse);
    }
  });

  test('actual raised illustrator credits cannot become contradictory joined rules and block historical printings', () async {
    final ScanCrop crop = ScanCrop.fromMap(
      jsonDecode(
        r'''{"imagePath":"/local/observed-card.jpg","width":2553,"height":3566,"rectified":true,"warnings":["incomplete_card","orientation_ensemble","geometry_adjusted"],"sharpness":0.881281829907651,"sourceCorners":[{"x":0.5505990386009216,"y":0.44097816944122314},{"x":0.8163083791732788,"y":0.44015634059906006},{"x":0.904419481754303,"y":0.6166709959506989},{"x":0.5260810852050781,"y":0.6090169548988342}],"lines":[{"text":"Enchantment","confidence":1.0,"alternatives":["Enchartment","Encharment"],"glyphHeight":0.023502132309808882,"bounds":{"x":0.11699917171774883,"y":0.522792255989652,"width":0.25697906183468333,"height":0.02888761125651218}},{"text":"1: Prevent all damage against you","confidence":1.0,"alternatives":["1 : Prevent all damage against you","1. Prevent all damage against you"],"glyphHeight":0.027927325225062274,"bounds":{"x":0.17129813340634983,"y":0.6082492529619374,"width":0.6349165639376958,"height":0.04924457526514514}},{"text":"from one blue source. If a source","confidence":1.0,"alternatives":["from on blue source. If a source","from one blue source If a source"],"glyphHeight":0.03009528839267206,"bounds":{"x":0.16150444585031828,"y":0.6421117246222513,"width":0.6323484511886991,"height":0.040464224737812415}},{"text":"deals damage to you more than","confidence":1.0,"alternatives":["deal damage to you more than","deals damage to you more han"],"glyphHeight":0.029588707138962958,"bounds":{"x":0.1653765554266376,"y":0.6725697036024553,"width":0.5919004961579875,"height":0.04119824694570906}},{"text":"once in a turn, you may pay 1","confidence":1.0,"alternatives":["once in a turn, you may pay","once in a turn you may pay 1"],"glyphHeight":0.028735834714011668,"bounds":{"x":0.16388696316458898,"y":0.7101414151509134,"width":0.5625569247228612,"height":0.03374712586202322}},{"text":"each time to prévent the damage.","confidence":1.0,"alternatives":["each time to prévent the damage","each time to préven the damage."],"glyphHeight":0.030037321389518146,"bounds":{"x":0.16547243579527274,"y":0.7337825769577281,"width":0.6285854928084622,"height":0.0430929897477369}},{"text":"flus. Pete Venrers","confidence":1.0,"alternatives":[],"glyphHeight":0.025516451598614955,"bounds":{"x":0.10701642166427576,"y":0.849577191166504,"width":0.2902907548514585,"height":0.029355930791837036}},{"text":"© 1995 Wizards of the Coast, Inc. All rights reserved.","confidence":1.0,"alternatives":[],"glyphHeight":0.0191387871632179,"bounds":{"x":0.10707433218882514,"y":0.8756036113355644,"width":0.4965712772091573,"height":0.02703294700551254}},{"text":"lllus. Pete Venters","confidence":1.0,"alternatives":[],"glyphHeight":0.02668404973073016,"bounds":{"x":0.10641421156157925,"y":0.8476946733311486,"width":0.2907505467426346,"height":0.02896553966486566}}]}''',
      ) as Map<String, Object?>,
    );
    final _Card modern = _bodyPrinting('modern');
    final _Card ice = _Card(
      'ice',
      modern.name,
      set: 'ice',
      collectorNumber: '13',
      artist: 'Pete Venters',
      releasedAt: DateTime(1995, 6, 3),
      typeLine: 'Enchantment',
      oracleText: modern.oracleText,
    );
    final _Catalog catalog = _Catalog()
      ..keywordCards = <MtgCard>[
        modern,
        _bodyPrinting('rune', name: 'Rune of Protection: Blue'),
        _bodyPrinting('sphere', name: 'Sphere of Reason'),
      ]
      ..namedCards[modern.name] = <MtgCard>[modern, ice];
    final _BodyArtwork artwork = _BodyArtwork();
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: artwork,
      symbols: _Symbol(),
    ).resolve(crop);
    expect(result.hints.names, isEmpty);
    expect(
      verifiedHistoricalBodyIdentity(crop, result),
      'Circle of Protection: Blue',
    );
    expect(
      result.historicalBodyIdentityProof?.name,
      'Circle of Protection: Blue',
    );
    expect(result.hints.rulesText, isNot(contains('lllus. Pete Venters')));
    expect(result.hints.rulesText, contains('flus. Pete Venrers'));
    expect(
      catalog.calls,
      contains('printings:Circle of Protection: Blue/null/null/1'),
    );
    expect(result.candidates.first.card.id, 'ice');
    expect(result.candidates.first.card.collectorNumber, '13');
    expect(result.candidates.first.hasContradiction, isFalse);
    expect(
      result.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.rulesKeywordMatch,
        ScanEvidence.typeLineMatch,
        ScanEvidence.illustratorMatch,
        ScanEvidence.copyrightYearMatch,
      ]),
    );
    expect(artwork.comparedIds, containsAll(<String>['modern', 'ice']));
    expect(artwork.bodyFallback, isTrue);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
  });

  test('historical identity requires a unique jointly supported name and complete body evidence', () {
    final ScanCrop crop = _historicalBodyCrop();
    final _Card ice = _bodyPrinting('ice', artist: 'Pete Venters', year: 1995);
    const Set<ScanEvidence> evidence = <ScanEvidence>{
      ScanEvidence.rulesKeywordMatch,
      ScanEvidence.typeLineMatch,
      ScanEvidence.illustratorMatch,
      ScanEvidence.copyrightYearMatch,
    };
    ScanResolution resolution(
      List<ScanCandidate> candidates, {
      bool hasMore = false,
      ScanResolutionStatus status = ScanResolutionStatus.needsReview,
    }) => ScanResolution(
      candidates: candidates,
      hints: ScanHints.fromCrop(crop),
      status: status,
      hasMore: hasMore,
    );
    final ScanCandidate supported = ScanCandidate(ice, evidence);
    final ScanCandidate unrelated = ScanCandidate(
      _bodyPrinting('rune', name: 'Rune of Protection: Blue'),
      const <ScanEvidence>{
        ScanEvidence.rulesKeywordMatch,
        ScanEvidence.typeLineMatch,
      },
    );
    final ScanResolution positive = resolution(<ScanCandidate>[
      unrelated,
      supported,
    ]);
    expect(verifiedHistoricalBodyIdentity(crop, positive), ice.name);
    expect(positive.candidates.first.card.id, 'rune');
    expect(positive.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, positive), isFalse);
    expect(
      verifiedHistoricalBodyIdentity(
        crop,
        resolution(<ScanCandidate>[
          supported,
          ScanCandidate(
            _bodyPrinting('variant', name: 'circle of protection blue'),
            evidence,
          ),
        ]),
      ),
      ice.name,
    );
    expect(
      verifiedHistoricalBodyIdentity(
        crop,
        resolution(<ScanCandidate>[
          supported,
          ScanCandidate(
            _bodyPrinting(
              'other',
              name: 'Rune of Protection: Blue',
              artist: 'Pete Venters',
              year: 1995,
            ),
            evidence,
          ),
        ]),
      ),
      isNull,
    );
    for (final ScanEvidence missing in evidence) {
      expect(
        verifiedHistoricalBodyIdentity(
          crop,
          resolution(<ScanCandidate>[
            ScanCandidate(ice, <ScanEvidence>{...evidence}..remove(missing)),
          ]),
        ),
        isNull,
        reason: missing.name,
      );
    }
    expect(
      verifiedHistoricalBodyIdentity(
        crop,
        resolution(<ScanCandidate>[
          ScanCandidate(ice, <ScanEvidence>{
            ...evidence,
            ScanEvidence.rulesTextMismatch,
          }),
        ]),
      ),
      isNull,
    );
    expect(
      verifiedHistoricalBodyIdentity(
        crop,
        resolution(<ScanCandidate>[supported], hasMore: true),
      ),
      isNull,
    );
    expect(
      verifiedHistoricalBodyIdentity(
        crop,
        resolution(<ScanCandidate>[
          supported,
        ], status: ScanResolutionStatus.noMatch),
      ),
      isNull,
    );
    for (final String condition in <String>[
      'live',
      'missingRepair',
      'missingType',
      'fewKeywords',
    ]) {
      final ScanCrop changed = ScanCrop(
        imagePath: condition == 'live' ? '' : crop.imagePath,
        width: crop.width,
        height: crop.height,
        rectified: crop.rectified,
        sourceCorners: crop.sourceCorners,
        warnings: condition == 'missingRepair'
            ? const <String>['geometry_adjusted']
            : crop.warnings,
        lines: crop.lines
            .where(
              (ScanTextLine line) =>
                  condition != 'missingType' || line.text != 'Enchantment',
            )
            .map(
              (ScanTextLine line) => ScanTextLine(
                text: condition == 'fewKeywords'
                    ? line.text.replaceAll('blue', '')
                    : line.text,
                confidence: line.confidence,
                bounds: line.bounds,
                glyphHeight: line.glyphHeight,
                alternatives: line.alternatives,
              ),
            )
            .toList(),
      );
      expect(
        verifiedHistoricalBodyIdentity(changed, positive),
        isNull,
        reason: condition,
      );
    }
  });

  test('recognized lower artist credit is excluded while incompatible gameplay remains contradictory', () async {
    final _Card blue = _bodyPrinting('blue');
    final _Catalog catalog = _Catalog()..keywordCards = <MtgCard>[blue];
    final ScanCrop crop = _historicalBodyCrop(
      footer: <ScanTextLine>[
        _line('Illus. Jason A. Engle', .835),
        _line('Prevent damage from one red source.', .805),
      ],
    );
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: _BodyArtwork(),
      symbols: _Symbol(),
    ).resolve(crop);
    expect(result.hints.rulesText, isNot(contains('Illus. Jason A. Engle')));
    expect(
      result.hints.rulesText,
      contains('Prevent damage from one red source.'),
    );
    expect(result.candidates.single.hasContradiction, isTrue);
    expect(
      result.candidates.single.evidence,
      contains(ScanEvidence.rulesTextMismatch),
    );
    expect(
      catalog.calls.any((String call) => call.startsWith('printings:')),
      isFalse,
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
  });

  test('complete historical identity survives clipped printing choices but rejects hidden competing identities and stale body', () async {
    final _Card representative = _bodyPrinting(
      'modern',
      artist: 'Pete Venters',
      year: 1995,
    );
    final List<MtgCard> editions = <MtgCard>[
      for (int index = 0; index < 4; index++)
        _bodyPrinting('old-$index', artist: 'Pete Venters', year: 1995),
    ];
    final _Catalog catalog = _Catalog()
      ..keywordCards = <MtgCard>[representative]
      ..namedCards[representative.name] = editions;
    final ScanCrop crop = _historicalBodyCrop();
    final ScanResolution full = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
      symbols: _Symbol(),
    ).resolve(crop);
    final HistoricalBodyIdentityProof proof = full.historicalBodyIdentityProof!;
    expect(proof.name, representative.name);
    expect(full.candidates, hasLength(4));
    expect(full.hasMore, isFalse);
    ScanResolution clip(
      ScanResolution result, {
      List<ScanCandidate>? candidates,
      HistoricalBodyIdentityProof? identity,
    }) => ScanResolution(
      candidates: candidates ?? result.candidates.take(3).toList(),
      hints: result.hints,
      status: result.status,
      hasMore: true,
      historicalBodyIdentityProof:
          identity ?? result.historicalBodyIdentityProof,
    );
    final ScanResolution clipped = clip(full);
    expect(verifiedHistoricalBodyIdentity(crop, clipped), representative.name);
    expect(clipped.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, clipped), isFalse);
    expect(
      verifiedHistoricalBodyIdentity(
        crop,
        clip(
          full,
          candidates: full.candidates
              .map(
                (ScanCandidate candidate) => ScanCandidate(
                  candidate.card,
                  <ScanEvidence>{...candidate.evidence}
                    ..remove(ScanEvidence.illustratorMatch),
                ),
              )
              .toList(),
        ),
      ),
      isNull,
    );
    expect(
      verifiedHistoricalBodyIdentity(
        crop,
        clip(
          full,
          identity: HistoricalBodyIdentityProof(
            name: 'Other identity',
            bodySignature: proof.bodySignature,
          ),
        ),
      ),
      isNull,
    );
    final ScanCrop stale = _historicalBodyCrop(
      footer: <ScanTextLine>[
        _line('Illus. Pete Venters', .919),
        _line('© 1996 Wizards of the Coast', .950),
      ],
    );
    expect(verifiedHistoricalBodyIdentity(stale, clipped), isNull);
    final ScanCrop changedBody = ScanCrop(
      imagePath: crop.imagePath,
      width: crop.width,
      height: crop.height,
      rectified: crop.rectified,
      sourceCorners: crop.sourceCorners,
      warnings: crop.warnings,
      lines: crop.lines
          .map(
            (ScanTextLine line) => ScanTextLine(
              text: line.text.replaceAll('blue', 'red'),
              confidence: line.confidence,
              bounds: line.bounds,
              glyphHeight: line.glyphHeight,
              alternatives: line.alternatives,
            ),
          )
          .toList(),
    );
    expect(verifiedHistoricalBodyIdentity(changedBody, clipped), isNull);
    final ScanCrop invalid = ScanCrop(
      imagePath: '',
      width: crop.width,
      height: crop.height,
      rectified: crop.rectified,
      sourceCorners: crop.sourceCorners,
      warnings: crop.warnings,
      lines: crop.lines,
    );
    expect(verifiedHistoricalBodyIdentity(invalid, clipped), isNull);
    final _Card rival = _bodyPrinting(
      'rival',
      name: 'Rune of Protection: Blue',
      artist: 'Pete Venters',
      year: 1995,
    );
    catalog.keywordCards = <MtgCard>[representative, rival];
    catalog.namedCards[rival.name] = <MtgCard>[rival];
    final ScanResolution ambiguous = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
      symbols: _Symbol(),
    ).resolve(crop);
    expect(ambiguous.candidates, hasLength(5));
    expect(
      ambiguous.candidates
          .take(3)
          .every(
            (ScanCandidate candidate) =>
                candidate.card.name == representative.name,
          ),
      isTrue,
    );
    expect(ambiguous.historicalBodyIdentityProof, isNull);
    expect(verifiedHistoricalBodyIdentity(crop, clip(ambiguous)), isNull);
  });

  test('historical proof rejects real discovery and printing truncation, expansion failure and caps', () async {
    final _Card known = _bodyPrinting(
      'known',
      artist: 'Pete Venters',
      year: 1995,
    );
    for (final String condition in <String>[
      'discoveryPage',
      'printingPage',
      'printingCap',
      'identityCap',
      'failure',
    ]) {
      final _Catalog catalog = _Catalog()
        ..keywordCards = <MtgCard>[known]
        ..namedCards[known.name] = <MtgCard>[known];
      if (condition == 'discoveryPage') catalog.hasMore = true;
      if (condition == 'printingPage') catalog.namedHasMore[known.name] = true;
      if (condition == 'failure') {
        catalog.namedFailures[known.name] = StateError('offline');
      }
      if (condition == 'printingCap') {
        catalog.namedCards[known.name] = <MtgCard>[
          for (int index = 0; index < 33; index++)
            _bodyPrinting('old-$index', artist: 'Pete Venters', year: 1995),
        ];
      }
      if (condition == 'identityCap') {
        catalog.keywordCards = <MtgCard>[
          for (int index = 0; index < 4; index++)
            _bodyPrinting(
              'id-$index',
              name: 'Protection $index',
              artist: 'Pete Venters',
              year: 1995,
            ),
        ];
      }
      final ScanResolution result = await ScanResolver(
        catalog: catalog,
        artwork: _Artwork(),
        symbols: _Symbol(),
      ).resolve(_historicalBodyCrop());
      expect(result.historicalBodyIdentityProof, isNull, reason: condition);
      expect(
        verifiedHistoricalBodyIdentity(_historicalBodyCrop(), result),
        isNull,
        reason: condition,
      );
      expect(
        hasExactPrintingEvidence(_historicalBodyCrop(), result),
        isFalse,
        reason: condition,
      );
    }
  });

  test('shared historical illustrator artwork and copyright never prove a unique printing', () async {
    final _Card one = _bodyPrinting(
      'one',
      artist: 'Pete Venters',
      year: 1995,
      illustration: 'shared',
    );
    final _Card two = _bodyPrinting(
      'two',
      set: 'other',
      artist: 'Pete Venters',
      year: 1995,
      illustration: 'shared',
    );
    final _Catalog catalog = _Catalog()
      ..keywordCards = <MtgCard>[one]
      ..namedCards[one.name] = <MtgCard>[one, two];
    final ScanCrop crop = _historicalBodyCrop();
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
      symbols: _Symbol(),
    ).resolve(crop);
    expect(result.candidates, hasLength(2));
    expect(result.candidates[0].score, result.candidates[1].score);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
  });

  test('actual complementary illustrator observations corroborate the catalog artist for printing review', () async {
    final _Card ice = _Card(
      'ice',
      'Circle of Protection: Blue',
      set: 'ice',
      collectorNumber: '13',
      artist: 'Pete Venters',
      releasedAt: DateTime(1995, 6, 3),
      illustrationId: 'ice-art',
      typeLine: 'Enchantment',
      oracleText: '{1}: The next time a blue source of your choice would deal damage to you this turn, prevent that damage.',
    );
    final _Card modern = _bodyPrinting('modern');
    final _Catalog catalog = _Catalog()
      ..keywordCards = <MtgCard>[modern]
      ..namedCards[modern.name] = <MtgCard>[modern, ice, modern];
    final ScanCrop crop = _historicalBodyCrop(
      footer: const <ScanTextLine>[
        ScanTextLine(
          text: 'Illun Fete Venters',
          confidence: 1,
          glyphHeight: .03278391629654841,
          bounds: ScanBounds(
            .03749999946908602,
            .9257425735669014,
            .3541666666666667,
            .03278391629654837,
          ),
        ),
        ScanTextLine(
          text: 'Illun Pete Venrers',
          confidence: 1,
          glyphHeight: .03160929337974989,
          bounds: ScanBounds(
            .050880856110259304,
            .924018580089061,
            .3369596905178494,
            .03524698766862384,
          ),
        ),
        ScanTextLine(
          text: '© 1995 Wicrands of die Craur, Sac. All digua pesep',
          confidence: 1,
          glyphHeight: .02093543291257928,
          bounds: ScanBounds(
            .049700702532744064,
            .9520048373295686,
            .5297509935167101,
            .025536204331758006,
          ),
        ),
      ],
    );
    final _BodyArtwork artwork = _BodyArtwork();
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: artwork,
      symbols: _Symbol(),
    ).resolve(crop);
    expect(result.candidates, hasLength(2));
    expect(result.candidates.first.card.set, 'ice');
    expect(result.candidates.first.card.collectorNumber, '13');
    expect(
      result.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.illustratorMatch,
        ScanEvidence.copyrightYearMatch,
      ]),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(artwork.comparedIds, containsAll(<String>['ice', 'modern']));
    for (final List<ScanTextLine> footer in <List<ScanTextLine>>[
      <ScanTextLine>[crop.lines[crop.lines.length - 3]],
      <ScanTextLine>[crop.lines[crop.lines.length - 2]],
      <ScanTextLine>[
        _line('Illun Pete Venrers', .92),
        _line('Illus Pete Venrers', .93),
      ],
      <ScanTextLine>[
        _line('Illun Fete Venrers', .92),
        _line('Illun Fete Ventes', .93),
      ],
    ]) {
      final ScanResolution unsupported = await ScanResolver(
        catalog: catalog,
        artwork: _BodyArtwork(),
        symbols: _Symbol(),
      ).resolve(_historicalBodyCrop(footer: footer));
      expect(
        unsupported.candidates.every(
          (ScanCandidate candidate) =>
              !candidate.evidence.contains(ScanEvidence.illustratorMatch),
        ),
        isTrue,
      );
    }
  });

  test('printing expansion keeps textual matches on lookup failure and exposes single-page truncation', () async {
    final _Card representative = _bodyPrinting('modern');
    final _Catalog failed = _Catalog()
      ..keywordCards = <MtgCard>[representative]
      ..namedFailures[representative.name] = StateError(
        'Printing lookup failed',
      );
    final ScanResolution retained = await ScanResolver(
      catalog: failed,
      artwork: _BodyArtwork(),
      symbols: _Symbol(),
    ).resolve(_historicalBodyCrop());
    expect(retained.candidates.single.card.id, representative.id);
    expect(retained.hasMore, isTrue);
    expect(retained.status, ScanResolutionStatus.needsReview);
    final _Catalog truncated = _Catalog()
      ..keywordCards = <MtgCard>[representative]
      ..namedCards[representative.name] = List<MtgCard>.generate(
        40,
        (int index) => _bodyPrinting('print-$index'),
      )
      ..namedHasMore[representative.name] = true;
    final ScanResolution bounded = await ScanResolver(
      catalog: truncated,
      artwork: _BodyArtwork(),
      symbols: _Symbol(),
    ).resolve(_historicalBodyCrop());
    expect(bounded.candidates, hasLength(32));
    expect(bounded.hasMore, isTrue);
    expect(
      truncated.calls.where((String call) => call.startsWith('printings:')),
      <String>['printings:Circle of Protection: Blue/null/null/1'],
    );
  });

  test('printing expansion admits at most three supported identities and 96 candidate printings', () async {
    final List<_Card> representatives = List<_Card>.generate(
      4,
      (int index) =>
          _bodyPrinting('identity-$index', name: 'Protection $index'),
    );
    final _Catalog catalog = _Catalog()..keywordCards = representatives;
    for (final _Card card in representatives) {
      catalog.namedCards[card.name] = List<MtgCard>.generate(
        32,
        (int index) => _bodyPrinting(
          '${card.id}-print-$index',
          name: card.name,
          illustration: 'art-$index',
        ),
      );
    }
    final _BodyArtwork artwork = _BodyArtwork();
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: artwork,
      symbols: _Symbol(),
    ).resolve(_historicalBodyCrop());
    expect(
      catalog.calls.where((String call) => call.startsWith('printings:')),
      hasLength(3),
    );
    expect(result.candidates, hasLength(96));
    expect(
      result.candidates.map((ScanCandidate candidate) => candidate.card.id),
      contains(representatives.last.id),
    );
    expect(artwork.comparedIds.length, lessThanOrEqualTo(96));
    expect(result.hasMore, isTrue);
  });

  test('illustrator and year use bounded observed footer labels and remain positive-only', () async {
    final _Card old = _bodyPrinting('old', artist: 'Pete Venters', year: 1995);
    final _Card newer = _bodyPrinting(
      'newer',
      artist: 'Pete Venters',
      year: 2003,
    );
    final _Catalog catalog = _Catalog()..cards = <MtgCard>[newer, old];
    final ScanCrop valid = _crop(<ScanTextLine>[
      _line('Circle of Protection: Blue', .04),
      _line('Illun. Pete Venters', .92),
      _line('© 1995 Wizards of the Coast', .95),
    ]);
    final ScanResolution ranked = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
      symbols: _Symbol(),
    ).resolve(valid);
    expect(ranked.candidates.first.card.id, 'old');
    expect(
      ranked.candidates.every(
        (ScanCandidate candidate) => !candidate.hasContradiction,
      ),
      isTrue,
    );
    expect(ranked.status, ScanResolutionStatus.needsReview);
    for (final List<ScanTextLine> footer in <List<ScanTextLine>>[
      <ScanTextLine>[_line('Pete Venters', .92), _line('1995', .95)],
      <ScanTextLine>[_line('Illus. Pete Venrers', .92)],
      <ScanTextLine>[_line('Illus. Pete Venters', .62)],
      <ScanTextLine>[
        const ScanTextLine(
          text: 'Illus. Pete Venters',
          confidence: .7,
          bounds: ScanBounds(.1, .92, .7, .025),
        ),
      ],
      <ScanTextLine>[
        const ScanTextLine(
          text: 'Illus. Pete Venters',
          confidence: 1,
          bounds: ScanBounds(.1, .92, .7, .08),
        ),
      ],
    ]) {
      final ScanResolution rejected =
          await ScanResolver(
            catalog: catalog,
            artwork: _Artwork(),
            symbols: _Symbol(),
          ).resolve(
            _crop(<ScanTextLine>[
              _line('Circle of Protection: Blue', .04),
              ...footer,
            ]),
          );
      expect(
        rejected.candidates.every(
          (ScanCandidate candidate) =>
              !candidate.evidence.contains(ScanEvidence.illustratorMatch) &&
              !candidate.evidence.contains(ScanEvidence.copyrightYearMatch),
        ),
        isTrue,
      );
    }
    final ScanResolution corroborated =
        await ScanResolver(
          catalog: catalog,
          artwork: _Artwork(),
          symbols: _Symbol(),
        ).resolve(
          _crop(<ScanTextLine>[
            _line('Circle of Protection: Blue', .04),
            _line('Illus. Pete Venrers', .92),
            _line('Illus. Pete Ventes', .93),
          ]),
        );
    expect(
      corroborated.candidates.every(
        (ScanCandidate candidate) =>
            candidate.evidence.contains(ScanEvidence.illustratorMatch),
      ),
      isTrue,
    );
  });

  test(
    'measured glyph height admits a slanted title without changing its bounds',
    () {
      final ScanTextLine line = ScanTextLine.fromMap(<String, Object>{
        'text': 'Circle of Protection: Blue',
        'confidence': 1.0,
        'glyphHeight': .037616,
        'bounds': <String, double>{
          'x': .03,
          'y': .02,
          'width': .75,
          'height': .118766,
        },
      });
      expect(line.bounds.height, .118766);
      expect(ScanHints.fromCrop(_crop(<ScanTextLine>[line])).names, <String>[
        'Circle of Protection: Blue',
      ]);
      for (final double? measured in <double?>[
        null,
        .09,
        double.nan,
        double.infinity,
        -1,
      ]) {
        final ScanTextLine unproven = ScanTextLine(
          text: line.text,
          confidence: line.confidence,
          bounds: line.bounds,
          glyphHeight: measured,
        );
        expect(
          ScanHints.fromCrop(_crop(<ScanTextLine>[unproven])).names,
          isEmpty,
        );
      }
      final ScanTextLine oversized = ScanTextLine(
        text: line.text,
        confidence: line.confidence,
        bounds: const ScanBounds(.03, .02, .75, .30),
        glyphHeight: .037616,
      );
      expect(
        ScanHints.fromCrop(_crop(<ScanTextLine>[oversized])).names,
        isEmpty,
      );
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();

  test('overlapping alternate type OCR is not treated as rules', () {
    const ScanTextLine type = ScanTextLine(
      text: 'Enchantment',
      confidence: 1,
      bounds: ScanBounds(.052738, .55377905, .300203, .026163),
    );
    const ScanTextLine alternate = ScanTextLine(
      text: 'Enchanument',
      confidence: 1,
      bounds: ScanBounds(.046653, .55377907, .304260, .027616),
    );
    final List<ScanTextLine> lines = <ScanTextLine>[
      _line('Crele of Prorections Blue', .03),
      alternate,
      _line('1; Prevent all damage against you', .656126),
      _line('from one plue source? i a source', .70),
      _line('deals damage to you more than', .729560),
      type,
    ];
    for (final bool reverse in <bool>[false, true]) {
      final ScanHints hints = ScanHints.fromCrop(
        _crop(reverse ? lines.reversed.toList() : lines),
      );
      expect(hints.typeLine, 'enchantment');
      expect(hints.rulesText, <String>[
        '1; Prevent all damage against you',
        'from one plue source? i a source',
        'deals damage to you more than',
      ]);
      expect(
        ScanResolver.rulesSearchKeywords(hints.rulesText),
        isNot(contains('enchanument')),
      );
    }
    final ScanTextLine separate = ScanTextLine(
      text: alternate.text,
      confidence: alternate.confidence,
      bounds: const ScanBounds(.046653, .60, .304260, .027616),
    );
    expect(
      ScanHints.fromCrop(_crop(<ScanTextLine>[type, separate])).rulesText,
      <String>['Enchanument'],
    );
    final ScanTextLine uncertain = ScanTextLine(
      text: type.text,
      confidence: .80,
      bounds: type.bounds,
    );
    expect(
      ScanHints.fromCrop(_crop(<ScanTextLine>[uncertain, alternate])).rulesText,
      <String>['Enchanument'],
    );
  });

  const List<ScanTextLine> slopedNevermore = <ScanTextLine>[
    ScanTextLine(
      text: 'Nevermore',
      confidence: 1,
      bounds: ScanBounds(.04939, .03495, .31091, .05798),
    ),
    ScanTextLine(
      text: 'Enchantment',
      confidence: 1,
      bounds: ScanBounds(.03892, .45371, .38983, .08101),
    ),
    ScanTextLine(
      text: 'As Nevermore enters the bat',
      confidence: 1,
      bounds: ScanBounds(.03376, .52194, .97084, .15667),
    ),
    ScanTextLine(
      text: 'name a nonland card.',
      confidence: 1,
      bounds: ScanBounds(.03066, .55619, .75026, .14027),
    ),
    ScanTextLine(
      text: "The named card can't be ca",
      confidence: 1,
      bounds: ScanBounds(.02351, .61077, .98375, .16267),
    ),
    ScanTextLine(
      text: '«By the law of Avacyn, the fol',
      confidence: 1,
      bounds: ScanBounds(.02871, .67488, .97730, .17914),
    ),
    ScanTextLine(
      text: 'thoughts, words, and deeds are',
      confidence: 1,
      bounds: ScanBounds(.02178, .73022, .98076, .16365),
    ),
    ScanTextLine(
      text: 'henceforth disallowed.""',
      confidence: 1,
      bounds: ScanBounds(.02141, .77305, .75668, .13420),
    ),
    ScanTextLine(
      text: 'BE 2995-201 Wiuto dE',
      confidence: .30,
      bounds: ScanBounds(0, .88660, .49987, .10191),
    ),
  ];

  test('actual sloped partial OCR preserves Nevermore rules and excludes the quoted flavor paragraph', () async {
    final ScanCrop partial = _partial(slopedNevermore);
    final ScanHints hints = ScanHints.fromCrop(partial);
    expect(hints.names, <String>['Nevermore']);
    expect(hints.typeLine, 'enchantment');
    expect(hints.setCode, isNull);
    expect(hints.language, isNull);
    expect(hints.collectorNumber, isNull);
    expect(hints.rulesText, <String>[
      'As Nevermore enters the bat',
      'name a nonland card.',
      "The named card can't be ca",
    ]);
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _Card('nevermore', 'Nevermore', typeLine: 'Enchantment'),
      ];
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(partial);
    expect(catalog.calls, <String>['printings:Nevermore/null/null/1']);
    expect(result.candidates.single.evidence, contains(ScanEvidence.nameMatch));
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(partial, result), isFalse);
  });

  test('partial geometry allowance rejects oversized companions and leaves ordinary body bounds unchanged', () {
    ScanTextLine taller(ScanTextLine line, double height) => ScanTextLine(
      text: line.text,
      confidence: line.confidence,
      bounds: ScanBounds(
        line.bounds.x,
        line.bounds.y,
        line.bounds.width,
        height,
      ),
    );
    final List<ScanTextLine> excessiveType = List<ScanTextLine>.of(
      slopedNevermore,
    );
    excessiveType[1] = taller(excessiveType[1], .12);
    expect(ScanHints.fromCrop(_partial(excessiveType)).names, isEmpty);
    final List<ScanTextLine> excessiveRules = List<ScanTextLine>.of(
      slopedNevermore,
    );
    for (int index = 2; index <= 4; index++) {
      excessiveRules[index] = taller(excessiveRules[index], .21);
    }
    expect(ScanHints.fromCrop(_partial(excessiveRules)).names, isEmpty);
    final ScanHints ordinary = ScanHints.fromCrop(_crop(slopedNevermore));
    expect(ordinary.names, <String>['Nevermore']);
    expect(ordinary.typeLine, isNull);
    expect(ordinary.rulesText, isEmpty);
  });

  test('verified partial Nevermore nameplate resolves by exact name but remains review-only', () async {
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _Card(
          'nevermore',
          'Nevermore',
          typeLine: 'Enchantment',
          oracleText: 'As Nevermore enters the battlefield, choose a nonland card name.',
        ),
      ];
    final ScanCrop partial = _partial(<ScanTextLine>[
      _line('Nevermore', .04),
      _line('Enchantment', .34),
      _line('As Nevermore enters the battlefield,', .44),
      _line('choose a nonland card name.', .49),
    ]);
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(partial);
    expect(result.hints.names, <String>['Nevermore']);
    expect(result.hints.typeLine, 'enchantment');
    expect(catalog.calls, <String>['printings:Nevermore/null/null/1']);
    expect(result.candidates.single.card.name, 'Nevermore');
    expect(
      result.candidates.single.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
        ScanEvidence.rulesTextMatch,
      ]),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(partial, result), isFalse);
  });

  test('partial title alone, weak text, or ordinary clipped geometry does not promote a name', () async {
    final _Catalog catalog = _Catalog();
    final ScanCrop titleOnly = _partial(<ScanTextLine>[
      _line('Sacrifice', .04),
    ]);
    final ScanResolution titleResult = await ScanResolver(catalog: catalog)
        .resolve(titleOnly);
    expect(titleResult.hints.names, isEmpty);
    expect(titleResult.status, ScanResolutionStatus.noMatch);
    expect(catalog.calls, isEmpty);
    final List<ScanTextLine> readable = <ScanTextLine>[
      _line('Nevermore', .04),
      _line('Enchantment', .34),
      _line('choose a nonland card name.', .49),
    ];
    for (int weakIndex = 0; weakIndex < readable.length; weakIndex++) {
      final List<ScanTextLine> weak = List<ScanTextLine>.of(readable);
      weak[weakIndex] = ScanTextLine(
        text: readable[weakIndex].text,
        confidence: .70,
        bounds: readable[weakIndex].bounds,
      );
      expect(ScanHints.fromCrop(_partial(weak)).names, isEmpty);
    }
    final ScanCrop ordinaryClipped = ScanCrop(
      imagePath: '',
      width: 993,
      height: 1865,
      rectified: false,
      sourceCorners: const <ScanPoint>[],
      warnings: const <String>['incomplete_card'],
      lines: readable,
    );
    expect(ScanHints.fromCrop(ordinaryClipped).names, isEmpty);
  });

  test(
    'wrong partial OCR name never sends an automatic fuzzy lookup',
    () async {
      final _Catalog catalog = _Catalog()
        ..fuzzy = _Card('nevermore', 'Nevermore');
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(
            _partial(<ScanTextLine>[
              _line('Nvermore', .04),
              _line('Enchantment', .34),
              _line('choose a nonland card name.', .49),
            ]),
          );
      expect(catalog.calls.first, 'printings:Nvermore/null/null/1');
      expect(
        catalog.calls.any((String call) => call.startsWith('fuzzy:')),
        isFalse,
      );
      expect(result.candidates, isEmpty);
      expect(result.status, ScanResolutionStatus.noMatch);
    },
  );

  test('explicit manual partial name and normal full-card OCR preserve fuzzy review suggestions', () async {
    final ScanCrop partial = _partial(<ScanTextLine>[_line('Sacrifice', .04)]);
    for (final bool manualPartial in <bool>[true, false]) {
      final _Catalog catalog = _Catalog()
        ..fuzzy = _Card('nevermore', 'Nevermore');
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(
            manualPartial
                ? partial
                : _crop(<ScanTextLine>[_line('Nvermore', .04)]),
            name: manualPartial ? 'Nvermore' : null,
          );
      expect(catalog.calls, contains('fuzzy:Nvermore'));
      expect(result.candidates.single.card.name, 'Nevermore');
      expect(
        result.candidates.single.evidence,
        contains(ScanEvidence.fuzzyName),
      );
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(hasExactPrintingEvidence(partial, result), isFalse);
    }
  });

  test(
    'partial crop with exact title and footer still requires printing review',
    () async {
      final _Catalog catalog = _Catalog()
        ..exact = _Card('nevermore', 'Nevermore', typeLine: 'Enchantment');
      final ScanCrop partial = _partial(<ScanTextLine>[
        _line('Nevermore', .04),
        _line('Enchantment', .34),
        _line('choose a nonland card name.', .49),
        _line('123', .87),
        _line('MOM EN', .91),
      ]);
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(partial);
      expect(catalog.calls, <String>['mom/123/en']);
      expect(
        result.candidates.single.evidence,
        containsAll(<ScanEvidence>[
          ScanEvidence.nameMatch,
          ScanEvidence.footerMatch,
        ]),
      );
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(hasExactPrintingEvidence(partial, result), isFalse);
    },
  );

  test('partial footer rejects prose and unreliable geometry while retaining structured identifiers', () {
    ScanTextLine footer(
      String text, {
      double confidence = .97,
      double height = .025,
      double y = .91,
    }) => ScanTextLine(
      text: text,
      confidence: confidence,
      bounds: ScanBounds(.10, y, .70, height),
    );
    for (final List<ScanTextLine> lines in <List<ScanTextLine>>[
      <ScanTextLine>[footer('The law of MOM EN remains')],
      <ScanTextLine>[footer('They call it MOM EN')],
      <ScanTextLine>[footer('MOM EN remains forbidden')],
      <ScanTextLine>[footer('MOM EN', confidence: .30)],
      <ScanTextLine>[footer('MOM EN', height: .10)],
      <ScanTextLine>[footer('MOM EN', y: .73)],
      <ScanTextLine>[footer('The law of MOM', y: .90), footer('EN', y: .93)],
    ]) {
      final ScanHints hints = ScanHints.fromCrop(_partial(lines));
      expect(hints.setCode, isNull, reason: lines.first.text);
      expect(hints.language, isNull, reason: lines.first.text);
    }
    for (final List<ScanTextLine> lines in <List<ScanTextLine>>[
      <ScanTextLine>[footer('007★/350 R MH3•EN')],
      <ScanTextLine>[footer('007★/350 R', y: .87), footer('MH3•EN')],
      <ScanTextLine>[
        footer('007★/350 R', y: .85),
        footer('MH3', y: .90),
        footer('EN', y: .93),
      ],
    ]) {
      final ScanHints hints = ScanHints.fromCrop(_partial(lines));
      expect(hints.setCode, 'mh3');
      expect(hints.language, 'en');
      expect(hints.collectorNumber, '007★');
    }
    expect(
      ScanHints.fromCrop(
        _partial(<ScanTextLine>[footer('123', confidence: .40)]),
      ).collectorNumber,
      isNull,
    );
  });

  test('fragmented titles join only horizontal nameplate observations', () {
    final ScanHints hints = ScanHints.fromCrop(
      _crop(const <ScanTextLine>[
        ScanTextLine(
          text: 'Nev',
          confidence: 1,
          bounds: ScanBounds(.05, .039, .10, .032),
        ),
        ScanTextLine(
          text: 'more',
          confidence: 1,
          bounds: ScanBounds(.19, .043, .14, .026),
        ),
        ScanTextLine(
          text: 'Sacrifice a creature',
          confidence: 1,
          bounds: ScanBounds(.77, .05, .12, .79),
        ),
      ]),
    );
    expect(hints.names.first, 'Nev more');
    expect(hints.names, isNot(contains('Sacrifice a creature')));
  });

  test('actual split historical title retains its weak prefix for keyword ranking', () async {
    const List<ScanTextLine> lines = <ScanTextLine>[
      ScanTextLine(
        text: 'Cirola o',
        confidence: .30000001192092896,
        glyphHeight: .04736876993934429,
        bounds: ScanBounds(
          .03336604967403892,
          .09225000075175616,
          .18645730203027883,
          .04736876792572112,
        ),
      ),
      ScanTextLine(
        text: 'f Protection: Blue',
        confidence: 1,
        glyphHeight: .03525000026848309,
        bounds: ScanBounds(
          .21295387809212526,
          .09149999973986567,
          .4661432761513725,
          .03525000026848309,
        ),
      ),
      ScanTextLine(
        text: 'Enchantment',
        confidence: 1,
        bounds: ScanBounds(
          .032258064705200276,
          .6046511630816613,
          .3092979093941536,
          .02616278985411924,
        ),
      ),
      ScanTextLine(
        text: '1; Prevent all damage against you',
        confidence: 1,
        bounds: ScanBounds(
          .09547749667545576,
          .7,
          .7783867430291782,
          .03904233484172422,
        ),
      ),
      ScanTextLine(
        text: 'from one blue source. If a source',
        confidence: 1,
        bounds: ScanBounds(
          .09166667771901879,
          .7319148932331814,
          .7666666441859462,
          .0319935573658473,
        ),
      ),
      ScanTextLine(
        text: 'deals damage to you mo',
        confidence: 1,
        bounds: ScanBounds(
          .09681490359560027,
          .76,
          .5483352013201217,
          .041995731757251756,
        ),
      ),
    ];
    final ScanCrop crop = ScanCrop(
      imagePath: '/local/physical-split-title.jpg',
      width: 2896,
      height: 3786,
      rectified: true,
      sourceCorners: const <ScanPoint>[],
      warnings: const <String>['geometry_adjusted'],
      lines: lines,
    );
    final ScanHints hints = ScanHints.fromCrop(crop);
    expect(hints.names, <String>[
      'Cirola o f Protection: Blue',
      'f Protection: Blue',
    ]);
    const String oracle =
        'The next time a blue source of your choice would deal damage to you this turn, prevent that damage.';
    final _Catalog catalog = _Catalog()
      ..keywordCards = <MtgCard>[
        _Card(
          'rune',
          'Rune of Protection: Blue',
          oracleText: oracle,
          typeLine: 'Enchantment',
        ),
        _Card(
          'circle',
          'Circle of Protection: Blue',
          oracleText: oracle,
          typeLine: 'Enchantment',
        ),
      ];
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(crop);
    expect(result.candidates.first.card.id, 'circle');
    expect(
      result.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.fuzzyName,
        ScanEvidence.rulesKeywordMatch,
        ScanEvidence.typeLineMatch,
      ]),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(
      catalog.calls.where((String call) => call.startsWith('keywords:')),
      hasLength(1),
    );
  });

  test('weak title fragments require a strong adjacent companion and cannot relax partial proof', () {
    const ScanTextLine suffix = ScanTextLine(
      text: 'of Protection: Blue',
      confidence: 1,
      bounds: ScanBounds(.22, .04, .45, .035),
    );
    for (final (double confidence, ScanBounds bounds) in <(double, ScanBounds)>[
      (.29, const ScanBounds(.05, .04, .16, .035)),
      (.30, const ScanBounds(.01, .04, .10, .035)),
      (.30, const ScanBounds(.05, .09, .16, .035)),
      (.30, const ScanBounds(.05, .04, .16, .21)),
    ]) {
      final ScanHints hints = ScanHints.fromCrop(
        _crop(<ScanTextLine>[
          ScanTextLine(text: 'Circle', confidence: confidence, bounds: bounds),
          suffix,
        ]),
      );
      expect(hints.names, <String>[suffix.text]);
    }
    const ScanTextLine prefix = ScanTextLine(
      text: 'Circle',
      confidence: .30,
      bounds: ScanBounds(.05, .04, .16, .035),
    );
    expect(
      ScanHints.fromCrop(_crop(const <ScanTextLine>[prefix])).names,
      isEmpty,
    );
    final ScanTextLine weakCompanion = ScanTextLine(
      text: suffix.text,
      confidence: .80,
      bounds: suffix.bounds,
    );
    expect(
      ScanHints.fromCrop(_crop(<ScanTextLine>[prefix, weakCompanion])).names,
      <String>[suffix.text],
    );
    expect(
      ScanHints.fromCrop(
        _partial(<ScanTextLine>[
          prefix,
          suffix,
          _line('Enchantment', .4),
          _line('Prevent all damage from a blue source.', .5),
        ]),
      ).names,
      <String>[suffix.text],
    );
  });

  test(
    'real capture title geometry excludes inverted rules and vertical text',
    () {
      final ScanHints inverted = ScanHints.fromCrop(
        _crop(<ScanTextLine>[
          _line('thoughts', .14),
          _line('"By the lies of Avacyn, the following', .178),
        ]),
      );
      expect(inverted.names, isEmpty);
      final ScanHints upright = ScanHints.fromCrop(
        _crop(<ScanTextLine>[
          _line('Nevermore', .043),
          const ScanTextLine(
            text: 'Sacrifice a creature to add that',
            confidence: 1,
            bounds: ScanBounds(.773, .058, .126, .789),
          ),
        ]),
      );
      expect(upright.names, <String>['Nevermore']);
      final ScanHints partial = ScanHints.fromCrop(
        ScanCrop(
          imagePath: '/local/partial.jpg',
          width: 993,
          height: 1865,
          rectified: true,
          sourceCorners: const <ScanPoint>[],
          warnings: const <String>['incomplete_card'],
          lines: <ScanTextLine>[_line('Sacrifice', .04)],
        ),
      );
      expect(partial.names, isEmpty);
    },
  );

  test('title and footer zones retain string collector identifiers', () {
    final ScanHints hints = ScanHints.fromCrop(
      _crop(<ScanTextLine>[
        _line('Lightning Bolt', 0.04),
        _line('Deal three damage to any target.', 0.61),
        _line('007★/350 R', 0.87),
        _line('2XM • EN', 0.91),
        _line('© 2020 Wizards of the Coast', 0.95),
      ]),
    );
    expect(hints.names, <String>['Lightning Bolt']);
    expect(hints.setCode, '2xm');
    expect(hints.collectorNumber, '007★');
    expect(hints.language, 'en');
  });

  test('split footer set and language lines preserve prefixed printing identifiers', () {
    final ScanHints hints = ScanHints.fromCrop(
      _crop(<ScanTextLine>[
        _line('Lightning Bolt', .04),
        _line('A-001a★/300', .83),
        _line('P23', .90),
        _line('EN', .93),
      ]),
    );
    expect(hints.collectorNumber, 'A-001a★');
    expect(hints.setCode, 'p23');
    expect(hints.language, 'en');
  });

  test('tight bullet footer separators need no OCR whitespace', () {
    for (final String text in <String>['MH3•EN', 'MH3·EN', 'MH3 • EN']) {
      final ScanHints hints = ScanHints.fromCrop(
        _crop(<ScanTextLine>[_line(text, .9)]),
      );
      expect(hints.setCode, 'mh3');
      expect(hints.language, 'en');
    }
    expect(
      ScanHints.fromCrop(_crop(<ScanTextLine>[_line('MH3EN', .9)])).setCode,
      isNull,
    );
  });

  test(
    'power and toughness on the lower right cannot supply a collector number',
    () {
      final ScanHints hints = ScanHints.fromCrop(
        _crop(<ScanTextLine>[
          const ScanTextLine(
            text: '3/3',
            confidence: .99,
            bounds: ScanBounds(.82, .81, .1, .03),
          ),
          _line('MH3•EN', .9),
        ]),
      );
      expect(hints.setCode, 'mh3');
      expect(hints.collectorNumber, isNull);
    },
  );

  test('reordered footer retains the number after set and language', () {
    for (final ScanCrop Function(List<ScanTextLine>) makeCrop
        in <ScanCrop Function(List<ScanTextLine>)>[_crop, _partial]) {
      final ScanHints hints = ScanHints.fromCrop(
        makeCrop(<ScanTextLine>[_line('MH3•EN R 001a★', .92)]),
      );
      expect(hints.setCode, 'mh3');
      expect(hints.language, 'en');
      expect(hints.collectorNumber, '001a★');
    }
  });

  test('right footer number requires nearby structured set and language', () {
    const ScanTextLine rightNumber = ScanTextLine(
      text: '0163 C',
      confidence: .97,
      bounds: ScanBounds(.72, .94, .20, .025),
    );
    const ScanTextLine rightSet = ScanTextLine(
      text: 'LTR•EN',
      confidence: .99,
      bounds: ScanBounds(.70, .90, .22, .025),
    );
    for (final ScanCrop Function(List<ScanTextLine>) makeCrop
        in <ScanCrop Function(List<ScanTextLine>)>[_crop, _partial]) {
      final ScanHints hints = ScanHints.fromCrop(
        makeCrop(<ScanTextLine>[rightNumber, rightSet]),
      );
      expect(hints.collectorNumber, '0163');
      expect(hints.setCode, 'ltr');
      expect(hints.language, 'en');
      expect(
        ScanHints.fromCrop(makeCrop(<ScanTextLine>[rightNumber]))
            .collectorNumber,
        isNull,
      );
    }
  });

  test('right footer set and language can occupy separate aligned lines', () {
    final ScanHints hints = ScanHints.fromCrop(
      _crop(const <ScanTextLine>[
        ScanTextLine(
          text: '001a★',
          confidence: .98,
          bounds: ScanBounds(.72, .88, .18, .02),
        ),
        ScanTextLine(
          text: 'SLD',
          confidence: .98,
          bounds: ScanBounds(.72, .92, .12, .02),
        ),
        ScanTextLine(
          text: 'EN',
          confidence: .98,
          bounds: ScanBounds(.72, .95, .10, .02),
        ),
      ]),
    );
    expect(hints.collectorNumber, '001a★');
    expect(hints.setCode, 'sld');
    expect(hints.language, 'en');
  });

  test(
    'structured right footer never admits power toughness or weak reads',
    () {
      for (final (String, double, double, double) sample
          in <(String, double, double, double)>[
            ('3/3', .99, .94, .025),
            ('0163 C', .84, .94, .025),
            ('0163 C', .99, .81, .025),
            ('0163 C', .99, .94, .07),
            ('© 2023', .99, .94, .025),
          ]) {
        final ScanHints hints = ScanHints.fromCrop(
          _crop(<ScanTextLine>[
            ScanTextLine(
              text: sample.$1,
              confidence: sample.$2,
              bounds: ScanBounds(.72, sample.$3, .20, sample.$4),
            ),
            const ScanTextLine(
              text: 'LTR•EN',
              confidence: .99,
              bounds: ScanBounds(.70, .90, .22, .025),
            ),
          ]),
        );
        expect(
          hints.collectorNumber,
          isNull,
          reason: '${sample.$1}/${sample.$2}',
        );
      }
    },
  );

  test('actual footer number outranks an isolated number in the rules box', () {
    final ScanHints hints = ScanHints.fromCrop(
      _crop(<ScanTextLine>[
        _line('2', .72),
        _line('0163 C', .88),
        _line('LTR•EN', .93),
      ]),
    );
    expect(hints.collectorNumber, '0163');
  });

  test('right footer selects exact printing and raises evidence without visual work', () async {
    final _Catalog catalog = _Catalog()
      ..exact = _Card(
        'edition-a',
        'Lightning Bolt',
        set: 'm11',
        collectorNumber: '123a',
      );
    final _Artwork artwork = _Artwork();
    final _Symbol symbols = _Symbol();
    final ScanCrop crop = _crop(<ScanTextLine>[
      _line('Lightning Bolt', .04),
      const ScanTextLine(
        text: 'M11•EN',
        confidence: .99,
        bounds: ScanBounds(.70, .90, .22, .025),
      ),
      const ScanTextLine(
        text: '123a R',
        confidence: .99,
        bounds: ScanBounds(.72, .94, .20, .025),
      ),
    ]);
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: artwork,
      symbols: symbols,
    ).resolve(crop);
    expect(catalog.calls, <String>['m11/123a/en']);
    expect(result.status, ScanResolutionStatus.exactPrinting);
    expect(hasExactPrintingEvidence(crop, result), isTrue);
    expect(result.candidates.single.card.id, 'edition-a');
    expect(
      result.candidates.single.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.footerMatch,
        ScanEvidence.collectorNumberMatch,
        ScanEvidence.nameMatch,
        ScanEvidence.languageMatch,
      ]),
    );
    expect(artwork.calls, 0);
    expect(symbols.calls, 0);
  });

  test(
    'collector number without a set cannot claim an exact printing',
    () async {
      final _Catalog catalog = _Catalog()
        ..cards = <MtgCard>[
          _Card('edition-a', 'Lightning Bolt', set: 'm11'),
          _Card('edition-b', 'Lightning Bolt', set: 'mom'),
        ];
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(
            _crop(<ScanTextLine>[
              _line('Lightning Bolt', .04),
              _line('123 R', .91),
            ]),
          );
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(result.candidates, hasLength(2));
      expect(catalog.calls.single, startsWith('printings:'));
    },
  );

  test('conflicting reliable footer numbers cannot choose a printing', () {
    final ScanHints hints = ScanHints.fromCrop(
      _crop(<ScanTextLine>[
        _line('0163 C', .88),
        _line('0164 C', .88),
        _line('LTR•EN', .93),
      ]),
    );
    expect(hints.setCode, 'ltr');
    expect(hints.collectorNumber, isNull);
    final ScanHints padded = ScanHints.fromCrop(
      _crop(<ScanTextLine>[
        _line('0163 C', .88),
        _line('163 C', .88),
        _line('LTR•EN', .93),
      ]),
    );
    expect(padded.collectorNumber, '0163');
  });

  test(
    'footer match with contradictory title recovers the observed identity',
    () async {
      final _Catalog catalog = _Catalog()
        ..exact = _Card('edition-a', 'Shock')
        ..cards = <MtgCard>[
          _Card('bolt', 'Lightning Bolt', collectorNumber: '124'),
        ];
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(
            _crop(<ScanTextLine>[
              _line('Lightning Bolt', 0.05),
              _line('0123 R', 0.87),
              _line('MOM EN', 0.91),
            ]),
          );
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(
        result.candidates.single.evidence,
        containsAll(<ScanEvidence>[
          ScanEvidence.nameMatch,
          ScanEvidence.printingMismatch,
        ]),
      );
      expect(result.candidates.single.card.name, 'Lightning Bolt');
      expect(catalog.calls, <String>[
        'mom/0123/en',
        'printings:Lightning Bolt/mom/en/1',
      ]);
    },
  );

  test('weak footer 177 cannot override strong Lightning Bolt name and body in single or bulk resolution', () async {
    final _Card bolt = _Card(
      'bolt',
      'Lightning Bolt',
      set: '2x2',
      collectorNumber: '117',
      oracleText: 'Lightning Bolt deals 3 damage to any target.',
    );
    final _Catalog catalog = _Catalog()
      ..exact = _Card(
        'atla',
        'Atla Palani, Nest Tender',
        set: '2x2',
        collectorNumber: '177',
        typeLine: 'Legendary Creature',
        oracleText: 'Create a green Egg creature token with defender.',
      )
      ..cards = <MtgCard>[bolt];
    final _BulkCatalog bulk = _BulkCatalog(catalog);
    addTearDown(bulk.close);
    for (final double confidence in <double>[.3000000119, .97]) {
      catalog.calls.clear();
      final ScanCrop crop = _mistakenBoltFooter(footerConfidence: confidence);
      expect(
        ScanHints.fromCrop(crop).collectorNumber,
        confidence >= .75 ? '177' : null,
      );
      final List<ScanResolution> results = <ScanResolution>[
        await ScanResolver(catalog: catalog).resolve(crop),
        ...(await ScanResolver(catalog: bulk).resolveBatch(<ScanCrop>[crop])),
      ];
      for (final ScanResolution result in results) {
        expect(result.candidates.single.card.id, 'bolt');
        expect(result.status, ScanResolutionStatus.needsReview);
        expect(result.hints.setCode, confidence >= .75 ? '2x2' : null);
        expect(result.hints.collectorNumber, confidence >= .75 ? '177' : null);
        expect(
          result.candidates.single.evidence,
          containsAll(<ScanEvidence>[
            ScanEvidence.nameMatch,
            ScanEvidence.rulesTextMatch,
            if (confidence >= .75) ScanEvidence.printingMismatch,
          ]),
        );
        if (confidence < .75) {
          expect(result.candidates.single.hasContradiction, isFalse);
        }
        expect(hasExactPrintingEvidence(crop, result), isFalse);
      }
      expect(
        catalog.calls.where((String call) => call.startsWith('printings:')),
        <String>[
          confidence >= .75
              ? 'printings:Lightning Bolt/2x2/en/1'
              : 'printings:Lightning Bolt/null/null/1',
          confidence >= .75
              ? 'printings:Lightning Bolt/2x2/en/1'
              : 'printings:Lightning Bolt/null/null/1',
        ],
      );
    }
  });

  test('wrong footer set gets one unconstrained name retry without discarding print conflicts', () async {
    final _Catalog catalog = _Catalog()
      ..exact = _Card('wrong', 'Shock', set: 'mom', collectorNumber: '177')
      ..scopedCards['Lightning Bolt/mom'] = <MtgCard>[]
      ..scopedCards['Lightning Bolt/null'] = <MtgCard>[
        _Card(
          'bolt',
          'Lightning Bolt',
          set: '2x2',
          collectorNumber: '117',
          oracleText: 'Lightning Bolt deals 3 damage to any target.',
        ),
      ];
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(_mistakenBoltFooter(set: 'MOM', footerConfidence: .97));
    expect(result.candidates.single.card.id, 'bolt');
    expect(result.hints.setCode, 'mom');
    expect(result.hints.collectorNumber, '177');
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(
      result.candidates.single.evidence,
      contains(ScanEvidence.printingMismatch),
    );
    expect(catalog.calls, <String>[
      'mom/177/en',
      'printings:Lightning Bolt/mom/en/1',
      'printings:Lightning Bolt/null/en/1',
    ]);
  });

  test('strong body recovers identity from a contradictory footer without a visible title', () async {
    final _Catalog catalog = _Catalog()
      ..exact = _Card(
        'atla',
        'Atla Palani, Nest Tender',
        set: '2x2',
        collectorNumber: '177',
        oracleText: 'Create a green Egg creature token with defender.',
      )
      ..bodyCards = <MtgCard>[
        _Card(
          'throat',
          'Go for the Throat',
          set: '2x2',
          collectorNumber: '81',
          oracleText: 'Destroy target nonartifact creature.',
        ),
      ];
    final ScanResolution result = await ScanResolver(catalog: catalog).resolve(
      _crop(<ScanTextLine>[
        _line('Instant', .49),
        _line('Destroy target nonartifact creature.', .61),
        _line('177/331', .88),
        _line('2X2 EN', .93),
      ]),
    );
    expect(result.candidates.single.card.id, 'throat');
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(
      result.candidates.single.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.rulesTextMatch,
        ScanEvidence.printingMismatch,
      ]),
    );
    expect(catalog.calls, <String>[
      '2x2/177/en',
      'body:Destroy target nonartifact creature./null/null/en/instant/1',
    ]);
  });

  test('supported exact footer still performs one lookup', () async {
    final _Catalog catalog = _Catalog()
      ..exact = _Card(
        'bolt',
        'Lightning Bolt',
        set: '2x2',
        collectorNumber: '117',
        oracleText: 'Lightning Bolt deals 3 damage to any target.',
      );
    final ScanCrop crop = _crop(<ScanTextLine>[
      _line('Lightning Bolt', .05),
      _line('Instant', .49),
      _line('Lightning Bolt deals 3 damage to any target.', .61),
      _line('117 C', .88),
      _line('2X2 EN', .93),
    ]);
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(crop);
    expect(result.status, ScanResolutionStatus.exactPrinting);
    expect(catalog.calls, <String>['2x2/117/en']);
    expect(hasExactPrintingEvidence(crop, result), isTrue);
  });

  test(
    'failed footer identity recovery cannot retain an unrelated candidate',
    () async {
      final _Catalog catalog = _Catalog()
        ..exact = _Card(
          'atla',
          'Atla Palani, Nest Tender',
          set: '2x2',
          collectorNumber: '177',
        );
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(_mistakenBoltFooter(footerConfidence: .97));
      expect(result.status, ScanResolutionStatus.noMatch);
      expect(result.candidates, isEmpty);
      expect(result.hints.collectorNumber, '177');
      expect(
        catalog.calls.where((String call) => call.startsWith('printings:')),
        hasLength(2),
      );
      expect(
        catalog.calls.where((String call) => call.startsWith('body:')),
        hasLength(1),
      );

      final StateError failure = StateError('Connection unavailable');
      catalog.namedFailures['Lightning Bolt'] = failure;
      await expectLater(
        ScanResolver(catalog: catalog)
            .resolve(_mistakenBoltFooter(footerConfidence: .97)),
        throwsA(same(failure)),
      );
    },
  );

  test('explicit printing overrides preserve the chosen footer and its contradictory evidence', () async {
    final _Catalog catalog = _Catalog()
      ..exact = _Card(
        'atla',
        'Atla Palani, Nest Tender',
        set: '2x2',
        collectorNumber: '177',
      );
    final ScanResolver resolver = ScanResolver(catalog: catalog);
    final List<ScanResolution> results = <ScanResolution>[
      await resolver.resolve(
        _mistakenBoltFooter(footerConfidence: .97),
        name: 'Lightning Bolt',
      ),
      await resolver.resolve(
        _mistakenBoltFooter(footerConfidence: .97),
        setCode: '2X2',
      ),
      await resolver.resolve(
        _mistakenBoltFooter(footerConfidence: .97),
        collectorNumber: '177',
      ),
      await resolver.resolve(
        _mistakenBoltFooter(footerConfidence: .97),
        language: 'en',
      ),
    ];
    for (final ScanResolution result in results) {
      expect(result.candidates.single.card.id, 'atla');
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(
        result.candidates.single.evidence,
        contains(ScanEvidence.nameMismatch),
      );
    }
    expect(catalog.calls, List<String>.filled(4, '2x2/177/en'));
  });

  test('manual printing overrides OCR and retains number suffix', () async {
    final _Catalog catalog = _Catalog()
      ..exact = _Card(
        'edition-a',
        'Lightning Bolt',
        set: 'sld',
        collectorNumber: '123a',
        lang: Language.french,
      );
    final ScanResolution result = await ScanResolver(catalog: catalog).resolve(
      _crop(<ScanTextLine>[_line('Lightning Bolt', 0.05)]),
      setCode: 'SLD',
      collectorNumber: '123a',
      language: 'FR',
    );
    expect(catalog.calls, <String>['sld/123a/fr']);
    expect(result.status, ScanResolutionStatus.exactPrinting);
  });

  test(
    'name-only identification retains distinct printings and pagination',
    () async {
      final _Catalog catalog = _Catalog()
        ..cards = <MtgCard>[
          _Card('edition-a', 'Island'),
          _Card('edition-b', 'Island'),
        ]
        ..hasMore = true;
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(_crop(<ScanTextLine>[_line('Island', 0.05)]), page: 2);
      expect(
        result.candidates.map((ScanCandidate value) => value.card.id),
        <String>['edition-a', 'edition-b'],
      );
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(result.hasMore, isTrue);
      expect(result.page, 2);
      expect(catalog.calls, <String>['printings:Island/null/null/2']);
    },
  );

  test(
    'blank OCR does not query unrelated rules or invent a candidate',
    () async {
      final _Catalog catalog = _Catalog();
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(_crop(<ScanTextLine>[_line('Draw three cards.', 0.61)]));
      expect(result.status, ScanResolutionStatus.noMatch);
      expect(catalog.calls, isEmpty);
    },
  );

  test(
    'obscured title uses distinctive body phrase but requires printing review',
    () async {
      final _Catalog catalog = _Catalog()
        ..bodyCards = <MtgCard>[
          _Card(
            'nevermore',
            'Nevermore',
            oracleText: 'As Nevermore enters the battlefield, choose a nonland card name.',
          ),
        ];
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(
            _crop(<ScanTextLine>[
              _line('As Nevermore enters the battlefield,', .61),
              _line('choose a nonland card name.', .65),
            ]),
          );
      expect(
        catalog.calls.single,
        startsWith('body:choose a nonland card name.'),
      );
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(
        result.candidates.single.evidence,
        contains(ScanEvidence.rulesTextMatch),
      );
      expect(
        result.candidates.single.evidence,
        isNot(contains(ScanEvidence.nameMatch)),
      );
    },
  );

  test(
    'generic or unreliable body observations cause no oracle searches',
    () async {
      final _Catalog catalog = _Catalog();
      await ScanResolver(catalog: catalog).resolve(
        _crop(<ScanTextLine>[
          _line('Draw three cards.', .61),
          const ScanTextLine(
            text: 'Destroy target nonartifact creature.',
            confidence: .55,
            bounds: ScanBounds(.1, .67, .7, .025),
          ),
        ]),
      );
      expect(catalog.calls, isEmpty);
    },
  );

  test(
    'body damage contradiction cannot recover an unsupported footer identity',
    () async {
      final _Catalog catalog = _Catalog()
        ..exact = _Card(
          'bolt',
          'Lightning Bolt',
          oracleText: 'Lightning Bolt deals 3 damage to any target.',
        );
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(
            _crop(<ScanTextLine>[
              _line('Lightning Bolt', .04),
              _line('Lightning Bolt deals two damage to any target.', .61),
              _line('0123 R', .87),
              _line('MOM EN', .91),
            ]),
          );
      expect(result.status, ScanResolutionStatus.noMatch);
      expect(result.candidates, isEmpty);
      expect(catalog.calls, contains('printings:Lightning Bolt/mom/en/1'));
    },
  );

  test('body corroboration outranks visually tied wrong candidates', () async {
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _Card(
          'wrong',
          'Nevermore',
          oracleText: 'Destroy target nonartifact creature.',
        ),
        _Card(
          'right',
          'Nevermore',
          oracleText: 'As Nevermore enters the battlefield, choose a nonland card name.',
        ),
      ];
    final ScanResolution result =
        await ScanResolver(catalog: catalog, artwork: _Artwork()).resolve(
          _crop(<ScanTextLine>[
            _line('Nevermore', .04),
            _line('As Nevermore enters the battlefield,', .61),
          ]),
        );
    expect(result.candidates.first.card.id, 'right');
    expect(
      result.candidates.first.score,
      greaterThan(result.candidates.last.score),
    );
    expect(
      result.candidates.every(
        (ScanCandidate item) => item.artworkDistance == .2,
      ),
      isTrue,
    );
    expect(result.status, ScanResolutionStatus.needsReview);
  });

  test('oracle phrase search escapes quotes and constrains documented printing metadata', () async {
    final List<Uri> requests = <Uri>[];
    final ScryfallScanCatalog catalog = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient((http.Request request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode(<String, Object?>{
              'object': 'list',
              'data': <Object?>[],
              'has_more': false,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    await catalog.rulesTextPrintings(
      'choose a "nonland" card name',
      setCode: 'isd',
      collectorNumber: '001a',
      language: 'en',
      typeLine: 'enchantment',
    );
    expect(
      requests.single.queryParameters['q'],
      r'oracle:"choose a \"nonland\" card name" game:paper set:"isd" cn:"1a" lang:"en" type:"enchantment"',
    );
    expect(requests.single.queryParameters['unique'], 'prints');
    catalog.close();
  });

  test('wrapped rules text finds a card without a title or footer', () async {
    final _Catalog catalog = _Catalog()
      ..bodyCards = <MtgCard>[
        _Card(
          'throat',
          'Go for the Throat',
          oracleText: 'Destroy target nonartifact creature.',
        ),
      ];
    final ScanResolution result = await ScanResolver(catalog: catalog).resolve(
      _crop(<ScanTextLine>[
        _line('Destroy target nonartifact', .60),
        _line('creature.', .64),
      ]),
    );
    expect(
      catalog.calls.single,
      startsWith('body:Destroy target nonartifact creature.'),
    );
    expect(
      result.candidates.single.evidence,
      contains(ScanEvidence.rulesTextMatch),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
  });

  test('historical rules retrieve bounded candidates and damaged titles remain review-only', () async {
    const String oracle =
        'The next time a blue source of your choice would deal damage to you this turn, prevent that damage.';
    final _Catalog catalog = _Catalog()
      ..keywordCards = <MtgCard>[
        _Card(
          'rune',
          'Rune of Protection: Blue',
          oracleText: oracle,
          typeLine: 'Enchantment',
        ),
        _Card(
          'circle',
          'Circle of Protection: Blue',
          oracleText: oracle,
          typeLine: 'Enchantment',
        ),
      ];
    final ScanResolution result = await ScanResolver(catalog: catalog).resolve(
      _partial(<ScanTextLine>[
        _line('Cirels of Protection Clue', .04),
        _line('Enchantment', .4),
        _line('Prevent all damage against you', .5),
        _line('from one blue source. If a source', .54),
        _line('deals damage to you more than', .58),
      ]),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(result.candidates.first.card.id, 'circle');
    expect(
      result.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.rulesKeywordMatch,
        ScanEvidence.fuzzyName,
      ]),
    );
    expect(
      result.candidates.first.evidence,
      isNot(contains(ScanEvidence.nameMatch)),
    );
    expect(result.candidates.last.hasContradiction, isTrue);
    expect(
      catalog.calls.where((String call) => call.startsWith('keywords:')),
      hasLength(1),
    );
    expect(
      catalog.calls.any((String call) => call.startsWith('fuzzy:')),
      isFalse,
    );
  });

  test(
    'keyword rules without a name keep ambiguous candidates for review',
    () async {
      final _Catalog catalog = _Catalog()
        ..keywordCards = <MtgCard>[
          _Card(
            'circle',
            'Circle of Protection: Blue',
            oracleText: 'Prevent damage from a blue source.',
          ),
          _Card(
            'rune',
            'Rune of Protection: Blue',
            oracleText: 'Prevent damage from a blue source.',
          ),
        ];
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(
            _crop(<ScanTextLine>[
              _line('Prevent all damage against you', .6),
              _line('from one blue source. If a source', .64),
            ]),
          );
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(result.candidates, hasLength(2));
      expect(
        result.candidates.every(
          (ScanCandidate candidate) =>
              candidate.evidence.contains(ScanEvidence.rulesKeywordMatch),
        ),
        isTrue,
      );
      expect(
        result.candidates.any(
          (ScanCandidate candidate) =>
              candidate.evidence.contains(ScanEvidence.nameMatch),
        ),
        isFalse,
      );
    },
  );

  test(
    'keyword search rejects broad result sets and propagates lookup errors',
    () async {
      final ScanCrop crop = _crop(<ScanTextLine>[
        _line('Prevent all damage against you', .6),
        _line('from one blue source. If a source', .64),
      ]);
      for (final bool paginated in <bool>[true, false]) {
        final _Catalog catalog = _Catalog()
          ..hasMore = paginated
          ..keywordCards = List<MtgCard>.generate(
            paginated ? 1 : 33,
            (int index) => _Card('$index', 'Card $index'),
          );
        final ScanResolution result = await ScanResolver(catalog: catalog)
            .resolve(crop);
        expect(result.status, ScanResolutionStatus.noMatch);
        expect(
          catalog.calls.where((String call) => call.startsWith('keywords:')),
          hasLength(1),
        );
      }
      final _Catalog failing = _Catalog()
        ..keywordFailure = StateError('rate limited');
      await expectLater(
        ScanResolver(catalog: failing).resolve(crop),
        throwsStateError,
      );
    },
  );

  ScanCrop alternativeTitleCrop({
    String title = 'Circle of Protections Blue',
    List<String> alternatives = const <String>[
      'Circle of Protection Blue',
      'Cirele of Protections Blue',
    ],
    double titleConfidence = 1,
    double titleY = .013195,
    String? type = 'Enchantment',
    double typeConfidence = 1,
    double bodyConfidence = 1,
    String source = 'from one blue source. Ii a source',
  }) => ScanCrop(
    imagePath: '',
    width: 2500,
    height: 3494,
    rectified: true,
    sourceCorners: _crop(const <ScanTextLine>[]).sourceCorners,
    warnings: const <String>['geometry_adjusted'],
    lines: <ScanTextLine>[
      ScanTextLine(
        text: title,
        confidence: titleConfidence,
        bounds: ScanBounds(.057371, titleY, .627077, .052167),
        alternatives: alternatives,
      ),
      if (type != null)
        ScanTextLine(
          text: type,
          confidence: typeConfidence,
          bounds: const ScanBounds(.063576, .557779, .297404, .033454),
        ),
      ScanTextLine(
        text: '1; Prevent all damage against you',
        confidence: bodyConfidence,
        bounds: const ScanBounds(.114109, .660216, .746882, .048755),
      ),
      ScanTextLine(
        text: source,
        confidence: bodyConfidence,
        bounds: const ScanBounds(.116667, .7, .729167, .031395),
      ),
      ScanTextLine(
        text: 'deals damage to you more than',
        confidence: bodyConfidence,
        bounds: const ScanBounds(.115983, .726915, .689510, .044526),
      ),
      ScanTextLine(
        text: 'esch time to prevent the aamage',
        confidence: bodyConfidence,
        bounds: const ScanBounds(.116667, .804613, .716667, .034922),
      ),
    ],
  );

  test('native title alternatives recover actual name only after primary lookup fails', () async {
    final _Card circle = _Card(
      'circle',
      'Circle of Protection: Blue',
      typeLine: 'Enchantment',
      oracleText: '{1}: The next time a blue source of your choice would deal damage to you this turn, prevent that damage.',
    );
    final _Catalog catalog = _Catalog()
      ..namedCards['Circle of Protection Blue'] = <MtgCard>[circle];
    final ScanCrop crop = alternativeTitleCrop();
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(crop);
    expect(catalog.calls, <String>[
      'printings:Circle of Protections Blue/null/null/1',
      'printings:Circle of Protection Blue/null/null/1',
    ]);
    expect(result.candidates.single.card.id, 'circle');
    expect(result.candidates.single.evidence, contains(ScanEvidence.nameMatch));
    expect(
      result.candidates.single.evidence,
      contains(ScanEvidence.typeLineMatch),
    );
    expect(
      result.candidates.single.evidence,
      contains(ScanEvidence.rulesKeywordMatch),
    );
    expect(
      result.candidates.single.evidence,
      isNot(contains(ScanEvidence.fuzzyName)),
    );
    expect(
      result.candidates.single.evidence,
      isNot(contains(ScanEvidence.rulesTextMatch)),
    );
    expect(result.candidates.single.hasContradiction, isFalse);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(result.hints.names, <String>[
      'Circle of Protections Blue',
      'Circle of Protection Blue',
    ]);
    expect(crop.lines.first.text, 'Circle of Protections Blue');
    expect(crop.lines.first.alternatives, <String>[
      'Circle of Protection Blue',
      'Cirele of Protections Blue',
    ]);
    final _Catalog primary = _Catalog()..cards = <MtgCard>[circle];
    await ScanResolver(catalog: primary).resolve(crop);
    expect(primary.calls, <String>[
      'printings:Circle of Protections Blue/null/null/1',
    ]);
  });

  test('native title retries reject unrelated color changed weak and misplaced observations', () async {
    for (final ScanCrop crop in <ScanCrop>[
      alternativeTitleCrop(
        alternatives: const <String>['Rune of Protection Blue'],
      ),
      alternativeTitleCrop(
        alternatives: const <String>['Circle of Protection Red'],
      ),
      alternativeTitleCrop(
        alternatives: const <String>['Circle of Protections Glue'],
      ),
      alternativeTitleCrop(
        alternatives: const <String>['Circle in Protections Blue'],
      ),
      alternativeTitleCrop(
        alternatives: const <String>['Circle of Protections Blue 1'],
      ),
      alternativeTitleCrop(titleConfidence: .84),
      alternativeTitleCrop(titleY: .20),
      alternativeTitleCrop(type: null),
      alternativeTitleCrop(typeConfidence: .84),
      alternativeTitleCrop(bodyConfidence: .84),
    ]) {
      final _Catalog catalog = _Catalog();
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(crop);
      expect(result.status, ScanResolutionStatus.noMatch);
      expect(
        catalog.calls.where(
          (String call) =>
              call.startsWith('printings:Circle of Protection Blue/'),
        ),
        isEmpty,
      );
    }
    final _Catalog manual = _Catalog();
    await ScanResolver(catalog: manual)
        .resolve(alternativeTitleCrop(), name: 'Circle of Protections Blue');
    expect(
      manual.calls.where(
        (String call) =>
            call.startsWith('printings:Circle of Protection Blue/'),
      ),
      isEmpty,
    );
    final _Catalog laterPage = _Catalog();
    await ScanResolver(catalog: laterPage)
        .resolve(alternativeTitleCrop(), page: 2);
    expect(
      laterPage.calls.where(
        (String call) =>
            call.startsWith('printings:Circle of Protection Blue/'),
      ),
      isEmpty,
    );
  });

  test('observed alternatives need independent catalog type and rules corroboration', () async {
    for (final _Card card in <_Card>[
      _Card(
        'wrong-name',
        'Rune of Protection: Blue',
        typeLine: 'Enchantment',
        oracleText: 'Prevent all damage from one blue source.',
      ),
      _Card(
        'wrong-type',
        'Circle of Protection: Blue',
        typeLine: 'Artifact',
        oracleText: 'Prevent all damage from one blue source.',
      ),
      _Card(
        'wrong-body',
        'Circle of Protection: Blue',
        typeLine: 'Enchantment',
        oracleText: '{1}: The next time a red source of your choice would deal damage to you this turn, prevent that damage.',
      ),
    ]) {
      final _Catalog catalog = _Catalog()
        ..namedCards['Circle of Protection Blue'] = <MtgCard>[card];
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(alternativeTitleCrop());
      expect(result.status, ScanResolutionStatus.noMatch, reason: card.id);
      expect(result.candidates, isEmpty);
    }
    final _Catalog limited = _Catalog();
    await ScanResolver(catalog: limited).resolve(
      alternativeTitleCrop(
        alternatives: const <String>[
          'Circle of Protection Blue',
          'Cirele of Protections Blue',
          'Circle of Protextions Blue',
        ],
      ),
    );
    expect(
      limited.calls.where((String call) => call.startsWith('printings:')),
      <String>[
        'printings:Circle of Protections Blue/null/null/1',
        'printings:Circle of Protection Blue/null/null/1',
        'printings:Cirele of Protections Blue/null/null/1',
      ],
    );
  });

  test(
    'successful keyword lookup compares artwork for verified repaired bodies',
    () async {
      const ScanCrop crop = ScanCrop(
        imagePath: '/local/card.jpg',
        width: 1000,
        height: 1400,
        rectified: true,
        warnings: <String>[
          'orientation_ensemble',
          'geometry_adjusted',
          'incomplete_card',
        ],
        sourceCorners: <ScanPoint>[
          ScanPoint(.1, .1),
          ScanPoint(.9, .1),
          ScanPoint(.9, .9),
          ScanPoint(.1, .9),
        ],
        lines: <ScanTextLine>[
          ScanTextLine(
            text: 'Enchantment',
            confidence: 1,
            bounds: ScanBounds(.08, .54, .3, .03),
          ),
          ScanTextLine(
            text: '1: Prevent all damage against you',
            confidence: 1,
            bounds: ScanBounds(.14, .64, .72, .04),
          ),
          ScanTextLine(
            text: 'from one blue source. If a source',
            confidence: 1,
            bounds: ScanBounds(.14, .68, .72, .035),
          ),
          ScanTextLine(
            text: 'deals damage to you more than',
            confidence: 1,
            bounds: ScanBounds(.14, .72, .68, .035),
          ),
          ScanTextLine(
            text: 'once in a turn, you may pay 1',
            confidence: 1,
            bounds: ScanBounds(.14, .76, .65, .035),
          ),
          ScanTextLine(
            text: 'each time to prevent the damage.',
            confidence: 1,
            bounds: ScanBounds(.14, .80, .72, .035),
          ),
        ],
      );
      final _Catalog catalog = _Catalog()
        ..keywordCards = <MtgCard>[
          _Card(
            'blue',
            'Circle of Protection: Blue',
            typeLine: 'Enchantment',
            oracleText: 'Prevent all damage from a blue source.',
          ),
        ];
      final _BodyArtwork artwork = _BodyArtwork();
      final ScanResolution result = await ScanResolver(
        catalog: catalog,
        artwork: artwork,
      ).resolve(crop);
      expect(
        catalog.calls.where((String call) => call.startsWith('keywords:')),
        hasLength(1),
      );
      expect(artwork.calls, 1);
      expect(artwork.bodyFallback, isTrue);
      expect(
        result.candidates.single.evidence,
        contains(ScanEvidence.artworkCompared),
      );
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(hasExactPrintingEvidence(crop, result), isFalse);
    },
  );

  test('actual titleless old rules use a bounded phrase and type query without inventing color or printing', () async {
    final ScanCrop actual = ScanCrop.fromMap(
      jsonDecode(
        r'''{"imagePath":"/local/observed-card.jpg","width":1917,"height":2678,"rectified":true,"warnings":["incomplete_card","orientation_ensemble","geometry_adjusted"],"sharpness":0.8770940767062105,"sourceCorners":[{"x":0.5275646448135376,"y":0.43636244535446167},{"x":0.7437624931335449,"y":0.4347569942474365},{"x":0.8292030096054077,"y":0.5606984496116638},{"x":0.5403050184249878,"y":0.5648854076862335}],"lines":[{"text":"Enchantmeht","confidence":0.5,"alternatives":["Enchantricht","Enchantreht"],"glyphHeight":0.028897100878441044,"bounds":{"x":0.08425945691780244,"y":0.5445773784397772,"width":0.28769382321672965,"height":0.03459011075031948}},{"text":"1; Prevent all damage against you","confidence":1.0,"alternatives":["1 ; Prevent all damage against you","1 Prevent all damage against you"],"glyphHeight":0.036180029579202556,"bounds":{"x":0.14340344930117802,"y":0.6451953615328703,"width":0.7293011264582248,"height":0.043092281805925836}},{"text":"LaSoUI","confidence":0.30000001192092896,"alternatives":[],"glyphHeight":0.013494808994122398,"bounds":{"x":0.6482558124007075,"y":0.7000000003410954,"width":0.1598837238904457,"height":0.013494808994122398}},{"text":"deals damage to you more than","confidence":1.0,"alternatives":[],"glyphHeight":0.03405325735658382,"bounds":{"x":0.13913109953713193,"y":0.716959793883974,"width":0.6751843274447666,"height":0.03937530802257024}},{"text":"once in a turn, you may","confidence":1.0,"alternatives":[],"glyphHeight":0.03434850072612191,"bounds":{"x":0.13722003618139303,"y":0.7537962677672201,"width":0.5161311017335767,"height":0.04345615443898671}},{"text":"pay 1","confidence":1.0,"alternatives":[],"glyphHeight":0.029458225346958515,"bounds":{"x":0.6447075901932777,"y":0.7572209399679233,"width":0.13809850094092146,"height":0.036785475887469374}},{"text":"each time to prevent the damage.","confidence":1.0,"alternatives":[],"glyphHeight":0.03525076509691142,"bounds":{"x":0.13764923659346037,"y":0.786175971093857,"width":0.7205290570622067,"height":0.04330353238689368}},{"text":"Illus. Pete Venrers","confidence":1.0,"alternatives":[],"glyphHeight":0.02931501837865974,"bounds":{"x":0.07677368612468646,"y":0.9183872810638154,"width":0.3260758353224388,"height":0.03101252655484782}},{"text":"© 1995 Wizards of the Coast, Inc. All rights reserved.","confidence":1.0,"alternatives":[],"glyphHeight":0.0207447288444767,"bounds":{"x":0.0746490616409369,"y":0.9452754600975256,"width":0.5590246874796337,"height":0.0267756974519189}},{"text":"each time to prevent the","confidence":1.0,"alternatives":[],"glyphHeight":0.035483820924013365,"bounds":{"x":0.13809787373063526,"y":0.7867286029674971,"width":0.5113895734151204,"height":0.04027666080072058}},{"text":"lllus. Pete Venrers","confidence":1.0,"alternatives":[],"glyphHeight":0.029404063944350804,"bounds":{"x":0.07567754912236496,"y":0.9185778267121492,"width":0.3257144927978516,"height":0.031852414622810306}},{"text":"Enchantment","confidence":1.0,"alternatives":["Enchartment","Encharment"],"glyphHeight":0.02906978627045953,"bounds":{"x":0.08722108701507825,"y":0.5436046330705382,"width":0.290060868696733,"height":0.029069803655147552}}]}''',
      ) as Map<String, Object?>,
    );
    final List<MtgCard> cards = <MtgCard>[
      for (final String color in <String>['Red', 'Blue'])
        _Card(
          color.toLowerCase(),
          'Circle of Protection: $color',
          typeLine: 'Enchantment',
          oracleText:
              '{1}: The next time a ${color.toLowerCase()} source of your choice would deal damage to you this turn, prevent that damage.',
        ),
    ];
    final _Catalog catalog = _Catalog()..keywordCards = cards;
    final _BodyArtwork artwork = _BodyArtwork();
    final ScanResolver resolver = ScanResolver(
      catalog: catalog,
      artwork: artwork,
      symbols: _Symbol(),
    );
    final ScanResolution result = await resolver.resolve(actual);
    expect(result.hints.typeLine, 'enchantment');
    expect(result.hints.names, isEmpty);
    expect(result.hints.setCode, isNull);
    expect(result.hints.collectorNumber, isNull);
    expect(catalog.calls, <String>[
      'body:1; Prevent all damage against you/null/null/null/enchantment/1',
      'keywords:prevent,damage/null/null/null/enchantment/damage to you',
      'printings:Circle of Protection: Red/null/null/1',
      'printings:Circle of Protection: Blue/null/null/1',
    ]);
    expect(
      result.candidates.map((ScanCandidate candidate) => candidate.card.id),
      <String>['blue', 'red'],
    );
    expect(
      result.candidates.every(
        (ScanCandidate candidate) => !candidate.hasContradiction,
      ),
      isTrue,
    );
    expect(
      result.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.typeLineMatch,
        ScanEvidence.rulesTextMatch,
        ScanEvidence.rulesKeywordMatch,
        ScanEvidence.artworkCompared,
      ]),
    );
    expect(
      result.candidates.first.evidence,
      isNot(contains(ScanEvidence.nameMatch)),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(actual, result), isFalse);
    expect(artwork.calls, 1);
    expect(artwork.bodyFallback, isTrue);
    final _BodyArtwork coverage = _BodyArtwork();
    final List<MtgCard> allCandidates = <MtgCard>[
      ...cards,
      for (int index = 0; index < 28; index++)
        _Card(
          'extra-$index',
          'Alternative $index',
          typeLine: 'Enchantment',
          oracleText: cards.first.oracleText,
        ),
    ];
    final ScanResolution covered = await ScanResolver(
      catalog: _Catalog()..keywordCards = allCandidates,
      artwork: coverage,
      symbols: _Symbol(),
    ).resolve(actual);
    expect(
      coverage.comparedIds.toSet(),
      allCandidates.map((MtgCard card) => card.id).toSet(),
    );
    expect(coverage.bodyFallback, isTrue);
    expect(covered.candidates, hasLength(30));
    expect(covered.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(actual, covered), isFalse);

    for (final String condition in <String>[
      'missingType',
      'weakType',
      'oneRule',
      'weakRules',
      'tooMany',
      'paginated',
    ]) {
      final _Catalog bounded = _Catalog()
        ..keywordCards = condition == 'tooMany'
            ? List<MtgCard>.filled(33, cards.first)
            : cards
        ..hasMore = condition == 'paginated';
      final ScanCrop changed = ScanCrop(
        imagePath: actual.imagePath,
        width: actual.width,
        height: actual.height,
        rectified: actual.rectified,
        sourceCorners: actual.sourceCorners,
        warnings: actual.warnings,
        lines: actual.lines
            .where(
              (ScanTextLine line) =>
                  !(condition == 'missingType' && line.text == 'Enchantment') &&
                  !(condition == 'oneRule' &&
                      line.bounds.y > .69 &&
                      line.bounds.y < .86),
            )
            .map(
              (ScanTextLine line) => ScanTextLine(
                text: line.text,
                bounds: line.bounds,
                glyphHeight: line.glyphHeight,
                confidence:
                    (condition == 'weakType' && line.text == 'Enchantment') ||
                        (condition == 'weakRules' &&
                            line.bounds.y >= .64 &&
                            line.bounds.y < .86)
                    ? .70
                    : line.confidence,
                alternatives: line.alternatives,
              ),
            )
            .toList(),
      );
      final ScanResolution rejected = await ScanResolver(
        catalog: bounded,
        artwork: _BodyArtwork(),
        symbols: _Symbol(),
      ).resolve(changed);
      expect(rejected.candidates, isEmpty, reason: condition);
      expect(rejected.status, ScanResolutionStatus.noMatch, reason: condition);
      if (condition != 'tooMany' && condition != 'paginated') {
        expect(
          bounded.calls.any((String call) => call.startsWith('keywords:')),
          isFalse,
          reason: condition,
        );
      }
    }
  });

  test('actual neighboring damaged source rows cannot suppress intact body phrase fallback', () async {
    final List<ScanCrop> crops =
        (jsonDecode(
              r'''[{"imagePath":"/local/observed-card.jpg","width":1934,"height":2702,"rectified":true,"warnings":["incomplete_card","orientation_ensemble","geometry_adjusted"],"sharpness":0.8819666145699748,"sourceCorners":[{"x":0.5276235938072205,"y":0.43730807304382324},{"x":0.7433838844299316,"y":0.4343882203102112},{"x":0.8292797207832336,"y":0.5606080591678619},{"x":0.5400839447975159,"y":0.5651864111423492}],"lines":[{"text":"Enchantment","confidence":1.0,"alternatives":["Enchanement","Enchanament"],"glyphHeight":0.029069766391214835,"bounds":{"x":0.08519270430711297,"y":0.5421511632829866,"width":0.2900608382279279,"height":0.029069766391214835}},{"text":"1: Prevent all damage against you","confidence":1.0,"alternatives":["1 : Prevent all damage against you","1 Prevent all damage against you"],"glyphHeight":0.033965855729433524,"bounds":{"x":0.14508308458026217,"y":0.6444418003579098,"width":0.7258177069868149,"height":0.04579824451867254}},{"text":"PARAOДUOOULCO","confidence":0.30000001192092896,"alternatives":[],"glyphHeight":0.011418685067463385,"bounds":{"x":0.17877906785994033,"y":0.7000000000248865,"width":0.428779073437096,"height":0.011418685067463385}},{"text":"wa sourco","confidence":1.0,"alternatives":[],"glyphHeight":0.020792079793995864,"bounds":{"x":0.6208333299690973,"y":0.7,"width":0.23750000631180523,"height":0.02079207948271966}},{"text":"deals damage to you more than","confidence":1.0,"alternatives":[],"glyphHeight":0.03393849561481762,"bounds":{"x":0.14177035044835234,"y":0.7147220615003226,"width":0.6728103464120669,"height":0.04284684599326749}},{"text":"once in a turn, you may pay -","confidence":1.0,"alternatives":[],"glyphHeight":0.03332419877892262,"bounds":{"x":0.13716240518954814,"y":0.7586575639755972,"width":0.6463738552910095,"height":0.03706708917476859}},{"text":"each time to prevent the damage.","confidence":1.0,"alternatives":[],"glyphHeight":0.03658339976040337,"bounds":{"x":0.1390196285011177,"y":0.7849164797668196,"width":0.7250128255881593,"height":0.044536478766079614}},{"text":"Illus. Pete Venters","confidence":1.0,"alternatives":[],"glyphHeight":0.030652353620292155,"bounds":{"x":0.07646935686355766,"y":0.9165378950134473,"width":0.32958728746889543,"height":0.03443695500566456}},{"text":"© 1995 Wizards of the Coast, Inc. All rights reserved","confidence":1.0,"alternatives":[],"glyphHeight":0.019482327224594365,"bounds":{"x":0.07515512409357962,"y":0.9457757466432736,"width":0.5560039532098306,"height":0.028077600037523087}},{"text":"once in a turn, you may","confidence":1.0,"alternatives":[],"glyphHeight":0.030741346342095778,"bounds":{"x":0.1409327388886761,"y":0.76,"width":0.5086034656518593,"height":0.03523902905527957}},{"text":"each time to prevent the","confidence":1.0,"alternatives":[],"glyphHeight":0.03747155646703827,"bounds":{"x":0.13771196063866764,"y":0.784286985577746,"width":0.5121842716380788,"height":0.0459748563326322}},{"text":"lllus. Pete Venters","confidence":1.0,"alternatives":[],"glyphHeight":0.03140826604383289,"bounds":{"x":0.07706990229677646,"y":0.9169924102324533,"width":0.3284346976227146,"height":0.03413096078725963}}]},{"imagePath":"/local/observed-card.jpg","width":1963,"height":2742,"rectified":true,"warnings":["incomplete_card","orientation_ensemble","geometry_adjusted"],"sharpness":0.8840636303364093,"sourceCorners":[{"x":0.5278835296630859,"y":0.43765151500701904},{"x":0.7435005307197571,"y":0.4342581629753113},{"x":0.8295397162437439,"y":0.5608182549476624},{"x":0.5402694344520569,"y":0.5639385879039764}],"lines":[{"text":"Enchantment","confidence":1.0,"alternatives":["Encharment","Enchairment"],"glyphHeight":0.028371431976101,"bounds":{"x":0.08448853436573338,"y":0.544567272588424,"width":0.29554419119343495,"height":0.03391506270193678}},{"text":"1: Prevent all damage against you","confidence":1.0,"alternatives":["1; Prevent all damage against you","1 : Prevent all damage against you"],"glyphHeight":0.034853638359685864,"bounds":{"x":0.13558475679711832,"y":0.6461724461387919,"width":0.7393654631014511,"height":0.04581162322619636}},{"text":"hon one pre sourecrtr a source","confidence":1.0,"alternatives":[],"glyphHeight":0.02079207874038843,"bounds":{"x":0.1416666643865358,"y":0.7000000002277569,"width":0.7208333374769285,"height":0.02079207874038843}},{"text":"deals damage to you more than","confidence":1.0,"alternatives":[],"glyphHeight":0.03366666903900431,"bounds":{"x":0.14356924769681453,"y":0.7202339547776693,"width":0.6721242372470086,"height":0.03766333941117073}},{"text":"once in a turn, you may pay 1","confidence":1.0,"alternatives":[],"glyphHeight":0.037342020019737174,"bounds":{"x":0.14211341052070756,"y":0.7573447378371867,"width":0.6429951778497327,"height":0.041296641340533534}},{"text":"each time to prevent the damage.","confidence":1.0,"alternatives":[],"glyphHeight":0.035649291129524724,"bounds":{"x":0.1420488609520015,"y":0.7895064712804342,"width":0.7218253763047352,"height":0.0421050636513719}},{"text":"Illus. Pete Venters","confidence":1.0,"alternatives":[],"glyphHeight":0.03063506759982964,"bounds":{"x":0.07797797932808594,"y":0.9228388613248338,"width":0.3353818128162392,"height":0.0342537083672088}},{"text":"© 1995 Wizards of the Coast, Inc. All rights reserved.","confidence":1.0,"alternatives":[],"glyphHeight":0.020383288792272844,"bounds":{"x":0.07840157873940291,"y":0.9549511961246715,"width":0.5626721663776095,"height":0.021860274296362413}},{"text":"once in a turn, you may","confidence":1.0,"alternatives":[],"glyphHeight":0.0339082618495536,"bounds":{"x":0.14090796132799802,"y":0.76,"width":0.5088906315053144,"height":0.03974754655201648}},{"text":"each time to prévent th","confidence":1.0,"alternatives":[],"glyphHeight":0.03278881963407994,"bounds":{"x":0.1423396879597637,"y":0.7920589498417482,"width":0.4987715981223367,"height":0.03642606700550429}},{"text":"lllus. Pere Venters","confidence":1.0,"alternatives":[],"glyphHeight":0.029818181818181824,"bounds":{"x":0.0774294669482077,"y":0.924363636350672,"width":0.33009404388714725,"height":0.029818181818181824}}]}]''',
            ) as List<Object?>)
            .map(
              (Object? value) =>
                  ScanCrop.fromMap(value as Map<String, Object?>),
            )
            .toList();
    for (final ScanCrop crop in crops) {
      final _Catalog catalog = _Catalog()
        ..phraseCards = <MtgCard>[
          _Card(
            'blue',
            'Circle of Protection: Blue',
            typeLine: 'Enchantment',
            oracleText: '{1}: The next time a blue source of your choice would deal damage to you this turn, prevent that damage.',
          ),
          _Card(
            'red',
            'Circle of Protection: Red',
            typeLine: 'Enchantment',
            oracleText: '{1}: The next time a red source of your choice would deal damage to you this turn, prevent that damage.',
          ),
        ];
      final _BodyArtwork artwork = _BodyArtwork();
      final ScanResolution result = await ScanResolver(
        catalog: catalog,
        artwork: artwork,
        symbols: _Symbol(),
      ).resolve(crop);
      expect(hasVerifiedSavedBodyLayout(crop), isTrue);
      expect(
        catalog.calls.where((String call) => call.endsWith('/damage to you')),
        <String>[
          'keywords:prevent,damage/null/null/null/enchantment/damage to you',
        ],
        reason: '${crop.width}',
      );
      if (crop.width == 1963) {
        expect(
          catalog.calls,
          contains(
            'keywords:prevent,damage,source,sourecrtr/null/null/null/enchantment',
          ),
        );
      }
      expect(
        result.candidates.map((ScanCandidate candidate) => candidate.card.id),
        <String>['blue', 'red'],
      );
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(hasExactPrintingEvidence(crop, result), isFalse);
      expect(artwork.bodyFallback, isTrue);
    }
  });

  test('observed title color corroborates a one-letter source typo only for review search', () async {
    final _Catalog catalog = _Catalog()
      ..keywordCards = <MtgCard>[
        _Card(
          'rune',
          'Rune of Protection: Blue',
          typeLine: 'Enchantment',
          oracleText: '{W}: The next time a blue source of your choice would deal damage to you this turn, prevent that damage.\nCycling {2} ({2}, Discard this card: Draw a card.)',
        ),
        _Card(
          'circle',
          'Circle of Protection: Blue',
          typeLine: 'Enchantment',
          oracleText: '{1}: The next time a blue source of your choice would deal damage to you this turn, prevent that damage.',
        ),
        _Card(
          'sphere',
          'Sphere of Reason',
          typeLine: 'Enchantment',
          oracleText: 'If a blue source would deal damage to you, prevent 2 of that damage.',
        ),
      ];
    final ScanCrop crop = ScanCrop(
      imagePath: '',
      width: 2490,
      height: 3478,
      rectified: true,
      sourceCorners: _crop(const <ScanTextLine>[]).sourceCorners,
      warnings: const <String>['geometry_adjusted'],
      lines: <ScanTextLine>[
        _line('Sprele of Protections Blue', .03),
        _line('Enchantment', .5503),
        _line('1; Prevent all damage against you', .6548),
        _line('from one plue source? ira source', .70),
        _line('deals damage to you more than', .7288),
        _line('once in a turn, you may', .7621),
        _line('lime to prevent the', .8045),
      ],
    );
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(crop);
    expect(
      catalog.calls,
      contains(
        'keywords:blue,prevent,damage,source/null/null/null/enchantment',
      ),
    );
    expect(result.candidates.first.card.id, 'circle');
    expect(result.candidates.first.hasContradiction, isFalse);
    expect(result.candidates.first.evidence, contains(ScanEvidence.fuzzyName));
    expect(
      result.candidates.first.evidence,
      contains(ScanEvidence.rulesKeywordMatch),
    );
    expect(
      result.candidates.first.evidence,
      isNot(contains(ScanEvidence.rulesTextMatch)),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(crop, result), isFalse);
    expect(result.hints.names, <String>['Sprele of Protections Blue']);
    expect(
      result.hints.rulesText,
      contains('from one plue source? ira source'),
    );
  });

  test(
    'color corroboration covers all colors and retains catalog contradictions',
    () async {
      for (final (String, String) color in <(String, String)>[
        ('blue', 'plue'),
        ('red', 'fred'),
        ('white', 'whlte'),
        ('black', 'blacx'),
        ('green', 'greer'),
      ]) {
        final ScanCrop crop = _crop(<ScanTextLine>[
          _line('Shieid of ${color.$1}', .04),
          _line('Instant', .5),
          _line('Prevent all damage against you', .60),
          _line('from one ${color.$2} source.', .64),
        ]);
        final _Catalog catalog = _Catalog()
          ..keywordCards = <MtgCard>[
            _Card(
              'correct',
              'Shield of ${color.$1}',
              oracleText:
                  'Prevent all damage against you from one ${color.$1} source.',
            ),
          ];
        final ScanResolution result = await ScanResolver(catalog: catalog)
            .resolve(crop);
        expect(
          catalog.calls,
          contains(
            'keywords:${color.$1},prevent,damage,source/null/null/null/instant',
          ),
        );
        expect(result.candidates.single.hasContradiction, isFalse);
        expect(result.status, ScanResolutionStatus.needsReview);
        expect(hasExactPrintingEvidence(crop, result), isFalse);
        final String other = color.$1 == 'red' ? 'blue' : 'red';
        for (final bool wrongName in <bool>[false, true]) {
          final _Catalog contradictory = _Catalog()
            ..keywordCards = <MtgCard>[
              _Card(
                'wrong',
                'Shield of ${wrongName ? other : color.$1}',
                oracleText:
                    'Prevent all damage against you from one $other source.',
              ),
            ];
          final ScanResolution wrong = await ScanResolver(
            catalog: contradictory,
          ).resolve(crop);
          expect(wrong.candidates.single.hasContradiction, isTrue);
          expect(
            wrong.candidates.single.evidence,
            contains(ScanEvidence.rulesTextMismatch),
          );
          if (wrongName) {
            expect(
              wrong.candidates.single.evidence,
              contains(ScanEvidence.nameMismatch),
            );
          }
        }
      }
    },
  );

  test('color search repair requires confident unambiguous observed title and compatible body', () async {
    for (final (String, double, String?, double) condition
        in <(String, double, String?, double)>[
          ('Shield of Blue', .60, null, .97),
          ('Shield of Blue and Green', .97, null, .97),
          ('Shield', .97, null, .97),
          ('Shield of Blue', .97, 'Prevent damage from a red source.', .97),
          ('Shield of Blue', .97, null, .80),
        ]) {
      final _Catalog catalog = _Catalog();
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(
            _crop(<ScanTextLine>[
              ScanTextLine(
                text: condition.$1,
                confidence: condition.$2,
                bounds: const ScanBounds(.1, .04, .7, .025),
              ),
              _line('Instant', .5),
              _line('Prevent all damage against you', .60),
              ScanTextLine(
                text: 'from one plue source.',
                confidence: condition.$4,
                bounds: const ScanBounds(.1, .64, .7, .025),
              ),
              if (condition.$3 != null) _line(condition.$3!, .69),
            ]),
            name: condition.$1 == 'Shield' ? 'Shield of Blue' : null,
          );
      expect(result.status, ScanResolutionStatus.noMatch);
      expect(
        catalog.calls.any((String call) => call.startsWith('keywords:blue,')),
        isFalse,
      );
    }
    final _Catalog conflict = _Catalog()
      ..keywordCards = <MtgCard>[
        _Card(
          'red',
          'Shield of Red',
          oracleText: 'Prevent all damage against you from one red source.',
        ),
      ];
    final ScanResolution wrong = await ScanResolver(catalog: conflict).resolve(
      _crop(<ScanTextLine>[
        _line('Shieid of Blue', .04),
        _line('Instant', .5),
        _line('Prevent all damage against you', .60),
        _line('from one red source.', .64),
      ]),
    );
    expect(
      wrong.candidates.single.evidence,
      contains(ScanEvidence.nameMismatch),
    );
    expect(wrong.candidates.single.hasContradiction, isTrue);
  });

  test(
    'keyword search excludes desk text, single lines, and weak OCR',
    () async {
      expect(
        ScanResolver.rulesSearchKeywords(<String>[
          'Please place the computer here',
          'Use the keyboard and speaker',
        ]),
        isEmpty,
      );
      expect(
        ScanResolver.rulesSearchKeywords(<String>[
          'Prevent damage from a blue source.',
        ]),
        isEmpty,
      );
      expect(
        ScanResolver.rulesSearchKeywords(<String>[
          'Draw a card',
          'You gain two life',
        ]),
        isEmpty,
      );
      final _Catalog catalog = _Catalog();
      await ScanResolver(catalog: catalog).resolve(
        _crop(<ScanTextLine>[
          _line('Prevent all damage against you', .6),
          const ScanTextLine(
            text: 'from one blue source. If a source',
            confidence: .3,
            bounds: ScanBounds(.1, .64, .7, .025),
          ),
        ]),
      );
      expect(
        catalog.calls.any((String call) => call.startsWith('keywords:')),
        isFalse,
      );
    },
  );

  test(
    'keyword catalog uses four safe tokens and unique gameplay cards',
    () async {
      final List<Uri> requests = <Uri>[];
      final ScryfallScanCatalog catalog = ScryfallScanCatalog(
        api: ScryfallApiClient(
          httpClient: MockClient((http.Request request) async {
            requests.add(request.url);
            return http.Response(
              jsonEncode(<String, Object?>{
                'object': 'list',
                'data': <Object?>[],
                'has_more': false,
              }),
              200,
            );
          }),
        ),
      );
      await catalog.rulesKeywordCards(
        <String>['prevent', 'damage', 'blue', 'source'],
        setCode: '4ed',
        collectorNumber: '001a',
        language: 'en',
        typeLine: 'enchantment',
      );
      expect(requests.single.queryParameters['unique'], 'cards');
      expect(
        requests.single.queryParameters['q'],
        'oracle:prevent oracle:damage oracle:blue oracle:source game:paper set:"4ed" cn:"1a" lang:"en" type:"enchantment"',
      );
      await expectLater(
        catalog.rulesKeywordCards(<String>[
          'prevent',
          'damage',
          'blue',
          'source" or:*',
        ]),
        throwsArgumentError,
      );
      await catalog.rulesKeywordCards(<String>[
        'prevent',
        'damage',
        'red',
        'source',
      ]);
      expect(
        requests.last.queryParameters['q'],
        'oracle:prevent oracle:damage oracle:red oracle:source game:paper',
      );
      await expectLater(
        catalog.rulesKeywordCards(<String>[
          'prevent',
          'damage',
          'xyz',
          'source',
        ]),
        throwsArgumentError,
      );
      expect(requests, hasLength(2));
      await catalog.rulesKeywordCards(
        <String>['prevent', 'damage'],
        phrase: 'damage to you',
        typeLine: 'enchantment',
      );
      expect(
        requests.last.queryParameters['q'],
        'oracle:prevent oracle:damage game:paper oracle:"damage to you" type:"enchantment"',
      );
      expect(requests.last.queryParameters['unique'], 'cards');
      for (final (String?, String?) query in <(String?, String?)>[
        (null, 'enchantment'),
        ('damage to you', null),
        ('damage to you" or:*', 'enchantment'),
      ]) {
        await expectLater(
          catalog.rulesKeywordCards(
            <String>['prevent', 'damage'],
            phrase: query.$1,
            typeLine: query.$2,
          ),
          throwsArgumentError,
        );
      }
      expect(requests, hasLength(3));
      catalog.close();
    },
  );

  test('keyword extraction retains red while excluding other short tokens', () {
    expect(
      ScanResolver.rulesSearchKeywords(<String>[
        'Prevent all damage against you',
        'from one red source. If a source',
      ]),
      <String>['red', 'prevent', 'damage', 'source'],
    );
    expect(
      ScanResolver.rulesSearchKeywords(<String>[
        'Prevent all damage against you',
        'from one xyz source. If a source',
      ]),
      isEmpty,
    );
  });

  test('actual rectified Bats OCR keeps quoted flavor continuations out of rule contradictions', () async {
    final ScanCrop actual = ScanCrop.fromMap(
      jsonDecode(
        r'''{"imagePath":"","width":1393,"height":2023,"rectified":true,"warnings":[],"sharpness":0.8931803603654099,"sourceCorners":[{"x":0.2836645245552063,"y":0.18960803747177124},{"x":0.50181645154953,"y":0.17551612854003906},{"x":0.5721979737281799,"y":0.40818315744400024},{"x":0.3500847816467285,"y":0.4297069311141968}],"lines":[{"text":"Creature - Bat","confidence":1.0,"alternatives":["Creature -Bat","Creature- Bat"],"glyphHeight":0.024334972281233214,"bounds":{"x":0.13854996055616084,"y":0.5859920832080778,"width":0.2779421046953461,"height":0.030046795667866943}},{"text":"Flying","confidence":1.0,"alternatives":["Flyin","Fying"],"glyphHeight":0.033430231418534295,"bounds":{"x":0.13924050746066727,"y":0.6584302328493569,"width":0.1350210947833068,"height":0.033430231418534295}},{"text":"Whenever you create or sachulc a","confidence":1.0,"alternatives":[],"glyphHeight":0.027807680183557386,"bounds":{"x":0.14648606781258536,"y":0.7,"width":0.6591951433179026,"height":0.030905419915543162}},{"text":"token, each opponent loses 1 life.","confidence":1.0,"alternatives":[],"glyphHeight":0.03434284706787942,"bounds":{"x":0.1425591158956196,"y":0.7186871733534105,"width":0.6449524538759863,"height":0.05414251967480307}},{"text":"\"The enemy has many spies and many","confidence":1.0,"alternatives":[],"glyphHeight":0.03462313637854156,"bounds":{"x":0.13723886730568605,"y":0.7745902634811036,"width":0.6939604880991077,"height":0.05314601408807855}},{"text":"ways of hearingạẠại","confidence":1.0,"alternatives":[],"glyphHeight":0.03644593126203016,"bounds":{"x":0.14110069027772265,"y":0.8114839548017783,"width":0.32737766960943104,"height":0.05935657400833935}},{"text":"—Gandalf","confidence":1.0,"alternatives":[],"glyphHeight":0.028224040110192396,"bounds":{"x":0.15062257228443454,"y":0.8555690872952497,"width":0.19876853910032954,"height":0.030482895123331175}},{"text":"C 0095","confidence":1.0,"alternatives":[],"glyphHeight":0.019359088100992006,"bounds":{"x":0.1089840147507547,"y":0.9196738461624788,"width":0.1060525464532707,"height":0.023323077904550658}},{"text":"LTR • EN TOHN TEDRICK","confidence":1.0,"alternatives":[],"glyphHeight":0.015578393235859002,"bounds":{"x":0.1209152369708358,"y":0.9264310734339576,"width":0.2922972100365966,"height":0.027191350334569063}},{"text":"2/3","confidence":1.0,"alternatives":[],"glyphHeight":0.0279999996486463,"bounds":{"x":0.7732558150586301,"y":0.8670000000201213,"width":0.06540697445315302,"height":0.0279999996486463}},{"text":"© MEE","confidence":1.0,"alternatives":[],"glyphHeight":0.012773986239812844,"bounds":{"x":0.5829353641209033,"y":0.9022274668896804,"width":0.06950456134900129,"height":0.01684463682927585}},{"text":"™M & © 2023 Wizards of the Coast •","confidence":1.0,"alternatives":[],"glyphHeight":0.014505632590504119,"bounds":{"x":0.582119432573114,"y":0.907379604796779,"width":0.30521689460130474,"height":0.025977847450657898}},{"text":"\"The enemy has many spies","confidence":1.0,"alternatives":[],"glyphHeight":0.03310583124121454,"bounds":{"x":0.1398926788935085,"y":0.7817153933344507,"width":0.5040556210818934,"height":0.0441398564091435}},{"text":"ways of hearingạẠạ","confidence":1.0,"alternatives":[],"glyphHeight":0.035156751646918956,"bounds":{"x":0.1399086127623928,"y":0.812770845578648,"width":0.3279119916835895,"height":0.057567862051504624}},{"text":"Gandalf","confidence":1.0,"alternatives":[],"glyphHeight":0.031604938271604925,"bounds":{"x":0.15496688818487858,"y":0.8538271603358025,"width":0.19657836644591614,"height":0.031604938271604925}},{"text":"Mirkwood Bats","confidence":1.0,"alternatives":["Mirkwood Bat","Mirkwood Bas"],"glyphHeight":0.03156251708445177,"bounds":{"x":0.14331357593113006,"y":0.0782248839463423,"width":0.33320199536798334,"height":0.034256847993827166}}]}''',
      ) as Map<String, Object?>,
    );
    final _Card reference = _Card(
      'bats',
      'Mirkwood Bats',
      set: 'ltr',
      collectorNumber: '95',
      typeLine: 'Creature — Bat',
      oracleText: 'Flying\nWhenever you create or sacrifice a token, each opponent loses 1 life.',
      flavorText:
          '"The enemy has many spies and many ways of hearing."\n—Gandalf',
    );
    final _Catalog catalog = _Catalog()..exact = reference;
    final _Artwork artwork = _Artwork();
    final ScanResolver resolver = ScanResolver(
      catalog: catalog,
      artwork: artwork,
    );
    ScanCrop withText(String before, String after) => ScanCrop(
      imagePath: actual.imagePath,
      width: actual.width,
      height: actual.height,
      rectified: actual.rectified,
      sourceCorners: actual.sourceCorners,
      warnings: actual.warnings,
      sharpness: actual.sharpness,
      lines: actual.lines
          .map(
            (ScanTextLine line) => ScanTextLine(
              text: line.text == before ? after : line.text,
              confidence: line.confidence,
              bounds: line.bounds,
              glyphHeight: line.glyphHeight,
              alternatives: line.alternatives,
            ),
          )
          .toList(),
    );
    final ScanResolution result = await resolver.resolve(actual);
    expect(result.hints.collectorNumber, '0095');
    expect(result.hints.setCode, 'ltr');
    expect(result.hints.language, 'en');
    expect(result.hints.postQuoteText, contains('ways of hearingạẠại'));
    expect(result.hints.rulesText, isNot(contains('ways of hearingạẠại')));
    expect(
      result.candidates.single.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.nameMatch,
        ScanEvidence.footerMatch,
        ScanEvidence.collectorNumberMatch,
        ScanEvidence.languageMatch,
        ScanEvidence.rulesTextMatch,
      ]),
    );
    expect(catalog.calls, <String>['ltr/0095/en']);
    expect(artwork.calls, 0);
    expect(result.candidates.single.hasContradiction, isFalse);
    expect(
      result.candidates.single.evidence,
      isNot(contains(ScanEvidence.rulesTextMismatch)),
    );

    final ScanCrop expandedNoise = ScanCrop.fromMap(
      jsonDecode(
        r'''{"imagePath":"","width":1377,"height":1989,"rectified":true,"warnings":[],"sharpness":0.8946823726717592,"sourceCorners":[{"x":0.282105952501297,"y":0.1894322633743286},{"x":0.5025120973587036,"y":0.17459791898727417},{"x":0.5716971158981323,"y":0.4087718725204468},{"x":0.34988167881965637,"y":0.42842239141464233}],"lines":[{"text":"Creature - Bat","confidence":1.0,"alternatives":["Creature -Bat","Creature- Bat"],"glyphHeight":0.024675510491248276,"bounds":{"x":0.14156927396982552,"y":0.5812509528499239,"width":0.27862340653063766,"height":0.03226781107073451}},{"text":"Flying","confidence":1.0,"alternatives":["Flyin","Flyng"],"glyphHeight":0.03197674391856742,"bounds":{"x":0.1383647823480147,"y":0.6569767441199315,"width":0.13626833889411738,"height":0.03197674391856742}},{"text":"Whenever you create or saemy","confidence":1.0,"alternatives":[],"glyphHeight":0.026815110224894138,"bounds":{"x":0.145195018512425,"y":0.7,"width":0.6093856302158925,"height":0.028039580693747058}},{"text":"token, each opponent loses 1 life.","confidence":1.0,"alternatives":[],"glyphHeight":0.03591257138102241,"bounds":{"x":0.14242982058360532,"y":0.7124555959460631,"width":0.6497334119024402,"height":0.05936974745530346}},{"text":"\"The enemy has many spies and many","confidence":1.0,"alternatives":[],"glyphHeight":0.03642544213182519,"bounds":{"x":0.1403659555002553,"y":0.770234245877223,"width":0.6992933829740793,"height":0.061381025537599304}},{"text":"ways of hearingạẠạồi","confidence":1.0,"alternatives":[],"glyphHeight":0.03547337014202491,"bounds":{"x":0.14117495785969256,"y":0.8096707415863307,"width":0.33156374196355676,"height":0.06004876867185866}},{"text":"—Gandalf","confidence":1.0,"alternatives":[],"glyphHeight":0.030312857111264083,"bounds":{"x":0.1434998697446842,"y":0.8538240460687891,"width":0.20861158661641643,"height":0.031220226861960108}},{"text":"C 0095","confidence":1.0,"alternatives":[],"glyphHeight":0.019494399991820316,"bounds":{"x":0.10893019454421038,"y":0.9202230159755154,"width":0.10760206823252108,"height":0.023682707847161453}},{"text":"LTR • EN JOHN TEDRICK","confidence":1.0,"alternatives":[],"glyphHeight":0.017381109092609773,"bounds":{"x":0.11954690577914198,"y":0.9254409502581165,"width":0.3111116716581436,"height":0.02992423417974875}},{"text":"2/3","confidence":1.0,"alternatives":[],"glyphHeight":0.027090301003344464,"bounds":{"x":0.7761627908709904,"y":0.8635451504401034,"width":0.06686046473000662,"height":0.027090301003344464}},{"text":"© MEE","confidence":1.0,"alternatives":[],"glyphHeight":0.013698171213717747,"bounds":{"x":0.5881531242594856,"y":0.9010709481398825,"width":0.06676600529597365,"height":0.013698171213717747}},{"text":"™M & © 2023 Wizards of the Coast •","confidence":1.0,"alternatives":[],"glyphHeight":0.01829131282160291,"bounds":{"x":0.5863101268052602,"y":0.9017620045145038,"width":0.2980016035680675,"height":0.032887548746472615}},{"text":"\"The enemy has many spies","confidence":1.0,"alternatives":[],"glyphHeight":0.0341162655502436,"bounds":{"x":0.13984705327120517,"y":0.7778498602787337,"width":0.5072251558303833,"height":0.04856285127136997}},{"text":"ways of hearingạẠạỊạ","confidence":1.0,"alternatives":[],"glyphHeight":0.03569358170038658,"bounds":{"x":0.14090432099717512,"y":0.8102543841322121,"width":0.33122111048017233,"height":0.06071691537003137}},{"text":"-Gandalf","confidence":1.0,"alternatives":[],"glyphHeight":0.03045700162926646,"bounds":{"x":0.14254910527027542,"y":0.8531269271697439,"width":0.2106562444141933,"height":0.03447282224519482}},{"text":"Mirkwood Bats","confidence":1.0,"alternatives":["Mirkwood Bat","MirkwoodBats"],"glyphHeight":0.03092166019948644,"bounds":{"x":0.14664850454526138,"y":0.07646982770043897,"width":0.33321840150608895,"height":0.03220632513197895}}]}''',
      ) as Map<String, Object?>,
    );
    final ScanResolution expandedResult = await resolver.resolve(expandedNoise);
    expect(
      expandedResult.candidates.single.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.nameMatch,
        ScanEvidence.footerMatch,
        ScanEvidence.rulesTextMatch,
      ]),
    );
    expect(expandedResult.candidates.single.hasContradiction, isFalse);
    expect(expandedResult.hints.postQuoteText, contains('ways of hearingạẠạồi'));
    expect(expandedResult.hints.postQuoteText, contains('ways of hearingạẠạỊạ'));

    for (final String text in <String>[
      'ways of hearingạẠại blue',
      'ways of hearingạẠại nonartifact',
      'ways of hearingạẠạồi three blue',
      'ways of hearingạẠạỊạ nonartifact',
      'ways of hearingredạ with Gandalf',
      'entirely unrelated destructive prose',
    ]) {
      final ScanResolution negative = await resolver.resolve(
        withText('ways of hearingạẠại', text),
      );
      expect(negative.status, ScanResolutionStatus.noMatch, reason: text);
      expect(negative.candidates, isEmpty, reason: text);
      expect(negative.hints.names, <String>['Mirkwood Bats'], reason: text);
      expect(negative.hints.setCode, 'ltr', reason: text);
      expect(negative.hints.collectorNumber, '0095', reason: text);
      expect(negative.hints.language, 'en', reason: text);
      expect(negative.hints.postQuoteText, contains(text), reason: text);
      expect(negative.hints.rulesText, isNot(contains(text)), reason: text);
    }
    final ScanResolution wrongNumber = await resolver.resolve(
      withText(
        'token, each opponent loses 1 life.',
        'token, each opponent loses 2 life.',
      ),
    );
    expect(wrongNumber.status, ScanResolutionStatus.noMatch);
    expect(wrongNumber.candidates, isEmpty);
    expect(wrongNumber.hints.names, <String>['Mirkwood Bats']);
    expect(wrongNumber.hints.setCode, 'ltr');
    expect(wrongNumber.hints.collectorNumber, '0095');
    expect(wrongNumber.hints.language, 'en');
    expect(
      wrongNumber.hints.rulesText,
      contains('token, each opponent loses 2 life.'),
    );
  });

  test('post-quote oracle overlap cannot supply rules proof without catalog flavor', () async {
    const String rules = 'Destroy target nonartifact creature.';
    for (final bool observedRules in <bool>[false, true]) {
      for (final String? flavor in <String?>[
        null,
        'The distant voices faded into silence.',
      ]) {
        final _Catalog catalog = _Catalog()
          ..cards = <MtgCard>[
            _Card('spell', 'Spell', oracleText: rules, flavorText: flavor),
          ];
        final ScanCrop crop = _crop(<ScanTextLine>[
          _line('Spell', .04),
          _line('Instant', .54),
          if (observedRules) _line(rules, .60),
          _line('"I remember', .68),
          _line(rules, .74),
        ]);
        final ScanResolution result = await ScanResolver(
          catalog: catalog,
          artwork: _Artwork(),
        ).resolve(crop);

        expect(result.hints.rulesText, observedRules ? <String>[rules] : isEmpty);
        expect(result.hints.postQuoteText, <String>[rules]);
        expect(result.candidates.single.hasContradiction, isFalse);
        expect(
          result.candidates.single.evidence.contains(ScanEvidence.rulesTextMatch),
          observedRules,
          reason: 'prequote rules: $observedRules; flavor: $flavor',
        );
        expect(hasExactPrintingEvidence(crop, result), isFalse);
      }
    }
  });

  test('post-quote observations cannot join a short prequote row into rules proof', () async {
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _Card('spell', 'Spell', oracleText: 'Destroy target nonartifact creature.'),
      ];
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
    ).resolve(_crop(<ScanTextLine>[
      _line('Spell', .04),
      _line('Instant', .54),
      _line('Destroy target', .60),
      _line('"I remember', .68),
      _line('nonartifact creature.', .74),
    ]));

    expect(result.hints.rulesText, <String>['Destroy target']);
    expect(result.hints.postQuoteText, <String>['nonartifact creature.']);
    expect(
      result.candidates.single.evidence,
      isNot(contains(ScanEvidence.rulesTextMatch)),
    );
  });

  test('post-quote contradictions survive automatic and manual hint copies', () async {
    for (final bool manual in <bool>[false, true]) {
      final _Catalog catalog = _Catalog()
        ..cards = <MtgCard>[
          _Card('spell', 'Spell', oracleText: 'You draw two cards.'),
        ];
      final ScanResolution result = await ScanResolver(
        catalog: catalog,
        artwork: _Artwork(),
      ).resolve(
        _crop(<ScanTextLine>[
          _line('Spell', .04),
          _line('Instant', .54),
          _line('You draw two cards.', .60),
          _line('"I remember', .68),
          _line('Destroy target nonartifact creature.', .74),
        ]),
        name: manual ? 'Spell' : null,
      );

      expect(result.hints.postQuoteText, <String>[
        'Destroy target nonartifact creature.',
      ]);
      expect(
        result.candidates.single.evidence,
        containsAll(<ScanEvidence>[
          ScanEvidence.rulesTextMatch,
          ScanEvidence.rulesTextMismatch,
        ]),
        reason: 'manual: $manual',
      );
    }
  });

  test('post-quote text cannot drive phrase keyword or filtered body lookup', () async {
    const List<String> quoted = <String>[
      'Destroy target nonartifact creature.',
      'Whenever a creature attacks alone.',
      'Return another creature to your hand.',
    ];
    expect(ScanResolver.rulesSearchPhrase(quoted), isNotNull);
    expect(ScanResolver.rulesSearchKeywords(quoted), isNotEmpty);
    for (final double confidence in <double>[.80, .97]) {
      final ScanCrop crop = _crop(<ScanTextLine>[
        _line('Enchantment', .52),
        ScanTextLine(
          text: '"Witness',
          confidence: confidence,
          bounds: const ScanBounds(.1, .59, .7, .025),
        ),
        for (int index = 0; index < quoted.length; index++)
          _line(quoted[index], .65 + index * .06),
      ]);
      final _Catalog catalog = _Catalog();
      final ScanResolution result = await ScanResolver(
        catalog: catalog,
        artwork: _Artwork(),
      ).resolve(crop);

      expect(result.hints.rulesText, isEmpty, reason: '$confidence');
      expect(result.hints.postQuoteText, quoted, reason: '$confidence');
      expect(catalog.calls, isEmpty, reason: '$confidence');
      expect(result.status, ScanResolutionStatus.noMatch, reason: '$confidence');
    }
  });

  test('post-quote self-reference rows cannot qualify through a weak or short opener', () {
    for (final (double, String) opener in <(double, String)>[
      (.80, '"The decree is remembered'),
      (.97, '"Witness'),
    ]) {
      final ScanCrop crop = _crop(<ScanTextLine>[
        _line('Never', .04),
        _line('Enchantment', .50),
        ScanTextLine(
          text: opener.$2,
          confidence: opener.$1,
          bounds: const ScanBounds(.1, .55, .7, .025),
        ),
        _line('As Nevermore enters the battlefield,', .61),
        _line('name a nonland card.', .67),
        _line("The named card can't be cast.", .73),
      ]);
      expect(ScanHints.fromCrop(crop).rulesText, isEmpty, reason: '$opener');
      expect(ScanHints.fromCrop(crop).postQuoteText, hasLength(3), reason: '$opener');
      expect(ScanHints.observedBodySelfReference(crop), isNull, reason: '$opener');
    }
  });

  test('post-quote duplicate rows cannot complete independent self-reference evidence', () {
    const String self = 'As Nevermore enters the battlefield,';
    final ScanCrop crop = _crop(<ScanTextLine>[
      _line('Never', .04),
      _line('Enchantment', .50),
      _line(self, .56),
      const ScanTextLine(
        text: '"Witness',
        confidence: .80,
        bounds: ScanBounds(.1, .61, .7, .025),
      ),
      _line(self, .67),
      _line(self, .73),
    ]);
    expect(ScanHints.fromCrop(crop).rulesText, <String>[self]);
    expect(ScanHints.fromCrop(crop).postQuoteText, <String>[self, self]);
    expect(ScanHints.observedBodySelfReference(crop), isNull);
  });

  test('known flavor text does not contradict matching rules or count as rules proof', () async {
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _Card(
          'nevermore',
          'Nevermore',
          oracleText: "As this enchantment enters, choose a nonland card name. Spells with the chosen name can't be cast.",
          flavorText: 'By the law of Avacyn, the following thoughts, words, and deeds are henceforth disallowed.',
          artist: 'Jason A. Engle',
          typeLine: 'Enchantment',
        ),
      ];
    final ScanResolution result = await ScanResolver(catalog: catalog).resolve(
      _partial(<ScanTextLine>[
        _line('Nevermore', .04),
        _line('Enchantment', .4),
        _line('name a nonland card.', .54),
        _line('thoughts, words, and deeds are', .72),
        _line('henceforth disallowed.', .76),
        _line('houghts, words,', .73),
        _line('- Jason A. Engle', .84),
      ]),
    );
    expect(result.candidates.single.hasContradiction, isFalse);
    expect(
      result.candidates.single.evidence,
      contains(ScanEvidence.rulesTextMatch),
    );
    final ScanResolution onlyFlavor = await ScanResolver(catalog: catalog)
        .resolve(
          _crop(<ScanTextLine>[
            _line('Nevermore', .04),
            _line('thoughts, words, and deeds are', .72),
          ]),
        );
    expect(onlyFlavor.candidates.single.hasContradiction, isFalse);
    expect(
      onlyFlavor.candidates.single.evidence,
      isNot(contains(ScanEvidence.rulesTextMatch)),
    );
  });

  test(
    'contained noisy flavor OCR does not become a contradictory joined rule',
    () async {
      const List<ScanTextLine> observations = <ScanTextLine>[
        ScanTextLine(
          text: 'Nevermore',
          confidence: 1,
          bounds: ScanBounds(.041653, .032959, .324595, .057937),
        ),
        ScanTextLine(
          text: 'Enchantment',
          confidence: 1,
          bounds: ScanBounds(.044372, .456162, .398549, .071306),
        ),
        ScanTextLine(
          text: 'As Nevermore enters the ba',
          confidence: 1,
          bounds: ScanBounds(.043155, .525557, .956845, .128717),
        ),
        ScanTextLine(
          text: 'name a nonland card.',
          confidence: 1,
          bounds: ScanBounds(.042006, .558260, .765704, .124522),
        ),
        ScanTextLine(
          text: "The named card can't be c",
          confidence: 1,
          bounds: ScanBounds(.032526, .617635, .962288, .136756),
        ),
        ScanTextLine(
          text: 'By the law of Avacyn, the fo',
          confidence: 1,
          bounds: ScanBounds(.082102, .70, .917898, .127087),
        ),
        ScanTextLine(
          text: 'thoughts, words, and deeds ar',
          confidence: 1,
          bounds: ScanBounds(.035308, .726092, .964692, .142455),
        ),
        ScanTextLine(
          text: 'ughis, woras, ar',
          confidence: 1,
          bounds: ScanBounds(.142921, .76, .507079, .078595),
        ),
        ScanTextLine(
          text: 'henceforth disallor',
          confidence: 1,
          bounds: ScanBounds(.034211, .774188, .615789, .101687),
        ),
      ];
      final _Catalog catalog = _Catalog()
        ..cards = <MtgCard>[
          _Card(
            'nevermore',
            'Nevermore',
            typeLine: 'Enchantment',
            oracleText: "As this enchantment enters, choose a nonland card name. Spells with the chosen name can't be cast.",
            flavorText: 'By the law of Avacyn, the following thoughts, words, and deeds are henceforth disallowed.',
          ),
        ];
      final ScanResolver resolver = ScanResolver(catalog: catalog);
      final ScanCrop actual = _partial(observations);
      final ScanResolution result = await resolver.resolve(actual);
      expect(result.hints.rulesText, contains('ughis, woras, ar'));
      expect(actual.lines, observations);
      expect(result.candidates.single.hasContradiction, isFalse);
      expect(
        result.candidates.single.evidence,
        contains(ScanEvidence.rulesTextMatch),
      );
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(hasExactPrintingEvidence(actual, result), isFalse);

      for (final (String, ScanBounds) fragment in <(String, ScanBounds)>[
        ('ughis, woras, ar', const ScanBounds(0, .76, .20, .078595)),
        ('words three blue', observations[7].bounds),
        ('words nonartifact ar', observations[7].bounds),
        ('Destroy target nonartifact creature.', observations[7].bounds),
        ('entirely unrelated prose', observations[7].bounds),
      ]) {
        final List<ScanTextLine> changed = List<ScanTextLine>.of(observations);
        changed[7] = ScanTextLine(
          text: fragment.$1,
          confidence: 1,
          bounds: fragment.$2,
        );
        final ScanResolution negative = await resolver.resolve(
          _partial(changed),
        );
        expect(negative.hints.rulesText, contains(fragment.$1));
        expect(
          negative.candidates.single.evidence,
          contains(ScanEvidence.rulesTextMismatch),
          reason: fragment.$1,
        );
      }
      final ScanResolution flavorOnly = await resolver.resolve(
        _partial(<ScanTextLine>[
          observations[0],
          observations[1],
          ...observations.skip(5),
        ]),
      );
      expect(flavorOnly.candidates.single.hasContradiction, isFalse);
      expect(
        flavorOnly.candidates.single.evidence,
        isNot(contains(ScanEvidence.rulesTextMatch)),
      );
    },
  );

  test(
    'unknown prose still contradicts rules instead of being assumed flavor',
    () async {
      final _Catalog catalog = _Catalog()
        ..cards = <MtgCard>[
          _Card(
            'protection',
            'Protection',
            oracleText: 'Prevent all damage from a blue source.',
            flavorText: 'The sea shone brilliantly beneath the moon.',
          ),
        ];
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(
            _crop(<ScanTextLine>[
              _line('Protection', .04),
              _line('thoughts, words, and deeds are', .72),
            ]),
          );
      expect(result.candidates.single.hasContradiction, isTrue);
    },
  );

  test('flavor classification preserves numeric color and non qualifier contradictions', () async {
    for (final (String, String) pair in <(String, String)>[
      (
        'Destroy target creature with toughness of two or less.',
        'Destroy target creature with toughness of three or less.',
      ),
      (
        'Prevent all damage from one blue source this turn.',
        'Prevent all damage from one black source this turn.',
      ),
      (
        'Destroy target nonartifact creature with toughness of three or less.',
        'Destroy target artifact creature with toughness of three or less.',
      ),
    ]) {
      final _Catalog catalog = _Catalog()
        ..cards = <MtgCard>[
          _Card('sample', 'Sample', oracleText: pair.$2, flavorText: pair.$2),
        ];
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(
            _crop(<ScanTextLine>[_line('Sample', .04), _line(pair.$1, .64)]),
          );
      expect(
        result.candidates.single.hasContradiction,
        isTrue,
        reason: pair.$1,
      );
    }
  });

  test('rule colors contradict otherwise matching candidates', () async {
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _Card(
          'wrong',
          'Protection',
          oracleText: 'Prevent all damage from one black source.',
        ),
      ];
    final ScanResolution result = await ScanResolver(catalog: catalog).resolve(
      _crop(<ScanTextLine>[
        _line('Protection', .04),
        _line('Prevent all damage from one blue source.', .6),
      ]),
    );
    expect(
      result.candidates.single.evidence,
      contains(ScanEvidence.rulesTextMismatch),
    );
    expect(result.candidates.single.hasContradiction, isTrue);
  });

  test('set-symbol distance separates text and shared-art ties without confirming printing', () async {
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _Card('edition-a', 'Island'),
        _Card('edition-b', 'Island'),
      ];
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: _Artwork(),
      symbols: _Symbol(),
    ).resolve(_crop(<ScanTextLine>[_line('Island', .04)]));
    expect(result.candidates.first.card.id, 'edition-b');
    expect(result.candidates.first.symbolDistance, .1);
    expect(
      result.candidates.first.evidence,
      contains(ScanEvidence.symbolCompared),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
  });

  test('complete saved same-art same-set printings avoid nondiscriminating visual work', () async {
    final _Catalog catalog = _Catalog()
      ..cards = <MtgCard>[
        _sceneCollectorCard('ordinary', '735'),
        _sceneCollectorCard('near', '712'),
      ];
    final _Artwork artwork = _Artwork();
    final _Symbol symbols = _Symbol();
    final ScanCrop crop = _sceneCollectorCrop();
    final ScanResolution result = await ScanResolver(
      catalog: catalog,
      artwork: artwork,
      symbols: symbols,
    ).resolve(crop);
    expect(artwork.calls, 0);
    expect(symbols.calls, 0);
    expect(
      result.candidates.map((ScanCandidate candidate) => candidate.card.id),
      <String>['near', 'ordinary'],
    );
    expect(result.hints.setCode, isNull);
    expect(result.hints.collectorNumber, isNull);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(
      result.candidates.first.evidence,
      contains(ScanEvidence.collectorNumberSimilar),
    );
    expect(
      result.candidates
          .map((ScanCandidate candidate) => candidate.score)
          .toSet(),
      hasLength(1),
    );
    for (final ScanCandidate candidate in result.candidates) {
      expect(candidate.artworkDistance, isNull);
      expect(candidate.symbolDistance, isNull);
      expect(candidate.evidence, isNot(contains(ScanEvidence.artworkCompared)));
      expect(candidate.evidence, isNot(contains(ScanEvidence.symbolCompared)));
    }
    expect(hasExactPrintingEvidence(crop, result), isFalse);
  });

  test('distinct unknown incomplete or fuzzy references still receive visual comparisons', () async {
    for (final List<MtgCard> cards in <List<MtgCard>>[
      <MtgCard>[
        _sceneCollectorCard('first', '735', illustration: null),
        _sceneCollectorCard('second', '712', illustration: null),
      ],
      <MtgCard>[
        _sceneCollectorCard('first', '735'),
        _sceneCollectorCard('second', '712', illustration: 'other-art'),
      ],
      <MtgCard>[
        _sceneCollectorCard('first', '735'),
        _sceneCollectorCard('second', '712', set: 'other'),
      ],
    ]) {
      final _Artwork artwork = _Artwork();
      final _Symbol symbols = _Symbol();
      await ScanResolver(
        catalog: _Catalog()..cards = cards,
        artwork: artwork,
        symbols: symbols,
      ).resolve(_sceneCollectorCrop());
      expect(artwork.calls, 1);
      expect(symbols.calls, 1);
    }
    final List<MtgCard> shared = <MtgCard>[
      _sceneCollectorCard('first', '735'),
      _sceneCollectorCard('second', '712'),
    ];
    final _Artwork incompleteArtwork = _Artwork();
    final _Symbol incompleteSymbols = _Symbol();
    await ScanResolver(
      catalog: _Catalog()
        ..cards = shared
        ..hasMore = true,
      artwork: incompleteArtwork,
      symbols: incompleteSymbols,
    ).resolve(_sceneCollectorCrop());
    expect(incompleteArtwork.calls, 1);
    expect(incompleteSymbols.calls, 1);

    final _Artwork fuzzyArtwork = _Artwork();
    final _Symbol fuzzySymbols = _Symbol();
    final _NameIndex index = _NameIndex()
      ..matches['Fixture Spell'] = const ScanNameMatch(
        canonicalName: 'Fixture  Spell',
        exact: false,
      );
    await ScanResolver(
      catalog: _Catalog()..cards = shared,
      nameIndex: index,
      artwork: fuzzyArtwork,
      symbols: fuzzySymbols,
    ).resolve(_sceneCollectorCrop());
    expect(fuzzyArtwork.calls, 1);
    expect(fuzzySymbols.calls, 1);
  });

  test('clean title and exact footer avoid optional visual network and native work', () async {
    final _Catalog catalog = _Catalog()..exact = _Card('edition-a', 'Island');
    final _Artwork artwork = _Artwork();
    final _Symbol symbols = _Symbol();
    final ScanResolver resolver = ScanResolver(
      catalog: catalog,
      artwork: artwork,
      symbols: symbols,
    );
    final ScanResolution exact = await resolver.resolve(
      _crop(<ScanTextLine>[
        _line('Island', .04),
        _line('0123 R', .87),
        _line('MOM EN', .91),
      ]),
    );
    expect(exact.status, ScanResolutionStatus.exactPrinting);
    expect(artwork.calls, 0);
    expect(symbols.calls, 0);
    catalog.exact = null;
    catalog.cards = <MtgCard>[
      _Card('edition-a', 'Island'),
      _Card('edition-b', 'Island'),
    ];
    await resolver.resolve(_crop(<ScanTextLine>[_line('Island', .04)]));
    expect(artwork.calls, 1);
    expect(symbols.calls, 1);
  });

  test('network errors remain errors, rather than no-match results', () async {
    final _Catalog catalog = _Catalog()..failure = StateError('offline');
    await expectLater(
      ScanResolver(catalog: catalog)
          .resolve(_crop(<ScanTextLine>[_line('Island', 0.05)])),
      throwsStateError,
    );
  });

  test(
    'native adapter decodes crop coordinates and prevents overlap',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final Completer<Map<String, Object>> pending =
          Completer<Map<String, Object>>();
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeCardRecognizer.channel, (
            MethodCall call,
          ) {
            calls.add(call);
            return pending.future;
          });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeCardRecognizer.channel, null);
      });
      final NativeCardRecognizer recognizer = NativeCardRecognizer();
      final Future<ScanRecognition> result = recognizer.recognize(
        '/local/original.heic',
      );
      await expectLater(
        recognizer.recognize('/local/second.jpg'),
        throwsStateError,
      );
      pending.complete(<String, Object>{
        'imagePath': '/local/original.heic',
        'width': 3024,
        'height': 4032,
        'crops': <Object>[
          <String, Object>{
            'imagePath': '/local/corrected.jpg',
            'width': 745,
            'height': 1040,
            'rectified': true,
            'sourceCorners': <Object>[
              <String, double>{'x': 0.1, 'y': 0.2},
            ],
            'lines': <Object>[
              <String, Object>{
                'text': 'Island',
                'confidence': 0.98,
                'alternatives': <String>['Is land'],
                'bounds': <String, double>{
                  'x': 0.1,
                  'y': 0.04,
                  'width': 0.7,
                  'height': 0.03,
                },
              },
            ],
            'warnings': <String>[],
          },
        ],
      });
      final ScanRecognition decoded = await result;
      expect(decoded.crops.single.lines.single.bounds.y, 0.04);
      expect(decoded.crops.single.sourceCorners.single.y, 0.2);
      expect(decoded.crops.single.lines.single.alternatives, <String>[
        'Is land',
      ]);
      expect(calls.single.arguments, <String, Object>{
        'path': '/local/original.heic',
        'multipleCards': false,
      });
    },
  );

  test(
    'shared requests serialize, retain spacing and recover after errors',
    () async {
      final List<DateTime> started = <DateTime>[];
      final Future<void> first = ScryfallRequestScheduler.run<void>(() async {
        started.add(DateTime.now());
        throw StateError('network');
      });
      final Future<void> failed = expectLater(first, throwsStateError);
      final Future<int> second = ScryfallRequestScheduler.run<int>(() async {
        started.add(DateTime.now());
        return 2;
      });
      final Future<int> third = ScryfallRequestScheduler.run<int>(() async {
        started.add(DateTime.now());
        return 3;
      });
      await failed;
      expect(await second, 2);
      expect(await third, 3);
      expect(
        started[1].difference(started[0]).inMilliseconds,
        greaterThanOrEqualTo(490),
      );
      expect(
        started[2].difference(started[1]).inMilliseconds,
        greaterThanOrEqualTo(490),
      );
    },
  );

  test(
    'Scryfall transport identifies the application and requests JSON',
    () async {
      final ScryfallHttpClient client = ScryfallHttpClient(
        clientFactory: () => MockClient((http.Request request) async {
          expect(request.headers['User-Agent'], contains('TheCollector/'));
          expect(request.headers['Accept'], 'application/json');
          return http.Response('{}', 200);
        }),
      );
      addTearDown(client.close);
      expect(
        (await client.get(Uri.https('api.scryfall.com', '/cards/test')))
            .statusCode,
        200,
      );
    },
  );
}
