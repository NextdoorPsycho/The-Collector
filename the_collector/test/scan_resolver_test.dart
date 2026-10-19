import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

Map<String, Object?> _printing({
  String set = 'nem',
  String number = '51',
  String language = 'ja',
  String name = 'Ascendant Evincar',
  String artist = 'Mark Zug',
  String releasedAt = '2000-02-14',
}) {
  final Map<String, Object?> base = Map<String, Object?>.from(
    jsonDecode(
      File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
    ) as Map<Object?, Object?>,
  )..remove('card_faces');
  return <String, Object?>{
    ...base,
    'id': '$set-$number-$language',
    'name': name,
    'printed_name': language == 'ja' ? '隆盛なるエヴィンカー' : null,
    'layout': 'normal',
    'type_line': 'Legendary Creature — Phyrexian Vampire Noble',
    'oracle_text': 'Flying',
    'printed_text': language == 'ja' ? '飛行' : null,
    'set': set,
    'collector_number': number,
    'lang': language,
    'artist': artist,
    'released_at': releasedAt,
    'games': <String>['paper'],
  };
}

ScanTextLine _footer(String text, {double y = .93, double confidence = .99}) =>
    ScanTextLine(
      text: text,
      confidence: confidence,
      bounds: ScanBounds(.72, y, .20, .025),
    );

ScanCrop _crop({String title = '隆盛なるエヴィンカー', List<ScanTextLine>? footer}) =>
    ScanCrop(
      imagePath: '',
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: const <ScanPoint>[
        ScanPoint(.1, .1),
        ScanPoint(.4, .1),
        ScanPoint(.4, .7),
        ScanPoint(.1, .7),
      ],
      lines: <ScanTextLine>[
        ScanTextLine(
          text: title,
          confidence: .99,
          bounds: const ScanBounds(.08, .04, .7, .035),
        ),
        const ScanTextLine(
          text: 'クリーチャー レジェンド',
          confidence: .99,
          bounds: ScanBounds(.08, .53, .7, .035),
        ),
        ...footer ?? <ScanTextLine>[_footer('51/143')],
      ],
    );

ScanCrop _metadataCrop({
  String? title,
  String copyright = '©1993-2000Wizards of the Coast, Inc. 51/143',
  double copyrightY = .8935450439368685,
  double copyrightConfidence = 1,
  bool artist = true,
  bool japanese = true,
  List<ScanTextLine> extra = const <ScanTextLine>[],
}) => ScanCrop(
  imagePath: '',
  width: 1405,
  height: 1963,
  rectified: true,
  sourceCorners: const <ScanPoint>[
    ScanPoint(.207, .408),
    ScanPoint(.485, .414),
    ScanPoint(.508, .606),
    ScanPoint(.095, .608),
  ],
  warnings: <String>[if (title == null) 'incomplete_card', 'geometry_adjusted'],
  lines: <ScanTextLine>[
    if (title != null)
      ScanTextLine(
        text: title,
        confidence: .5,
        bounds: const ScanBounds(.12, .05, .5, .035),
      ),
    if (japanese) ...const <ScanTextLine>[
      ScanTextLine(
        text: 'クリーチャーーレジェンド',
        confidence: .5,
        bounds: ScanBounds(.1217, .5523, .6085, .0262),
      ),
      ScanTextLine(
        text: '他の黒のクリーチャーは+1/+1の修正を',
        confidence: 1,
        bounds: ScanBounds(.1542, .6466, .6836, .0321),
      ),
    ],
    if (artist)
      const ScanTextLine(
        text: 'Illus. Mark Zug',
        confidence: 1,
        bounds: ScanBounds(.3558, .8694, .2797, .0321),
      ),
    ScanTextLine(
      text: copyright,
      confidence: copyrightConfidence,
      bounds: ScanBounds(.2758, copyrightY, .4469, .0264),
    ),
    const ScanTextLine(
      text: '3/3',
      confidence: 1,
      bounds: ScanBounds(.8256, .8775, .0828, .0343),
    ),
    ...extra,
  ],
);

