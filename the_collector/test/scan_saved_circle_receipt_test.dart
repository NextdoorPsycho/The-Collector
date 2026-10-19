import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/live_scan_tracker.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

class _UnusedCatalog extends Fake implements ScanCatalog {}

class _QuietResolver extends ScanResolver {
  _QuietResolver() : super(catalog: _UnusedCatalog());
  @override
  Future<ScanResolution> resolve(
    ScanCrop crop, {
    String? name,
    String? setCode,
    String? collectorNumber,
    String? language,
    int page = 1,
  }) async => ScanResolution(
    candidates: const <ScanCandidate>[],
    hints: ScanHints.fromCrop(crop),
    status: ScanResolutionStatus.noMatch,
  );
}

const ScanCrop _circle = ScanCrop(
  imagePath: '',
  width: 2895,
  height: 3800,
  rectified: true,
  warnings: <String>["geometry_adjusted"],
  sourceCorners: <ScanPoint>[
    ScanPoint(0.3033448272943497, 0.5393620502948762),
    ScanPoint(0.5685481691360473, 0.5752311336994171),
    ScanPoint(0.5599467754364014, 0.8404898196458817),
    ScanPoint(0.1151718869805336, 0.7826899439096451),
  ],
  lines: <ScanTextLine>[
    ScanTextLine(
      text: "1 ₴",
      confidence: 0.5,
      alternatives: <String>["1 3", "1 9"],
      glyphHeight: 0.026162789997301594,
      bounds: ScanBounds(
        0.8685714275705663,
        0.09883720961980846,
        0.08571428752077215,
        0.026162789997301594,
      ),
    ),
    ScanTextLine(
      text: "Enchantment",
      confidence: 1.0,
      alternatives: <String>["Enchaniment", "Enchantmen"],
      glyphHeight: 0.027118029892757387,
      bounds: ScanBounds(
        0.035780562773626075,
        0.6043940969830639,
        0.3074670443877331,
        0.030584969771535797,
      ),
    ),
    ScanTextLine(
      text: "1; Prevent all damage against you",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.03467371733263823,
      bounds: ScanBounds(
        0.09541421350972429,
        0.7,
        0.7841604664839434,
        0.03881835480293767,
      ),
    ),
    ScanTextLine(
      text: "from one blue source. li a source",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.025568070662649035,
      bounds: ScanBounds(
        0.09447676173159177,
        0.7342105263716905,
        0.761627871687241,
        0.025568071666516756,
      ),
    ),
    ScanTextLine(
      text: "deals damage",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.031106178112361105,
      bounds: ScanBounds(
        0.09689971942918164,
        0.7611194987678314,
        0.3211199023645059,
        0.03478214464689557,
      ),
    ),
    ScanTextLine(
      text: "to you mo",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.03512376434718653,
      bounds: ScanBounds(
        0.4079250718498547,
        0.7654738309949461,
        0.24092228693865816,
        0.03671131334806741,
      ),
    ),
    ScanTextLine(
      text: "once in a turn, you may",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.03169708839382237,
      bounds: ScanBounds(
        0.09801587238239949,
        0.7935453927968615,
        0.5428308533558049,
        0.035606203581157486,
      ),
    ),
    ScanTextLine(
      text: "each time to prevent the",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.03553454703839063,
      bounds: ScanBounds(
        0.09614683652849464,
        0.8256675248260248,
        0.5531333153103414,
        0.03833683013916017,
      ),
    ),
    ScanTextLine(
      text: "Circle of Protections Blue",
      confidence: 1.0,
      alternatives: <String>[
        "Circle of Protection Blue",
        "Cirele of Protections Blue",
      ],
      glyphHeight: 0.034736842105263156,
      bounds: ScanBounds(
        0.029166667555838677,
        0.09157894734085215,
        0.6583333305232433,
        0.034736842105263184,
      ),
    ),
  ],
);
const ScanCrop _nevermore = ScanCrop(
  imagePath: '',
  width: 1571,
  height: 2201,
  rectified: false,
  warnings: <String>["no_card_rectangle", "partial_card", "incomplete_card"],
  sourceCorners: <ScanPoint>[
    ScanPoint(0.6205459349156065, 0.563779739398766),
    ScanPoint(0.88027766324252, 0.563779739398766),
    ScanPoint(0.88027766324252, 0.8366071851203138),
    ScanPoint(0.6205459349156065, 0.8366071851203138),
  ],
  lines: <ScanTextLine>[
    ScanTextLine(
      text: "Enchantment",
      confidence: 1.0,
      alternatives: <String>["Enchantmen", "Enchantmet"],
      glyphHeight: 0.030954200236552615,
      bounds: ScanBounds(
        0.043093147751670426,
        0.4579126966052558,
        0.4010412395758786,
        0.07017535106579254,
      ),
    ),
    ScanTextLine(
      text: "As Nevermore enters the ba",
      confidence: 1.0,
      alternatives: <String>[
        "As Nevermore enter the ba",
        "As Nevermor enters the ba",
      ],
      glyphHeight: 0.04292297894984114,
      bounds: ScanBounds(
        0.04332745702500753,
        0.5272722585401817,
        0.9566725429749925,
        0.12659743306422422,
      ),
    ),
    ScanTextLine(
      text: "name a nonland card.",
      confidence: 1.0,
      alternatives: <String>["name a nonland card", "name a noland card."],
      glyphHeight: 0.045409685114838214,
      bounds: ScanBounds(
        0.03521933775030952,
        0.566784983620006,
        0.7743181612048745,
        0.11981914218829826,
      ),
    ),
    ScanTextLine(
      text: "The named card can't be c",
      confidence: 1.0,
      alternatives: <String>[
        "The named card can't bec",
        "The named card can't be",
      ],
      glyphHeight: 0.049889682751813144,
      bounds: ScanBounds(
        0.032165939292810114,
        0.618734383424442,
        0.9678340607071899,
        0.13749371215931194,
      ),
    ),
    ScanTextLine(
      text: "can t de c",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.03681247337135818,
      bounds: ScanBounds(
        0.6470449320021794,
        0.7,
        0.3449233737004016,
        0.04553581472477466,
      ),
    ),
    ScanTextLine(
      text: "By the law of Avacyn, the fo",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.05414914610830768,
      bounds: ScanBounds(
        0.0903920457626324,
        0.7,
        0.9096079542373676,
        0.12516456105169468,
      ),
    ),
    ScanTextLine(
      text: "thoughts, words, and deeds a",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.05720818445835803,
      bounds: ScanBounds(
        0.03406162386640344,
        0.7297576873020832,
        0.951481865259224,
        0.14331001212589692,
      ),
    ),
    ScanTextLine(
      text: "- Engle",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.037884783361066474,
      bounds: ScanBounds(
        0.3180465124744451,
        0.8976407019008426,
        0.1638949251053594,
        0.0416281656916408,
      ),
    ),
    ScanTextLine(
      text: "Ne de C 5995-2051 Wpardo df Que CA",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.02982527599752896,
      bounds: ScanBounds(
        0.0035754340796215057,
        0.8991287097919919,
        0.6464324640560393,
        0.09475247823939945,
      ),
    ),
    ScanTextLine(
      text: "mongnes, woras, ar",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.05056837132066848,
      bounds: ScanBounds(
        0.057518048050908786,
        0.76,
        0.5924819519490913,
        0.08031098924270046,
      ),
    ),
    ScanTextLine(
      text: "henceforth disallor",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.0514922417498063,
      bounds: ScanBounds(
        0.03592700725501631,
        0.7729946834113157,
        0.6140729927449837,
        0.11199093224867333,
      ),
    ),
    ScanTextLine(
      text: "son A. Engl",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.030566858186060704,
      bounds: ScanBounds(
        0.1776894887539972,
        0.877074588076639,
        0.2771161491856883,
        0.06085088765846108,
      ),
    ),
    ScanTextLine(
      text: "2055 Wrande dl due 4",
      confidence: 0.30000001192092896,
      alternatives: <String>[],
      glyphHeight: 0.02158348710478046,
      bounds: ScanBounds(
        0.23274571223332305,
        0.9222115373803184,
        0.3842873112329532,
        0.058978005463222294,
      ),
    ),
    ScanTextLine(
      text: "Nevermore",
      confidence: 1.0,
      alternatives: <String>["Nevermor", "Nevemore"],
      glyphHeight: 0.025359664873606955,
      bounds: ScanBounds(
        0.04288462018793382,
        0.03309321646168628,
        0.31878203957438767,
        0.05310701535782723,
      ),
    ),
  ],
);