ScanCrop _mounted36Japanese() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":1587,"height":2217,"rectified":true,"warnings":["incomplete_card","geometry_adjusted"],"sharpness":0.7889193702937762,"sourceCorners":[{"x":0.21155360341072083,"y":0.40802186727523804},{"x":0.48419877886772156,"y":0.413174033164978},{"x":0.508881151676178,"y":0.6037100255489349},{"x":0.06930947303771973,"y":0.6099904477596283}],"lines":[{"text":"クリーチャーー","confidence":0.5,"alternatives":["フリーチャーー","クレーチャーー"],"glyphHeight":0.024377919677540764,"sceneFooterGuide":false,"bounds":{"x":0.1455979161645882,"y":0.5681041509546876,"width":0.30106776547371894,"height":0.027848007229666516}},{"text":"レジェンド","confidence":1.0,"alternatives":["ジェンド","レジェン"],"glyphHeight":0.02616278963341796,"sceneFooterGuide":false,"bounds":{"x":0.44810422131888045,"y":0.5719249849067769,"width":0.21738182087088714,"height":0.027661658064323746}},{"text":"飛行","confidence":0.5,"alternatives":["行","飛"],"glyphHeight":0.02627550405462753,"sceneFooterGuide":false,"bounds":{"x":0.170385395651622,"y":0.6248872861963551,"width":0.07505070952984788,"height":0.02627550405462753}},{"text":"他の黒のクリーチャーは＋1/+1の修正を","confidence":1.0,"alternatives":["他の黒のクリーチャーは+1/+1の修正を","他の黒のクリーチャーは＋1/＋1の修正を"],"glyphHeight":0.026683500753576454,"sceneFooterGuide":false,"bounds":{"x":0.17595044867671772,"y":0.6599950315768819,"width":0.6643997307688523,"height":0.036462592906625124}},{"text":"クリーチャーーレジェンド","confidence":0.5,"alternatives":[],"glyphHeight":null,"sceneFooterGuide":false,"bounds":{"x":0.1455979161645882,"y":0.5681041509546876,"width":0.5198881260251794,"height":0.031482492016413066}},{"text":"黒でないクリーチャーは-1/-1の修正を受","confidence":0.5,"alternatives":["黒でないクリーチャーは－1/-1の修正を受","黒でないクリーチャーは-1/1の修正を受"],"glyphHeight":0.024389900583649482,"sceneFooterGuide":false,"bounds":{"x":0.18006987035916808,"y":0.724512746104198,"width":0.664174192798528,"height":0.03312617405993756}},{"text":"Illus. Mark Zug -","confidence":1.0,"alternatives":[],"glyphHeight":0.02693438233666353,"sceneFooterGuide":false,"bounds":{"x":0.38242010766851275,"y":0.8748200394469126,"width":0.29805934339086126,"height":0.03474890906531531}},{"text":"©1993-2000Wizards of the Coast, Inc. 51/143","confidence":1.0,"alternatives":[],"glyphHeight":0.020449361804790407,"sceneFooterGuide":false,"bounds":{"x":0.3034316118058263,"y":0.8971705022605535,"width":0.43461847185187735,"height":0.029152703500008814}},{"text":"3/3","confidence":1.0,"alternatives":[],"glyphHeight":0.030103807191591003,"sceneFooterGuide":false,"bounds":{"x":0.8299418607211861,"y":0.8899653973820592,"width":0.0784883715343716,"height":0.030103807191591003}},{"text":"Illus. Mark Zug","confidence":1.0,"alternatives":[],"glyphHeight":0.02708914965517555,"sceneFooterGuide":false,"bounds":{"x":0.3832013090620991,"y":0.8783749450349043,"width":0.26344321396307735,"height":0.027705042221966927}},{"text":"©1903-2000 Wizards of the Coast, In","confidence":1.0,"alternatives":[],"glyphHeight":0.020153952934813344,"sceneFooterGuide":false,"bounds":{"x":0.3025707520206617,"y":0.8967633040629522,"width":0.3470999823676215,"height":0.0284388929612944}}]}''',
  ) as Map<Object?, Object?>,
);