const ScanCrop _earlyType = ScanCrop(
  imagePath: '',
  width: 2570,
  height: 3590,
  rectified: true,
  warnings: <String>["orientation_ensemble", "geometry_adjusted"],
  sourceCorners: <ScanPoint>[
    ScanPoint(0.2687262296676636, 0.5437735617160797),
    ScanPoint(0.6540533900260925, 0.6006710827350616),
    ScanPoint(0.5982998609542847, 0.8812561482191086),
    ScanPoint(0.04786635562777519, 0.8092069625854492),
  ],
  lines: <ScanTextLine>[
    ScanTextLine(
      text: "• blue",
      confidence: 1.0,
      alternatives: <String>[". blue", "blue"],
      glyphHeight: 0.017441860613384597,
      bounds: ScanBounds(
        0.4503042612371988,
        0.024709302211806672,
        0.1014198748518057,
        0.017441860613384597,
      ),
    ),
    ScanTextLine(
      text: "Enchaniment",
      confidence: 1.0,
      alternatives: <String>["Enchanment", "Enchanmment"],
      glyphHeight: 0.026133917662745525,
      bounds: ScanBounds(
        0.09506615836495055,
        0.48820652249123486,
        0.2438888371686527,
        0.02779476835203032,
      ),
    ),
    ScanTextLine(
      text: "1; Prevent all damage against you",
      confidence: 1.0,
      alternatives: <String>[
        "1 Prevent all damage against you",
        "1; Prevent all damagé against you",
      ],
      glyphHeight: 0.03367622196753767,
      bounds: ScanBounds(
        0.1478157325467926,
        0.579362376780544,
        0.6150992901872568,
        0.03715733180139058,
      ),
    ),
    ScanTextLine(
      text: "from one blue source. If a source",
      confidence: 1.0,
      alternatives: <String>[
        "from one blue source If a source",
        "from on blue source. If a source",
      ],
      glyphHeight: 0.03244364923364327,
      bounds: ScanBounds(
        0.1455810533499762,
        0.6085064428169499,
        0.6113304999088035,
        0.03817406019460523,
      ),
    ),
    ScanTextLine(
      text: "deals damage to you more than",
      confidence: 1.0,
      alternatives: <String>[
        "deals damage to you more han",
        "deal damage to you more than",
      ],
      glyphHeight: 0.039081757183985176,
      bounds: ScanBounds(
        0.14554957747917158,
        0.6447125445295044,
        0.5790459896339981,
        0.044133093363727394,
      ),
    ),
    ScanTextLine(
      text: "cach time to prevent the damage",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.034531692981078124,
      bounds: ScanBounds(
        0.14548924136439323,
        0.7189684826116114,
        0.6090795138466683,
        0.03975548399180342,
      ),
    ),
    ScanTextLine(
      text: "Circle of Protection: Blue",
      confidence: 1.0,
      alternatives: <String>[
        "Circle of Protection Blue",
        "Cirele of Protection: Blue",
      ],
      glyphHeight: 0.028571539293757678,
      bounds: ScanBounds(
        0.09133130348153237,
        0.01685284465378012,
        0.4652633488874026,
        0.03977691437971287,
      ),
    ),
    ScanTextLine(
      text: "Enchantment",
      confidence: 1.0,
      alternatives: <String>["Enchanument", "Enchanment"],
      glyphHeight: 0.024709316591421726,
      bounds: ScanBounds(
        0.09939148285744948,
        0.4869185900848213,
        0.24340770374644882,
        0.02470933149258292,
      ),
    ),
  ],
);

LiveCardDetection _detection(ScanCrop crop, {bool text = true}) =>
    LiveCardDetection(
      confidence: .99,
      corners: crop.sourceCorners,
      lines: text ? crop.lines : const <ScanTextLine>[],
      warnings: crop.warnings,
    );

void main() {
  test('early normal type window rejects high titles, mana, non-type text and weak confidence without moving the rules floor', () {
    for (final (String, double, double) sample in <(String, double, double)>[
      ('Enchantment', .12, 1),
      ('Enchantment', .449, 1),
      ('{1}{W}', .487, 1),
      ('Destroy target creature.', .487, 1),
      ('Enchantment', .487, .84),
    ]) {
      final ScanTextLine line = ScanTextLine(
        text: sample.$1,
        confidence: sample.$3,
        bounds: ScanBounds(.1, sample.$2, .4, .03),
      );
      final ScanCrop probe = ScanCrop(
        imagePath: '',
        width: _earlyType.width,
        height: _earlyType.height,
        rectified: true,
        sourceCorners: _earlyType.sourceCorners,
        warnings: _earlyType.warnings,
        lines: <ScanTextLine>[
          _earlyType.lines[6],
          ..._earlyType.lines.sublist(2, 6),
          line,
        ],
      );
      final ScanHints hints = ScanHints.fromCrop(probe);
      expect(
        hints.typeLine,
        isNull,
        reason: '${sample.$1} at ${sample.$2} confidence ${sample.$3}',
      );
      expect(
        hints.rulesText,
        isNot(contains(sample.$1)),
        reason: 'The normal rules region still begins at .50.',
      );
    }
  });

  test('actual rectified Circle type just above the rules region is retained as type proof', () {
    final ScanHints hints = ScanHints.fromCrop(_earlyType);
    expect(hints.typeLine, 'enchantment');
    expect(hints.rulesText, isNot(contains('Enchaniment')));
    expect(ScanResolver.rulesSearchPhrase(hints.rulesText), isNotNull);
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _QuietResolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final List<List<ScanPoint>> geometry = <List<ScanPoint>>[
      _earlyType.sourceCorners,
    ];
    final List<LiveCardDetection> cards = <LiveCardDetection>[
      _detection(_earlyType),
    ];
    tracker.update(cards, currentGeometry: geometry);
    tracker.update(cards, currentGeometry: geometry);
    expect(tracker.snapshotCapture(currentGeometry: geometry).count, 1);
  });

  test('actual saved Circle has strong capture proof and can become a yellow owned raw receipt without printing approval', () {
    final ScanHints hints = ScanHints.fromCrop(_circle);
    expect(hints.names, contains('Circle of Protections Blue'));
    expect(hints.typeLine, 'enchantment');
    expect(ScanResolver.rulesSearchPhrase(hints.rulesText), isNotNull);
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _QuietResolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final List<LiveCardDetection> cards = <LiveCardDetection>[
      _detection(_circle),
    ];
    final List<List<ScanPoint>> geometry = <List<ScanPoint>>[
      _circle.sourceCorners,
    ];
    tracker.update(cards, currentGeometry: geometry);
    tracker.update(cards, currentGeometry: geometry);
    final int capture = tracker.beginCapture();
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture(
      currentGeometry: geometry,
    );
    expect(
      snapshot.count,
      1,
      reason: 'Snapshot admission uses the production strong-proof filter on the unchanged actual crop.',
    );
    expect(tracker.markCaptured(snapshot), 1);
    expect(tracker.rememberSavedCrop(_circle, snapshot), isTrue);
    expect(tracker.savedFootprints, hasLength(1));
    expect(tracker.tracks.single.captured, isTrue);
    expect(tracker.tracks.single.capturedIdentified, isFalse);
    expect(
      tracker.tracks.single.resolution?.status,
      isNot(ScanResolutionStatus.exactPrinting),
    );
    tracker.endCapture(capture, resumeTracking: false);
  });

  test('Nevermore-only semantic shutter proof binds an owned saved Circle to its frozen pre-shutter geometry as yellow', () {
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _QuietResolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final List<List<ScanPoint>> geometry = <List<ScanPoint>>[
      _circle.sourceCorners,
      _nevermore.sourceCorners,
    ];
    final List<LiveCardDetection> cards = <LiveCardDetection>[
      _detection(_nevermore),
      _detection(_circle, text: false),
    ];
    tracker.update(cards, currentGeometry: geometry);
    tracker.update(cards, currentGeometry: geometry);
    final int capture = tracker.beginCapture();
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture(
      currentGeometry: geometry,
    );
    expect(snapshot.count, 1);
    expect(
      ScanHints.fromCrop(snapshot.crops.single).names,
      contains('Nevermore'),
    );
    expect(tracker.markCaptured(snapshot), 1);
    expect(
      tracker.rememberSavedCrop(_circle, snapshot),
      isTrue,
      reason: 'Strong saved OCR supplies identity only for the owned geometry frozen before shutter and acknowledged after durable save.',
    );
    expect(tracker.savedFootprints, hasLength(2));
    final LiveScanTrack circle = tracker.tracks.singleWhere(
      (LiveScanTrack track) =>
          ScanHints.fromCrop(track.crop).names
              .contains('Circle of Protections Blue'),
    );
    expect(circle.captured, isTrue);
    expect(circle.capturedIdentified, isFalse);
    expect(
      circle.resolution?.status,
      isNot(ScanResolutionStatus.exactPrinting),
    );
    expect(
      tracker.tracks.any((LiveScanTrack track) => track.capturedIdentified),
      isFalse,
    );
    tracker.endCapture(capture, resumeTracking: false);
  });

  test('saved Circle cannot claim a geometry-only region first discovered after shutter', () {
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _QuietResolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final List<List<ScanPoint>> before = <List<ScanPoint>>[
      _nevermore.sourceCorners,
    ];
    final List<LiveCardDetection> initial = <LiveCardDetection>[
      _detection(_nevermore),
    ];
    tracker.update(initial, currentGeometry: before);
    tracker.update(initial, currentGeometry: before);
    final int capture = tracker.beginCapture();
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture(
      currentGeometry: before,
    );
    expect(snapshot.count, 1);
    expect(tracker.markCaptured(snapshot), 1);
    final List<List<ScanPoint>> after = <List<ScanPoint>>[
      _nevermore.sourceCorners,
      _circle.sourceCorners,
    ];
    final List<LiveCardDetection> later = <LiveCardDetection>[
      _detection(_nevermore),
      _detection(_circle, text: false),
    ];
    tracker.update(later, currentGeometry: after);
    tracker.update(later, currentGeometry: after);
    expect(
      tracker.rememberSavedCrop(_circle, snapshot),
      isFalse,
      reason: 'Later geometry cannot prove that this Circle belonged to the acknowledged photo.',
    );
    expect(tracker.savedFootprints, hasLength(1));
    expect(
      tracker.tracks.any((LiveScanTrack track) => track.capturedIdentified),
      isFalse,
    );
    tracker.endCapture(capture, resumeTracking: false);
  });
}