ScanCrop _mounted36Glimpse() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":773,"height":1079,"rectified":true,"warnings":[],"sharpness":0.9181218435135119,"sourceCorners":[{"x":0.5756555199623108,"y":0.07928627729415894},{"x":0.7869646549224854,"y":0.07192492485046387},{"x":0.8160020709037781,"y":0.3349725008010864},{"x":0.608014702796936,"y":0.32178735733032227}],"lines":[{"text":"Ghimpse nf Natur:","confidence":1.0,"alternatives":[],"glyphHeight":0.039100749408232556,"sceneFooterGuide":false,"bounds":{"x":0.054146745503848535,"y":0.030187895771049966,"width":0.4868082133262624,"height":0.05180199329969608}},{"text":"Sorcery","confidence":1.0,"alternatives":[],"glyphHeight":0.028683984445168214,"sceneFooterGuide":false,"bounds":{"x":0.06190056620263973,"y":0.547514786416157,"width":0.189012830344095,"height":0.033147658314734096}},{"text":"Whenever you cast a creature spell","confidence":1.0,"alternatives":[],"glyphHeight":0.0381652806044569,"sceneFooterGuide":false,"bounds":{"x":0.07241849327618811,"y":0.5594204380326566,"width":0.8036964235612745,"height":0.09351524765909891}},{"text":"this turn, draw a card.","confidence":1.0,"alternatives":[],"glyphHeight":0.03904578052407228,"sceneFooterGuide":false,"bounds":{"x":0.06961386610185939,"y":0.610730084847129,"width":0.5387982857778578,"height":0.07930400299844986}},{"text":"\"In the acorn, find the oak; in the cub,","confidence":1.0,"alternatives":[],"glyphHeight":0.03321051030744633,"sceneFooterGuide":false,"bounds":{"x":0.06686399995459563,"y":0.6552676541023023,"width":0.8286145501816995,"height":0.09300795785435689}},{"text":"find the pride-king. In all living things,","confidence":1.0,"alternatives":[],"glyphHeight":0.032763406637779595,"sceneFooterGuide":false,"bounds":{"x":0.05731568878020231,"y":0.684273453948218,"width":0.8514529868811191,"height":0.10036433942926304}},{"text":"great or small, find not what they are,","confidence":1.0,"alternatives":[],"glyphHeight":0.04011529581288975,"sceneFooterGuide":false,"bounds":{"x":0.0666459976391409,"y":0.7159519985511477,"width":0.8260038916202342,"height":0.11077583229960575}},{"text":"but what they can becomeiằ","confidence":1.0,"alternatives":[],"glyphHeight":0.03648354333246408,"sceneFooterGuide":false,"bounds":{"x":0.06847569191144538,"y":0.7629541761469955,"width":0.6141871183957491,"height":0.09824445446846164}},{"text":"The Nature of Infinity, vol. 1","confidence":1.0,"alternatives":[],"glyphHeight":0.04170932254599569,"sceneFooterGuide":false,"bounds":{"x":0.06631553830003839,"y":0.7866171709702686,"width":0.7343601764726881,"height":0.10373632544925426}},{"text":"R 0053","confidence":1.0,"alternatives":[],"glyphHeight":0.019608205359594535,"sceneFooterGuide":false,"bounds":{"x":0.03974954852534344,"y":0.9136998452400118,"width":0.12308443250955717,"height":0.030735938986943157}},{"text":"SOA • EN","confidence":1.0,"alternatives":[],"glyphHeight":0.019972775467191985,"sceneFooterGuide":false,"bounds":{"x":0.03641881024920867,"y":0.9283461708295702,"width":0.14196681697543753,"height":0.03731140982024361}},{"text":"YER","confidence":1.0,"alternatives":[],"glyphHeight":0.012353468673878074,"sceneFooterGuide":false,"bounds":{"x":0.3772697877244681,"y":0.9069124502629317,"width":0.047496633169032076,"height":0.014394379673137947}},{"text":"I & © 2026 Wizards of the Coast","confidence":1.0,"alternatives":[],"glyphHeight":0.01906739970446726,"sceneFooterGuide":false,"bounds":{"x":0.6237201317856806,"y":0.844806607509073,"width":0.34587166900743005,"height":0.05488564392940709}}]}''',
  ) as Map<Object?, Object?>,
);

Map<String, Object?> _mounted36GlimpsePrinting() => <String, Object?>{
  ..._printing(
    name: 'Glimpse of Nature',
    set: 'soa',
    number: '53',
    language: 'en',
    artist: 'Dominik Mayer',
    releasedAt: '2026-04-24',
  ),
  'id': '7cb6fd05-0bd9-4f2f-b159-280aba98d3a5',
  'type_line': 'Sorcery',
  'oracle_text': 'Whenever you cast a creature spell this turn, draw a card.',
  'flavor_text': '"In the acorn, find the oak; in the cub, find the pride-king. In all living things, great or small, find not what they are, but what they can become."\n—*The Nature of Infinity, vol. 1*',
};

class _Catalog implements ScanCatalog, ScanMetadataCatalog {
  _Catalog(this.cards, {this.fuzzy, this.exact, this.metadataHasMore = false});
  final List<MtgCard> cards;
  final MtgCard? fuzzy;
  final MtgCard? exact;
  final bool metadataHasMore;
  final List<({String number, String artist, String? language})>
  metadataQueries = <({String number, String artist, String? language})>[];
  final List<({String name, String? language})> queries =
      <({String name, String? language})>[];
  final List<({List<String> keywords, String? phrase})> rulesQueries =
      <({List<String> keywords, String? phrase})>[];
  int exactCalls = 0;

  @override
  Future<PaginableList<MtgCard>> metadataPrintings({
    required String collectorNumber,
    required String illustrator,
    String? language,
  }) async {
    metadataQueries.add((
      number: collectorNumber,
      artist: illustrator,
      language: language,
    ));
    return PaginableList<MtgCard>(data: cards, hasMore: metadataHasMore);
  }

  @override
  Future<MtgCard?> exactPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  }) async {
    exactCalls++;
    return exact;
  }

  @override
  Future<MtgCard?> fuzzyName(String name) async => fuzzy;

  @override
  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) async {
    queries.add((name: name, language: language));
    return PaginableList<MtgCard>(
      data: cards
          .where(
            (MtgCard card) =>
                (name == card.name || name == card.printedName) &&
                (language == null || language == card.lang.json),
          )
          .toList(),
      hasMore: false,
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
  }) async => PaginableList<MtgCard>(data: const <MtgCard>[], hasMore: false);

  @override
  Future<PaginableList<MtgCard>> rulesKeywordCards(
    List<String> keywords, {
    String? phrase,
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
  }) async {
    rulesQueries.add((keywords: List<String>.of(keywords), phrase: phrase));
    return PaginableList<MtgCard>(data: const <MtgCard>[], hasMore: false);
  }
}

void main() {
  test(
    'mounted Japanese duplicate artist punctuation permits metadata review',
    () async {
      final _Catalog catalog = _Catalog(<MtgCard>[
        MtgCard.fromJson(_printing()),
        MtgCard.fromJson(
          _printing(
            set: 'ddo',
            name: 'Coiling Oracle',
            releasedAt: '2015-02-27',
          ),
        ),
      ]);
      final ScanCrop crop = _mounted36Japanese();
      expect(ScanHints.fromCrop(crop).collectorNumber, '51');
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(crop);
      expect(
        catalog.metadataQueries,
        <({String number, String artist, String? language})>[
          (number: '51', artist: 'mark zug', language: 'ja'),
        ],
      );
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(result.candidates, hasLength(2));
      expect(result.candidates.first.card.name, 'Ascendant Evincar');
      expect(
        result.candidates.first.evidence,
        containsAll(<ScanEvidence>[
          ScanEvidence.collectorNumberMatch,
          ScanEvidence.illustratorMatch,
          ScanEvidence.copyrightYearMatch,
        ]),
      );
      expect(catalog.exactCalls, 0);
    },
  );

  test('mounted tilted rows retain literal flavor continuations for catalog validation', () {
    final ScanCrop crop = _mounted36Glimpse();
    final ScanHints hints = ScanHints.fromCrop(crop);
    expect(hints.names, contains('Ghimpse nf Natur:'));
    expect(hints.setCode, 'soa');
    expect(hints.collectorNumber, '0053');
    expect(hints.language, 'en');
    expect(hints.typeLine, 'sorcery');
    expect(hints.rulesText, <String>[
      'Whenever you cast a creature spell',
      'this turn, draw a card.',
    ]);
    expect(hints.postQuoteText, <String>[
      'find the pride-king. In all living things,',
      'great or small, find not what they are,',
      'but what they can becomeiằ',
      'The Nature of Infinity, vol. 1',
    ]);
    expect(crop.lines[4].text, '"In the acorn, find the oak; in the cub,');
    expect(crop.lines[7].text, 'but what they can becomeiằ');
  });

  test('confidence-filtered hints retain quote boundaries without admitting weaker evidence', () {
    ScanTextLine row(String text, double y, double confidence) => ScanTextLine(
      text: text,
      confidence: confidence,
      bounds: ScanBounds(.1, y, .7, .025),
    );
    final ScanCrop crop = ScanCrop(
      imagePath: '',
      width: 745,
      height: 1040,
      rectified: true,
      sourceCorners: const <ScanPoint>[],
      lines: <ScanTextLine>[
        row('Spell', .04, .80),
        row('Instant', .54, .80),
        row('Destroy target creature.', .59, .80),
        row('You draw two cards.', .63, .97),
        row('"Witness', .68, .80),
        row('Destroy target nonartifact creature.', .74, .97),
        row('MOM EN', .92, .80),
        row('123', .96, .80),
      ],
    );
    final ScanHints raw = ScanHints.fromCrop(crop);
    expect(raw.names, <String>['Spell']);
    expect(raw.typeLine, 'instant');
    expect(raw.setCode, 'mom');
    for (final double confidence in <double>[.85, .90]) {
      final ScanHints hints = ScanHints.fromCrop(
        crop,
        minimumConfidence: confidence,
      );
      expect(hints.names, isEmpty, reason: '$confidence');
      expect(hints.typeLine, isNull, reason: '$confidence');
      expect(hints.setCode, isNull, reason: '$confidence');
      expect(hints.collectorNumber, isNull, reason: '$confidence');
      expect(hints.rulesText, <String>['You draw two cards.']);
      expect(hints.postQuoteText, <String>[
        'Destroy target nonartifact creature.',
      ]);
      expect(hints.postQuoteText, isNot(contains('"Witness')));
    }
  });

  test('post-quote duplicate cannot supply the third row for constrained body lookup', () async {
    ScanTextLine row(String text, double y, {double confidence = .99}) =>
        ScanTextLine(
          text: text,
          confidence: confidence,
          bounds: ScanBounds(.1, y, .7, .025),
        );
    for (final double quoteConfidence in <double>[.80, 1]) {
      for (final bool thirdRuleBeforeQuote in <bool>[false, true]) {
        final String reason =
            'quote confidence=$quoteConfidence, third rule=$thirdRuleBeforeQuote';
        final ScanCrop crop = ScanCrop(
          imagePath: '',
          width: 1000,
          height: 1400,
          rectified: true,
          sourceCorners: const <ScanPoint>[],
          lines: <ScanTextLine>[
            row('Enchantment', .50),
            row('Prevent all damage', .56),
            row('source would deal', .61),
            if (thirdRuleBeforeQuote) row('to you this turn', .66),
            row('"Witness', .71, confidence: quoteConfidence),
            row('source would deal', .77),
          ],
        );
        final _Catalog catalog = _Catalog(const <MtgCard>[]);
        final ScanResolution result = await ScanResolver(
          catalog: catalog,
        ).resolve(crop);
        expect(result.hints.names, isEmpty, reason: reason);
        expect(
          result.hints.rulesText,
          <String>[
            'Prevent all damage',
            'source would deal',
            if (thirdRuleBeforeQuote) 'to you this turn',
          ],
          reason: reason,
        );
        expect(result.hints.postQuoteText, <String>['source would deal']);
        expect(
          catalog.rulesQueries,
          hasLength(thirdRuleBeforeQuote ? 1 : 0),
          reason: reason,
        );
        if (thirdRuleBeforeQuote) {
          expect(catalog.rulesQueries.single.keywords, <String>['prevent', 'source']);
          expect(catalog.rulesQueries.single.phrase, 'source would deal');
        }
        expect(result.status, ScanResolutionStatus.noMatch, reason: reason);
      }
    }
  });

  test('tall body rows require valid measured glyphs within card bounds', () {
    final ScanCrop original = _mounted36Glimpse();
    final ScanTextLine observed = original.lines[2];
    for (final ScanTextLine rejected in <ScanTextLine>[
      for (final double? glyph in <double?>[
        null,
        0,
        -.01,
        double.nan,
        double.infinity,
        .08,
      ])
        ScanTextLine(
          text: observed.text,
          confidence: observed.confidence,
          bounds: observed.bounds,
          glyphHeight: glyph,
        ),
      for (final ScanBounds bounds in const <ScanBounds>[
        ScanBounds(.07, .56, .80, .14),
        ScanBounds(-.02, .56, .80, .0935),
        ScanBounds(.07, .56, .98, .0935),
      ])
        ScanTextLine(
          text: observed.text,
          confidence: observed.confidence,
          bounds: bounds,
          glyphHeight: observed.glyphHeight,
        ),
    ]) {
      final ScanCrop crop = ScanCrop(
        imagePath: '',
        width: original.width,
        height: original.height,
        rectified: original.rectified,
        sourceCorners: original.sourceCorners,
        lines: <ScanTextLine>[
          ...original.lines.take(2),
          rejected,
          ...original.lines.skip(3),
        ],
      );
      expect(
        ScanHints.fromCrop(crop).rulesText,
        isNot(contains(observed.text)),
        reason: 'glyph=${rejected.glyphHeight}, bounds=${rejected.bounds}',
      );
    }
  });

  test(
    'mounted noisy title keeps a body-corroborated exact footer for review',
    () async {
      final MtgCard card = MtgCard.fromJson(_mounted36GlimpsePrinting());
      final _Catalog catalog = _Catalog(const <MtgCard>[], exact: card);
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(_mounted36Glimpse());
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(result.candidates.single.card.id, card.id);
      expect(result.hints.names, contains('Ghimpse nf Natur:'));
      expect(
        result.candidates.single.evidence,
        containsAll(<ScanEvidence>[
          ScanEvidence.footerMatch,
          ScanEvidence.collectorNumberMatch,
          ScanEvidence.languageMatch,
          ScanEvidence.typeLineMatch,
          ScanEvidence.rulesTextMatch,
          ScanEvidence.nameMismatch,
        ]),
      );
      expect(result.candidates.single.hasContradiction, isTrue);
      expect(catalog.exactCalls, 1);
    },
  );

  test(
    'footer review fallback cannot hide set number language or body conflicts',
    () async {
      final Map<String, Object?> base = _mounted36GlimpsePrinting();
      for (final Map<String, Object?> conflict in <Map<String, Object?>>[
        <String, Object?>{'set': 'chk'},
        <String, Object?>{'collector_number': '55'},
        <String, Object?>{'lang': 'ja'},
        <String, Object?>{'name': 'An Unrelated Spell'},
        <String, Object?>{'type_line': 'Instant'},
        <String, Object?>{'oracle_text': 'Destroy target nonland permanent.'},
      ]) {
        final _Catalog catalog = _Catalog(
          const <MtgCard>[],
          exact: MtgCard.fromJson(<String, Object?>{...base, ...conflict}),
        );
        final ScanResolution result = await ScanResolver(catalog: catalog)
            .resolve(_mounted36Glimpse());
        expect(
          result.status,
          ScanResolutionStatus.noMatch,
          reason: '$conflict',
        );
        expect(result.candidates, isEmpty, reason: '$conflict');
      }
    },
  );

  test('mounted quoted continuations cannot hide conflicting text or missing catalog flavor', () async {
    final ScanCrop original = _mounted36Glimpse();
    for (final String variant in <String>[
      'blue',
      'nonartifact',
      'missingFlavor',
    ]) {
      final String continuation = variant == 'missingFlavor'
          ? original.lines[7].text
          : '${original.lines[7].text} $variant';
      final ScanCrop crop = ScanCrop(
        imagePath: original.imagePath,
        width: original.width,
        height: original.height,
        rectified: original.rectified,
        sourceCorners: original.sourceCorners,
        warnings: original.warnings,
        sharpness: original.sharpness,
        lines: <ScanTextLine>[
          for (int index = 0; index < original.lines.length; index++)
            if (index == 7)
              ScanTextLine(
                text: continuation,
                confidence: original.lines[index].confidence,
                bounds: original.lines[index].bounds,
                glyphHeight: original.lines[index].glyphHeight,
                alternatives: original.lines[index].alternatives,
              )
            else
              original.lines[index],
        ],
      );
      final _Catalog catalog = _Catalog(
        const <MtgCard>[],
        exact: MtgCard.fromJson(<String, Object?>{
          ..._mounted36GlimpsePrinting(),
          if (variant == 'missingFlavor') 'flavor_text': null,
        }),
      );

      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(crop);

      expect(result.hints.postQuoteText, contains(continuation), reason: variant);
      expect(result.hints.rulesText, isNot(contains(continuation)), reason: variant);
      expect(crop.lines[7].text, continuation, reason: variant);
      expect(result.status, ScanResolutionStatus.noMatch, reason: variant);
      expect(result.candidates, isEmpty, reason: variant);
      expect(catalog.exactCalls, 1, reason: variant);
    }
  });

  test('an uncertain copyright endpoint preserves the literal collector number without scoring a year', () async {
    for (final String footer in <String>[
      '©1993-200Q.Wizards of the Coast, Inc. 51/143',
      '©1993 - 200Q Wizards of the Coast, Inc. 51/143',
    ]) {
      final _Catalog catalog = _Catalog(<MtgCard>[
        MtgCard.fromJson(_printing(set: 'old', releasedAt: '1993-08-05')),
        MtgCard.fromJson(_printing()),
      ]);
      final ScanCrop crop = _metadataCrop(copyright: footer);
      expect(ScanHints.fromCrop(crop).collectorNumber, '51');
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(crop);
      expect(catalog.metadataQueries.single.number, '51');
      expect(result.candidates, hasLength(2));
      for (final ScanCandidate candidate in result.candidates) {
        expect(candidate.evidence, contains(ScanEvidence.collectorNumberMatch));
        expect(
          candidate.evidence,
          isNot(contains(ScanEvidence.copyrightYearMatch)),
        );
      }
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(catalog.exactCalls, 0);
    }
  });

  test('uncertain copyright context rejects arbitrary text and ambiguous collector evidence', () async {
    final List<ScanCrop> rejected = <ScanCrop>[
      _metadataCrop(copyright: '©1993-20QQ.Wizards of the Coast, Inc. 51/143'),
      _metadataCrop(copyright: '©1993-200X.Wizards of the Coast, Inc. 51/143'),
      _metadataCrop(copyright: '©1993-200Q0.Wizards of the Coast, Inc. 51/143'),
      _metadataCrop(copyright: '©199Q-2000.Wizards of the Coast, Inc. 51/143'),
      _metadataCrop(copyright: '©1993-200Q.Wizards 51/143'),
      _metadataCrop(copyright: '©1993-200Q.Wizards of the Coast, Inc. 3/3'),
      _metadataCrop(copyright: '©1993-200Q.Wizards of the Coast, Inc. 145/143'),
      _metadataCrop(copyright: '©1993-200Q.Wizards of the Coast, Inc.'),
      _metadataCrop(
        copyright: '©1993-200Q.Wizards of the Coast, Inc. 51/143',
        extra: <ScanTextLine>[_footer('52/143')],
      ),
    ];
    for (final ScanCrop crop in rejected) {
      final _Catalog catalog = _Catalog(<MtgCard>[
        MtgCard.fromJson(_printing()),
      ]);
      expect(ScanHints.fromCrop(crop).collectorNumber, isNull);
      await ScanResolver(catalog: catalog).resolve(crop);
      expect(catalog.metadataQueries, isEmpty);
    }
  });

  test('unmatched automatic titles fall back once to metadata without erasing contradictions', () async {
    for (final String title in <String>['インカ', '益なもエヴィンカ']) {
      final _Catalog catalog = _Catalog(<MtgCard>[
        MtgCard.fromJson(_printing()),
      ]);
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(_metadataCrop(title: title));
      expect(
        catalog.queries.map(
          (({String name, String? language}) query) => query.name,
        ),
        contains(title),
      );
      expect(catalog.metadataQueries, hasLength(1));
      expect(result.hints.names, contains(title));
      expect(
        result.candidates.single.evidence,
        contains(ScanEvidence.nameMismatch),
      );
      expect(result.candidates.single.hasContradiction, isTrue);
      expect(result.status, ScanResolutionStatus.needsReview);
      expect(catalog.exactCalls, 0);
    }
  });

  test(
    'valid titles retain their normal lookup and do not use metadata fallback',
    () async {
      final _Catalog catalog = _Catalog(<MtgCard>[
        MtgCard.fromJson(_printing()),
      ]);
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(_metadataCrop(title: '隆盛なるエヴィンカー'));
      expect(catalog.metadataQueries, isEmpty);
      expect(
        result.candidates.single.evidence,
        contains(ScanEvidence.nameMatch),
      );
    },
  );

  test('unmatched title metadata fallback respects manual overrides and footer conflicts', () async {
    final _Catalog catalog = _Catalog(<MtgCard>[MtgCard.fromJson(_printing())]);
    final ScanResolver resolver = ScanResolver(catalog: catalog);
    final ScanCrop crop = _metadataCrop(title: 'インカ');
    await resolver.resolve(crop, name: 'インカ');
    await resolver.resolve(crop, collectorNumber: '51');
    await resolver.resolve(crop, setCode: 'nem');
    await resolver.resolve(crop, language: 'ja');
    await resolver.resolve(crop, page: 2);
    await resolver.resolve(
      _metadataCrop(title: 'インカ', extra: <ScanTextLine>[_footer('52/143')]),
    );
    expect(catalog.metadataQueries, isEmpty);
  });

  test('observed copyright footer and artist retrieve Japanese candidates without claiming identity', () async {
    final _Catalog catalog = _Catalog(<MtgCard>[
      MtgCard.fromJson(
        _printing(set: 'ddo', name: 'Coiling Oracle', releasedAt: '2015-02-27'),
      ),
      MtgCard.fromJson(_printing()),
    ]);
    final ScanCrop crop = _metadataCrop();
    final ScanHints detected = ScanHints.fromCrop(crop);
    expect(detected.names, isEmpty);
    expect(detected.collectorNumber, '51');
    expect(detected.setCode, isNull);
    expect(detected.language, isNull);
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(crop);
    expect(
      catalog.metadataQueries,
      <({String number, String artist, String? language})>[
        (number: '51', artist: 'mark zug', language: 'ja'),
      ],
    );
    expect(result.candidates, hasLength(2));
    expect(result.candidates.first.card.name, 'Ascendant Evincar');
    expect(
      result.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.collectorNumberMatch,
        ScanEvidence.illustratorMatch,
        ScanEvidence.copyrightYearMatch,
      ]),
    );
    expect(
      result.candidates.last.evidence,
      isNot(contains(ScanEvidence.copyrightYearMatch)),
    );
    expect(
      result.candidates.every(
        (ScanCandidate candidate) =>
            !candidate.evidence.contains(ScanEvidence.nameMatch) &&
            !candidate.evidence.contains(ScanEvidence.footerMatch),
      ),
      isTrue,
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(catalog.exactCalls, 0);
  });

  test('footer metadata rejects body fractions, PT, dates, weak OCR and conflicting numbers', () async {
    final List<ScanCrop> rejected = <ScanCrop>[
      _metadataCrop(copyright: '3/3'),
      _metadataCrop(copyright: '1993/2000'),
      _metadataCrop(copyright: '©1993-2000Wizards of the Coast, Inc.'),
      _metadataCrop(copyright: '©1993-2000Wizards of the Coast, Inc. 3/3'),
      _metadataCrop(copyright: '©2000-1993Wizards of the Coast, Inc. 51/143'),
      _metadataCrop(copyright: '©1993-2000Wizards of the Coast, Inc. 145/143'),
      _metadataCrop(copyrightY: .64),
      _metadataCrop(copyrightY: .85),
      _metadataCrop(copyrightConfidence: .7),
      _metadataCrop(artist: false),
      _metadataCrop(extra: <ScanTextLine>[_footer('52/143')]),
      _metadataCrop(
        extra: const <ScanTextLine>[
          ScanTextLine(
            text: 'Illus. Rebecca Guay',
            confidence: 1,
            bounds: ScanBounds(.2, .83, .5, .03),
          ),
        ],
      ),
    ];
    for (final ScanCrop crop in rejected) {
      final _Catalog catalog = _Catalog(<MtgCard>[
        MtgCard.fromJson(_printing()),
      ]);
      final ScanResolution result = await ScanResolver(catalog: catalog)
          .resolve(crop);
      expect(
        catalog.metadataQueries,
        isEmpty,
        reason: crop.lines.map((ScanTextLine line) => line.text).join(' / '),
      );
      expect(result.status, isNot(ScanResolutionStatus.exactPrinting));
    }
  });

  test('copyright ranges score their terminal year and unknown script stays multilingual', () async {
    final _Catalog catalog = _Catalog(<MtgCard>[
      MtgCard.fromJson(
        _printing(set: 'old', releasedAt: '1993-08-05', language: 'en'),
      ),
      MtgCard.fromJson(_printing()),
    ]);
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(_metadataCrop(japanese: false));
    expect(catalog.metadataQueries.single.language, isNull);
    expect(result.candidates, hasLength(2));
    expect(result.candidates.first.card.releasedAt.year, 2000);
    expect(
      result.candidates.first.evidence,
      contains(ScanEvidence.copyrightYearMatch),
    );
    expect(
      result.candidates.last.evidence,
      isNot(contains(ScanEvidence.copyrightYearMatch)),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
  });

  test(
    'metadata retrieval rejects excessive results and rechecks returned fields',
    () async {
      final _Catalog incorrect = _Catalog(<MtgCard>[
        MtgCard.fromJson(_printing(number: '52')),
        MtgCard.fromJson(_printing(artist: 'Rebecca Guay')),
        MtgCard.fromJson(_printing(language: 'en')),
        MtgCard.fromJson(_printing(number: 'B51')),
      ]);
      expect(
        (await ScanResolver(catalog: incorrect).resolve(_metadataCrop()))
            .status,
        ScanResolutionStatus.noMatch,
      );
      for (final _Catalog catalog in <_Catalog>[
        _Catalog(<MtgCard>[
          MtgCard.fromJson(_printing()),
        ], metadataHasMore: true),
        _Catalog(
          List<MtgCard>.generate(
            33,
            (int index) => MtgCard.fromJson(_printing(set: 's$index')),
          ),
        ),
      ]) {
        expect(
          (await ScanResolver(catalog: catalog).resolve(_metadataCrop()))
              .status,
          ScanResolutionStatus.noMatch,
        );
      }
      final _Catalog single = _Catalog(<MtgCard>[
        MtgCard.fromJson(_printing()),
      ]);
      expect(
        (await ScanResolver(catalog: single).resolve(_metadataCrop())).status,
        ScanResolutionStatus.needsReview,
      );
    },
  );

  test('metadata HTTP query uses observed fields and retains multilingual printings', () async {
    final List<Uri> requests = <Uri>[];
    final ScryfallScanCatalog catalog = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient((http.Request request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode(<String, Object?>{
              'object': 'list',
              'data': <Object?>[_printing()],
              'has_more': false,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    addTearDown(catalog.close);
    await catalog.metadataPrintings(
      collectorNumber: '051',
      illustrator: 'Mark Zug',
      language: 'ja',
    );
    await catalog.metadataPrintings(
      collectorNumber: '51',
      illustrator: 'Mark Zug',
    );
    expect(
      requests[0].queryParameters['q'],
      'cn:"51" artist:"Mark Zug" game:paper lang:"ja"',
    );
    expect(
      requests[1].queryParameters['q'],
      'cn:"51" artist:"Mark Zug" game:paper',
    );
    expect(
      requests.every(
        (Uri uri) => uri.queryParameters['include_multilingual'] == 'true',
      ),
      isTrue,
    );
    expect(
      requests.every((Uri uri) => uri.queryParameters['unique'] == 'prints'),
      isTrue,
    );
  });

  test(
    'Japanese type lines normalize without treating Japanese rules as types',
    () {
      const Map<String, String> cases = <String, String>{
        'クリーチャー レジェンド': 'creature',
        'クリーチャーーレジェンド': 'creature',
        'クリーチャー－レジェンド': 'creature',
        '伝説のクリーチャー — 吸血鬼': 'creature',
        'アーティファクト・クリーチャー — ゴーレム': 'artifact creature',
        '基本土地 — 森': 'land',
        'インスタント': 'instant',
        'ソーサリー': 'sorcery',
        'Legendary Creature — Vampire': 'creature',
        'Summon Vampire': 'creature',
      };
      for (final MapEntry<String, String> entry in cases.entries) {
        expect(observedCardType(entry.key), entry.value, reason: entry.key);
      }
      for (final String text in <String>[
        '他の黒のクリーチャーは＋1/+1の修正を受ける。',
        'クリーチャーは飛行を持つ。',
        'Target creature gains flying.',
      ]) {
        expect(observedCardType(text), isNull, reason: text);
      }
      expect(ScanHints.fromCrop(_crop()).typeLine, 'creature');
    },
  );

  test('old lower-right fractions provide numbers without inventing set or language', () {
    final ScanHints hints = ScanHints.fromCrop(_crop());
    expect(hints.collectorNumber, '51');
    expect(hints.setCode, isNull);
    expect(hints.language, isNull);
    for (final String text in <String>[
      '3/3',
      '51/43',
      '145/143',
      '1995/2000',
      '1995-2000',
      '© 2000 Wizards 51/143',
    ]) {
      expect(
        ScanHints.fromCrop(_crop(footer: <ScanTextLine>[_footer(text)]))
            .collectorNumber,
        isNull,
        reason: text,
      );
    }
    for (final ScanTextLine line in <ScanTextLine>[
      _footer('51/143', y: .85),
      _footer('51/143', confidence: .70),
    ]) {
      expect(
        ScanHints.fromCrop(_crop(footer: <ScanTextLine>[line])).collectorNumber,
        isNull,
      );
    }
    final ScanHints conflicting = ScanHints.fromCrop(
      _crop(footer: <ScanTextLine>[_footer('51/143'), _footer('52/143')]),
    );
    expect(conflicting.collectorNumber, isNull);
    expect(conflicting.hasConflictingFooter, isTrue);
  });

  test('foreign names request multilingual printings while English queries stay unchanged', () async {
    final List<Uri> requests = <Uri>[];
    final ScryfallScanCatalog catalog = ScryfallScanCatalog(
      api: ScryfallApiClient(
        httpClient: MockClient((http.Request request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode(<String, Object?>{
              'object': 'list',
              'data': <Object?>[_printing()],
              'has_more': false,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    addTearDown(catalog.close);
    await catalog.printings('隆盛なるエヴィンカー');
    await catalog.printings('Ascendant Evincar');
    expect(requests[0].queryParameters['include_multilingual'], 'true');
    expect(requests[0].queryParameters['q'], '!"隆盛なるエヴィンカー" game:paper');
    expect(requests[1].queryParameters['include_multilingual'], 'false');
    expect(requests[1].queryParameters['q'], '!"Ascendant Evincar" game:paper');
  });

  test('Japanese name and collector number rank the matching printing but cannot claim exact identity', () async {
    final _Catalog catalog = _Catalog(<MtgCard>[
      MtgCard.fromJson(_printing(set: '10e', number: '127')),
      MtgCard.fromJson(_printing()),
    ]);
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(_crop());
    expect(result.candidates.first.card.set, 'nem');
    expect(result.candidates.first.card.lang, Language.japanese);
    expect(
      result.candidates.first.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.nameMatch,
        ScanEvidence.collectorNumberMatch,
        ScanEvidence.typeLineMatch,
      ]),
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(catalog.exactCalls, 0);
  });

  test('noisy foreign titles retain fuzzy-result language when expanding printings', () async {
    final MtgCard foreign = MtgCard.fromJson(
      _printing(set: '10e', number: '127'),
    );
    final _Catalog catalog = _Catalog(<MtgCard>[
      foreign,
      MtgCard.fromJson(_printing()),
      MtgCard.fromJson(_printing(language: 'en')),
    ], fuzzy: foreign);
    final ScanResolution result = await ScanResolver(catalog: catalog)
        .resolve(_crop(title: '隆盛なるエヴインカー'));
    expect(catalog.queries.last, (name: 'Ascendant Evincar', language: 'ja'));
    expect(result.candidates.first.card.set, 'nem');
    expect(
      result.candidates.every(
        (ScanCandidate value) => value.card.lang == Language.japanese,
      ),
      isTrue,
    );
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(catalog.exactCalls, 0);
  });

  test(
    'English fuzzy expansion does not gain an inferred language filter',
    () async {
      final MtgCard english = MtgCard.fromJson(_printing(language: 'en'));
      final _Catalog catalog = _Catalog(<MtgCard>[english], fuzzy: english);
      await ScanResolver(catalog: catalog)
          .resolve(_crop(title: 'Ascendant Evincor'));
      expect(catalog.queries.last, (name: 'Ascendant Evincar', language: null));
    },
  );
}
