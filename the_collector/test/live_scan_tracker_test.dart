import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/live_scan_tracker.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

class _Card extends Fake implements MtgCard {
  @override
  String get name => 'Test card';
}

class _NamedCard extends _Card {
  final String title;
  _NamedCard(this.title);
  @override
  String get name => title;
}

class _SelfReferenceCard extends _NamedCard {
  _SelfReferenceCard(super.title);
  @override
  String? get artist => 'Jason A. Engle';
  @override
  DateTime get releasedAt => DateTime(2011, 9, 30);
  @override
  List<CardFace>? get cardFaces => null;
}

class _Resolver extends ScanResolver {
  int calls = 0;
  final List<ScanCrop> crops = <ScanCrop>[];
  Completer<ScanResolution>? pending;

  @override
  Future<ScanResolution> resolve(
    ScanCrop crop, {
    String? name,
    String? setCode,
    String? collectorNumber,
    String? language,
    int page = 1,
  }) async {
    calls++;
    crops.add(crop);
    return pending?.future ?? _resolution(crop);
  }
}

ScanResolution _resolution(ScanCrop crop) => ScanResolution(
  candidates: const <ScanCandidate>[],
  hints: ScanHints.fromCrop(crop),
  status: ScanResolutionStatus.noMatch,
);

LiveCardDetection _card(
  double x, {
  double y = .1,
  String? title = 'Lightning Bolt',
  String? footer,
  List<String> warnings = const <String>[],
}) => LiveCardDetection(
  confidence: .95,
  warnings: warnings,
  corners: <ScanPoint>[
    ScanPoint(x, y),
    ScanPoint(x + .2, y),
    ScanPoint(x + .2, y + .3),
    ScanPoint(x, y + .3),
  ],
  lines: <ScanTextLine>[
    if (title != null)
      ScanTextLine(
        text: title,
        confidence: .99,
        bounds: const ScanBounds(.1, .04, .7, .03),
      ),
    if (footer != null)
      ScanTextLine(
        text: footer,
        confidence: .99,
        bounds: const ScanBounds(.05, .91, .4, .03),
      ),
  ],
);

ScanResolution _savedRead(ScanCrop crop) => ScanResolution(
  candidates: <ScanCandidate>[
    ScanCandidate(_Card(), const <ScanEvidence>{ScanEvidence.nameMatch}),
  ],
  hints: ScanHints.fromCrop(crop),
  status: ScanResolutionStatus.needsReview,
);

LiveCardAppearanceSample _appearance(
  String id,
  List<ScanPoint> corners, {
  bool present = true,
  bool reversed = false,
  double gain = 1,
}) => LiveCardAppearanceSample(
  id: id,
  corners: corners,
  present: present,
  values: <double>[
    for (int pixel = 0; pixel < 96; pixel++)
      for (int channel = 0; channel < 3; channel++)
        (.15 + ((reversed ? 95 - pixel : pixel) % 12) / 18 + channel * .025) *
            gain,
  ],
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

LiveCardAppearanceSample _fixedSceneSample(
  LiveScanExcludedRegion region, {
  bool replaced = false,
}) {
  final List<double> pixels = <double>[];
  for (int row = 0; row < 12; row++) {
    for (int column = 0; column < 8; column++) {
      final double u = (column + .5) / 8;
      final double v = (row + .5) / 12;
      final ScanPoint top = ScanPoint(
        region.corners[0].x * (1 - u) + region.corners[1].x * u,
        region.corners[0].y * (1 - u) + region.corners[1].y * u,
      );
      final ScanPoint bottom = ScanPoint(
        region.corners[3].x * (1 - u) + region.corners[2].x * u,
        region.corners[3].y * (1 - u) + region.corners[2].y * u,
      );
      final double x = top.x * (1 - v) + bottom.x * v;
      final double y = top.y * (1 - v) + bottom.y * v;
      final double original = .15 + ((x * 237 + y * 383).floor() % 11) * .06;
      final double light = replaced ? 1 - original : original;
      pixels.addAll(<double>[light, light * .85 + .05, light * .75 + .08]);
    }
  }
  return LiveCardAppearanceSample(
    id: region.id,
    corners: region.corners,
    present: true,
    values: pixels,
  );
}

// Native body-panel ACK and later full-card OCR from mounted capture25.
ScanCrop _recordedBats25Inset() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":1000,"height":1400,"rectified":true,"warnings":["small_image"],"sourceCorners":[{"x":0.6535243847742677,"y":0.32137351401150227},{"x":0.8385079914852978,"y":0.32818472680449484},{"x":0.8245576333478093,"y":0.41642119733989236},{"x":0.6382511257305741,"y":0.4026818452551961}],"lines":[{"text":"Whenever you create or sacrifice a","confidence":1.0,"glyphHeight":0.05494598729306671,"bounds":{"x":0.6022467078499483,"y":0.06924002148827613,"width":0.11625402674955476,"height":0.8362761871724188}},{"text":"token, cach opponent loses 1 life.","confidence":1.0,"glyphHeight":0.05696206756784945,"bounds":{"x":0.505882285181813,"y":0.056962014952531836,"width":0.10588249879724831,"height":0.829113924050633}},{"text":"Flying","confidence":1.0,"glyphHeight":0.055322650916538554,"bounds":{"x":0.7202256228292014,"y":0.07108291023254543,"width":0.13405318540685318,"height":0.16786157708418997}},{"text":"token,","confidence":1.0,"glyphHeight":0.0509971141142732,"bounds":{"x":0.5017357707849657,"y":0.05404657870947038,"width":0.12362586750703697,"height":0.17715273405376233}}]}''',
  ) as Map<Object?, Object?>,
);

ScanCrop _recordedBats25Full() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":1000,"height":1400,"rectified":false,"warnings":["partial_card","incomplete_card","no_card_rectangle"],"sourceCorners":[{"x":0.642521181352108,"y":0.2016596951672951},{"x":0.8941483423657094,"y":0.2016596951672951},{"x":0.8941483423657094,"y":0.46597393992948144},{"x":0.642521181352108,"y":0.46597393992948144}],"lines":[{"text":"Creature - Bat","confidence":1.0,"glyphHeight":0.02751124184344297,"bounds":{"x":0.047290643336684146,"y":0.47522400259262443,"width":0.25670707618797217,"height":0.038188975627028054}},{"text":"Whenever you create or sacrifice a","confidence":1.0,"glyphHeight":0.029176498428892784,"bounds":{"x":0.035601341516963286,"y":0.5720638123783147,"width":0.6266750293773609,"height":0.06383808766763044}},{"text":"token, each opponent loses 1 life.","confidence":1.0,"glyphHeight":0.029591088868568233,"bounds":{"x":0.024660638807715133,"y":0.6029874937251236,"width":0.6044278826032365,"height":0.0626447407279428}},{"text":"Mirkwood Bats","confidence":1.0,"glyphHeight":0.03535802483691128,"bounds":{"x":0.11343972865363151,"y":0.04160519620167746,"width":0.3121263063870944,"height":0.047284751016585545}}]}''',
  ) as Map<Object?, Object?>,
);

LiveCardDetection _cropDetection(ScanCrop crop) => LiveCardDetection(
  confidence: 1,
  corners: crop.sourceCorners,
  lines: crop.lines,
  warnings: crop.warnings,
);

ScanCrop _recordedCircle25Ack() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":1000,"height":1400,"rectified":true,"warnings":[],"sourceCorners":[{"x":0.29254415466374456,"y":0.5559213817068787},{"x":0.5709351244318238,"y":0.5950574474671542},{"x":0.5607512453315714,"y":0.8423264148904359},{"x":0.11483123219262364,"y":0.782308553932866}],"lines":[{"text":"Enchantment","confidence":1.0,"glyphHeight":0.028708133971291905,"bounds":{"x":0.05307262555865926,"y":0.5574162679287817,"width":0.29608938547486036,"height":0.028708133971291905}},{"text":"1; Prevent all damage against you","confidence":1.0,"glyphHeight":0.038277511961722466,"bounds":{"x":0.11173184315642457,"y":0.6578947367655502,"width":0.7513966480446927,"height":0.038277511961722466}},{"text":"from one blue source. If a source","confidence":1.0,"glyphHeight":0.03813353175563765,"bounds":{"x":0.1058353093920687,"y":0.6893755697407888,"width":0.743605970670391,"height":0.044433543556614885}},{"text":"deals damage to you more than","confidence":1.0,"glyphHeight":0.03809523809523809,"bounds":{"x":0.1061452512446235,"y":0.7309523809439529,"width":0.6983240223463687,"height":0.03809523809523809}},{"text":"Gree of Proreecion Blue","confidence":1.0,"glyphHeight":0.03865104818781052,"bounds":{"x":0.04560252337526009,"y":0.0,"width":0.6338510779695138,"height":0.03894591837722542}}]}''',
  ) as Map<Object?, Object?>,
);

ScanCrop _recordedCircle25Saved() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":2501,"height":3494,"rectified":true,"warnings":["geometry_adjusted"],"sourceCorners":[{"x":0.2887096107006073,"y":0.5532311201095581},{"x":0.5754585266113281,"y":0.592754065990448},{"x":0.5662395358085632,"y":0.8473644554615021},{"x":0.10477100312709808,"y":0.7845177799463272}],"lines":[{"text":"Enchantment","confidence":1.0,"glyphHeight":0.02761627922210952,"bounds":{"x":0.0466531391411068,"y":0.5537790696630909,"width":0.30425964404257844,"height":0.02761627922210952}},{"text":"1; Prevent all damage against you","confidence":1.0,"glyphHeight":0.034818219412464824,"bounds":{"x":0.11134316818944319,"y":0.655440353195917,"width":0.7489007329292815,"height":0.03823417135150209}},{"text":"deals damage to you more than","confidence":1.0,"glyphHeight":0.03947404697963173,"bounds":{"x":0.10901161648171878,"y":0.7279999996559724,"width":0.69622095292516,"height":0.03947404915945868}},{"text":"Crele of Protections Blue","confidence":1.0,"glyphHeight":0.029714285714285714,"bounds":{"x":0.04583332823152188,"y":0.0,"width":0.6375000097578187,"height":0.02971428554245703}}]}''',
  ) as Map<Object?, Object?>,
);

// Actual retained capture26 OCR, with its frozen full-card source boundary.
ScanCrop _recordedBats26Proof() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":1000,"height":1400,"rectified":false,"warnings":["partial_card","incomplete_card","no_card_rectangle"],"sourceCorners":[{"x":0.6426417537465223,"y":0.20032561248464986},{"x":0.8964932390086288,"y":0.20032561248464986},{"x":0.8964932390086288,"y":0.4669763322977869},{"x":0.6426417537465223,"y":0.4669763322977869}],"lines":[{"text":"Creature - Bat","confidence":1.0,"glyphHeight":0.023763157967268383,"bounds":{"x":0.04733370758804232,"y":0.47333959375458645,"width":0.260146969654521,"height":0.03453642848864602}},{"text":"Whenever you create or sacrifice a","confidence":1.0,"glyphHeight":0.029763757183405976,"bounds":{"x":0.034949977439311095,"y":0.5657675977147125,"width":0.6294231310568221,"height":0.06798821386196274}},{"text":"token, each opponent loses 1 life.","confidence":1.0,"glyphHeight":0.0327362936682998,"bounds":{"x":0.024472875732835363,"y":0.5958441854746217,"width":0.612881936662184,"height":0.06733558892276037}},{"text":"Mirkwood Bats","confidence":1.0,"glyphHeight":0.03500590047528664,"bounds":{"x":0.11902920821291214,"y":0.04648147584732809,"width":0.3083708299313738,"height":0.03500590047528667}}]}''',
  ) as Map<Object?, Object?>,
);

ScanCrop _recordedCircle26Proof() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":1000,"height":1400,"rectified":true,"warnings":[],"sourceCorners":[{"x":0.29020678198118105,"y":0.5522535844939546},{"x":0.5757086793903874,"y":0.5883218708216117},{"x":0.5671799012855316,"y":0.8467694725924769},{"x":0.10654196984997857,"y":0.7844457732911114}],"lines":[{"text":"Sirele of Orotection: Blue","confidence":1.0,"glyphHeight":0.03810867880025393,"bounds":{"x":0.06292826657613569,"y":0.012023043932042454,"width":0.6355582050893498,"height":0.07703404104237233}},{"text":"Enchantment","confidence":1.0,"glyphHeight":0.027897187953416298,"bounds":{"x":0.06194327000091933,"y":0.5582071180365098,"width":0.3099643663428296,"height":0.038521053074123124}},{"text":"1; Prevent all damage against you","confidence":1.0,"glyphHeight":0.037648019560564884,"bounds":{"x":0.1253749427030838,"y":0.6584947016163344,"width":0.7434455608499462,"height":0.055233504110838716}},{"text":"deals damage to you more than","confidence":1.0,"glyphHeight":0.03749906935810909,"bounds":{"x":0.12267760717907797,"y":0.7296805071912855,"width":0.6912620369045214,"height":0.050850557726483024}},{"text":"Cirele of Droteerion: Blue","confidence":1.0,"glyphHeight":0.0371245524809064,"bounds":{"x":0.06292329019284296,"y":0.010572083790372444,"width":0.6356412514872934,"height":0.07911341991239382}}]}''',
  ) as Map<Object?, Object?>,
);

ScanCrop _recordedCircle26Late() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":1000,"height":1400,"rectified":true,"warnings":[],"sourceCorners":[{"x":0.29007149321800285,"y":0.5548021337750049},{"x":0.5743324503704401,"y":0.5965706070518497},{"x":0.564465506725934,"y":0.8454452452776711},{"x":0.10956315394168187,"y":0.7840114787921828}],"lines":[{"text":"Srele of Prorection Blue","confidence":1.0,"glyphHeight":0.04035252205213542,"bounds":{"x":0.05023896236902742,"y":0.0021242649174948447,"width":0.6403319095274662,"height":0.055484508958395184}},{"text":"En chantinent","confidence":1.0,"glyphHeight":0.024983141810976526,"bounds":{"x":0.05374373816558386,"y":0.5612386862982907,"width":0.3000235924353966,"height":0.029970910939921103}},{"text":"1; Prevent all damage against you","confidence":1.0,"glyphHeight":0.037949970470530545,"bounds":{"x":0.11647956415398979,"y":0.6601520558121992,"width":0.7499421817964298,"height":0.04355299671019064}},{"text":"deals damage to you more than","confidence":1.0,"glyphHeight":0.03849475336522234,"bounds":{"x":0.11062731555673906,"y":0.7304139097592349,"width":0.6989150088057559,"height":0.04656941571573573}},{"text":"Cirele of Protection Bhe","confidence":1.0,"glyphHeight":0.03821835031055094,"bounds":{"x":0.050260115465396035,"y":0.0018094298296340572,"width":0.6403590797359109,"height":0.05435043939269417}}]}''',
  ) as Map<Object?, Object?>,
);

// Frozen source bounds and retained native OCR from capture27.
ScanCrop _recordedNevermore27Proof() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":1000,"height":1400,"rectified":false,"warnings":["partial_card","incomplete_card","no_card_rectangle"],"sourceCorners":[{"x":0.6083403495505801,"y":0.5676243761948554},{"x":0.8973334035190099,"y":0.5676243761948554},{"x":0.8973334035190099,"y":0.8346281811126863},{"x":0.6083403495505801,"y":0.8346281811126863}],"lines":[{"text":"Enchantment","confidence":1.0,"glyphHeight":0.03099522394097725,"bounds":{"x":0.042446485921157406,"y":0.4560826101133981,"width":0.39712824965968274,"height":0.07026013992626035}},{"text":"As Nevermore enters the ba","confidence":1.0,"glyphHeight":0.042902114145453155,"bounds":{"x":0.0412821445095128,"y":0.5244894561124122,"width":0.9587178554904872,"height":0.12903398904207053}},{"text":"name a nonland card.","confidence":1.0,"glyphHeight":0.04101725620047435,"bounds":{"x":0.03999861058779344,"y":0.5645604434759015,"width":0.759570497455019,"height":0.11211019641542563}},{"text":"The named card can't be c","confidence":1.0,"glyphHeight":0.05006176717481264,"bounds":{"x":0.03265984658484487,"y":0.6172723547879914,"width":0.9673401534151551,"height":0.1350046472575237}},{"text":"Nevermore","confidence":1.0,"glyphHeight":0.026260884302194944,"bounds":{"x":0.038509516268503054,"y":0.035097103982798306,"width":0.3313037217265427,"height":0.05726916709642732}}]}''',
  ) as Map<Object?, Object?>,
);

ScanCrop _recordedNevermore27Saved() {
  final ScanCrop proof = _recordedNevermore27Proof();
  return ScanCrop(
    imagePath: '',
    width: 1584,
    height: 2218,
    rectified: false,
    warnings: proof.warnings,
    lines: proof.lines,
    sourceCorners: const <ScanPoint>[
      ScanPoint(.6239249069702109, .5636041231688158),
      ScanPoint(.8855917858089628, .5636041231688158),
      ScanPoint(.8855917858089628, .8384642900162442),
      ScanPoint(.6239249069702109, .8384642900162442),
    ],
  );
}

ScanCrop _recordedCircle27Ack() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":1000,"height":1400,"rectified":true,"warnings":["incomplete_card"],"sourceCorners":[{"x":0.2985349612619741,"y":0.5544064346040041},{"x":0.5694692949970981,"y":0.5901329636052706},{"x":0.5588620698215078,"y":0.8327149981583359},{"x":0.12367629548807527,"y":0.7751902473951955}],"lines":[{"text":"Enchantment","confidence":1.0,"glyphHeight":0.02985074626865669,"bounds":{"x":0.031791907368539235,"y":0.5547263681447133,"width":0.3121387283236994,"height":0.02985074626865669}},{"text":"1; Prevent all damage against you","confidence":1.0,"glyphHeight":0.03980099502487555,"bounds":{"x":0.09537572205202315,"y":0.6592039799999999,"width":0.7803468208092484,"height":0.03980099502487566}},{"text":"from one blue source. If a source","confidence":1.0,"glyphHeight":0.032102512023479655,"bounds":{"x":0.08945197889957217,"y":0.7,"width":0.7690491428264993,"height":0.03314326877209651}}]}''',
  ) as Map<Object?, Object?>,
);

ScanCrop _recordedCircle27Saved() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":3022,"height":3609,"rectified":true,"warnings":["orientation_ensemble"],"sourceCorners":[{"x":0.28789594769477844,"y":0.5496633350849152},{"x":0.5776219964027405,"y":0.5868417322635651},{"x":0.570165753364563,"y":0.8500749915838242},{"x":0.09965874254703522,"y":0.7856961190700531}],"lines":[{"text":"Enchaniment","confidence":1.0,"glyphHeight":0.027362687857231626,"bounds":{"x":0.05679110564546469,"y":0.5591944650273041,"width":0.29957769407806295,"height":0.03268047131990126}},{"text":"1; Prevent all damage against you","confidence":1.0,"glyphHeight":0.04371498628638663,"bounds":{"x":0.11410883630424613,"y":0.6602157435215743,"width":0.7468824809470135,"height":0.04875517657589057}},{"text":"from one blue source. Ii a source","confidence":1.0,"glyphHeight":0.03139534981928185,"bounds":{"x":0.11666665292373131,"y":0.7,"width":0.7291666935959216,"height":0.03139534931626262}},{"text":"Circle of Protections Blue","confidence":1.0,"glyphHeight":0.03860931262534434,"bounds":{"x":0.057371192956747294,"y":0.013195417176347424,"width":0.6270773765821477,"height":0.05216697587395593}},{"text":"Enchantment","confidence":1.0,"glyphHeight":0.028276327416840663,"bounds":{"x":0.06357569801528151,"y":0.5577788240532684,"width":0.297403773906068,"height":0.03345423440138506}}]}''',
  ) as Map<Object?, Object?>,
);

// Actual inferred partial OCR bounds; image path remains absent.
ScanCrop _recordedPartialProof() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "imagePath": "",
  "width": 1000,
  "height": 1400,
  "rectified": false,
  "warnings": [
    "partial_card",
    "incomplete_card",
    "no_card_rectangle"
  ],
  "sharpness": null,
  "sourceCorners": [
    {
      "x": 0.5798560275040663,
      "y": 0.5735661987186108
    },
    {
      "x": 0.890092301011665,
      "y": 0.5735661988401333
    },
    {
      "x": 0.8900923017531637,
      "y": 0.8227313112572876
    },
    {
      "x": 0.5798560274530788,
      "y": 0.8227313108985658
    }
  ],
  "lines": [
    {
      "text": "Enchantment",
      "confidence": 1.0,
      "alternatives": [
        "Enchantmen",
        "Enchantent"
      ],
      "glyphHeight": 0.03804633561650083,
      "bounds": {
        "x": 0.03551923136507757,
        "y": 0.4524315906976005,
        "width": 0.414799334551837,
        "height": 0.0936581589454828
      }
    },
    {
      "text": "As Nevermore enters the ba",
      "confidence": 1.0,
      "alternatives": [
        "As Nevermore enter the ba",
        "As Nevermore enters theba"
      ],
      "glyphHeight": 0.04514652691713307,
      "bounds": {
        "x": 0.031109184619220447,
        "y": 0.5258302385903278,
        "width": 0.9688908153807796,
        "height": 0.14956585935844013
      }
    },
    {
      "text": "name a nonland card.",
      "confidence": 1.0,
      "alternatives": [
        "name a nonland card",
        "name a noland card."
      ],
      "glyphHeight": 0.04581480579210854,
      "bounds": {
        "x": 0.02578867373134691,
        "y": 0.559668124201126,
        "width": 0.7842423722550675,
        "height": 0.14194670388864916
      }
    },
    {
      "text": "The named card can't be c",
      "confidence": 1.0,
      "alternatives": [
        "The named card can't bec",
        "The named card can't be"
      ],
      "glyphHeight": 0.04979858979118598,
      "bounds": {
        "x": 0.017840976265286315,
        "y": 0.6176233363700881,
        "width": 0.9789095491976351,
        "height": 0.1560469634773195
      }
    },
    {
      "text": "\u00abBy the law of Avacyn, the fo",
      "confidence": 1.0,
      "alternatives": [
        "\"By the law of Avacyn, the fo",
        "\u00abBy the law of Avacyn the fo"
      ],
      "glyphHeight": 0.05925177403092224,
      "bounds": {
        "x": 0.016908491342595224,
        "y": 0.6750669455933769,
        "width": 0.9830915086574048,
        "height": 0.17954500331435086
      }
    },
    {
      "text": "Nevermore",
      "confidence": 1.0,
      "alternatives": [
        "Nevermor",
        "evermore"
      ],
      "glyphHeight": 0.023881382403106763,
      "bounds": {
        "x": 0.08832995081645197,
        "y": 0.03493297373245219,
        "width": 0.3203249338510874,
        "height": 0.05795596711179043
      }
    }
  ]
}''') as Map<Object?, Object?>,
);

// Bounded native live OCR from the mounted physical16 scene.
ScanCrop _recordedCapture16Proof() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "imagePath": "",
  "width": 1000,
  "height": 1400,
  "rectified": false,
  "warnings": [
    "partial_card",
    "incomplete_card",
    "no_card_rectangle"
  ],
  "sharpness": null,
  "sourceCorners": [
    {
      "x": 0.5787297026227308,
      "y": 0.5732883628446228
    },
    {
      "x": 0.8909293706620398,
      "y": 0.5732883633145949
    },
    {
      "x": 0.8909293724247564,
      "y": 0.8236980521209293
    },
    {
      "x": 0.5787297016727515,
      "y": 0.8236980511503131
    }
  ],
  "lines": [
    {
      "text": "Nevermore",
      "confidence": 1.0,
      "alternatives": [
        "Nevermor",
        "evermore"
      ],
      "glyphHeight": 0.024070828150457163,
      "bounds": {
        "x": 0.0875175814634236,
        "y": 0.035128440046306664,
        "width": 0.32113729940878377,
        "height": 0.05851764016169847
      }
    },
    {
      "text": "Enchantment",
      "confidence": 1.0,
      "alternatives": [
        "Enchantmen",
        "Enchantmet"
      ],
      "glyphHeight": 0.033094541683666275,
      "bounds": {
        "x": 0.042010842344371795,
        "y": 0.45140672292026585,
        "width": 0.4072969591295397,
        "height": 0.0877139190909485
      }
    },
    {
      "text": "As Nevermore enters the ba",
      "confidence": 1.0,
      "alternatives": [
        "As Nevermore enter the ba",
        "As Nevermore enters theba"
      ],
      "glyphHeight": 0.04555583275346625,
      "bounds": {
        "x": 0.03098681473811405,
        "y": 0.5238000034656108,
        "width": 0.969013185261886,
        "height": 0.1495626368577877
      }
    },
    {
      "text": "name a nonland card.",
      "confidence": 1.0,
      "alternatives": [
        "name a noland card.",
        "name a nonland card"
      ],
      "glyphHeight": 0.04499194536669528,
      "bounds": {
        "x": 0.025677105693929003,
        "y": 0.5587966832884056,
        "width": 0.7823153109163852,
        "height": 0.13985709702186133
      }
    },
    {
      "text": "The named card can't be c",
      "confidence": 1.0,
      "alternatives": [
        "The named card can't be",
        "The named card can't bec"
      ],
      "glyphHeight": 0.04983708925415781,
      "bounds": {
        "x": 0.017733059486924406,
        "y": 0.6151915175952039,
        "width": 0.9822669405130756,
        "height": 0.15714654959306762
      }
    },
    {
      "text": "\"By the law of Avacyn, the Jo",
      "confidence": 1.0,
      "alternatives": [
        "\"By the law of Avacyn, the jo",
        "\"By the lawv of Avacyn, the Jo"
      ],
      "glyphHeight": 0.04583292721124946,
      "bounds": {
        "x": 0.02240658787456874,
        "y": 0.6787634239945937,
        "width": 0.9732141443201013,
        "height": 0.16664484384897593
      }
    }
  ]
}''') as Map<Object?, Object?>,
);

// Bounded OCR and geometry from the real rear-card capture20 scene.
ScanCrop _recordedBatsProof() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "width": 1000,
  "height": 1400,
  "rectified": false,
  "warnings": [
    "partial_card",
    "incomplete_card",
    "no_card_rectangle"
  ],
  "sourceCorners": [
    {
      "x": 0.6639959320646244,
      "y": 0.19276287196373323
    },
    {
      "x": 0.9313599432340529,
      "y": 0.19276287196373323
    },
    {
      "x": 0.9313599432340529,
      "y": 0.4551789125587886
    },
    {
      "x": 0.6639959320646244,
      "y": 0.4551789125587886
    }
  ],
  "lines": [
    {
      "text": "Creature - Bat",
      "confidence": 1.0,
      "glyphHeight": 0.02634669624635914,
      "bounds": {
        "x": 0.04110418408165456,
        "y": 0.4741969309012043,
        "width": 0.24787233230915473,
        "height": 0.036633016492024106
      }
    },
    {
      "text": "Whenever you create or sacrifice a",
      "confidence": 1.0,
      "glyphHeight": 0.029695862777201827,
      "bounds": {
        "x": 0.024688158759244596,
        "y": 0.5638783247146172,
        "width": 0.5995598245174327,
        "height": 0.054752853886709474
      }
    },
    {
      "text": "token, each opponent loses 1 life.",
      "confidence": 1.0,
      "glyphHeight": 0.027843137305093767,
      "bounds": {
        "x": 0.014620597091383832,
        "y": 0.5945340762826958,
        "width": 0.5774698866174576,
        "height": 0.04991579962320658
      }
    },
    {
      "text": "Mirkwood Bats",
      "confidence": 1.0,
      "glyphHeight": 0.036527136088093805,
      "bounds": {
        "x": 0.12003368335079598,
        "y": 0.04032239811235239,
        "width": 0.3186573880784055,
        "height": 0.05015814644949779
      }
    }
  ],
  "imagePath": ""
}''') as Map<Object?, Object?>,
);

// Bounded native OCR and geometry from mounted capture22.
ScanCrop _recordedBats22Proof() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "width": 1000,
  "height": 1400,
  "rectified": false,
  "warnings": [
    "partial_card",
    "incomplete_card",
    "no_card_rectangle"
  ],
  "sourceCorners": [
    {
      "x": 0.6426268046548045,
      "y": 0.20068513711990166
    },
    {
      "x": 0.8956189614563967,
      "y": 0.20068513711990166
    },
    {
      "x": 0.8956189614563967,
      "y": 0.4664332009871204
    },
    {
      "x": 0.6426268046548045,
      "y": 0.4664332009871204
    }
  ],
  "lines": [
    {
      "text": "Creature - Bat",
      "confidence": 1.0,
      "glyphHeight": 0.024143276336527044,
      "bounds": {
        "x": 0.04723237980239697,
        "y": 0.47405278480811097,
        "width": 0.2603980726231643,
        "height": 0.036002267152071
      }
    },
    {
      "text": "Whenever you create or sacrifice a",
      "confidence": 1.0,
      "glyphHeight": 0.033771272318940976,
      "bounds": {
        "x": 0.03448336787844339,
        "y": 0.5679776260041065,
        "width": 0.6348474638058188,
        "height": 0.07243621349334717
      }
    },
    {
      "text": "token, each opponent loses 1 life.",
      "confidence": 1.0,
      "glyphHeight": 0.032692469311971534,
      "bounds": {
        "x": 0.02442633602676202,
        "y": 0.5970484722034486,
        "width": 0.6071241201598787,
        "height": 0.06953377276659012
      }
    },
    {
      "text": "Mirkwood Bats",
      "confidence": 1.0,
      "glyphHeight": 0.0350037629466889,
      "bounds": {
        "x": 0.1178887199621353,
        "y": 0.040388460352343225,
        "width": 0.3109463342551977,
        "height": 0.047418570364675235
      }
    }
  ],
  "imagePath": ""
}''') as Map<Object?, Object?>,
);

// Bounded native OCR and geometry from mounted capture22.
ScanCrop _recordedCircle22Body() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "width": 1000,
  "height": 1400,
  "rectified": true,
  "warnings": [
    "incomplete_card"
  ],
  "sourceCorners": [
    {
      "x": 0.28502810851803684,
      "y": 0.5498579947389282
    },
    {
      "x": 0.6004202737013002,
      "y": 0.5891784033857455
    },
    {
      "x": 0.5770498935246213,
      "y": 0.8579105103055747
    },
    {
      "x": 0.08718875915002113,
      "y": 0.7912804715923412
    }
  ],
  "lines": [
    {
      "text": "Enchantment",
      "confidence": 1.0,
      "glyphHeight": 0.029556650246305494,
      "bounds": {
        "x": 0.06353591146280951,
        "y": 0.5566502462917351,
        "width": 0.30110497237569056,
        "height": 0.029556650246305494
      }
    },
    {
      "text": "1: Prevent all damage against you",
      "confidence": 1.0,
      "glyphHeight": 0.039408866995073955,
      "bounds": {
        "x": 0.1270718228959484,
        "y": 0.6600985221510673,
        "width": 0.7513812154696132,
        "height": 0.039408866995073955
      }
    },
    {
      "text": "from one blue source. If a source",
      "confidence": 1.0,
      "glyphHeight": 0.03178168148604457,
      "bounds": {
        "x": 0.12137492729093095,
        "y": 0.7,
        "width": 0.7434128397736102,
        "height": 0.03280001000662631
      }
    },
    {
      "text": "deals damage to you more than",
      "confidence": 1.0,
      "glyphHeight": 0.04090160183837745,
      "bounds": {
        "x": 0.12417195334778687,
        "y": 0.7316336695234913,
        "width": 0.6964137883476131,
        "height": 0.043705413380607225
      }
    }
  ],
  "imagePath": ""
}''') as Map<Object?, Object?>,
);

// Bounded native OCR and geometry from mounted capture22.
ScanCrop _recordedCircle22Saved() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "width": 2797,
  "height": 3907,
  "rectified": true,
  "warnings": [
    "geometry_adjusted"
  ],
  "sourceCorners": [
    {
      "x": 0.27261272072792053,
      "y": 0.5369243323802948
    },
    {
      "x": 0.6206542253494263,
      "y": 0.6098310649394989
    },
    {
      "x": 0.5879865884780884,
      "y": 0.8682435005903244
    },
    {
      "x": 0.048023100942373276,
      "y": 0.8100203424692154
    }
  ],
  "lines": [
    {
      "text": "Enchantment",
      "confidence": 1.0,
      "glyphHeight": 0.023091171125997925,
      "bounds": {
        "x": 0.0920600614957437,
        "y": 0.5066557934095257,
        "width": 0.23774526185696254,
        "height": 0.031125038404669736
      }
    },
    {
      "text": "1; Prevent all damage against you",
      "confidence": 1.0,
      "glyphHeight": 0.03370915757988821,
      "bounds": {
        "x": 0.13895618758782616,
        "y": 0.5901333226937195,
        "width": 0.6388435063829075,
        "height": 0.04576602026042342
      }
    },
    {
      "text": "from one blue source. If a source",
      "confidence": 1.0,
      "glyphHeight": 0.03192918529564939,
      "bounds": {
        "x": 0.13050917271425583,
        "y": 0.619942302630382,
        "width": 0.6372216029027431,
        "height": 0.04846992414585771
      }
    },
    {
      "text": "deals damage to you more than",
      "confidence": 1.0,
      "glyphHeight": 0.038052326385015225,
      "bounds": {
        "x": 0.1330811116043183,
        "y": 0.6599329771315128,
        "width": 0.595918820362759,
        "height": 0.04683250341347078
      }
    },
    {
      "text": "GIrele of Protection: Blue",
      "confidence": 0.5,
      "glyphHeight": 0.030967114690040976,
      "bounds": {
        "x": 0.09135628726054074,
        "y": 0.0,
        "width": 0.4889578720430889,
        "height": 0.08093887286987107
      }
    }
  ],
  "imagePath": ""
}''') as Map<Object?, Object?>,
);

// Bounded native OCR and geometry from mounted capture23.
ScanCrop _recordedBats23Live() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "width": 1000,
  "height": 1400,
  "rectified": false,
  "warnings": [
    "partial_card",
    "incomplete_card",
    "no_card_rectangle"
  ],
  "sourceCorners": [
    {
      "x": 0.648551661952951,
      "y": 0.20869790174866254
    },
    {
      "x": 0.8808500380194627,
      "y": 0.21290260160809366
    },
    {
      "x": 0.8702890261294436,
      "y": 0.4495660087202028
    },
    {
      "x": 0.6374868072090077,
      "y": 0.4447606364572667
    }
  ],
  "lines": [
    {
      "text": "Creature - Bat",
      "confidence": 1.0,
      "glyphHeight": 0.024832872369087322,
      "bounds": {
        "x": 0.05219955072514516,
        "y": 0.47119959911555065,
        "width": 0.25581851813311135,
        "height": 0.038339029997587204
      }
    },
    {
      "text": "Whenever you create or sacrificc a",
      "confidence": 1.0,
      "glyphHeight": 0.03548600310306266,
      "bounds": {
        "x": 0.03469499192369616,
        "y": 0.5672590547399328,
        "width": 0.6348513410391051,
        "height": 0.0708511434495449
      }
    },
    {
      "text": "token, each opponent loses 1 life.",
      "confidence": 1.0,
      "glyphHeight": 0.0327520756879197,
      "bounds": {
        "x": 0.024668445792918225,
        "y": 0.5984183113787667,
        "width": 0.6177025049761996,
        "height": 0.06519121304154396
      }
    },
    {
      "text": "Mirkwood Bats",
      "confidence": 1.0,
      "glyphHeight": 0.030878555901000578,
      "bounds": {
        "x": 0.12291866920222237,
        "y": 0.03725237005508353,
        "width": 0.30630024143906887,
        "height": 0.047294123249669244
      }
    }
  ],
  "imagePath": ""
}''') as Map<Object?, Object?>,
);

// Bounded native OCR and geometry from mounted capture23.
ScanCrop _recordedBats23Saved() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "width": 1535,
  "height": 2150,
  "rectified": false,
  "warnings": [
    "no_card_rectangle",
    "partial_card",
    "incomplete_card"
  ],
  "sourceCorners": [
    {
      "x": 0.641923449717229,
      "y": 0.1996516536763031
    },
    {
      "x": 0.8955432349871394,
      "y": 0.1996516536763031
    },
    {
      "x": 0.8955432349871394,
      "y": 0.4660589911446964
    },
    {
      "x": 0.641923449717229,
      "y": 0.4660589911446964
    }
  ],
  "lines": [
    {
      "text": "Creature - Bat",
      "confidence": 1.0,
      "glyphHeight": 0.02192696813104757,
      "bounds": {
        "x": 0.05097717329699932,
        "y": 0.474230313630187,
        "width": 0.25144477685292566,
        "height": 0.03513515738553774
      }
    },
    {
      "text": "Whenever you create or sacrifice a",
      "confidence": 1.0,
      "glyphHeight": 0.028162576438274002,
      "bounds": {
        "x": 0.03806985830169977,
        "y": 0.5711465951352397,
        "width": 0.6227929989496868,
        "height": 0.06483965851539786
      }
    },
    {
      "text": "token, each opponent loses 1 life.",
      "confidence": 1.0,
      "glyphHeight": 0.0337369845850221,
      "bounds": {
        "x": 0.02755740071144726,
        "y": 0.598465553027417,
        "width": 0.6137260595957438,
        "height": 0.07077539843182235
      }
    },
    {
      "text": "Mirkwood Bats",
      "confidence": 1.0,
      "glyphHeight": 0.027891877333288465,
      "bounds": {
        "x": 0.12389938672213208,
        "y": 0.0419473534420739,
        "width": 0.2996995647748311,
        "height": 0.045620731087618105
      }
    }
  ],
  "imagePath": ""
}''') as Map<Object?, Object?>,
);

// Bounded post-ACK OCR/geometry from mounted capture24.
ScanCrop _recordedCircle24Captured() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "width": 1000,
  "height": 1400,
  "rectified": true,
  "warnings": [],
  "sourceCorners": [
    {
      "x": 0.29675333431185075,
      "y": 0.5521358761174631
    },
    {
      "x": 0.5707353551048889,
      "y": 0.5902716748906619
    },
    {
      "x": 0.5607253402672747,
      "y": 0.8357266943308632
    },
    {
      "x": 0.12109995774538232,
      "y": 0.7769900447012531
    }
  ],
  "lines": [
    {
      "text": "Cirele of Drotections Blue",
      "confidence": 1.0,
      "glyphHeight": 0.03631266983233445,
      "bounds": {
        "x": 0.053147821807476125,
        "y": 0.0017505776245855253,
        "width": 0.6296928062867583,
        "height": 0.03984498069399878
      }
    },
    {
      "text": "Enchantment",
      "confidence": 1.0,
      "glyphHeight": 0.026064592298838226,
      "bounds": {
        "x": 0.05305719380852724,
        "y": 0.5596173601213271,
        "width": 0.29558520370654845,
        "height": 0.02931181362697055
      }
    },
    {
      "text": "1; Prevent all damage against you",
      "confidence": 1.0,
      "glyphHeight": 0.03925911510099968,
      "bounds": {
        "x": 0.11223638413263502,
        "y": 0.6582444811334588,
        "width": 0.7530726743548103,
        "height": 0.04206994374593109
      }
    },
    {
      "text": "from one blue source. If a source",
      "confidence": 1.0,
      "glyphHeight": 0.033333333333333326,
      "bounds": {
        "x": 0.10674157386762645,
        "y": 0.6952380951339285,
        "width": 0.74438202247191,
        "height": 0.03333333333333344
      }
    },
    {
      "text": "from one blue source. li a source",
      "confidence": 1.0,
      "glyphHeight": 0.028571428571428567,
      "bounds": {
        "x": 0.10674157284500145,
        "y": 0.7,
        "width": 0.7415730337078652,
        "height": 0.028571428564102563
      }
    },
    {
      "text": "deals damage to you more than",
      "confidence": 1.0,
      "glyphHeight": 0.03939579012149645,
      "bounds": {
        "x": 0.10655824026480555,
        "y": 0.7301914573534934,
        "width": 0.6997990554638124,
        "height": 0.04284241085960753
      }
    },
    {
      "text": "once in a turn, you may pay 1",
      "confidence": 1.0,
      "glyphHeight": 0.03728826278202129,
      "bounds": {
        "x": 0.10937843209447702,
        "y": 0.7660397187530024,
        "width": 0.6660382560129915,
        "height": 0.040321829205467584
      }
    },
    {
      "text": "each time to prevent the damage.",
      "confidence": 1.0,
      "glyphHeight": 0.039313725062779005,
      "bounds": {
        "x": 0.10833331954426603,
        "y": 0.8023529421071871,
        "width": 0.7291666952411779,
        "height": 0.03931372506277903
      }
    },
    {
      "text": "Cirele of Drotestion Blue",
      "confidence": 1.0,
      "glyphHeight": 0.036272244381562666,
      "bounds": {
        "x": 0.050357547524512346,
        "y": 0.0017000093503691804,
        "width": 0.6352735798010665,
        "height": 0.039828811494430676
      }
    }
  ],
  "imagePath": ""
}''') as Map<Object?, Object?>,
);

// Bounded post-ACK OCR/geometry from mounted capture24.
ScanCrop _recordedCircle24Drift() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "width": 1000,
  "height": 1400,
  "rectified": true,
  "warnings": [],
  "sourceCorners": [
    {
      "x": 0.275441381719261,
      "y": 0.5452429028982877
    },
    {
      "x": 0.6642909301683998,
      "y": 0.5997137752945002
    },
    {
      "x": 0.5981858465085041,
      "y": 0.8808366643322528
    },
    {
      "x": 0.04956807258268358,
      "y": 0.8071668749463398
    }
  ],
  "lines": [
    {
      "text": "•Trele of Proreecion Blue",
      "confidence": 1.0,
      "glyphHeight": 0.03292980124200991,
      "bounds": {
        "x": 0.0640408087016655,
        "y": 0.0,
        "width": 0.6178250445999912,
        "height": 0.03586480276925508
      }
    },
    {
      "text": "Enchanument",
      "confidence": 1.0,
      "glyphHeight": 0.02863961813842475,
      "bounds": {
        "x": 0.047486033116520374,
        "y": 0.5560859188135016,
        "width": 0.30446927374301674,
        "height": 0.02863961813842475
      }
    },
    {
      "text": "1; Prevent all damage against you",
      "confidence": 1.0,
      "glyphHeight": 0.03818615751789978,
      "bounds": {
        "x": 0.11173184316179635,
        "y": 0.658711217110336,
        "width": 0.7513966480446927,
        "height": 0.03818615751789978
      }
    },
    {
      "text": "from one blue source. If a source",
      "confidence": 1.0,
      "glyphHeight": 0.03571897708524086,
      "bounds": {
        "x": 0.10597374729361918,
        "y": 0.6909911942018154,
        "width": 0.743336427145164,
        "height": 0.03926543916324443
      }
    },
    {
      "text": "from one blue source. il a source",
      "confidence": 1.0,
      "glyphHeight": 0.026190476190476198,
      "bounds": {
        "x": 0.10614525126820629,
        "y": 0.7023809523692601,
        "width": 0.740223463687151,
        "height": 0.026190476190476198
      }
    },
    {
      "text": "deals damage to you more than",
      "confidence": 1.0,
      "glyphHeight": 0.03809523809523809,
      "bounds": {
        "x": 0.10893854733384273,
        "y": 0.7309523809438394,
        "width": 0.6955307262569832,
        "height": 0.03809523809523809
      }
    },
    {
      "text": "once in a turn, you may pay 1",
      "confidence": 1.0,
      "glyphHeight": 0.03830579813468172,
      "bounds": {
        "x": 0.10807033649925366,
        "y": 0.7668871021929091,
        "width": 0.6588945868294998,
        "height": 0.04283961341494604
      }
    },
    {
      "text": "each time to prevent the damage.",
      "confidence": 1.0,
      "glyphHeight": 0.037151630441990546,
      "bounds": {
        "x": 0.11150937701715166,
        "y": 0.7984828699536856,
        "width": 0.7377832508619938,
        "height": 0.0413697151910691
      }
    },
    {
      "text": "Crele of Prorection Blue",
      "confidence": 1.0,
      "glyphHeight": 0.038503994008531495,
      "bounds": {
        "x": 0.04560253862004039,
        "y": 0.0,
        "width": 0.6338498419223552,
        "height": 0.03894591775057418
      }
    }
  ],
  "imagePath": ""
}''') as Map<Object?, Object?>,
);

// Bounded post-ACK OCR/geometry from mounted capture24.
ScanCrop _recordedCircle24Clipped() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "width": 1000,
  "height": 1400,
  "rectified": true,
  "warnings": [],
  "sourceCorners": [
    {
      "x": 0.2743097617436269,
      "y": 0.5448075363881865
    },
    {
      "x": 0.6668759308654387,
      "y": 0.5999583269641344
    },
    {
      "x": 0.5910530563185712,
      "y": 0.8812860284575113
    },
    {
      "x": 0.04796812835213318,
      "y": 0.8083815503413441
    }
  ],
  "lines": [
    {
      "text": "Cirele of",
      "confidence": 1.0,
      "glyphHeight": 0.014861995753715496,
      "bounds": {
        "x": 0.09929077996076656,
        "y": 0.012738853487374135,
        "width": 0.17021276595744678,
        "height": 0.014861995753715496
      }
    },
    {
      "text": "Jn.chern.popent",
      "confidence": 0.30000001192092896,
      "glyphHeight": 0.02108120354159535,
      "bounds": {
        "x": 0.1625054583408559,
        "y": 0.31891517208845643,
        "width": 0.3375924834122895,
        "height": 0.025658648991027988
      }
    },
    {
      "text": "1: Prevent all damage agai",
      "confidence": 1.0,
      "glyphHeight": 0.03690498376865482,
      "bounds": {
        "x": 0.23333805796405274,
        "y": 0.3979523926345736,
        "width": 0.7567143000609486,
        "height": 0.04435805909952539
      }
    },
    {
      "text": "from one blue source. If",
      "confidence": 1.0,
      "glyphHeight": 0.033555757782895226,
      "bounds": {
        "x": 0.2362670845332949,
        "y": 0.43001398413209224,
        "width": 0.7436013729014295,
        "height": 0.04741959865432377
      }
    },
    {
      "text": "deals damage to you mo",
      "confidence": 1.0,
      "glyphHeight": 0.0414765648903282,
      "bounds": {
        "x": 0.24080957241386997,
        "y": 0.4754648199780034,
        "width": 0.7524144598778257,
        "height": 0.04377336157861533
      }
    },
    {
      "text": "once in a turn, you may",
      "confidence": 1.0,
      "glyphHeight": 0.044201637793600215,
      "bounds": {
        "x": 0.25131919662340907,
        "y": 0.5109642409440538,
        "width": 0.7456428581941212,
        "height": 0.047856498928839475
      }
    },
    {
      "text": "each time to prevent t",
      "confidence": 1.0,
      "glyphHeight": 0.051159088624523716,
      "bounds": {
        "x": 0.2572687243363475,
        "y": 0.5469566786667186,
        "width": 0.7415669759114584,
        "height": 0.06422798901859617
      }
    },
    {
      "text": "Girele of Droteet",
      "confidence": 0.5,
      "glyphHeight": 0.01583517551691614,
      "bounds": {
        "x": 0.0989552545544107,
        "y": 0.007923660798723864,
        "width": 0.3375766294222351,
        "height": 0.020593411295037525
      }
    }
  ],
  "imagePath": ""
}''') as Map<Object?, Object?>,
);

// Bounded post-ACK OCR/geometry from mounted capture24.
ScanCrop _recordedCircle24ClippedLater() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "width": 1000,
  "height": 1400,
  "rectified": true,
  "warnings": [],
  "sourceCorners": [
    {
      "x": 0.29490002076564925,
      "y": 0.551930919027143
    },
    {
      "x": 0.5780711590854634,
      "y": 0.5932218063465756
    },
    {
      "x": 0.5399373096048465,
      "y": 0.837343061800147
    },
    {
      "x": 0.11336222830762901,
      "y": 0.7804276350995725
    }
  ],
  "lines": [
    {
      "text": "Girele of Droreecion Blac",
      "confidence": 0.5,
      "glyphHeight": 0.01627670926022471,
      "bounds": {
        "x": 0.09990996884704754,
        "y": 0.005036317208292451,
        "width": 0.5206035764413923,
        "height": 0.023956565775422933
      }
    },
    {
      "text": "in cheen cop eieng",
      "confidence": 0.30000001192092896,
      "glyphHeight": 0.021273885547427988,
      "bounds": {
        "x": 0.1642354456399537,
        "y": 0.31941711857408284,
        "width": 0.33691585363025733,
        "height": 0.02544447907015812
      }
    },
    {
      "text": "1; Prevent all damage agai",
      "confidence": 1.0,
      "glyphHeight": 0.03607848828563924,
      "bounds": {
        "x": 0.2356462692073334,
        "y": 0.3970604336209951,
        "width": 0.7617814258862567,
        "height": 0.04614372334928607
      }
    },
    {
      "text": "from one blue source. If:",
      "confidence": 1.0,
      "glyphHeight": 0.03290936768660627,
      "bounds": {
        "x": 0.2386250099946493,
        "y": 0.4298089798062671,
        "width": 0.7592649288929492,
        "height": 0.047696902201725844
      }
    },
    {
      "text": "deals damage to you mo",
      "confidence": 1.0,
      "glyphHeight": 0.042650068833182994,
      "bounds": {
        "x": 0.22871336532048686,
        "y": 0.4732185003285396,
        "width": 0.7647245673723118,
        "height": 0.047070173116830594
      }
    },
    {
      "text": "once in a turn, you may",
      "confidence": 1.0,
      "glyphHeight": 0.04448994536379514,
      "bounds": {
        "x": 0.2539453907153418,
        "y": 0.5099054712228736,
        "width": 0.743030999296455,
        "height": 0.04823904567294657
      }
    },
    {
      "text": "each time to prevent t",
      "confidence": 1.0,
      "glyphHeight": 0.04827370848998407,
      "bounds": {
        "x": 0.25969101610930967,
        "y": 0.5461503128150538,
        "width": 0.7393865004235272,
        "height": 0.06440092559553612
      }
    },
    {
      "text": "Girele of' Droteecion",
      "confidence": 0.5,
      "glyphHeight": 0.015949650726842464,
      "bounds": {
        "x": 0.09635959241091818,
        "y": 0.007164984411155095,
        "width": 0.4094235820154989,
        "height": 0.021578760737866416
      }
    }
  ],
  "imagePath": ""
}''') as Map<Object?, Object?>,
);

// Bounded post-ACK OCR/geometry from mounted capture24.
ScanCrop _recordedCircle24Saved() => ScanCrop.fromMap(
  jsonDecode(r'''{
  "width": 2723,
  "height": 3804,
  "rectified": true,
  "warnings": [
    "orientation_ensemble",
    "geometry_adjusted"
  ],
  "sourceCorners": [
    {
      "x": 0.2757945954799652,
      "y": 0.5448122024536133
    },
    {
      "x": 0.647661566734314,
      "y": 0.6003431081771851
    },
    {
      "x": 0.5997932553291321,
      "y": 0.8822622895240784
    },
    {
      "x": 0.04227014258503914,
      "y": 0.8075958639383316
    }
  ],
  "lines": [
    {
      "text": "• blac",
      "confidence": 1.0,
      "glyphHeight": 0.02034883669623566,
      "bounds": {
        "x": 0.45030425974549276,
        "y": 0.02180232566835505,
        "width": 0.10750507013038041,
        "height": 0.02034883669623566
      }
    },
    {
      "text": "Enchanument",
      "confidence": 1.0,
      "glyphHeight": 0.024709302418866264,
      "bounds": {
        "x": 0.0953346890175049,
        "y": 0.49999999994261446,
        "width": 0.24543609843205072,
        "height": 0.024709302418866264
      }
    },
    {
      "text": "1; Prevent all damage against you",
      "confidence": 1.0,
      "glyphHeight": 0.03387600338672985,
      "bounds": {
        "x": 0.1477862700231044,
        "y": 0.5893761459354457,
        "width": 0.6191820769232975,
        "height": 0.037325733718310494
      }
    },
    {
      "text": "from one blue source. If a source",
      "confidence": 1.0,
      "glyphHeight": 0.04009268878584035,
      "bounds": {
        "x": 0.14530778623781057,
        "y": 0.6194246686404452,
        "width": 0.6161608366889225,
        "height": 0.05009619294656942
      }
    },
    {
      "text": "deals damage to you more than",
      "confidence": 1.0,
      "glyphHeight": 0.036364718817260666,
      "bounds": {
        "x": 0.1480730232706316,
        "y": 0.658430232362707,
        "width": 0.5760649066314474,
        "height": 0.03636472082288489
      }
    },
    {
      "text": "once in a rurn, you may pay -",
      "confidence": 1.0,
      "glyphHeight": 0.029702969900154627,
      "bounds": {
        "x": 0.15000000897601887,
        "y": 0.7000000001744835,
        "width": 0.549999982074844,
        "height": 0.029702969900154627
      }
    },
    {
      "text": "me to prevent the damage",
      "confidence": 1.0,
      "glyphHeight": 0.03256353558776317,
      "bounds": {
        "x": 0.27747734330048845,
        "y": 0.7265206033574008,
        "width": 0.48282926898345735,
        "height": 0.03413708648414413
      }
    },
    {
      "text": "Circle of Protection: Blue",
      "confidence": 1.0,
      "glyphHeight": 0.029203811645831284,
      "bounds": {
        "x": 0.08170073364312232,
        "y": 0.01611638553358552,
        "width": 0.48036415671462,
        "height": 0.038385008430063566
      }
    },
    {
      "text": "Enchantment",
      "confidence": 1.0,
      "glyphHeight": 0.026162805656592014,
      "bounds": {
        "x": 0.09736307621822005,
        "y": 0.497093008394624,
        "width": 0.24746451637961642,
        "height": 0.026162820557753208
      }
    }
  ],
  "imagePath": ""
}''') as Map<Object?, Object?>,
);

ScanCrop _final4ClippedNevermore() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"/local/owned-nevermore.jpg","width":2515,"height":3513,"rectified":true,"warnings":["geometry_adjusted"],"sharpness":0.8323807485700743,"sourceCorners":[{"x":0.2409072369337082,"y":0.49379491806030273},{"x":0.5038254261016846,"y":0.5013433694839478},{"x":0.5296821594238281,"y":0.7067863941192627},{"x":0.1301061362028122,"y":0.69146928191185}],"lines":[{"text":"Never","confidence":1.0,"alternatives":["Neve","Nevr"],"glyphHeight":0.027269382679448492,"bounds":{"x":0.08055488741880881,"y":0.06542526381511837,"width":0.1551847594341527,"height":0.03733622464661435}},{"text":"Enchantment","confidence":1.0,"alternatives":["Enchantmen","Enchantent"],"glyphHeight":0.02478847907501361,"bounds":{"x":0.08378792551509248,"y":0.5849494853146537,"width":0.2948642360766097,"height":0.03552611931251004}},{"text":"As Nevermore enters the battlefield,","confidence":1.0,"alternatives":["As Nevermore enter the battlefield,","As Nevermore enters the battlefield"],"glyphHeight":0.03778636116255561,"bounds":{"x":0.0845527155249008,"y":0.6523097034140004,"width":0.8572954381023946,"height":0.04708108049804127}},{"text":"name a nonland card.","confidence":1.0,"alternatives":["name a noland card.","name a nonland card"],"glyphHeight":0.03461082572565965,"bounds":{"x":0.08215964826888363,"y":0.6852398548282744,"width":0.531860545632949,"height":0.04776619100814927}},{"text":"The named card can't be cast.","confidence":1.0,"alternatives":["The named card can't be cast","The named card can't becast."],"glyphHeight":0.03611636830934725,"bounds":{"x":0.08266481446152438,"y":0.7351937655545986,"width":0.7252145351779858,"height":0.04260371582170208}},{"text":"«By the law of Avacyn, the following","confidence":1.0,"alternatives":["«By the law of Avacy, the following","«By the law of Avacyn the following"],"glyphHeight":0.04510558847039604,"bounds":{"x":0.08187148335444808,"y":0.7843651100354064,"width":0.7913002293136427,"height":0.05968288189318616}},{"text":"thoughts, words, and deeds are","confidence":1.0,"alternatives":["thoughts, words and deeds are","thoughts, words, and deed are"],"glyphHeight":0.04237929188530962,"bounds":{"x":0.0822875623174856,"y":0.8278869922797605,"width":0.6525996804047844,"height":0.051632672192091}},{"text":"henceforth disallowed.\"","confidence":1.0,"alternatives":[],"glyphHeight":0.0419507304394075,"bounds":{"x":0.0809546646420745,"y":0.8602267424519187,"width":0.5137747808556489,"height":0.045313192002008715}},{"text":"-Jason A. Engle","confidence":1.0,"alternatives":[],"glyphHeight":0.023450514125643005,"bounds":{"x":0.12904034047720161,"y":0.935216856239503,"width":0.23891088731338186,"height":0.023450514125643005}},{"text":"IM & © 1993-2011 Wizards of the Coast LLC 25/264","confidence":1.0,"alternatives":[],"glyphHeight":0.019624453668727677,"bounds":{"x":0.06179488767612807,"y":0.9547452479891054,"width":0.5767089649679551,"height":0.03111435312926206}},{"text":"a cala call","confidence":1.0,"alternatives":[],"glyphHeight":0.013649289099526073,"bounds":{"x":0.33312500309790455,"y":0.7600000000810889,"width":0.2870833268666909,"height":0.013649289099526073}},{"text":"«By the law of Avacyn, th","confidence":1.0,"alternatives":[],"glyphHeight":0.04469904087324186,"bounds":{"x":0.08102563726679633,"y":0.7814373147076149,"width":0.5689743627332037,"height":0.06186498343662063}},{"text":"thoughts, words, and deeds","confidence":1.0,"alternatives":[],"glyphHeight":0.03729665280520691,"bounds":{"x":0.08422841668248343,"y":0.8297561637344076,"width":0.5654387233892688,"height":0.044840025698404166}},{"text":"henceforth disallowedạẠạ","confidence":1.0,"alternatives":[],"glyphHeight":0.03611648927789618,"bounds":{"x":0.08647793581723949,"y":0.8639661157733146,"width":0.5023453094557037,"height":0.03966325226553243}},{"text":"~Jason A. Engle","confidence":1.0,"alternatives":[],"glyphHeight":0.021743954561996598,"bounds":{"x":0.10419057330634532,"y":0.9314470996920013,"width":0.2620810399137091,"height":0.027633764257928222}}]}''',
  ) as Map<Object?, Object?>,
);

ScanCrop _final5TitlelessSaved() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"/local/observed-titleless-card.jpg","width":2363,"height":3301,"rectified":true,"warnings":["incomplete_card","orientation_ensemble","geometry_adjusted"],"sharpness":0.8414651279251035,"sourceCorners":[{"x":0.24087904393672943,"y":0.4990139603614807},{"x":0.5001259446144104,"y":0.4988778233528137},{"x":0.5243744850158691,"y":0.7044861316680908},{"x":0.13639390468597412,"y":0.6887986958026886}],"lines":[{"text":"Enchantment","confidence":1.0,"alternatives":["Enchantmen","Enchantmet"],"glyphHeight":0.029513527597153085,"bounds":{"x":0.07683706572839069,"y":0.5761347502869965,"width":0.31488571554271094,"height":0.045404915951151814}},{"text":"As Nevermore enters the battlefield,","confidence":1.0,"alternatives":["As Nevermore enters the battlefield","As Nevermore enter the battlefield,"],"glyphHeight":0.04209943977516781,"bounds":{"x":0.0750548037608145,"y":0.6397778914449976,"width":0.8847952647459286,"height":0.07335087980089006}},{"text":"name a nonland card.","confidence":1.0,"alternatives":["name a noland card.","name anonland card."],"glyphHeight":0.033167310674982055,"bounds":{"x":0.07577555027900904,"y":0.6844183232741038,"width":0.5551180508737837,"height":0.05315260075569728}},{"text":"The named card can't be cast.","confidence":1.0,"alternatives":["The named card can't be cast","The named card can't becast."],"glyphHeight":0.035834384609631516,"bounds":{"x":0.07794736542436699,"y":0.7347289211882027,"width":0.7469119928815038,"height":0.0509591752438745}},{"text":"«By the law of Avacyn, the following","confidence":1.0,"alternatives":["«By the law of Avacy, the following","«By the law of Avacyn the following"],"glyphHeight":0.04438869076027807,"bounds":{"x":0.07704834413613947,"y":0.7855536927723922,"width":0.8128146253866593,"height":0.06700081366037036}},{"text":"thoughts, words, and deeds are","confidence":1.0,"alternatives":["thoughts, words, and deed are","thoughts, words and deeds are"],"glyphHeight":0.042706415363904925,"bounds":{"x":0.07571097232857438,"y":0.8289138589292119,"width":0.6758644375099143,"height":0.05920445045364908}},{"text":"henceforth disallowediạ","confidence":1.0,"alternatives":[],"glyphHeight":0.037117216380665605,"bounds":{"x":0.07798773453675846,"y":0.8658188770232601,"width":0.5309702297152601,"height":0.0465454355362923}},{"text":"Jason A. Engle","confidence":1.0,"alternatives":[],"glyphHeight":0.02727797732613459,"bounds":{"x":0.05353829579550126,"y":0.9385260061361498,"width":0.32639187523959656,"height":0.03266701236847908}},{"text":"VM & © 1993-2011 Wizards of the Coast LLC 25/264","confidence":1.0,"alternatives":[],"glyphHeight":0.021070656078148314,"bounds":{"x":0.051667610377995686,"y":0.9621571298410255,"width":0.6043320605799227,"height":0.032004790536818935}},{"text":"cara can","confidence":1.0,"alternatives":[],"glyphHeight":0.018202247139188454,"bounds":{"x":0.3977470937257824,"y":0.7600000000217932,"width":0.21351744035879774,"height":0.018202247139188454}},{"text":"T","confidence":1.0,"alternatives":[],"glyphHeight":0.01617977514606741,"bounds":{"x":0.6131540699642244,"y":0.7600000002759103,"width":0.02267441811660928,"height":0.0161797745942469}},{"text":"«By the law of Avacyn, t","confidence":1.0,"alternatives":[],"glyphHeight":0.04549414163564089,"bounds":{"x":0.07652615466939199,"y":0.7820461971993571,"width":0.5734738453306081,"height":0.07550017311230715}},{"text":"thoughts, words, and deed","confidence":1.0,"alternatives":[],"glyphHeight":0.04623331632433574,"bounds":{"x":0.07492346631990048,"y":0.827657193064991,"width":0.5750765336800996,"height":0.060400424448008506}},{"text":"henceforth disallowed.\"","confidence":1.0,"alternatives":[],"glyphHeight":0.04489191042167122,"bounds":{"x":0.07680548197166824,"y":0.8642550792436894,"width":0.5338879466056823,"height":0.0499212707980754}}]}''',
  ) as Map<Object?, Object?>,
);

ScanCrop _final5FrozenNevermore() => ScanCrop.fromMap(
  jsonDecode(
    r'''{"imagePath":"","width":1000,"height":1400,"rectified":true,"warnings":[],"sharpness":null,"sourceCorners":[{"x":0.2401342250443293,"y":0.4987237705884473},{"x":0.5069078041434845,"y":0.5029429434875424},{"x":0.526029439502523,"y":0.7055949812258366},{"x":0.13551407840382468,"y":0.6888925247333048}],"lines":[{"text":"Enchantment","confidence":1.0,"alternatives":["Enchantmen","Enchantmet"],"glyphHeight":0.03383233841855918,"bounds":{"x":0.06544887215924503,"y":0.5722161052449114,"width":0.30807641325096635,"height":0.041572146945529576}},{"text":"As Nevermore enters the battlefield,","confidence":1.0,"alternatives":["As Nevermore enter the battlefield,","As Nevermore enters the battlefield"],"glyphHeight":0.045137315163394094,"bounds":{"x":0.06939680223580331,"y":0.6421294055748246,"width":0.885655260252205,"height":0.05251817736360753}},{"text":"name a nonland card.","confidence":1.0,"alternatives":["name a noland card.","name anonland card."],"glyphHeight":0.04157136253096824,"bounds":{"x":0.0656712459088073,"y":0.678400131005552,"width":0.5519587819169207,"height":0.05473647183842134}},{"text":"\"By the law of Avacyn, the following","confidence":1.0,"alternatives":["By the law of Avacyn, the following","\"By the law of Avacyn the following"],"glyphHeight":0.05204755587549188,"bounds":{"x":0.07270559207256709,"y":0.7878275444428819,"width":0.8162268130206065,"height":0.0598614083396064}},{"text":"henceforth disallowed.\"","confidence":1.0,"alternatives":["henceforth disallowed.","henceforth disallowed\""],"glyphHeight":0.04166666666666663,"bounds":{"x":0.06968641097443264,"y":0.8715277777637012,"width":0.5191637630662022,"height":0.04166666666666663}},{"text":"و ٨؟","confidence":0.30000001192092896,"alternatives":["و ٨.","ود.؟"],"glyphHeight":0.02083333333333337,"bounds":{"x":0.05923344919860627,"y":0.9687499998958332,"width":0.06271777003484322,"height":0.02083333333333337}},{"text":"mue a nonana cara.","confidence":1.0,"alternatives":[],"glyphHeight":0.031034482758620682,"bounds":{"x":0.06968641097102511,"y":0.7,"width":0.5435540069686411,"height":0.031034482748411984}},{"text":"The named card can't be cast.","confidence":1.0,"alternatives":[],"glyphHeight":0.042029381819440076,"bounds":{"x":0.06941550431925003,"y":0.7342417992424115,"width":0.7496572886609865,"height":0.04721440446787865}},{"text":"\"By the lar of Avacyn, the following","confidence":1.0,"alternatives":[],"glyphHeight":0.04093202165688796,"bounds":{"x":0.07629484479374285,"y":0.7928727979988801,"width":0.8020495371536096,"height":0.04852206295934217}},{"text":"thoughts, words, and deeds are","confidence":1.0,"alternatives":[],"glyphHeight":0.037931034482758606,"bounds":{"x":0.06968641090113573,"y":0.8379310344682811,"width":0.6655052264808363,"height":0.03793103448275864}},{"text":"henceforth disallowediạiại","confidence":1.0,"alternatives":[],"glyphHeight":0.04720276774318606,"bounds":{"x":0.0690692863998889,"y":0.8651294648460701,"width":0.5235596234790124,"height":0.05448644901144093}},{"text":"er Jason A. Engle","confidence":1.0,"alternatives":[],"glyphHeight":0.028428842632860694,"bounds":{"x":0.09719752728262541,"y":0.9438015910629537,"width":0.2621142025193271,"height":0.032966580884210006}},{"text":"考考了","confidence":0.30000001192092896,"alternatives":[],"glyphHeight":0.04288386644635882,"bounds":{"x":0.8181169829936527,"y":0.026664465032040452,"width":0.14793039780460582,"height":0.04288387952532088}},{"text":"Nevermore","confidence":1.0,"alternatives":["Nevermor","evermore"],"glyphHeight":0.03684552524991124,"bounds":{"x":0.05427129907274351,"y":0.005083742963709281,"width":0.3063318338959059,"height":0.05438423701695034}}]}''',
  ) as Map<Object?, Object?>,
);

void main() {
  test('quoted continuations cannot establish capture or remembered acknowledgement proof through confidence filtering', () {
    for (final double quoteConfidence in <double>[.80, 1]) {
      for (final bool hasRuleBeforeQuote in <bool>[false, true]) {
        final String reason =
            'quote confidence=$quoteConfidence, real rule=$hasRuleBeforeQuote';
        final LiveScanTracker tracker = LiveScanTracker(
          resolver: _Resolver(),
          retireIdentified: true,
        );
        addTearDown(tracker.dispose);
        final List<ScanTextLine> lines = <ScanTextLine>[
          const ScanTextLine(
            text: 'Glimpse of Nature',
            confidence: .99,
            bounds: ScanBounds(.05, .04, .6, .03),
          ),
          const ScanTextLine(
            text: 'Sorcery',
            confidence: .99,
            bounds: ScanBounds(.05, .50, .3, .03),
          ),
          if (hasRuleBeforeQuote)
            const ScanTextLine(
              text: 'Whenever you cast a creature spell this turn, draw a card.',
              confidence: .99,
              bounds: ScanBounds(.05, .58, .8, .03),
            ),
          ScanTextLine(
            text: '"Remember the ancient forest',
            confidence: quoteConfidence,
            bounds: const ScanBounds(.05, .67, .8, .03),
          ),
          const ScanTextLine(
            text: 'Whenever you cast a creature spell this turn, draw a card.',
            confidence: .99,
            bounds: ScanBounds(.05, .71, .8, .03),
          ),
          const ScanTextLine(
            text: 'Search your library for a creature card.',
            confidence: .99,
            bounds: ScanBounds(.05, .76, .8, .03),
          ),
          const ScanTextLine(
            text: 'Reveal that creature and shuffle your library.',
            confidence: .99,
            bounds: ScanBounds(.05, .81, .8, .03),
          ),
        ];
        final LiveCardDetection detection = LiveCardDetection(
          confidence: .99,
          corners: _card(.1).corners,
          lines: lines,
        );
        for (int frame = 0; frame < 2; frame++) {
          tracker.update(
            <LiveCardDetection>[detection],
            currentGeometry: <List<ScanPoint>>[detection.corners],
          );
        }
        expect(tracker.tracks, hasLength(1), reason: reason);
        final int expectedProofs = hasRuleBeforeQuote ? 1 : 0;
        expect(tracker.eligibleTracks, hasLength(expectedProofs), reason: reason);
        expect(tracker.recentFocusCrops, hasLength(expectedProofs), reason: reason);

        final LiveCaptureSnapshot capture = tracker.snapshotCapture(
          currentGeometry: <List<ScanPoint>>[detection.corners],
        );
        expect(capture.count, 1, reason: reason);
        expect(tracker.markCaptured(capture), 1, reason: reason);
        expect(tracker.tracks.single.captured, isTrue, reason: reason);
        expect(tracker.savedFootprints, hasLength(expectedProofs), reason: reason);
        final ScanCrop saved = ScanCrop(
          imagePath: 'quoted-capture.jpg',
          width: 1000,
          height: 1400,
          rectified: true,
          sourceCorners: detection.corners,
          lines: lines,
          warnings: const <String>['orientation_ensemble', 'geometry_adjusted'],
        );
        expect(
          tracker.rememberSavedCrop(saved, capture),
          hasRuleBeforeQuote,
          reason: reason,
        );
        expect(tracker.savedFootprints, hasLength(expectedProofs), reason: reason);
        expect(tracker.completedFootprints, isEmpty, reason: reason);
      }
    }
  });

  for (final bool acknowledged in <bool>[false, true]) {
    test(
      'photo check token cannot follow a same-quad replacement, acknowledged=$acknowledged',
      () async {
        final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
        addTearDown(tracker.dispose);
        final LiveCardDetection first = _card(.1, footer: '001 M21 EN');
        tracker.update(<LiveCardDetection>[first]);
        tracker.update(<LiveCardDetection>[first]);
        final LiveScanTrack track = tracker.tracks.single;
        final String coreId = track.id;
        final String firstToken = track.photoFeedbackId;
        final LiveCaptureSnapshot capture = tracker.snapshotCapture();
        expect(capture.count, 1);
        expect(capture.photoReceipts.single.trackId, firstToken);
        final Completer<void> saved = Completer<void>();
        final Future<List<({String receiptId, String trackId})>> feedback =
            saved.future.then((_) => capture.photoReceipts);
        if (acknowledged) {
          expect(tracker.markCaptured(capture), 1);
          saved.complete();
          expect((await feedback).single.trackId, track.photoFeedbackId);
        }
        final LiveCardDetection replacement = _card(
          .1,
          title: 'Lava Spike',
          footer: '002 M21 EN',
        );
        tracker.update(<LiveCardDetection>[replacement]);
        tracker.update(<LiveCardDetection>[replacement]);
        expect(tracker.tracks.single.id, coreId);
        expect(track.photoFeedbackId, isNot(firstToken));
        expect(track.captured, isFalse);
        if (!saved.isCompleted) saved.complete();
        final Set<String> savedChecks = (await feedback)
            .map((receipt) => receipt.trackId)
            .toSet();
        expect(savedChecks, isNot(contains(track.photoFeedbackId)));
        expect(capture.photoReceipts.single.trackId, firstToken);
        if (!acknowledged) expect(tracker.markCaptured(capture), 0);
        final LiveCaptureSnapshot next = tracker.snapshotCapture();
        expect(next.photoReceipts.single.trackId, track.photoFeedbackId);
        expect(
          next.photoReceipts.single.receiptId,
          isNot(capture.photoReceipts.single.receiptId),
        );
      },
    );
  }

  test('unchanged photo target keeps its cue token while explicit rearm and restored tracks cannot inherit it', () {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[card]);
    tracker.update(<LiveCardDetection>[card]);
    final LiveScanTrack track = tracker.tracks.single;
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture();
    final String token = snapshot.photoReceipts.single.trackId;
    expect(token, track.photoFeedbackId);
    tracker.update(<LiveCardDetection>[card]);
    expect(track.photoFeedbackId, token);
    expect(tracker.markCaptured(snapshot), 1);
    tracker.update(<LiveCardDetection>[card]);
    expect(track.photoFeedbackId, token);
    tracker.rearmCaptured();
    expect(track.photoFeedbackId, isNot(token));
    expect(
      tracker.snapshotCapture().photoReceipts.single.trackId,
      track.photoFeedbackId,
    );
    final LiveScanTrack restored = LiveScanTrack(
      id: track.id,
      detection: card,
      lastSeen: track.lastSeen,
    );
    expect(restored.id, track.id);
    expect(restored.photoFeedbackId, isNot(track.photoFeedbackId));
    expect(restored.photoFeedbackId, isNot(token));
  });

  test('refinement rotates the safe-check token but keeps its durable receipt dedup key', () async {
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[card]);
    tracker.update(<LiveCardDetection>[card]);
    final LiveCaptureSnapshot first = tracker.snapshotCapture();
    expect(tracker.markCaptured(first), 1);
    expect(
      await tracker.retainCapturedObservations(
        first,
        retain: (_) async => true,
      ),
      isTrue,
    );
    final String receipt = first.retainedObservations.single.receiptId;
    final String token = first.photoReceipts.single.trackId;
    final List<LiveScanTrack> rearmed = tracker.rearmMissingCaptured(
      first,
      const <ScanCrop>[],
    );
    expect(rearmed, hasLength(1));
    expect(rearmed.single.photoFeedbackId, isNot(token));
    final LiveCaptureSnapshot refinement = tracker.snapshotCapture();
    expect(refinement.photoReceipts.single.receiptId, receipt);
    expect(
      refinement.photoReceipts.single.trackId,
      rearmed.single.photoFeedbackId,
    );
    expect(first.photoReceipts.single.trackId, token);
  });

  test('identity feedback receipts appear only after the identity retain callback succeeds', () async {
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    final _Resolver resolver = _Resolver();
    resolver.pending = Completer<ScanResolution>()
      ..complete(
        ScanResolution(
          candidates: <ScanCandidate>[
            ScanCandidate(_NamedCard('Lightning Bolt'), const <ScanEvidence>{
              ScanEvidence.nameMatch,
              ScanEvidence.footerMatch,
            }),
          ],
          hints: const ScanHints(names: <String>['Lightning Bolt']),
          status: ScanResolutionStatus.needsReview,
        ),
      );
    final LiveScanTracker tracker = LiveScanTracker(resolver: resolver);
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[card]);
    tracker.update(<LiveCardDetection>[card]);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 1);
    expect(capture.retainedIdentityReceipts, isEmpty);
    expect(
      await tracker.retainCapturedObservations(
        capture,
        retain: (_) async => true,
      ),
      isTrue,
    );
    expect(capture.retainedIdentityReceipts, isEmpty);
    final Completer<bool> retained = Completer<bool>();
    final Future<int> identifying = tracker.identifyCapturedLive(
      capture,
      retain: (_) => retained.future,
    );
    await Future<void>.delayed(Duration.zero);
    expect(capture.retainedIdentityReceipts, isEmpty);
    retained.complete(true);
    expect(await identifying, 1);
    expect(capture.retainedIdentityReceipts, capture.photoReceipts);
    expect(
      capture.retainedIdentityReceipts.single.trackId,
      tracker.tracks.single.photoFeedbackId,
    );
  });

  test(
    'raw green rejects an OCR request begun before durable acknowledgement',
    () {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      final LiveCardDetection card = _card(.05, footer: '001 M21 EN');
      final ScanCrop saved = ScanCrop(
        imagePath: '/tmp/raw-in-flight.jpg',
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: card.corners,
        lines: card.lines,
      );
      tracker.update(
        <LiveCardDetection>[card],
        currentGeometry: <List<ScanPoint>>[card.corners],
      );
      final LiveCaptureSnapshot capture = tracker.snapshotCapture(
        geometryOnly: true,
        currentGeometry: <List<ScanPoint>>[card.corners],
      );
      final int beforeSave = tracker.beginFrameAnalysis();
      now = now.add(const Duration(milliseconds: 100));
      tracker.markCaptured(capture);
      now = now.add(const Duration(milliseconds: 100));
      tracker.update(
        <LiveCardDetection>[card],
        currentGeometry: <List<ScanPoint>>[card.corners],
        frameAnalysis: beforeSave,
      );
      tracker.endFrameAnalysis(beforeSave);
      expect(tracker.corroboratesSavedIdentity(capture, saved), isFalse);
      now = now.add(const Duration(milliseconds: 100));
      final int afterSave = tracker.beginFrameAnalysis();
      now = now.add(const Duration(milliseconds: 100));
      tracker.update(
        <LiveCardDetection>[card],
        currentGeometry: <List<ScanPoint>>[card.corners],
        frameAnalysis: afterSave,
      );
      tracker.endFrameAnalysis(afterSave);
      expect(tracker.corroboratesSavedIdentity(capture, saved), isTrue);
    },
  );

  test(
    'raw promotion OCR corroboration requires a fresh post-ACK owned identity',
    () {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      final LiveCardDetection card = _card(.05, footer: '001 M21 EN');
      final ScanCrop saved = ScanCrop(
        imagePath: '/tmp/raw-corroboration.jpg',
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: card.corners,
        lines: card.lines,
      );
      tracker.update(
        <LiveCardDetection>[card],
        currentGeometry: <List<ScanPoint>>[card.corners],
      );
      final LiveCaptureSnapshot capture = tracker.snapshotCapture(
        geometryOnly: true,
        currentGeometry: <List<ScanPoint>>[card.corners],
      );
      tracker.markCaptured(capture);
      expect(tracker.corroboratesSavedIdentity(capture, saved), isFalse);
      now = now.add(const Duration(milliseconds: 100));
      tracker.update(
        const <LiveCardDetection>[],
        currentGeometry: <List<ScanPoint>>[card.corners],
      );
      expect(tracker.corroboratesSavedIdentity(capture, saved), isFalse);
      now = now.add(const Duration(milliseconds: 100));
      tracker.update(
        <LiveCardDetection>[card],
        currentGeometry: <List<ScanPoint>>[card.corners],
      );
      expect(tracker.corroboratesSavedIdentity(capture, saved), isTrue);
      now = now.add(const Duration(milliseconds: 100));
      tracker.update(<LiveCardDetection>[
        _card(.05, title: 'Lava Spike', footer: '002 M21 EN'),
      ]);
      expect(tracker.corroboratesSavedIdentity(capture, saved), isFalse);
    },
  );

  test('geometry-only capture admits no live identity and binds only its durable saved proof', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.05, footer: '001 M21 EN');
    final LiveCardDetection other = _card(.55, footer: '002 M21 EN');
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[card.corners, other.corners],
      appearanceSamplingSupported: true,
    );
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      geometryOnly: true,
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    ScanCrop saved(LiveCardDetection detected) => ScanCrop(
      imagePath: '/tmp/owned-raw-card.jpg',
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: detected.corners,
      lines: detected.lines,
    );
    final ScanCrop crop = saved(card);
    expect(capture.count, 0);
    expect(capture.retainedCrops, isEmpty);
    expect(tracker.savedFootprints, isEmpty);
    expect(
      tracker.identifyCaptured(crop, _savedRead(crop), capture: capture),
      0,
    );
    expect(tracker.markCaptured(capture), 0);
    expect(tracker.ownsFrozenRegion(capture, card.corners), isTrue);
    expect(tracker.ownsFrozenRegion(capture, other.corners), isFalse);
    expect(
      tracker.identifyCaptured(
        saved(other),
        _savedRead(saved(other)),
        capture: capture,
      ),
      0,
    );
    expect(
      tracker.identifyCaptured(crop, _savedRead(crop), capture: capture),
      0,
    );
    now = now.add(const Duration(milliseconds: 100));
    tracker.update(
      <LiveCardDetection>[card],
      currentGeometry: <List<ScanPoint>>[card.corners, other.corners],
      appearanceSamplingSupported: true,
    );
    expect(
      tracker.identifyCaptured(crop, _savedRead(crop), capture: capture),
      1,
    );
    expect(tracker.completedFootprints, hasLength(1));
    expect(tracker.eligibleTracks, isEmpty);
    expect(
      tracker.identifyCaptured(crop, _savedRead(crop), capture: capture),
      1,
    );
    expect(tracker.completedFootprints, hasLength(1));
  });

  test('revoking one raw frozen region blocks its late result without revoking a sibling', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final List<LiveCardDetection> cards = <LiveCardDetection>[
      _card(.05, footer: '001 M21 EN'),
      _card(.55, footer: '002 M21 EN'),
    ];
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: cards.map((LiveCardDetection card) => card.corners),
      appearanceSamplingSupported: true,
    );
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      geometryOnly: true,
      currentGeometry: cards.map((LiveCardDetection card) => card.corners),
    );
    tracker.markCaptured(capture);
    tracker.invalidateFrozenRegion(capture, cards.first.corners);
    now = now.add(const Duration(milliseconds: 100));
    tracker.update(
      cards,
      currentGeometry: cards.map((LiveCardDetection card) => card.corners),
      appearanceSamplingSupported: true,
    );
    for (int index = 0; index < cards.length; index++) {
      final LiveCardDetection card = cards[index];
      final ScanCrop crop = ScanCrop(
        imagePath: '/tmp/raw-sibling-$index.jpg',
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: card.corners,
        lines: card.lines,
      );
      expect(
        tracker.identifyCaptured(crop, _savedRead(crop), capture: capture),
        index,
      );
    }
    expect(tracker.completedFootprints, hasLength(1));
    expect(tracker.completedFootprints.single.corners.first.x, .55);
  });

  test('raw frozen geometry cannot manufacture identity from unreadable crops or a cloud suggestion', () {
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.05, footer: '001 M21 EN');
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      geometryOnly: true,
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    tracker.markCaptured(capture);
    for (final bool readable in <bool>[false, true]) {
      final ScanCrop crop = ScanCrop(
        imagePath: '/tmp/raw-unproven.jpg',
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: card.corners,
        lines: readable ? card.lines : const <ScanTextLine>[],
      );
      final ScanResolution result = readable
          ? ScanResolution(
              candidates: <ScanCandidate>[
                ScanCandidate(_Card(), const <ScanEvidence>{
                  ScanEvidence.cloudSuggestion,
                }),
              ],
              hints: ScanHints.fromCrop(crop),
              status: ScanResolutionStatus.needsReview,
            )
          : _savedRead(crop);
      expect(tracker.identifyCaptured(crop, result, capture: capture), 0);
    }
    expect(tracker.completedFootprints, isEmpty);
    expect(tracker.tracks, isEmpty);
  });

  test('raw saved results cannot bind after tracker ownership changes', () {
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
    );
    final LiveScanTracker foreign = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    addTearDown(foreign.dispose);
    final LiveCardDetection card = _card(.05, footer: '001 M21 EN');
    final ScanCrop crop = ScanCrop(
      imagePath: '/tmp/raw-old-owner.jpg',
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: card.corners,
      lines: card.lines,
    );
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      geometryOnly: true,
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    tracker.markCaptured(capture);
    foreign.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    expect(
      foreign.identifyCaptured(crop, _savedRead(crop), capture: capture),
      0,
    );
    tracker.clear();
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    expect(
      tracker.identifyCaptured(crop, _savedRead(crop), capture: capture),
      0,
    );
    expect(tracker.completedFootprints, isEmpty);
  });

  test(
    'a replacement card cannot inherit an armed canonical recovery receipt',
    () async {
      final LiveScanTracker tracker = LiveScanTracker(
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      final LiveCardDetection originalCard = _card(.1, footer: '001 M21 EN');
      tracker.update(<LiveCardDetection>[originalCard]);
      tracker.update(<LiveCardDetection>[originalCard]);
      final LiveCaptureSnapshot original = tracker.snapshotCapture();
      expect(tracker.markCaptured(original), 1);
      expect(
        await tracker.retainCapturedObservations(
          original,
          retain: (_) async => true,
        ),
        isTrue,
      );
      final String originalReceipt =
          original.retainedObservations.single.receiptId;
      final List<LiveScanTrack> rearmed = tracker.rearmMissingCaptured(
        original,
        const <ScanCrop>[],
      );
      expect(rearmed.single.hasRetainedCapture, isTrue);
      final LiveCardDetection replacement = _card(
        .1,
        title: 'Lava Spike',
        footer: '002 M21 EN',
      );
      tracker.update(<LiveCardDetection>[replacement]);
      tracker.update(<LiveCardDetection>[replacement]);
      expect(
        tracker.tracks.every(
          (LiveScanTrack track) => !track.hasRetainedCapture,
        ),
        isTrue,
      );
      final LiveCaptureSnapshot next = tracker.snapshotCapture();
      expect(tracker.markCaptured(next), 1);
      expect(
        await tracker.retainCapturedObservations(
          next,
          retain: (_) async => true,
        ),
        isTrue,
      );
      expect(next.retainedObservations.single.isRefinement, isFalse);
      expect(
        next.retainedObservations.single.receiptId,
        isNot(originalReceipt),
      );
    },
  );

  test('measured saved Bats contour reuses its owned receipt ID across repeated reads', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    final LiveScanTracker foreign = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    addTearDown(foreign.dispose);
    const List<ScanPoint> shutterCorners = <ScanPoint>[
      ScanPoint(.3918113891728481, .18083012780573043),
      ScanPoint(.6340533193080299, .18083012780573043),
      ScanPoint(.6340533193080299, .418741563686447),
      ScanPoint(.3918113891728481, .418741563686447),
    ];
    const List<ScanPoint> savedCorners = <ScanPoint>[
      ScanPoint(.406928481639152, .18436258065123734),
      ScanPoint(.6783127809850582, .18436258065123734),
      ScanPoint(.6783127809850582, .46943012198097067),
      ScanPoint(.406928481639152, .46943012198097067),
    ];
    const List<ScanPoint> currentCorners = <ScanPoint>[
      ScanPoint(.4074922589884822, .21765871944789067),
      ScanPoint(.6470541246853635, .2123200078526396),
      ScanPoint(.6521210573548435, .44528439666194175),
      ScanPoint(.4086901001047853, .4562711840846609),
    ];
    List<ScanTextLine> lines({String number = '095'}) => <ScanTextLine>[
      const ScanTextLine(
        text: 'Mirkwood Bats',
        confidence: 1,
        bounds: ScanBounds(.05, .04, .5, .04),
      ),
      const ScanTextLine(
        text: 'Creature - Bat',
        confidence: 1,
        bounds: ScanBounds(.05, .5, .5, .03),
      ),
      const ScanTextLine(
        text: 'Whenever you create or sacrifice a',
        confidence: 1,
        bounds: ScanBounds(.05, .59, .8, .03),
      ),
      const ScanTextLine(
        text: 'token, each opponent loses 1 life.',
        confidence: 1,
        bounds: ScanBounds(.05, .64, .8, .03),
      ),
      ScanTextLine(
        text: '$number LTR EN',
        confidence: 1,
        bounds: const ScanBounds(.05, .91, .4, .03),
      ),
    ];
    final LiveCardDetection original = LiveCardDetection(
      confidence: 1,
      corners: shutterCorners,
      lines: lines(),
    );
    final LiveCardDetection adjacent = LiveCardDetection(
      confidence: 1,
      corners: const <ScanPoint>[
        ScanPoint(.05, .60),
        ScanPoint(.29, .60),
        ScanPoint(.29, .84),
        ScanPoint(.05, .84),
      ],
      lines: lines(),
    );
    final List<LiveCardDetection> scene = <LiveCardDetection>[
      original,
      adjacent,
    ];
    for (int frame = 0; frame < 2; frame++) {
      tracker.update(
        scene,
        currentGeometry: scene.map((LiveCardDetection card) => card.corners),
        appearanceSamplingSupported: true,
      );
    }
    final String id = tracker.tracks
        .firstWhere((LiveScanTrack track) => track.corners.first.x > .3)
        .id;
    final int token = tracker.beginCapture();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      currentGeometry: scene.map((LiveCardDetection card) => card.corners),
    );
    expect(tracker.markCaptured(capture), 2);
    tracker.endCapture(token, resumeTracking: true);
    final LiveScanExcludedRegion originalReceipt = tracker.savedFootprints
        .firstWhere((LiveScanExcludedRegion region) => region.id == id);
    now = now.add(const Duration(milliseconds: 500));
    final LiveCardDetection current = LiveCardDetection(
      confidence: 1,
      corners: currentCorners,
      lines: lines(),
    );
    tracker.update(
      <LiveCardDetection>[current, adjacent],
      currentGeometry: <List<ScanPoint>>[currentCorners, adjacent.corners],
      appearanceSamplingSupported: true,
    );
    expect(tracker.tracks.map((LiveScanTrack track) => track.id), contains(id));
    final ScanCrop saved = ScanCrop(
      imagePath: '',
      width: 1900,
      height: 2650,
      rectified: true,
      sourceCorners: savedCorners,
      lines: lines(),
    );
    for (int notification = 0; notification < 12; notification++) {
      expect(tracker.rememberSavedCrop(saved, capture), isTrue);
      expect(tracker.savedFootprints, hasLength(2));
      expect(
        tracker.savedFootprints
            .map((LiveScanExcludedRegion region) => region.id)
            .toSet(),
        hasLength(2),
      );
      expect(
        tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
        1,
      );
      expect(tracker.completedFootprints, hasLength(1));
    }
    final LiveScanExcludedRegion retained = tracker.savedFootprints.firstWhere(
      (LiveScanExcludedRegion region) => region.id == id,
    );
    for (int corner = 0; corner < 4; corner++) {
      expect(retained.corners[corner].x, originalReceipt.corners[corner].x);
      expect(retained.corners[corner].y, originalReceipt.corners[corner].y);
    }
    expect(
      tracker.tracks.where((LiveScanTrack track) => track.capturedIdentified),
      hasLength(1),
    );
    final ScanCrop conflicting = ScanCrop(
      imagePath: '',
      width: saved.width,
      height: saved.height,
      rectified: true,
      sourceCorners: savedCorners,
      lines: lines(number: '096'),
    );
    expect(ScanHints.fromCrop(conflicting).collectorNumber, '096');
    expect(tracker.rememberSavedCrop(conflicting, capture), isFalse);
    foreign.update(scene);
    final LiveCaptureSnapshot foreignCapture = foreign.snapshotCapture();
    foreign.markCaptured(foreignCapture);
    expect(tracker.rememberSavedCrop(saved, foreignCapture), isFalse);
    expect(tracker.savedFootprints, hasLength(2));
    expect(tracker.completedFootprints, hasLength(1));
  });

  test('actual titleless self-name verifies only against its owned full-title frozen receipt and three literal rules', () {
    for (final String variant in <String>[
      'actual',
      'unverified',
      'foreign',
      'unowned',
      'wrongBody',
      'wrongArtist',
      'wrongYear',
      'wrongCurrentTitle',
      'printing',
      'competing',
      'stale',
      'staleWithoutFrame',
      'freshGeometry',
      'removed',
    ]) {
      DateTime now = DateTime.utc(2026);
      final ScanCrop proof = _final5FrozenNevermore();
      final ScanCrop actual = _final5TitlelessSaved();
      final LiveScanTracker tracker = LiveScanTracker(
        resolver: _Resolver(),
        retireIdentified: true,
        clock: () => now,
      );
      addTearDown(tracker.dispose);
      tracker.update(
        <LiveCardDetection>[_cropDetection(proof)],
        currentGeometry: <List<ScanPoint>>[proof.sourceCorners],
        appearanceSamplingSupported: true,
      );
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      expect(tracker.markCaptured(capture), 1, reason: variant);
      final List<ScanTextLine> lines = <ScanTextLine>[
        for (final ScanTextLine line in actual.lines)
          ScanTextLine(
            text:
                variant == 'wrongBody' &&
                    line.text == "The named card can't be cast."
                ? 'Destroy target nonartifact creature.'
                : variant == 'wrongArtist' && line.text == 'Jason A. Engle'
                ? 'Pete Venters'
                : variant == 'wrongYear' && line.text.contains('1993-2011')
                ? line.text.replaceAll('2011', '2012')
                : line.text,
            confidence: line.confidence,
            bounds: line.bounds,
            glyphHeight: line.glyphHeight,
          ),
      ];
      final ScanCrop saved = ScanCrop(
        imagePath: actual.imagePath,
        width: actual.width,
        height: actual.height,
        rectified: actual.rectified,
        sourceCorners: actual.sourceCorners,
        warnings: actual.warnings,
        lines: lines,
      );
      final ScanHints raw = ScanHints.fromCrop(saved);
      final Set<ScanEvidence> evidence = <ScanEvidence>{
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
        ScanEvidence.rulesTextMatch,
        if (variant != 'unverified') ScanEvidence.illustratorMatch,
        ScanEvidence.copyrightYearMatch,
        if (variant == 'printing') ScanEvidence.printingMismatch,
      };
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_SelfReferenceCard('Nevermore'), evidence),
          if (variant == 'competing')
            ScanCandidate(_SelfReferenceCard('Other enchantment'), evidence),
        ],
        hints: ScanHints(
          names: const <String>['Nevermore'],
          typeLine: raw.typeLine,
          rulesText: variant == 'wrongBody'
              ? ScanHints.fromCrop(actual).rulesText
              : raw.rulesText,
        ),
        status: ScanResolutionStatus.needsReview,
      );
      if (variant == 'wrongCurrentTitle') {
        tracker.update(
          <LiveCardDetection>[
            LiveCardDetection(
              confidence: 1,
              corners: proof.sourceCorners,
              lines: <ScanTextLine>[
                for (final ScanTextLine line in proof.lines)
                  ScanTextLine(
                    text: line.text == 'Nevermore'
                        ? 'Lightning Bolt'
                        : line.text,
                    confidence: line.confidence,
                    bounds: line.bounds,
                    glyphHeight: line.glyphHeight,
                  ),
              ],
            ),
          ],
          currentGeometry: <List<ScanPoint>>[proof.sourceCorners],
          appearanceSamplingSupported: true,
        );
      }
      if (variant == 'stale' || variant == 'removed') {
        now = now.add(const Duration(seconds: 3));
        tracker.update(
          const <LiveCardDetection>[],
          currentGeometry: const <List<ScanPoint>>[],
          appearanceSamplingSupported: true,
        );
      }
      if (variant == 'staleWithoutFrame') {
        now = now.add(const Duration(seconds: 3));
      }
      if (variant == 'freshGeometry') {
        now = now.add(const Duration(seconds: 3));
        tracker.update(
          const <LiveCardDetection>[],
          currentGeometry: <List<ScanPoint>>[proof.sourceCorners],
          appearanceSamplingSupported: true,
        );
        expect(tracker.tracks, hasLength(1), reason: 'retained receipt owner');
        final LiveScanTrack owner = tracker.tracks.single;
        expect(owner.captured, isTrue, reason: 'acknowledged receipt owner');
        expect(
          tracker.ownsFrozenRegion(
            capture,
            saved.sourceCorners,
            currentCorners: owner.corners,
          ),
          isTrue,
          reason: 'fresh geometry still occupies its frozen receipt region',
        );
        final ScanHints ownerHints = ScanHints.fromCrop(owner.crop);
        expect(
          owner.lastSeen,
          DateTime.utc(2026),
          reason: 'fresh owned geometry does not renew the frozen text',
        );
        expect(
          ScanResolver.rulesSearchPhrase(ownerHints.rulesText),
          isNull,
          reason:
              'literal self-name proof need not be a searchable rules phrase',
        );
      }
      final LiveScanTracker foreign = LiveScanTracker(
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(foreign.dispose);
      final LiveCaptureSnapshot other = foreign.snapshotCapture();
      foreign.markCaptured(other);
      expect(
        tracker.identifyCaptured(
          saved,
          read,
          capture: variant == 'unowned'
              ? null
              : variant == 'foreign'
              ? other
              : capture,
        ),
        variant == 'actual' || variant == 'freshGeometry' ? 1 : 0,
        reason: variant,
      );
      expect(
        tracker.completedFootprints,
        variant == 'actual' || variant == 'freshGeometry'
            ? hasLength(1)
            : isEmpty,
        reason: variant,
      );
      expect(hasExactPrintingEvidence(saved, read), isFalse);
    }
  });

  test('measured historical saved crop uses only its actual owned frozen full contour after verified identity', () {
    final ScanCrop actual = ScanCrop.fromMap(
      jsonDecode(
        r'''{"imagePath":"owned-circle.jpg","width":1899,"height":2652,"rectified":true,"warnings":["incomplete_card","orientation_ensemble","geometry_adjusted"],"sourceCorners":[{"x":0.575305163860321,"y":0.4507896304130554},{"x":0.7966911196708679,"y":0.45515769720077515},{"x":0.854987382888794,"y":0.5929323136806488},{"x":0.5576722025871277,"y":0.5870903730392456}],"lines":[{"text":"Enchanement","confidence":1.0,"alternatives":["Enchanment","Enchaement"],"glyphHeight":0.02976598512748072,"bounds":{"x":0.029654180368134164,"y":0.5401152179616883,"width":0.309871826171875,"height":0.035734593778354196}},{"text":"1; Prevent all damage against you","confidence":1.0,"alternatives":["1: Prevent all damage against you","1 ; Prevent all damage against you"],"glyphHeight":0.03758212886719201,"bounds":{"x":0.09894691874842053,"y":0.6452701129368913,"width":0.787919343647204,"height":0.044522494032731785}},{"text":"from one blue source. If a source","confidence":1.0,"alternatives":["from on blue source. If a source","from one lue source. If a source"],"glyphHeight":0.03772201144557814,"bounds":{"x":0.09317904978734125,"y":0.685357050434796,"width":0.7690130293996711,"height":0.0398821248188278}},{"text":"deals damage to you more than","confidence":1.0,"alternatives":["deal damage to you more than","deals damage to you more han"],"glyphHeight":0.04166666666666663,"bounds":{"x":0.08720929901807573,"y":0.7249999999813989,"width":0.7267441920230264,"height":0.04166666666666663}},{"text":"once in a turn, you may pay.-","confidence":1.0,"alternatives":["once in a turn, you may pay.","once in a turn, you may pay. -"],"glyphHeight":0.03730775284824129,"bounds":{"x":0.09315166189956352,"y":0.7641716178526136,"width":0.6858665707236843,"height":0.03914081924461488}},{"text":"each time to prevent the damage.","confidence":1.0,"alternatives":["each time to prevent the damage","ach time to prevent the damage."],"glyphHeight":0.036610008421413105,"bounds":{"x":0.09304354166347306,"y":0.798847657758235,"width":0.7734193821957237,"height":0.04114900419255363}},{"text":"Ilfus. Pete Venters","confidence":1.0,"alternatives":[],"glyphHeight":0.030271146764707324,"bounds":{"x":0.03197673988054431,"y":0.9374371852729009,"width":0.34302326403166117,"height":0.030271148202407314}},{"text":"\u00a9 1995 Wizards of the Coast, Inc. All rights reserved.","confidence":1.0,"alternatives":[],"glyphHeight":0.020686617596259036,"bounds":{"x":0.03286405204387836,"y":0.9660467576181648,"width":0.5883283434416119,"height":0.027908542767241994}},{"text":"once in a turn, you may","confidence":1.0,"alternatives":[],"glyphHeight":0.03557841719538907,"bounds":{"x":0.09304719233465826,"y":0.7645476471635354,"width":0.5479260540317178,"height":0.04165781146680301}},{"text":"each time to pr\u00e9vent the","confidence":1.0,"alternatives":[],"glyphHeight":0.0403055418086919,"bounds":{"x":0.0922530007857686,"y":0.7970930091640951,"width":0.5570136406660852,"height":0.04326090845568428}},{"text":"Illus. Pete","confidence":1.0,"alternatives":[],"glyphHeight":0.032742257096857186,"bounds":{"x":0.029192454837837625,"y":0.9363266915250494,"width":0.19500074787818883,"height":0.033156629221566425}},{"text":"Venters","confidence":1.0,"alternatives":[],"glyphHeight":0.02719335484514196,"bounds":{"x":0.22019140227253947,"y":0.9409434015311389,"width":0.1559005206456848,"height":0.027520815092941815}},{"text":"Enchantment","confidence":1.0,"alternatives":["Enchantment"],"glyphHeight":null,"bounds":{"x":0.029654581051127626,"y":0.5401152035780122,"width":0.30981626172806326,"height":0.03573356196284294}}]}''',
      ) as Map<String, Object?>,
    );
    const List<ScanPoint> parent = <ScanPoint>[
      ScanPoint(0.5552853469005857, 0.4412650112316997),
      ScanPoint(0.8207246584472783, 0.44434421444584227),
      ScanPoint(0.9031695204835701, 0.6172198607673166),
      ScanPoint(0.5245993578038972, 0.6088843715053995),
    ];
    for (final String variant in <String>[
      'supported',
      'noArtist',
      'noYear',
      'ambiguousIdentity',
      'contradiction',
      'nameOnly',
      'malformed',
      'tooSmall',
      'outside',
      'nonfinite',
      'weakRules',
      'shiftedCurrent',
      'replacement',
      'redTitle',
      'runeTitle',
      'observedTitle',
      'ocrTitle',
      'mixedTitle',
      'titleNoise',
      'removed',
      'reset',
      'foreignCapture',
      'stale',
      'laterGeometry',
      'adjacentCopy',
      'union',
      'printing',
    ]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      final LiveCardDetection front = _card(.1, footer: '001 M21 EN');
      final List<ScanPoint> observed = variant == 'union'
          ? const <ScanPoint>[
              ScanPoint(.4, .4),
              ScanPoint(.96, .4),
              ScanPoint(.96, .7),
              ScanPoint(.4, .7),
            ]
          : parent;
      final List<ScanPoint> adjacent = parent
          .map((ScanPoint point) => ScanPoint(point.x - .4, point.y))
          .toList();
      final List<List<ScanPoint>> geometry = <List<ScanPoint>>[
        front.corners,
        if (variant != 'laterGeometry') observed,
        if (variant == 'adjacentCopy') adjacent,
      ];
      tracker.update(
        <LiveCardDetection>[front],
        currentGeometry: geometry,
        appearanceSamplingSupported: true,
      );
      tracker.update(
        <LiveCardDetection>[front],
        currentGeometry: geometry,
        appearanceSamplingSupported: true,
      );
      final int token = tracker.beginCapture();
      final LiveCaptureSnapshot capture = tracker.snapshotCapture(
        currentGeometry: geometry,
      );
      expect(tracker.markCaptured(capture), 1);
      tracker.endCapture(token, resumeTracking: true);
      final double centerX =
          actual.sourceCorners.fold<double>(
            0,
            (double sum, ScanPoint point) => sum + point.x,
          ) /
          4;
      final double centerY =
          actual.sourceCorners.fold<double>(
            0,
            (double sum, ScanPoint point) => sum + point.y,
          ) /
          4;
      final List<ScanPoint> source = switch (variant) {
        'malformed' => <ScanPoint>[
          actual.sourceCorners[0],
          actual.sourceCorners[2],
          actual.sourceCorners[1],
          actual.sourceCorners[3],
        ],
        'tooSmall' =>
          actual.sourceCorners
              .map(
                (ScanPoint point) => ScanPoint(
                  centerX + (point.x - centerX) * .95,
                  centerY + (point.y - centerY) * .95,
                ),
              )
              .toList(),
        'outside' =>
          actual.sourceCorners
              .map((ScanPoint point) => ScanPoint(point.x + .04, point.y))
              .toList(),
        'nonfinite' => <ScanPoint>[
          const ScanPoint(double.nan, .45),
          ...actual.sourceCorners.skip(1),
        ],
        _ => actual.sourceCorners,
      };
      final ScanCrop saved = ScanCrop(
        imagePath: actual.imagePath,
        width: actual.width,
        height: actual.height,
        rectified: actual.rectified,
        sourceCorners: source,
        lines: variant == 'weakRules'
            ? actual.lines
                  .where(
                    (ScanTextLine line) =>
                        line.bounds.y < .6 || line.bounds.y > .9,
                  )
                  .toList()
            : <ScanTextLine>[
                ...actual.lines,
                if (variant == 'printing')
                  const ScanTextLine(
                    text: '001 ICE EN',
                    confidence: 1,
                    bounds: ScanBounds(.03, .88, .3, .025),
                  ),
              ],
        warnings: actual.warnings,
      );
      if (const <String>{
        'replacement',
        'printing',
        'redTitle',
        'runeTitle',
        'observedTitle',
        'ocrTitle',
        'mixedTitle',
        'titleNoise',
      }.contains(variant)) {
        tracker.update(
          <LiveCardDetection>[
            front,
            LiveCardDetection(
              confidence: 1,
              corners: parent,
              lines: <ScanTextLine>[
                if (const <String>{
                  'redTitle',
                  'runeTitle',
                  'observedTitle',
                  'ocrTitle',
                  'mixedTitle',
                  'titleNoise',
                }.contains(variant)) ...<ScanTextLine>[
                  ...actual.lines,
                  ScanTextLine(
                    text: switch (variant) {
                      'redTitle' => 'Circle of Protection: Red',
                      'runeTitle' => 'Rune of Protection: Blue',
                      'ocrTitle' => 'Cirele of Protection: Blue',
                      _ => 'Circle of Protection: Blue',
                    },
                    confidence: 1,
                    bounds: const ScanBounds(.03, .03, .65, .03),
                  ),
                  if (variant == 'mixedTitle')
                    const ScanTextLine(
                      text: 'Rune of Protection: Blue',
                      confidence: 1,
                      bounds: ScanBounds(.03, .03, .65, .03),
                    ),
                  if (variant == 'titleNoise')
                    const ScanTextLine(
                      text: '• blac',
                      confidence: 1,
                      bounds: ScanBounds(.45, .02, .1, .02),
                    ),
                ],
                if (variant == 'replacement')
                  const ScanTextLine(
                    text: 'Fog',
                    confidence: 1,
                    bounds: ScanBounds(.03, .03, .15, .03),
                  ),
                if (variant == 'printing')
                  const ScanTextLine(
                    text: '002 ICE EN',
                    confidence: 1,
                    bounds: ScanBounds(.03, .91, .3, .025),
                  ),
              ],
            ),
          ],
          currentGeometry: <List<ScanPoint>>[front.corners, parent],
          appearanceSamplingSupported: true,
        );
      }
      if (variant == 'shiftedCurrent' || variant == 'laterGeometry') {
        tracker.update(
          <LiveCardDetection>[front],
          currentGeometry: <List<ScanPoint>>[
            front.corners,
            variant == 'laterGeometry'
                ? parent
                : parent
                      .map(
                        (ScanPoint point) => ScanPoint(point.x - .1, point.y),
                      )
                      .toList(),
          ],
        );
      }
      if (variant == 'removed') {
        now = now.add(const Duration(seconds: 3));
        tracker.update(
          <LiveCardDetection>[front],
          currentGeometry: <List<ScanPoint>>[front.corners],
        );
      }
      if (variant == 'reset') tracker.clear();
      if (variant == 'stale') now = now.add(const Duration(seconds: 3));
      final LiveScanTracker foreign = LiveScanTracker(
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(foreign.dispose);
      final LiveCaptureSnapshot other = foreign.snapshotCapture();
      foreign.markCaptured(other);
      final LiveCaptureSnapshot owned = variant == 'foreignCapture'
          ? other
          : capture;
      expect(
        tracker.rememberSavedCrop(saved, owned),
        const <String>{
          'observedTitle',
          'ocrTitle',
          'runeTitle',
          'mixedTitle',
          'titleNoise',
        }.contains(variant),
        reason:
            'Only existing fresh strong live proof may bind before the supported saved read: $variant',
      );
      final Set<ScanEvidence> evidence = <ScanEvidence>{
        ScanEvidence.rulesKeywordMatch,
        ScanEvidence.typeLineMatch,
        if (variant != 'noArtist') ScanEvidence.illustratorMatch,
        if (variant != 'noYear') ScanEvidence.copyrightYearMatch,
        if (variant == 'contradiction') ScanEvidence.rulesTextMismatch,
        if (variant == 'nameOnly') ScanEvidence.nameMatch,
      };
      if (variant == 'nameOnly') evidence.remove(ScanEvidence.illustratorMatch);
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_NamedCard('Circle of Protection: Blue'), evidence),
          if (variant == 'ambiguousIdentity')
            ScanCandidate(_NamedCard('Rune of Protection: Blue'), evidence),
        ],
        hints: ScanHints.fromCrop(saved),
        status: ScanResolutionStatus.needsReview,
      );
      final bool accepted = const <String>{
        'supported',
        'adjacentCopy',
        'observedTitle',
        'ocrTitle',
        'titleNoise',
      }.contains(variant);
      expect(
        tracker.identifyCaptured(saved, read, capture: owned),
        accepted ? 1 : 0,
        reason: variant,
      );
      if (accepted) {
        final LiveScanTrack track = tracker.tracks.singleWhere(
          (LiveScanTrack track) => track.capturedIdentified,
        );
        expect(track.corners, parent);
        expect(track.resolution!.status, ScanResolutionStatus.needsReview);
        expect(hasExactPrintingEvidence(saved, read), isFalse);
        expect(
          saved.sourceCorners,
          same(source),
          reason: 'OCR and artwork image mapping is unchanged.',
        );
        expect(tracker.completedFootprints, hasLength(1));
      }
    }
  });

  test('actual clipped Never title and observed body self-name identify only its owned full-title receipt', () {
    for (final String variant in <String>[
      'actual',
      'wrongBody',
      'wrongType',
      'otherTitle',
      'foreign',
      'rearmed',
    ]) {
      final ScanCrop actual = _final4ClippedNevermore();
      final ScanCrop proof = ScanCrop(
        imagePath: '',
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: actual.sourceCorners,
        lines: <ScanTextLine>[
          for (final ScanTextLine line in actual.lines)
            ScanTextLine(
              text: line.text == 'Never'
                  ? 'Nevermore'
                  : line.text.startsWith('«')
                  ? line.text.replaceFirst('«', '"')
                  : line.text,
              confidence: line.confidence,
              glyphHeight: line.textHeight,
              bounds: line.bounds,
            ),
        ],
      );
      final LiveScanTracker tracker = LiveScanTracker(
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      tracker.update(<LiveCardDetection>[
        _cropDetection(proof),
      ], appearanceSamplingSupported: true);
      tracker.update(<LiveCardDetection>[
        _cropDetection(proof),
      ], appearanceSamplingSupported: true);
      final LiveCaptureSnapshot owned = tracker.snapshotCapture();
      expect(tracker.markCaptured(owned), 1, reason: variant);
      final LiveScanTracker other = LiveScanTracker(
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(other.dispose);
      other.update(<LiveCardDetection>[_cropDetection(proof)]);
      final LiveCaptureSnapshot foreign = other.snapshotCapture();
      other.markCaptured(foreign);
      final ScanCrop saved = ScanCrop(
        imagePath: actual.imagePath,
        width: actual.width,
        height: actual.height,
        rectified: true,
        warnings: actual.warnings,
        sourceCorners: actual.sourceCorners,
        lines: <ScanTextLine>[
          for (final ScanTextLine line in actual.lines)
            ScanTextLine(
              text:
                  variant == 'wrongBody' &&
                      line.text == "The named card can't be cast."
                  ? 'Destroy target nonartifact creature.'
                  : variant == 'wrongType' && line.text == 'Enchantment'
                  ? 'Sorcery'
                  : variant == 'otherTitle' && line.text == 'Never'
                  ? 'Lightning Bolt'
                  : line.text,
              confidence: line.confidence,
              glyphHeight: line.textHeight,
              bounds: line.bounds,
            ),
        ],
      );
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_NamedCard('Nevermore'), const <ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.rulesTextMatch,
            ScanEvidence.typeLineMatch,
          }),
        ],
        hints: ScanHints.fromCrop(saved),
        status: ScanResolutionStatus.needsReview,
      );
      if (variant == 'rearmed') tracker.rearmCaptured();
      expect(
        tracker.identifyCaptured(
          saved,
          read,
          capture: variant == 'foreign' ? foreign : owned,
        ),
        variant == 'actual' ? 1 : 0,
        reason: variant,
      );
      expect(
        tracker.completedFootprints,
        variant == 'actual' ? hasLength(1) : isEmpty,
        reason: variant,
      );
      if (variant == 'actual') {
        expect(
          tracker.tracks.single.resolution!.candidates.single.card.name,
          'Nevermore',
        );
        expect(hasExactPrintingEvidence(saved, read), isFalse);
      }
    }
  });

  test('saved Circle owns the largest actual contemporaneous quad rather than an earlier inset proposal', () {
    const List<ScanPoint> inset = <ScanPoint>[
      ScanPoint(.5582412481307983, .4506067633628845),
      ScanPoint(.855756938457489, .4506067633628845),
      ScanPoint(.855756938457489, .5934401154518127),
      ScanPoint(.5582412481307983, .5934401154518127),
    ];
    const List<ScanPoint> observed = <ScanPoint>[
      ScanPoint(.5473999407471382, .44809870716954714),
      ScanPoint(.8704204615846838, .44809870716954714),
      ScanPoint(.8704204615846838, .6009727448446172),
      ScanPoint(.5473999407471382, .6009727448446172),
    ];
    const ScanCrop saved = ScanCrop(
      imagePath: 'owned-circle.jpg',
      width: 2546,
      height: 3556,
      rectified: true,
      sourceCorners: <ScanPoint>[
        ScanPoint(.5490383505821228, .44318413734436035),
        ScanPoint(.819047749042511, .44291096925735474),
        ScanPoint(.9036235213279724, .6172851324081421),
        ScanPoint(.5265416502952576, .6086542010307312),
      ],
      warnings: <String>[
        'incomplete_card',
        'orientation_ensemble',
        'geometry_adjusted',
      ],
      lines: <ScanTextLine>[
        ScanTextLine(
          text: 'Enchantment',
          confidence: 1,
          bounds: ScanBounds(
            .11896724213428185,
            .5096823592152924,
            .25511057959329586,
            .02964832704971021,
          ),
        ),
        ScanTextLine(
          text: '1: Prevent all damage against you',
          confidence: 1,
          bounds: ScanBounds(
            .17128541589360244,
            .5977531645843002,
            .6349837789363215,
            .048073733214988756,
          ),
        ),
        ScanTextLine(
          text: 'from one blue source. If a source',
          confidence: 1,
          bounds: ScanBounds(
            .16361166741523178,
            .6334273002933067,
            .6320249403169187,
            .038254962058651976,
          ),
        ),
        ScanTextLine(
          text: 'deals damage to you more than',
          confidence: 1,
          bounds: ScanBounds(
            .16125518990435628,
            .6612279101347072,
            .6013255033170906,
            .05229319603558469,
          ),
        ),
      ],
    );
    for (final bool smallerFirst in <bool>[true, false]) {
      final LiveScanTracker tracker = LiveScanTracker(
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      final LiveCardDetection front = _card(.05, footer: '001 M21 EN');
      final LiveCardDetection circle = LiveCardDetection(
        confidence: .95,
        corners: observed,
      );
      tracker.update(
        <LiveCardDetection>[front, circle],
        currentGeometry: const <List<ScanPoint>>[inset],
      );
      tracker.update(
        <LiveCardDetection>[front, circle],
        currentGeometry: const <List<ScanPoint>>[inset],
      );
      final LiveCaptureSnapshot capture = tracker.snapshotCapture(
        currentGeometry: smallerFirst
            ? const <List<ScanPoint>>[inset, observed]
            : const <List<ScanPoint>>[observed, inset],
      );
      expect(capture.count, 1);
      expect(tracker.markCaptured(capture), 1);
      expect(
        tracker.rememberSavedCrop(saved, capture),
        isTrue,
        reason: 'Raw ordering $smallerFirst',
      );
      expect(tracker.savedFootprints, hasLength(2));
      expect(tracker.completedFootprints, isEmpty);
      final ScanCrop adjacent = ScanCrop(
        imagePath: saved.imagePath,
        width: saved.width,
        height: saved.height,
        rectified: true,
        warnings: saved.warnings,
        lines: saved.lines,
        sourceCorners: _card(.05, y: .55).corners,
      );
      tracker.update(<LiveCardDetection>[
        front,
        circle,
        LiveCardDetection(confidence: .95, corners: adjacent.sourceCorners),
      ]);
      expect(tracker.rememberSavedCrop(adjacent, capture), isFalse);
      expect(tracker.savedFootprints, hasLength(2));
    }
  });

  test('actual verified partial Bats text earns automatic eligibility when its whole geometry is current', () {
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    const LiveCardDetection card = LiveCardDetection(
      confidence: 1,
      corners: <ScanPoint>[
        ScanPoint(.40111232461682483, .18334380582212928),
        ScanPoint(.674123090867863, .18334380582212928),
        ScanPoint(.674123090867863, .4701198207917072),
        ScanPoint(.40111232461682483, .4701198207917072),
      ],
      warnings: <String>[
        'partial_card',
        'incomplete_card',
        'no_card_rectangle',
      ],
      lines: <ScanTextLine>[
        ScanTextLine(
          text: 'Creature - Bat',
          confidence: 1,
          bounds: ScanBounds(
            .11837751283064148,
            .45922893304142254,
            .2400074682865046,
            .046749142632968144,
          ),
        ),
        ScanTextLine(
          text: 'Whenever you create or sacrifice a',
          confidence: 1,
          bounds: ScanBounds(
            .1382664121320304,
            .5243313606862392,
            .5710997992965776,
            .08131220720816346,
          ),
        ),
        ScanTextLine(
          text: 'token, each opponent loses 1 life.',
          confidence: 1,
          bounds: ScanBounds(
            .14358491521846073,
            .5526623493565483,
            .5596974174383327,
            .0860415956248407,
          ),
        ),
        ScanTextLine(
          text: 'Mirkwood Bats',
          confidence: 1,
          bounds: ScanBounds(
            .022233347587885678,
            .03486984634082191,
            .2902035979450051,
            .04891915734134503,
          ),
        ),
      ],
    );
    tracker.update(const <LiveCardDetection>[card]);
    tracker.update(
      const <LiveCardDetection>[card],
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    expect(tracker.eligibleTracks, hasLength(1));
    expect(
      ScanHints.fromCrop(tracker.eligibleTracks.single.crop).names,
      contains('Mirkwood Bats'),
    );
    expect(
      tracker
          .snapshotCapture(currentGeometry: <List<ScanPoint>>[card.corners])
          .count,
      1,
    );
  });

  test('pending raw protection excludes both live and remembered admission while allowing a disjoint card', () {
    final DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
      clock: () => now,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection pending = _card(.05, footer: '001 M21 EN');
    final LiveCardDetection disjoint = _card(
      .65,
      title: 'Lava Spike',
      footer: '002 M21 EN',
    );
    tracker.update(<LiveCardDetection>[pending, disjoint]);
    tracker.update(<LiveCardDetection>[pending, disjoint]);
    final List<List<ScanPoint>> current = <List<ScanPoint>>[
      pending.corners,
      disjoint.corners,
    ];
    expect(tracker.snapshotCapture(currentGeometry: current).count, 2);
    final LiveCaptureSnapshot filtered = tracker.snapshotCapture(
      currentGeometry: current,
      blockedRegions: <List<ScanPoint>>[pending.corners],
    );
    expect(filtered.count, 1);
    expect(
      ScanHints.fromCrop(filtered.crops.single).names,
      contains('Lava Spike'),
    );
    tracker.tracks
        .singleWhere(
          (LiveScanTrack track) =>
              ScanHints.fromCrop(track.crop).names.contains('Lightning Bolt'),
        )
        .lastSeen = now.subtract(
      const Duration(seconds: 2),
    );
    expect(
      tracker.snapshotCapture(currentGeometry: current).count,
      2,
      reason: 'Recent proof can otherwise restore the absent live contour.',
    );
    final LiveCaptureSnapshot remembered = tracker.snapshotCapture(
      currentGeometry: current,
      blockedRegions: <List<ScanPoint>>[pending.corners],
    );
    expect(remembered.count, 1);
    expect(tracker.markCaptured(remembered), 1);
    expect(tracker.savedFootprints, hasLength(1));
    expect(tracker.isSaved(pending.corners), isFalse);
    expect(tracker.isSaved(disjoint.corners), isTrue);
  });

  test('owned unread photo suppresses only fresh physical regions frozen before its shutter', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
      clock: () => now,
    );
    final LiveScanTracker foreign = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
      clock: () => now,
    );
    addTearDown(tracker.dispose);
    addTearDown(foreign.dispose);
    final LiveCardDetection known = _card(.05, footer: '001 M21 EN');
    final LiveCardDetection unread = LiveCardDetection(
      confidence: .95,
      corners: _card(.35).corners,
    );
    final LiveCardDetection later = _card(.65, footer: '003 M21 EN');
    tracker.update(<LiveCardDetection>[known, unread]);
    tracker.update(<LiveCardDetection>[known, unread]);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(capture.count, 1);
    expect(tracker.ownsFrozenRegion(capture, unread.corners), isFalse);
    tracker.markCaptured(capture);
    final LiveCardDetection nowReadable = _card(.35, footer: '002 M21 EN');
    tracker.update(<LiveCardDetection>[known, nowReadable, later]);
    expect(tracker.ownsFrozenRegion(capture, nowReadable.corners), isTrue);
    expect(tracker.ownsFrozenRegion(capture, later.corners), isFalse);
    expect(foreign.ownsFrozenRegion(capture, nowReadable.corners), isFalse);
    expect(tracker.savedFootprints, hasLength(1));
    expect(
      tracker.tracks
          .singleWhere((LiveScanTrack track) => track.corners.first.x == .35)
          .captured,
      isFalse,
    );
    now = now.add(const Duration(seconds: 2));
    expect(tracker.ownsFrozenRegion(capture, nowReadable.corners), isFalse);
    tracker.update(<LiveCardDetection>[known]);
    now = now.add(const Duration(seconds: 2));
    tracker.update(<LiveCardDetection>[known]);
    tracker.update(<LiveCardDetection>[known, nowReadable]);
    expect(tracker.ownsFrozenRegion(capture, nowReadable.corners), isFalse);
    tracker.clear();
    expect(tracker.ownsFrozenRegion(capture, known.corners), isFalse);
  });

  test('actual unread Circle crop rediscovery reuses its owned whole-card footprint at both mounted snapshots', () {
    const List<ScanPoint> raw = <ScanPoint>[
      ScanPoint(.5626353621482849, .446195125579834),
      ScanPoint(.8015384674072266, .44809824228286743),
      ScanPoint(.8657147884368896, .5981282591819763),
      ScanPoint(.551145076751709, .5911363959312439),
    ];
    final List<List<ScanPoint>> mounted = <List<ScanPoint>>[
      const <ScanPoint>[
        ScanPoint(.5314493179321289, .44216883182525635),
        ScanPoint(.8961361050605774, .44216883182525635),
        ScanPoint(.8961361050605774, .6124570965766907),
        ScanPoint(.5314493179321289, .6124570965766907),
      ],
      const <ScanPoint>[
        ScanPoint(.5226590633392334, .4426594376564026),
        ScanPoint(.897635817527771, .4426594376564026),
        ScanPoint(.897635817527771, .6148141026496887),
        ScanPoint(.5226590633392334, .6148141026496887),
      ],
    ];
    for (final List<ScanPoint> whole in mounted) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      final LiveCardDetection known = _card(.05, footer: '001 M21 EN');
      tracker.update(
        <LiveCardDetection>[known],
        currentGeometry: <List<ScanPoint>>[known.corners, whole],
      );
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      expect(
        tracker.ownsFrozenRegion(capture, raw, currentCorners: whole),
        isFalse,
      );
      tracker.markCaptured(capture);
      expect(
        tracker.ownsFrozenRegion(capture, raw, currentCorners: whole),
        isTrue,
      );
      expect(
        tracker.ownsFrozenRegion(capture, whole, currentCorners: raw),
        isTrue,
        reason: 'A selected crop covering the owned region must suppress rediscovery too.',
      );
      final List<ScanPoint> adjacent = _card(.1, y: .44, title: null).corners;
      final List<ScanPoint> shifted = whole
          .map((ScanPoint point) => ScanPoint(point.x + .08, point.y))
          .toList();
      const List<ScanPoint> union = <ScanPoint>[
        ScanPoint(.4, .4),
        ScanPoint(.98, .4),
        ScanPoint(.98, .75),
        ScanPoint(.4, .75),
      ];
      for (final List<ScanPoint> rejected in <List<ScanPoint>>[
        adjacent,
        shifted,
        union,
      ]) {
        expect(
          tracker.ownsFrozenRegion(capture, raw, currentCorners: rejected),
          isFalse,
        );
      }
      expect(
        tracker.savedFootprints,
        hasLength(1),
        reason: 'Focus ownership creates no Circle receipt.',
      );
      now = now.add(const Duration(seconds: 2));
      expect(
        tracker.ownsFrozenRegion(capture, raw, currentCorners: whole),
        isFalse,
      );
      tracker.clear();
      expect(
        tracker.ownsFrozenRegion(capture, raw, currentCorners: whole),
        isFalse,
      );
    }
  });

  test('missing owned crop selectively rearms one physical card and preserves other late results', () {
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final List<LiveCardDetection> cards = <LiveCardDetection>[
      _card(.05, title: 'Lightning Bolt', footer: '001 M21 EN'),
      _card(.35, title: 'Lava Spike', footer: '002 M21 EN'),
      _card(.65, title: 'Mirkwood Bats', footer: '095 LTR EN'),
    ];
    tracker.update(cards);
    tracker.update(cards);
    final List<LiveScanTrack> tracks = tracker.tracks.toList();
    final List<ScanCrop> crops = tracks
        .map((LiveScanTrack track) => track.crop)
        .toList();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 3);
    expect(
      tracker.identifyCaptured(
        crops[0],
        _savedRead(crops[0]),
        capture: capture,
      ),
      1,
    );
    final List<LiveScanTrack> missing = tracker.rearmMissingCaptured(
      capture,
      <ScanCrop>[crops[0], crops[1]],
    );
    expect(missing, <LiveScanTrack>[tracks[2]]);
    expect(tracks[2].captured, isFalse);
    expect(tracks[0].capturedIdentified, isTrue);
    expect(tracks[1].captured, isTrue);
    expect(tracker.savedFootprints, hasLength(2));
    expect(tracker.canFocusSavedCapture(capture), isTrue);
    expect(tracker.rememberSavedCrop(crops[2], capture), isFalse);
    expect(
      tracker.identifyCaptured(
        crops[2],
        _savedRead(crops[2]),
        capture: capture,
      ),
      0,
    );
    expect(tracker.markCaptured(capture), 0);
    expect(tracks[2].captured, isFalse);
    expect(
      tracker.identifyCaptured(
        crops[1],
        _savedRead(crops[1]),
        capture: capture,
      ),
      1,
    );
    expect(
      tracker.rearmMissingCaptured(capture, <ScanCrop>[crops[0], crops[1]]),
      isEmpty,
    );
    tracker.beginCapture();
    final LiveCaptureSnapshot retry = tracker.snapshotCapture();
    expect(retry.count, 1);
    expect(tracker.markCaptured(retry), 1);
    expect(tracker.rememberSavedCrop(crops[2], retry), isTrue);
    expect(
      tracker.identifyCaptured(crops[2], _savedRead(crops[2]), capture: retry),
      1,
    );
    expect(tracker.savedFootprints, hasLength(3));
  });

  test(
    'any corresponding raw crop prevents rearm even when its OCR is unreadable',
    () {
      final LiveScanTracker tracker = LiveScanTracker(
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
      tracker.update(<LiveCardDetection>[card]);
      tracker.update(<LiveCardDetection>[card]);
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      tracker.markCaptured(capture);
      final ScanCrop unreadable = ScanCrop(
        imagePath: 'owned-original.jpg',
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: card.corners,
        lines: const <ScanTextLine>[],
        warnings: const <String>['incomplete_card'],
      );
      expect(
        tracker.rearmMissingCaptured(capture, <ScanCrop>[unreadable]),
        isEmpty,
      );
      expect(tracker.savedFootprints, hasLength(1));
      expect(tracker.tracks.single.captured, isTrue);
    },
  );

  test('missing crop recovery rejects stale, moved, replacement, foreign and unacknowledged scenes', () {
    for (final String variant in <String>[
      'stale',
      'moved',
      'replacement',
      'foreign',
      'unacknowledged',
      'identified',
      'unmapped',
    ]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        resolver: _Resolver(),
        clock: () => now,
        retireIdentified: true,
      );
      final LiveScanTracker foreign = LiveScanTracker(
        resolver: _Resolver(),
        clock: () => now,
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      addTearDown(foreign.dispose);
      final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
      tracker.update(<LiveCardDetection>[card]);
      tracker.update(<LiveCardDetection>[card]);
      final ScanCrop crop = tracker.tracks.single.crop;
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      if (variant != 'unacknowledged') tracker.markCaptured(capture);
      if (variant == 'stale') now = now.add(const Duration(seconds: 2));
      if (variant == 'moved') {
        tracker.update(<LiveCardDetection>[_card(.4, footer: '001 M21 EN')]);
      }
      if (variant == 'replacement') {
        tracker.update(<LiveCardDetection>[
          _card(.1, title: 'Lava Spike', footer: '002 M21 EN'),
        ]);
      }
      if (variant == 'identified') {
        tracker.identifyCaptured(crop, _savedRead(crop), capture: capture);
      }
      final List<ScanCrop> saved = variant == 'unmapped'
          ? <ScanCrop>[
              ScanCrop(
                imagePath: '',
                width: 1000,
                height: 1400,
                rectified: false,
                sourceCorners: const <ScanPoint>[],
                lines: const <ScanTextLine>[],
                warnings: const <String>['no_card_rectangle'],
              ),
            ]
          : <ScanCrop>[];
      expect(
        (variant == 'foreign' ? foreign : tracker).rearmMissingCaptured(
          capture,
          saved,
        ),
        isEmpty,
        reason: variant,
      );
    }
  });

  test('missing crop targeted retries stop after two attempts across owned capture groups', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
      clock: () => now,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[card]);
    tracker.update(<LiveCardDetection>[card]);
    final String id = tracker.tracks.single.id;
    LiveCaptureSnapshot? lastCapture;
    for (int attempt = 0; attempt < 3; attempt++) {
      tracker.beginCapture();
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      lastCapture = capture;
      expect(tracker.markCaptured(capture), 1);
      final List<LiveScanTrack> missing = tracker.rearmMissingCaptured(
        capture,
        const <ScanCrop>[],
      );
      expect(
        missing.map((LiveScanTrack track) => track.id),
        attempt < 2 ? <String>[id] : <String>[],
      );
    }
    expect(tracker.savedFootprints, hasLength(1));
    expect(tracker.tracks.single.captured, isTrue);
    for (int second = 0; second < 45; second++) {
      now = now.add(const Duration(seconds: 1));
      tracker.update(<LiveCardDetection>[card]);
    }
    expect(
      tracker.rearmMissingCaptured(lastCapture!, const <ScanCrop>[]),
      isEmpty,
    );
    expect(tracker.tracks.single.captured, isTrue);
  });

  test('adaptive missing-crop recovery continues across more than eight successive physical cards', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
      clock: () => now,
    );
    addTearDown(tracker.dispose);
    for (int index = 0; index < 70; index++) {
      final LiveCardDetection card = _card(
        .1,
        footer: '${(index + 1).toString().padLeft(3, '0')} M21 EN',
      );
      tracker.update(<LiveCardDetection>[card]);
      tracker.update(<LiveCardDetection>[card]);
      final int token = tracker.beginCapture();
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      expect(tracker.markCaptured(capture), 1, reason: 'Card $index');
      expect(
        tracker.rearmMissingCaptured(capture, const <ScanCrop>[]),
        hasLength(1),
        reason: 'Card $index',
      );
      tracker.endCapture(token, resumeTracking: false);
      tracker.update(const <LiveCardDetection>[]);
      now = now.add(const Duration(seconds: 2));
      tracker.update(const <LiveCardDetection>[]);
      now = now.add(const Duration(seconds: 2));
      tracker.update(const <LiveCardDetection>[]);
    }
  });

  test('missing-crop retry budget expires after physical absence but consumes only one target per call', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
      clock: () => now,
    );
    addTearDown(tracker.dispose);
    final List<LiveCardDetection> cards = <LiveCardDetection>[
      _card(.05, footer: '001 M21 EN'),
      _card(.65, title: 'Lava Spike', footer: '002 M21 EN'),
    ];
    tracker.update(cards);
    tracker.update(cards);
    tracker.beginCapture();
    final LiveCaptureSnapshot first = tracker.snapshotCapture();
    expect(tracker.markCaptured(first), 2);
    expect(
      tracker.rearmMissingCaptured(first, const <ScanCrop>[]),
      hasLength(1),
    );
    expect(tracker.savedFootprints, hasLength(1));
    tracker.beginCapture();
    final LiveCaptureSnapshot second = tracker.snapshotCapture();
    expect(tracker.markCaptured(second), 1);
    expect(
      tracker.rearmMissingCaptured(second, const <ScanCrop>[]),
      hasLength(1),
    );
    tracker.update(const <LiveCardDetection>[]);
    now = now.add(const Duration(seconds: 2));
    tracker.update(const <LiveCardDetection>[]);
    now = now.add(const Duration(seconds: 31));
    tracker.update(const <LiveCardDetection>[]);
    tracker.update(<LiveCardDetection>[cards.first]);
    tracker.update(<LiveCardDetection>[cards.first]);
    tracker.beginCapture();
    final LiveCaptureSnapshot afterRemoval = tracker.snapshotCapture();
    expect(tracker.markCaptured(afterRemoval), 1);
    expect(
      tracker.rearmMissingCaptured(afterRemoval, const <ScanCrop>[]),
      hasLength(1),
    );
  });

  test('saved capture may focus through slow lookup only while its owned front receipt stays present', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection front = _card(.1, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[front]);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.canFocusSavedCapture(capture), isFalse);
    tracker.markCaptured(capture);
    expect(tracker.canFocusSavedCapture(capture), isTrue);
    tracker.beginCapture();
    for (int second = 0; second < 45; second++) {
      now = now.add(const Duration(seconds: 1));
      tracker.update(
        const <LiveCardDetection>[],
        currentGeometry: <List<ScanPoint>>[front.corners],
      );
    }
    expect(tracker.canFocusSavedCapture(capture), isTrue);
    expect(tracker.savedFootprints, hasLength(1));
    expect(tracker.tracks.single.capturedIdentified, isFalse);
    expect(tracker.completedFootprints, isEmpty);
  });

  test('saved focus query rejects foreign, reset, removed, expired and unacknowledged captures without making receipts', () {
    for (final String variant in <String>[
      'foreign',
      'reset',
      'removed',
      'expired',
      'unacknowledged',
    ]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
        retireIdentified: true,
      );
      final LiveScanTracker foreign = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      addTearDown(foreign.dispose);
      final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
      if (variant != 'expired') {
        tracker.update(<LiveCardDetection>[card]);
      }
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      if (variant != 'unacknowledged') {
        tracker.markCaptured(capture);
      }
      if (variant == 'foreign') {
        expect(foreign.canFocusSavedCapture(capture), isFalse);
      } else {
        if (variant == 'reset') {
          tracker.clear();
        } else if (variant == 'removed') {
          tracker.update(const <LiveCardDetection>[]);
          now = now.add(const Duration(seconds: 2));
          tracker.update(const <LiveCardDetection>[]);
        } else if (variant == 'expired') {
          now = now.add(const Duration(seconds: 31));
        }
        expect(tracker.canFocusSavedCapture(capture), isFalse, reason: variant);
      }
      expect(
        tracker.tracks.where((LiveScanTrack track) => track.capturedIdentified),
        isEmpty,
      );
      expect(tracker.completedFootprints, isEmpty);
    }
  });

  test('actual saved Circle binds its frozen pre-shutter raw region without claiming live geometry is identity', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final ScanCrop saved = _recordedCircle25Saved();
    final LiveCardDetection front = _card(
      .65,
      title: 'Nevermore',
      footer: '001 M21 EN',
    );
    final LiveCardDetection unread = LiveCardDetection(
      confidence: 1,
      corners: saved.sourceCorners,
    );
    final LiveCardDetection panel = LiveCardDetection(
      confidence: 1,
      corners: const <ScanPoint>[
        ScanPoint(.32, .64),
        ScanPoint(.52, .64),
        ScanPoint(.52, .72),
        ScanPoint(.32, .72),
      ],
    );
    tracker.update(<LiveCardDetection>[front, unread, panel]);
    tracker.update(<LiveCardDetection>[front, unread, panel]);
    expect(tracker.eligibleTracks, hasLength(1));
    final int token = tracker.beginCapture();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(capture.count, 1, reason: 'Only Nevermore has live card evidence.');
    expect(tracker.markCaptured(capture), 1);
    tracker.endCapture(token, resumeTracking: true);
    for (int second = 0; second < 45; second++) {
      now = now.add(const Duration(seconds: 1));
      tracker.update(
        const <LiveCardDetection>[],
        currentGeometry: <List<ScanPoint>>[
          front.corners,
          unread.corners,
          panel.corners,
        ],
      );
    }
    expect(tracker.rememberSavedCrop(saved, capture), isTrue);
    expect(tracker.savedFootprints, hasLength(2));
    expect(
      tracker.tracks.where((LiveScanTrack track) => track.capturedIdentified),
      isEmpty,
    );
    final ScanResolution unsupported = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Card(), const <ScanEvidence>{ScanEvidence.fuzzyName}),
      ],
      hints: ScanHints.fromCrop(saved),
      status: ScanResolutionStatus.needsReview,
    );
    expect(tracker.identifyCaptured(saved, unsupported, capture: capture), 0);
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      1,
    );
    expect(
      tracker.tracks.where((LiveScanTrack track) => track.capturedIdentified),
      hasLength(1),
    );
    expect(tracker.eligibleTracks, isEmpty);
  });

  test('frozen raw region recovery rejects later geometry, removal, conflicts, copies, stale frames and foreign capture', () {
    for (final String variant in <String>[
      'later',
      'removed',
      'replacement',
      'printing',
      'copy',
      'stale',
      'foreign',
      'reset',
      'weak_saved',
    ]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
        retireIdentified: true,
      );
      final LiveScanTracker foreign = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      addTearDown(foreign.dispose);
      final ScanCrop actual = _recordedCircle25Saved();
      final ScanCrop saved = variant == 'printing'
          ? ScanCrop(
              imagePath: '',
              width: actual.width,
              height: actual.height,
              rectified: actual.rectified,
              sourceCorners: actual.sourceCorners,
              warnings: actual.warnings,
              lines: <ScanTextLine>[
                ...actual.lines,
                const ScanTextLine(
                  text: '001 M21 EN',
                  confidence: .99,
                  bounds: ScanBounds(.05, .91, .4, .03),
                ),
              ],
            )
          : actual;
      final LiveCardDetection front = _card(
        .65,
        title: 'Nevermore',
        footer: '001 M21 EN',
      );
      final LiveCardDetection unread = LiveCardDetection(
        confidence: 1,
        corners: saved.sourceCorners,
      );
      tracker.update(<LiveCardDetection>[
        front,
        if (variant != 'later') unread,
      ]);
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      tracker.markCaptured(capture);
      if (variant == 'removed') {
        tracker.update(<LiveCardDetection>[front]);
        now = now.add(const Duration(seconds: 2));
        tracker.update(<LiveCardDetection>[front]);
      } else if (variant == 'replacement' || variant == 'printing') {
        final List<ScanTextLine> replacement = <ScanTextLine>[
          if (variant == 'replacement')
            const ScanTextLine(
              text: 'Counterspell',
              confidence: .99,
              bounds: ScanBounds(.05, .04, .7, .03),
            )
          else ...<ScanTextLine>[
            ...actual.lines,
            const ScanTextLine(
              text: '002 M21 EN',
              confidence: .99,
              bounds: ScanBounds(.05, .91, .4, .03),
            ),
          ],
        ];
        if (variant == 'printing') {
          expect(ScanHints.fromCrop(saved).collectorNumber, '001');
          expect(
            ScanHints.fromCrop(
              ScanCrop(
                imagePath: '',
                width: 1000,
                height: 1400,
                rectified: true,
                sourceCorners: saved.sourceCorners,
                lines: replacement,
              ),
            ).collectorNumber,
            '002',
          );
        }
        tracker.update(<LiveCardDetection>[
          front,
          LiveCardDetection(
            confidence: 1,
            corners: saved.sourceCorners,
            lines: replacement,
          ),
        ]);
      } else if (variant == 'reset') {
        tracker.clear();
      }
      tracker.update(<LiveCardDetection>[
        front,
        unread,
        if (variant == 'copy') unread,
      ]);
      if (variant == 'stale') {
        now = now.add(const Duration(seconds: 2));
      }
      final LiveCaptureSnapshot authority;
      if (variant == 'foreign') {
        foreign.update(<LiveCardDetection>[front, unread]);
        authority = foreign.snapshotCapture();
        foreign.markCaptured(authority);
      } else {
        authority = capture;
      }
      final ScanCrop input = variant == 'weak_saved'
          ? ScanCrop(
              imagePath: '',
              width: 1000,
              height: 1400,
              rectified: true,
              sourceCorners: saved.sourceCorners,
              lines: const <ScanTextLine>[],
            )
          : saved;
      expect(
        tracker.rememberSavedCrop(input, authority),
        isFalse,
        reason: variant,
      );
      expect(
        tracker.identifyCaptured(input, _savedRead(input), capture: authority),
        0,
        reason: variant,
      );
      expect(
        tracker.isCompleted(saved.sourceCorners),
        isFalse,
        reason: variant,
      );
    }
  });

  test('completed appearance keeps a fixed scene reference through Vision contour jitter but detects actual artwork replacement', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[card]);
    final ScanCrop saved = tracker.tracks.single.crop;
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    tracker.markCaptured(capture);
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      1,
    );
    for (int frame = 0; frame < 3; frame++) {
      now = now.add(const Duration(milliseconds: 250));
      final LiveScanExcludedRegion region = tracker.savedFootprints.single;
      tracker.update(
        const <LiveCardDetection>[],
        currentGeometry: <List<ScanPoint>>[card.corners],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _fixedSceneSample(region),
        ],
      );
    }
    // The scene pixels remain fixed; only Vision's fitted quadrilateral changes.
    final List<ScanPoint> jitter = <ScanPoint>[
      const ScanPoint(.125, .105),
      const ScanPoint(.30, .115),
      const ScanPoint(.27, .39),
      const ScanPoint(.105, .375),
    ];
    for (int frame = 0; frame < 8; frame++) {
      now = now.add(const Duration(milliseconds: 350));
      expect(
        tracker.savedFootprints,
        hasLength(1),
        reason: 'Unchanged scene, frame $frame',
      );
      final LiveScanExcludedRegion appearance = tracker.savedFootprints.single;
      final LiveScanExcludedRegion excluded =
          tracker.completedFootprints.single;
      expect(excluded.id, appearance.id);
      for (int corner = 0; corner < 4; corner++) {
        expect(excluded.corners[corner].x, appearance.corners[corner].x);
        expect(excluded.corners[corner].y, appearance.corners[corner].y);
      }
      tracker.update(
        const <LiveCardDetection>[],
        currentGeometry: <List<ScanPoint>>[jitter],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _fixedSceneSample(appearance),
        ],
      );
      expect(tracker.isSaved(card.corners), isTrue);
      expect(tracker.eligibleTracks, isEmpty);
    }
    for (int frame = 0; frame < 3; frame++) {
      now = now.add(const Duration(milliseconds: 350));
      final LiveScanExcludedRegion region = tracker.savedFootprints.single;
      tracker.update(
        const <LiveCardDetection>[],
        currentGeometry: <List<ScanPoint>>[jitter],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _fixedSceneSample(region, replaced: true),
        ],
      );
    }
    expect(tracker.savedFootprints, isEmpty);
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      0,
    );
    tracker.update(<LiveCardDetection>[card]);
    tracker.update(<LiveCardDetection>[card]);
    expect(tracker.eligibleTracks, hasLength(1));
  });

  test('a stationary rotated perspective card retains one receipt through long-lived corner jitter', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection text = _card(.1, footer: '001 M21 EN');
    const List<ScanPoint> corners = <ScanPoint>[
      ScanPoint(.465, .24),
      ScanPoint(.67, .36),
      ScanPoint(.535, .75),
      ScanPoint(.29, .56),
    ];
    final LiveCardDetection card = LiveCardDetection(
      confidence: .95,
      corners: corners,
      lines: text.lines,
    );
    tracker.update(<LiveCardDetection>[card]);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 1);
    final ScanCrop saved = tracker.tracks.single.crop;
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      1,
    );
    final LiveScanExcludedRegion region = tracker.savedFootprints.single;
    for (int frame = 0; frame < 180; frame++) {
      now = now.add(const Duration(milliseconds: 500));
      final double jitter = frame.isEven ? .008 : -.008;
      tracker.update(
        <LiveCardDetection>[
          LiveCardDetection(
            confidence: .95,
            corners: <ScanPoint>[
              ScanPoint(corners[0].x + jitter, corners[0].y - jitter),
              ScanPoint(corners[1].x - jitter, corners[1].y - jitter),
              ScanPoint(corners[2].x + jitter, corners[2].y + jitter),
              ScanPoint(corners[3].x - jitter, corners[3].y + jitter),
            ],
            lines: card.lines,
          ),
        ],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _fixedSceneSample(region),
        ],
      );
      expect(tracker.savedFootprints.single.id, region.id);
      expect(tracker.eligibleTracks, isEmpty, reason: 'Frame $frame');
      expect(tracker.snapshotCapture().isEmpty, isTrue);
    }
  });

  test('fresh yellow photo settles appearance without Vision geometry through slow saved OCR', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[card]);
    tracker.update(<LiveCardDetection>[card]);
    final ScanCrop saved = tracker.tracks.single.crop;
    final String id = tracker.tracks.single.id;
    final int token = tracker.beginCapture();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 1);
    tracker.endCapture(token, resumeTracking: true);
    void sample(Duration elapsed, {double gain = 1}) {
      now = now.add(elapsed);
      tracker.update(
        const <LiveCardDetection>[],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _appearance(id, card.corners, present: false, gain: gain),
        ],
      );
    }

    for (int frame = 0; frame < 3; frame++) {
      sample(const Duration(milliseconds: 250));
    }
    for (int second = 0; second < 45; second++) {
      sample(const Duration(seconds: 1), gain: .7);
      expect(tracker.savedFootprints.single.id, id);
      expect(tracker.completedFootprints, isEmpty);
      expect(tracker.eligibleTracks, isEmpty);
      expect(tracker.tracks.single.capturedIdentified, isFalse);
    }
    final ScanResolution fuzzyOnly = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Card(), const <ScanEvidence>{ScanEvidence.fuzzyName}),
      ],
      hints: ScanHints.fromCrop(saved),
      status: ScanResolutionStatus.needsReview,
    );
    expect(tracker.identifyCaptured(saved, fuzzyOnly, capture: capture), 0);
    expect(tracker.tracks.single.capturedIdentified, isFalse);
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      1,
    );
    expect(tracker.tracks.single.capturedIdentified, isTrue);
    expect(tracker.completedFootprints.single.id, id);
    sample(const Duration(seconds: 3));
    expect(tracker.tracks, isEmpty);
    expect(tracker.isSaved(card.corners), isTrue);
    expect(tracker.snapshotCapture().isEmpty, isTrue);
  });

  test('yellow appearance survives exposure and one glare frame but repeated replacement releases its photo authority', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[card]);
    final ScanCrop saved = tracker.tracks.single.crop;
    final String id = tracker.tracks.single.id;
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 1);
    void sample(LiveCardAppearanceSample appearance) {
      now = now.add(const Duration(milliseconds: 300));
      tracker.update(
        const <LiveCardDetection>[],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[appearance],
      );
    }

    for (int frame = 0; frame < 3; frame++) {
      sample(_appearance(id, card.corners, present: false));
    }
    sample(
      LiveCardAppearanceSample(
        id: id,
        corners: card.corners,
        present: false,
        values: List<double>.filled(288, 1),
      ),
    );
    expect(tracker.isSaved(card.corners), isTrue);
    sample(_appearance(id, card.corners, present: false, gain: .7));
    expect(tracker.isSaved(card.corners), isTrue);
    expect(tracker.completedFootprints, isEmpty);
    for (int frame = 0; frame < 3; frame++) {
      sample(_appearance(id, card.corners, present: false, reversed: true));
    }
    expect(tracker.savedFootprints, isEmpty);
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      0,
    );
    tracker.update(<LiveCardDetection>[card]);
    tracker.update(<LiveCardDetection>[card]);
    expect(tracker.eligibleTracks.single.id, isNot(id));
  });

  test('flat removed-card pixels and late samples cannot bootstrap yellow appearance authority', () {
    for (final String variant in <String>['flat', 'late']) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
      tracker.update(<LiveCardDetection>[card]);
      final ScanCrop saved = tracker.tracks.single.crop;
      final String id = tracker.tracks.single.id;
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      tracker.markCaptured(capture);
      if (variant == 'late') {
        now = now.add(const Duration(seconds: 3));
      }
      for (int frame = 0; frame < 6; frame++) {
        now = now.add(const Duration(milliseconds: 400));
        tracker.update(
          const <LiveCardDetection>[],
          appearanceSamplingSupported: true,
          appearanceSamples: <LiveCardAppearanceSample>[
            variant == 'flat'
                ? LiveCardAppearanceSample(
                    id: id,
                    corners: card.corners,
                    present: false,
                    values: List<double>.filled(288, .4),
                  )
                : _appearance(id, card.corners, present: false),
          ],
        );
      }
      expect(tracker.savedFootprints, isEmpty, reason: variant);
      expect(
        tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
        0,
        reason: variant,
      );
      expect(tracker.completedFootprints, isEmpty, reason: variant);
    }
  });

  test('durable automatic ACK holds yellow footprints through 45 seconds of geometry before any saved OCR arrives', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final List<LiveCardDetection> front = <LiveCardDetection>[
      _card(.05, title: 'Lightning Bolt', footer: '001 M21 EN'),
      _card(.35, title: 'Lava Spike', footer: '002 M21 EN'),
    ];
    tracker.update(front);
    tracker.update(front);
    final List<ScanCrop> saved = tracker.tracks
        .map((LiveScanTrack track) => track.crop)
        .toList();
    final int token = tracker.beginCapture();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      currentGeometry: front.map((LiveCardDetection card) => card.corners),
    );
    expect(tracker.markCaptured(capture), 2);
    tracker.endCapture(token, resumeTracking: true);
    expect(tracker.savedFootprints, hasLength(2));
    expect(tracker.completedFootprints, isEmpty);
    expect(
      tracker.tracks.every((LiveScanTrack track) => track.capturedIdentified),
      isFalse,
    );

    // The actual photograph is durable, but no crop or catalog result exists yet.
    for (int second = 0; second < 45; second++) {
      now = now.add(const Duration(seconds: 1));
      tracker.update(
        const <LiveCardDetection>[],
        currentGeometry: front.map((LiveCardDetection card) => card.corners),
      );
      expect(tracker.savedFootprints, hasLength(2), reason: 'Second $second');
      expect(tracker.eligibleTracks, isEmpty, reason: 'Second $second');
      expect(
        tracker.snapshotCapture().isEmpty,
        isTrue,
        reason: 'Second $second',
      );
      expect(
        tracker.tracks.where((LiveScanTrack track) => track.capturedIdentified),
        isEmpty,
      );
    }
    expect(
      tracker.tracks.where((LiveScanTrack track) => track.captured),
      hasLength(2),
    );

    // This third card is in the owned photograph, but its readable live proof
    // first arrives after the shutter and the usual ACK deadline.
    final LiveCardDetection rear = _card(
      .65,
      title: 'Mirkwood Bats',
      footer: '095 LTR EN',
    );
    tracker.update(<LiveCardDetection>[
      rear,
    ], currentGeometry: front.map((LiveCardDetection card) => card.corners));
    final ScanCrop rearSaved = tracker.tracks
        .firstWhere((LiveScanTrack track) => !track.captured)
        .crop;
    for (final ScanCrop crop in saved) {
      expect(tracker.rememberSavedCrop(crop, capture), isTrue);
      expect(
        tracker.identifyCaptured(crop, _savedRead(crop), capture: capture),
        1,
      );
    }
    expect(tracker.rememberSavedCrop(rearSaved, capture), isTrue);
    expect(
      tracker.identifyCaptured(
        rearSaved,
        _savedRead(rearSaved),
        capture: capture,
      ),
      1,
    );
    expect(tracker.savedFootprints, hasLength(3));
    expect(
      tracker.tracks.where((LiveScanTrack track) => track.capturedIdentified),
      hasLength(3),
    );
    expect(tracker.eligibleTracks, isEmpty);
    expect(tracker.snapshotCapture().isEmpty, isTrue);
  });

  test('late automatic saved binding cannot borrow weak, absent, replaced or reset receipt authority', () {
    for (final String variant in <String>[
      'weak',
      'removed',
      'replacement',
      'printing',
      'reset',
      'stale_geometry',
    ]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      final LiveCardDetection first = _card(
        .05,
        footer: variant == 'weak' ? null : '001 M21 EN',
      );
      final LiveCardDetection second = _card(
        .35,
        title: 'Lava Spike',
        footer: variant == 'weak' ? null : '002 M21 EN',
      );
      tracker.update(<LiveCardDetection>[first, second]);
      tracker.update(<LiveCardDetection>[first, second]);
      final int token = tracker.beginCapture();
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      expect(tracker.markCaptured(capture), 2, reason: variant);
      tracker.endCapture(token, resumeTracking: true);
      expect(
        tracker.savedFootprints.length,
        variant == 'weak' ? 0 : 2,
        reason: variant,
      );
      for (int elapsed = 0; elapsed < 45; elapsed++) {
        now = now.add(const Duration(seconds: 1));
        tracker.update(
          const <LiveCardDetection>[],
          currentGeometry: <List<ScanPoint>>[first.corners, second.corners],
        );
      }
      final LiveCardDetection rear = _card(
        .65,
        title: 'Mirkwood Bats',
        footer: '095 LTR EN',
      );
      final ScanCrop rearSaved = ScanCrop(
        imagePath: '',
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: rear.corners,
        lines: rear.lines,
      );
      if (variant == 'removed') {
        tracker.update(const <LiveCardDetection>[]);
        now = now.add(const Duration(seconds: 2));
        tracker.update(const <LiveCardDetection>[]);
      } else if (variant == 'replacement' || variant == 'printing') {
        tracker.update(
          <LiveCardDetection>[
            _card(
              .05,
              title: variant == 'replacement'
                  ? 'Counterspell'
                  : 'Lightning Bolt',
              footer: variant == 'printing' ? '003 M21 EN' : '001 M21 EN',
            ),
          ],
          currentGeometry: <List<ScanPoint>>[second.corners],
        );
        expect(tracker.isSaved(first.corners), isFalse, reason: variant);
        expect(tracker.isSaved(second.corners), isTrue, reason: variant);
      } else if (variant == 'reset') {
        tracker.clear();
      }
      tracker.update(<LiveCardDetection>[first, second, rear]);
      if (variant == 'stale_geometry') {
        now = now.add(const Duration(seconds: 2));
      }
      expect(
        tracker.rememberSavedCrop(rearSaved, capture),
        isFalse,
        reason: variant,
      );
      expect(
        tracker.identifyCaptured(
          rearSaved,
          _savedRead(rearSaved),
          capture: capture,
        ),
        0,
        reason: variant,
      );
      expect(tracker.isCompleted(rear.corners), isFalse, reason: variant);
    }
  });

  test('manual ACK cannot identify an unfrozen card after 45 seconds of otherwise matching live geometry', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[card]);
    final int token = tracker.beginCapture();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 1);
    tracker.endCapture(token, resumeTracking: true);
    for (int second = 0; second < 45; second++) {
      now = now.add(const Duration(seconds: 1));
      tracker.update(<LiveCardDetection>[card]);
    }
    final LiveCardDetection rear = _card(
      .65,
      title: 'Mirkwood Bats',
      footer: '095 LTR EN',
    );
    tracker.update(<LiveCardDetection>[card, rear]);
    final ScanCrop saved = tracker.tracks
        .firstWhere((LiveScanTrack track) => !track.captured)
        .crop;
    expect(tracker.rememberSavedCrop(saved, capture), isFalse);
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      0,
    );
  });

  test('twenty physically removed automatic batches release bounded completion and receipt capacity immediately', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    for (int batch = 0; batch < 20; batch++) {
      expect(
        tracker.completionCapacityAvailable,
        isTrue,
        reason: 'Batch $batch',
      );
      final LiveCardDetection card = _card(
        .1,
        title: 'Card $batch',
        footer: '001 M21 EN',
      );
      tracker.update(<LiveCardDetection>[card]);
      tracker.update(<LiveCardDetection>[card]);
      expect(tracker.eligibleTracks, hasLength(1));
      tracker.beginCapture();
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      expect(tracker.markCaptured(capture), 1);
      final ScanCrop saved = tracker.tracks.single.crop;
      expect(
        tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
        1,
      );
      tracker.update(<LiveCardDetection>[]);
      now = now.add(const Duration(milliseconds: 1500));
      tracker.update(<LiveCardDetection>[]);
      expect(tracker.savedFootprints, isEmpty);
      expect(tracker.tracks, isEmpty);
    }
  });

  test('automatic completion is per physical copy and a confirmed printing replacement releases only its location', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection first = _card(.1, footer: '001 M21 EN');
    final LiveCardDetection second = _card(.6, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[first, second]);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 2);
    final List<ScanCrop> saved = tracker.tracks
        .map((LiveScanTrack track) => track.crop)
        .toList();
    for (final ScanCrop crop in saved) {
      expect(
        tracker.identifyCaptured(crop, _savedRead(crop), capture: capture),
        1,
      );
    }
    expect(tracker.savedFootprints, hasLength(2));
    tracker.update(<LiveCardDetection>[
      _card(.1, footer: '002 M21 EN'),
      second,
    ]);
    expect(tracker.isSaved(first.corners), isFalse);
    expect(tracker.isSaved(second.corners), isTrue);
    expect(tracker.uncapturedTracks, hasLength(1));
    expect(
      tracker.identifyCaptured(
        saved.first,
        _savedRead(saved.first),
        capture: capture,
      ),
      0,
    );
    tracker.clear();
    expect(tracker.savedFootprints, isEmpty);
  });

  test('automatic completed cards retire their AR label but never recapture while unchanged appearance remains present', () async {
    DateTime now = DateTime.utc(2026);
    final _Resolver resolver = _Resolver();
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: resolver,
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[card]);
    tracker.update(<LiveCardDetection>[card]);
    await _settle();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 1);
    final ScanCrop saved = tracker.tracks.single.crop;
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      1,
    );
    final String id = tracker.tracks.single.id;
    final int calls = resolver.calls;
    expect(
      tracker.completedFootprints,
      isEmpty,
      reason: 'An unsupported frame must not cause native OCR exclusion.',
    );
    for (int index = 0; index < 3; index++) {
      now = now.add(const Duration(milliseconds: 250));
      tracker.update(
        <LiveCardDetection>[],
        currentGeometry: <List<ScanPoint>>[card.corners],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _appearance(id, card.corners),
        ],
      );
    }
    expect(tracker.completedFootprints.single.id, id);
    expect(tracker.tracks.single.capturedIdentified, isTrue);
    now = now.add(const Duration(seconds: 90));
    tracker.update(
      <LiveCardDetection>[],
      appearanceSamplingSupported: true,
      appearanceSamples: <LiveCardAppearanceSample>[
        _appearance(id, card.corners, present: false, gain: .7),
      ],
    );
    await _settle();
    expect(
      tracker.tracks,
      isEmpty,
      reason:
          'Green is a brief acknowledgement rather than permanent AR clutter.',
    );
    expect(
      tracker.isCompleted(card.corners),
      isTrue,
      reason: 'Appearance corroborates a visible partial card during a Vision rectangle gap.',
    );
    expect(tracker.eligibleTracks, isEmpty);
    expect(tracker.recentFocusCrops, isEmpty);
    expect(tracker.snapshotCapture().isEmpty, isTrue);
    expect(resolver.calls, calls);
    tracker.update(
      <LiveCardDetection>[card],
      appearanceSamplingSupported: true,
      appearanceSamples: <LiveCardAppearanceSample>[
        _appearance(id, card.corners),
      ],
    );
    expect(
      tracker.tracks,
      isEmpty,
      reason: 'Repeated OCR results do not respawn the completed card.',
    );
  });

  test('static completed cards keep capture ownership through one noisy nameplate frame with unchanged appearance', () {
    for (final ({String original, String noisy}) title
        in <({String original, String noisy})>[
          (original: 'Pick Your Poison', noisy: 'Pick Your Polsom'),
          (original: '隆盛なるエヴィンカー', noisy: '隆盛なるエヴインガー'),
        ]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      final LiveCardDetection card = _card(
        .1,
        title: title.original,
        footer: '001 M21 EN',
      );
      tracker.update(<LiveCardDetection>[card]);
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      expect(tracker.markCaptured(capture), 1);
      final ScanCrop saved = tracker.tracks.single.crop;
      expect(
        tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
        1,
      );
      final String id = tracker.savedFootprints.single.id;
      for (int frame = 0; frame < 3; frame++) {
        now = now.add(const Duration(milliseconds: 250));
        tracker.update(
          const <LiveCardDetection>[],
          currentGeometry: <List<ScanPoint>>[card.corners],
          appearanceSamplingSupported: true,
          appearanceSamples: <LiveCardAppearanceSample>[
            _appearance(id, card.corners),
          ],
        );
      }
      now = now.add(const Duration(milliseconds: 350));
      tracker.update(
        <LiveCardDetection>[
          _card(.1, title: title.noisy, footer: '001 M21 EN'),
        ],
        currentGeometry: <List<ScanPoint>>[card.corners],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _appearance(id, card.corners, gain: .8),
        ],
      );
      expect(
        tracker.isSaved(card.corners),
        isTrue,
        reason: 'OCR changed, but the ${title.original} scene pixels did not.',
      );
      expect(tracker.eligibleTracks, isEmpty);
      for (int frame = 0; frame < 3; frame++) {
        now = now.add(const Duration(milliseconds: 350));
        tracker.update(
          <LiveCardDetection>[card],
          appearanceSamplingSupported: true,
          appearanceSamples: <LiveCardAppearanceSample>[
            _appearance(id, card.corners),
          ],
        );
        expect(tracker.savedFootprints.single.id, id);
        expect(tracker.eligibleTracks, isEmpty);
      }
    }
  });

  test('missing appearance samples do not rearm a mounted scene and observed removal releases only the removed card', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final List<LiveCardDetection> cards = <LiveCardDetection>[
      _card(.1, y: .55, title: '隆盛なるエヴィンカー', footer: '001 M21 EN'),
      _card(.45, y: .55, title: 'Pick Your Poison', footer: '002 M21 EN'),
      _card(.75, y: .08, title: 'Glimpse of Nature', footer: '003 M21 EN'),
    ];
    tracker.update(cards);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 3);
    final List<ScanCrop> saved = tracker.tracks
        .map((LiveScanTrack track) => track.crop)
        .toList();
    for (final ScanCrop crop in saved) {
      expect(
        tracker.identifyCaptured(crop, _savedRead(crop), capture: capture),
        1,
      );
    }
    final List<LiveScanExcludedRegion> regions = tracker.savedFootprints;
    for (int frame = 0; frame < 3; frame++) {
      now = now.add(const Duration(milliseconds: 250));
      tracker.update(
        const <LiveCardDetection>[],
        currentGeometry: cards.map((LiveCardDetection card) => card.corners),
        appearanceSamplingSupported: true,
        appearanceSamples: regions.map(_fixedSceneSample),
      );
    }
    for (int frame = 0; frame < 4; frame++) {
      now = now.add(const Duration(milliseconds: 500));
      tracker.update(
        const <LiveCardDetection>[],
        appearanceSamplingSupported: true,
      );
    }
    expect(
      tracker.savedFootprints,
      hasLength(3),
      reason: 'An analysis gap is not evidence that any card left the scene.',
    );
    tracker.update(
      cards,
      appearanceSamplingSupported: true,
      appearanceSamples: regions.map(_fixedSceneSample),
    );
    expect(tracker.eligibleTracks, isEmpty);
    expect(
      tracker.canFocusSavedCapture(capture),
      isTrue,
      reason:
          'A missing sample must not invalidate the saved capture generation.',
    );

    final LiveScanExcludedRegion removed = regions[1];
    for (int frame = 0; frame < 4; frame++) {
      now = now.add(const Duration(milliseconds: 500));
      tracker.update(
        <LiveCardDetection>[cards.first, cards.last],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _fixedSceneSample(regions.first),
          LiveCardAppearanceSample(
            id: removed.id,
            corners: removed.corners,
            present: false,
            values: List<double>.filled(288, .35),
          ),
          _fixedSceneSample(regions.last),
        ],
      );
    }
    expect(tracker.savedFootprints, hasLength(2));
    expect(tracker.isSaved(cards.first.corners), isTrue);
    expect(tracker.isSaved(cards.last.corners), isTrue);
    expect(tracker.isSaved(cards[1].corners), isFalse);
    tracker.update(cards);
    tracker.update(cards);
    expect(tracker.eligibleTracks, hasLength(1));
    expect(tracker.eligibleTracks.single.id, isNot(removed.id));
    expect(
      tracker.identifyCaptured(
        saved[1],
        _savedRead(saved[1]),
        capture: capture,
      ),
      0,
      reason: 'A removed capture cannot identify a newly presented copy.',
    );
  });

  test('suspending observations retains capture ownership but rejects stale frames and saved binding until a fresh frame', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[card]);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 1);
    final ScanCrop saved = tracker.tracks.single.crop;
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      1,
    );
    final LiveScanExcludedRegion region = tracker.savedFootprints.single;
    for (int frame = 0; frame < 3; frame++) {
      now = now.add(const Duration(milliseconds: 250));
      tracker.update(
        <LiveCardDetection>[card],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _fixedSceneSample(region),
        ],
      );
    }
    final int oldAnalysis = tracker.beginFrameAnalysis();
    tracker.suspendObservations();
    now = now.add(const Duration(seconds: 20));
    tracker.suspendObservations();
    tracker.update(<LiveCardDetection>[
      _card(.1, footer: '002 M21 EN'),
    ], frameAnalysis: oldAnalysis);
    expect(tracker.savedFootprints.single.id, region.id);
    expect(tracker.eligibleTracks, isEmpty);
    expect(tracker.canFocusSavedCapture(capture), isFalse);
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      0,
      reason: 'Paused observations cannot attach a late result to the scene.',
    );
    tracker.update(
      <LiveCardDetection>[card],
      currentGeometry: <List<ScanPoint>>[card.corners],
      appearanceSamplingSupported: true,
      appearanceSamples: <LiveCardAppearanceSample>[_fixedSceneSample(region)],
    );
    expect(tracker.savedFootprints.single.id, region.id);
    expect(tracker.canFocusSavedCapture(capture), isTrue);
    expect(tracker.eligibleTracks, isEmpty);
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      1,
    );
    for (int frame = 0; frame < 3; frame++) {
      now = now.add(const Duration(milliseconds: 350));
      tracker.update(
        const <LiveCardDetection>[],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _fixedSceneSample(region, replaced: true),
        ],
      );
    }
    expect(tracker.savedFootprints, isEmpty);
    tracker.update(<LiveCardDetection>[card]);
    tracker.update(<LiveCardDetection>[card]);
    expect(tracker.eligibleTracks.single.id, isNot(region.id));
  });

  test('suspending observations invalidates a held lookup without blocking new live recognition', () async {
    final Completer<ScanResolution> held = Completer<ScanResolution>();
    final _Resolver resolver = _Resolver()..pending = held;
    final LiveScanTracker tracker = LiveScanTracker(resolver: resolver);
    addTearDown(tracker.dispose);
    final LiveCardDetection previous = _card(.1);
    tracker.update(<LiveCardDetection>[previous]);
    tracker.update(<LiveCardDetection>[previous]);
    await _settle();
    expect(resolver.calls, 1);
    final ScanCrop oldCrop = tracker.tracks.single.crop;
    tracker.suspendObservations();
    expect(tracker.tracks, isEmpty);
    resolver.pending = null;
    final LiveCardDetection current = _card(.6, title: 'Pick Your Poison');
    tracker.update(<LiveCardDetection>[current]);
    tracker.update(<LiveCardDetection>[current]);
    await _settle();
    expect(resolver.calls, 2);
    expect(tracker.tracks.single.resolution!.hints.names, <String>[
      'Pick Your Poison',
    ]);
    held.complete(_savedRead(oldCrop));
    await _settle();
    expect(tracker.tracks.single.resolution!.hints.names, <String>[
      'Pick Your Poison',
    ]);
    expect(tracker.tracks.single.resolving, isFalse);
    expect(tracker.tracks.single.hasCatalogMatch, isFalse);
  });

  test('automatic completion tolerates one glare frame and exposure changes, but repeated appearance replacement admits an identical new copy', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[card]);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 1);
    final ScanCrop saved = tracker.tracks.single.crop;
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      1,
    );
    final String id = tracker.tracks.single.id;
    for (int index = 0; index < 3; index++) {
      now = now.add(const Duration(milliseconds: 250));
      tracker.update(
        <LiveCardDetection>[],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _appearance(id, card.corners),
        ],
      );
    }
    tracker.update(
      <LiveCardDetection>[],
      appearanceSamplingSupported: true,
      appearanceSamples: <LiveCardAppearanceSample>[
        _appearance(id, card.corners, reversed: true),
      ],
    );
    expect(tracker.isCompleted(card.corners), isTrue);
    tracker.update(
      <LiveCardDetection>[],
      appearanceSamplingSupported: true,
      appearanceSamples: <LiveCardAppearanceSample>[
        _appearance(id, card.corners, gain: .8),
      ],
    );
    expect(tracker.isCompleted(card.corners), isTrue);
    for (int index = 0; index < 3; index++) {
      now = now.add(const Duration(milliseconds: 300));
      tracker.update(
        <LiveCardDetection>[],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _appearance(id, card.corners, present: false, reversed: true),
        ],
      );
    }
    expect(tracker.isSaved(card.corners), isFalse);
    tracker.update(<LiveCardDetection>[card]);
    tracker.update(<LiveCardDetection>[card]);
    expect(tracker.eligibleTracks.single.id, isNot(id));
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      0,
      reason: 'The old photo cannot identify a replacement, even an identical printed copy.',
    );
    expect(tracker.rememberSavedCrop(saved, capture), isFalse);
  });

  test('a repeated empty tabletop releases completion but saturated glare without geometry does not', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    tracker.update(<LiveCardDetection>[card]);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    tracker.markCaptured(capture);
    final ScanCrop saved = tracker.tracks.single.crop;
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      1,
    );
    final String id = tracker.tracks.single.id;
    for (int index = 0; index < 3; index++) {
      now = now.add(const Duration(milliseconds: 250));
      tracker.update(
        <LiveCardDetection>[],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          _appearance(id, card.corners),
        ],
      );
    }
    for (int index = 0; index < 4; index++) {
      now = now.add(const Duration(milliseconds: 500));
      tracker.update(
        <LiveCardDetection>[],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          LiveCardAppearanceSample(
            id: id,
            corners: card.corners,
            present: false,
            values: List<double>.filled(288, 1),
          ),
        ],
      );
    }
    expect(tracker.isSaved(card.corners), isTrue);
    tracker.update(
      <LiveCardDetection>[],
      appearanceSamplingSupported: true,
      appearanceSamples: <LiveCardAppearanceSample>[
        _appearance(id, card.corners),
      ],
    );
    for (int index = 0; index < 4; index++) {
      now = now.add(const Duration(milliseconds: 500));
      tracker.update(
        <LiveCardDetection>[],
        appearanceSamplingSupported: true,
        appearanceSamples: <LiveCardAppearanceSample>[
          LiveCardAppearanceSample(
            id: id,
            corners: card.corners,
            present: false,
            values: List<double>.filled(288, .35),
          ),
        ],
      );
    }
    expect(tracker.isSaved(card.corners), isFalse);
    tracker.update(<LiveCardDetection>[card]);
    tracker.update(<LiveCardDetection>[card]);
    expect(tracker.eligibleTracks, hasLength(1));
  });

  test('saved review receipts block automatic recapture without excluding OCR or claiming identification', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
    tracker.beginCapture();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 0);
    tracker.update(<LiveCardDetection>[card]);
    tracker.update(<LiveCardDetection>[card]);
    final ScanCrop saved = tracker.tracks.single.crop;
    expect(
      tracker.rememberSavedCrop(saved, capture),
      isTrue,
      reason: 'A fresh uniquely proven card discovered after shutter can bind its actual owned photo.',
    );
    expect(tracker.savedFootprints, hasLength(1));
    expect(tracker.completedFootprints, isEmpty);
    expect(tracker.isSaved(card.corners), isTrue);
    expect(tracker.isCompleted(card.corners), isFalse);
    expect(tracker.eligibleTracks, isEmpty);
    expect(tracker.tracks.single.capturedIdentified, isFalse);
    tracker.beginCapture();
    for (int second = 0; second < 40; second++) {
      now = now.add(const Duration(seconds: 1));
      tracker.update(
        <LiveCardDetection>[card],
        currentGeometry: <List<ScanPoint>>[card.corners],
      );
    }
    expect(tracker.isSaved(card.corners), isTrue);
    expect(tracker.eligibleTracks, isEmpty);
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      1,
      reason: 'A continuously observed yellow receipt survives both another group and slow saved lookup.',
    );
    expect(tracker.isCompleted(card.corners), isTrue);
    tracker.rearmCaptured();
    expect(tracker.savedFootprints, isEmpty);
    expect(
      tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
      0,
    );
  });

  test('actual supported photo can identify a uniquely proven card discovered after shutter in automatic mode only', () {
    for (final bool automatic in <bool>[false, true]) {
      final LiveScanTracker tracker = LiveScanTracker(
        resolver: _Resolver(),
        retireIdentified: automatic,
      );
      addTearDown(tracker.dispose);
      tracker.beginCapture();
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      expect(tracker.markCaptured(capture), 0);
      final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
      tracker.update(<LiveCardDetection>[card]);
      final ScanCrop saved = tracker.tracks.single.crop;
      expect(
        tracker.identifyCaptured(saved, _savedRead(saved), capture: capture),
        automatic ? 1 : 0,
      );
      expect(tracker.isCompleted(card.corners), automatic);
    }
  });

  test('automatic saved-current binding rejects weak geometry, ambiguous copies, replacements and foreign owners', () {
    for (final String variant in <String>[
      'weak',
      'copy',
      'replacement',
      'printing',
      'foreign',
      'removed',
    ]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      final LiveScanTracker foreign = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(foreign.dispose);
      final LiveCardDetection card = _card(.1, footer: '001 M21 EN');
      tracker.beginCapture();
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      expect(tracker.markCaptured(capture), 0);
      final LiveCaptureSnapshot foreignCapture = foreign.snapshotCapture();
      foreign.markCaptured(foreignCapture);
      tracker.update(<LiveCardDetection>[
        variant == 'weak'
            ? LiveCardDetection(confidence: 1, corners: card.corners)
            : variant == 'replacement'
            ? _card(.1, title: 'Counterspell', footer: '001 M21 EN')
            : variant == 'printing'
            ? _card(.1, footer: '002 M21 EN')
            : card,
        if (variant == 'copy') card,
      ]);
      final ScanCrop saved = ScanCrop(
        imagePath: '',
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: card.corners,
        lines: card.lines,
      );
      if (variant == 'removed') {
        tracker.update(<LiveCardDetection>[]);
        now = now.add(const Duration(seconds: 2));
        tracker.update(<LiveCardDetection>[]);
        tracker.update(<LiveCardDetection>[card]);
      }
      final LiveCaptureSnapshot authority = variant == 'foreign'
          ? foreignCapture
          : capture;
      expect(
        tracker.rememberSavedCrop(saved, authority),
        isFalse,
        reason: variant,
      );
      expect(
        tracker.identifyCaptured(saved, _savedRead(saved), capture: authority),
        0,
        reason: variant,
      );
      expect(tracker.savedFootprints, isEmpty, reason: variant);
    }
  });

  test('visible completion capacity pauses admission without evicting any owned card, then physical removal frees capacity', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final List<LiveCardDetection> cards = <LiveCardDetection>[
      for (int index = 0; index < 8; index++)
        _card(
          .025 + (index % 4) * .25,
          y: .025 + (index ~/ 4) * .5,
          title: 'Card $index',
          footer: '001 M21 EN',
        ),
    ];
    tracker.update(cards);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 8);
    final List<ScanCrop> saved = tracker.tracks
        .map((LiveScanTrack track) => track.crop)
        .toList();
    for (final ScanCrop crop in saved) {
      expect(
        tracker.identifyCaptured(crop, _savedRead(crop), capture: capture),
        1,
      );
    }
    expect(tracker.savedFootprints, hasLength(8));
    expect(tracker.completionCapacityAvailable, isFalse);
    now = now.add(const Duration(seconds: 4));
    tracker.update(
      cards,
      currentGeometry: cards.map((LiveCardDetection card) => card.corners),
    );
    expect(tracker.tracks, isEmpty);
    expect(tracker.savedFootprints, hasLength(8));
    expect(tracker.snapshotCapture().isEmpty, isTrue);
    tracker.update(<LiveCardDetection>[]);
    now = now.add(const Duration(seconds: 2));
    tracker.update(<LiveCardDetection>[]);
    expect(tracker.savedFootprints, isEmpty);
    expect(tracker.completionCapacityAvailable, isTrue);
    tracker.update(<LiveCardDetection>[cards.first]);
    tracker.update(<LiveCardDetection>[cards.first]);
    expect(tracker.eligibleTracks, hasLength(1));
  });

  test('actual titleless Circle ACK maps its saved one-character rules repair only within that unique tight capture footprint', () {
    final ScanCrop receipt = _recordedCircle27Ack();
    final ScanCrop actualSaved = _recordedCircle27Saved();
    for (final String variant in <String>[
      'actual',
      'red',
      'printing',
      'one-rule',
      'two-errors',
      'shift',
      'below-.85',
      'copy',
      'no-ack',
      'foreign-cycle',
      'stale',
    ]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
      );
      addTearDown(tracker.dispose);
      final ScanCrop original = ScanCrop(
        imagePath: '',
        width: receipt.width,
        height: receipt.height,
        rectified: receipt.rectified,
        sourceCorners: receipt.sourceCorners,
        warnings: receipt.warnings,
        lines: <ScanTextLine>[
          ...receipt.lines,
          if (variant == 'printing')
            const ScanTextLine(
              text: '001 M21 EN',
              confidence: 1,
              bounds: ScanBounds(.05, .91, .4, .025),
            ),
        ],
      );
      tracker.update(<LiveCardDetection>[
        _cropDetection(original),
        if (variant == 'copy') _cropDetection(original),
      ]);
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      expect(capture.count, variant == 'copy' ? 2 : 1);
      if (variant != 'no-ack') {
        expect(tracker.markCaptured(capture), variant == 'copy' ? 2 : 1);
      }
      if (variant == 'foreign-cycle') {
        tracker.beginCapture();
      }
      if (variant == 'stale') {
        now = now.add(const Duration(seconds: 2));
      }
      final ScanCrop saved = ScanCrop(
        imagePath: '',
        width: actualSaved.width,
        height: actualSaved.height,
        rectified: actualSaved.rectified,
        warnings: actualSaved.warnings,
        sourceCorners: <ScanPoint>[
          for (final ScanPoint point in actualSaved.sourceCorners)
            ScanPoint(
              variant == 'below-.85'
                  ? .33864036947488785 + (point.x - .33864036947488785) * 1.015
                  : point.x + (variant == 'shift' ? .035 : 0),
              variant == 'below-.85'
                  ? .6998691633343697 + (point.y - .6998691633343697) * 1.015
                  : point.y,
            ),
        ],
        lines: <ScanTextLine>[
          for (final ScanTextLine line in actualSaved.lines)
            if (variant != 'one-rule' || !line.text.startsWith('from one'))
              ScanTextLine(
                text: variant == 'red'
                    ? line.text
                          .replaceAll('blue', 'red')
                          .replaceAll('Blue', 'Red')
                    : variant == 'two-errors' &&
                          line.text.startsWith('from one')
                    ? line.text.replaceAll('Ii a', 'Ix z')
                    : line.text,
                confidence: line.confidence,
                glyphHeight: line.glyphHeight,
                bounds: line.bounds,
              ),
          if (variant == 'printing')
            const ScanTextLine(
              text: '002 M21 EN',
              confidence: 1,
              bounds: ScanBounds(.05, .91, .4, .025),
            ),
        ],
      );
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_Card(), const <ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.rulesTextMatch,
          }),
        ],
        hints: ScanHints.fromCrop(saved),
        status: ScanResolutionStatus.needsReview,
      );
      expect(
        tracker.identifyCaptured(saved, read),
        0,
        reason: 'Generic body matching stays exact: $variant',
      );
      expect(
        tracker.identifyCaptured(saved, read, capture: capture),
        variant == 'actual' ? 1 : 0,
        reason: variant,
      );
      expect(
        tracker.tracks
            .where((LiveScanTrack track) => track.capturedIdentified)
            .length,
        variant == 'actual' ? 1 : 0,
        reason: variant,
      );
      if (variant == 'actual') {
        tracker.update(<LiveCardDetection>[
          LiveCardDetection(
            confidence: 1,
            corners: receipt.sourceCorners,
            lines: const <ScanTextLine>[
              ScanTextLine(
                text: 'Rune of Protection: Blue',
                confidence: 1,
                bounds: ScanBounds(.1, .04, .7, .03),
              ),
            ],
          ),
        ]);
        expect(tracker.tracks.single.capturedIdentified, isFalse);
      }
    }
  });

  test('actual widened Nevermore receipt corrects only against its acknowledged frozen proof and fresh unique geometry', () {
    final ScanCrop proof = _recordedNevermore27Proof();
    final ScanCrop actualSaved = _recordedNevermore27Saved();
    final List<ScanPoint> widened = <ScanPoint>[
      const ScanPoint(.6211730475146445, .5759589210190605),
      const ScanPoint(.8922468874135026, .5981765863893463),
      const ScanPoint(.9881380782636194, .8445666413470022),
      const ScanPoint(.6101351305148813, .8063263460794382),
    ];
    for (final String variant in <String>[
      'actual',
      'no-ack',
      'foreign-cycle',
      'stale',
      'copy',
      'printing',
      'replacement',
      'desk',
    ]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
      );
      addTearDown(tracker.dispose);
      final ScanCrop original = ScanCrop(
        imagePath: '',
        width: proof.width,
        height: proof.height,
        rectified: proof.rectified,
        warnings: proof.warnings,
        sourceCorners: proof.sourceCorners,
        lines: <ScanTextLine>[
          ...proof.lines,
          if (variant == 'printing')
            const ScanTextLine(
              text: '001 M21 EN',
              confidence: 1,
              bounds: ScanBounds(.05, .91, .4, .025),
            ),
        ],
      );
      tracker.update(<LiveCardDetection>[
        _cropDetection(original),
        if (variant == 'copy') _cropDetection(original),
      ]);
      for (int index = 0; index < 4; index++) {
        now = now.add(const Duration(milliseconds: 100));
        tracker.update(<LiveCardDetection>[
          LiveCardDetection(
            confidence: .9,
            corners: widened,
            lines: const <ScanTextLine>[],
          ),
          if (variant == 'copy')
            LiveCardDetection(
              confidence: .9,
              corners: widened,
              lines: const <ScanTextLine>[],
            ),
        ]);
      }
      final LiveCaptureSnapshot capture = tracker.snapshotCapture(
        currentGeometry: <List<ScanPoint>>[widened],
      );
      expect(capture.count, variant == 'copy' ? 2 : 1, reason: variant);
      if (variant != 'no-ack') {
        expect(tracker.markCaptured(capture), variant == 'copy' ? 2 : 1);
      }
      if (variant == 'foreign-cycle') {
        tracker.beginCapture();
      }
      if (variant == 'stale') {
        now = now.add(const Duration(seconds: 2));
      }
      if (variant == 'replacement') {
        tracker.update(<LiveCardDetection>[
          LiveCardDetection(
            confidence: 1,
            corners: widened,
            lines: const <ScanTextLine>[
              ScanTextLine(
                text: 'Lightning Bolt',
                confidence: 1,
                bounds: ScanBounds(.1, .04, .7, .03),
              ),
            ],
          ),
        ]);
      }
      if (variant == 'desk') {
        tracker.update(<LiveCardDetection>[
          LiveCardDetection(
            confidence: .9,
            corners: const <ScanPoint>[
              ScanPoint(.5, .45),
              ScanPoint(1, .45),
              ScanPoint(1, .95),
              ScanPoint(.5, .95),
            ],
            lines: const <ScanTextLine>[],
          ),
        ]);
      }
      final ScanCrop saved = ScanCrop(
        imagePath: '',
        width: actualSaved.width,
        height: actualSaved.height,
        rectified: actualSaved.rectified,
        sourceCorners: actualSaved.sourceCorners,
        warnings: actualSaved.warnings,
        lines: <ScanTextLine>[
          ...actualSaved.lines,
          if (variant == 'printing')
            const ScanTextLine(
              text: '002 M21 EN',
              confidence: 1,
              bounds: ScanBounds(.05, .91, .4, .025),
            ),
        ],
      );
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_Card(), const <ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.rulesTextMatch,
          }),
        ],
        hints: ScanHints.fromCrop(saved),
        status: ScanResolutionStatus.needsReview,
      );
      expect(
        tracker.identifyCaptured(saved, read),
        0,
        reason: 'Ordinary geometry remains strict: $variant',
      );
      expect(
        tracker.identifyCaptured(saved, read, capture: capture),
        variant == 'actual' ? 1 : 0,
        reason: variant,
      );
      expect(
        tracker.tracks
            .where((LiveScanTrack track) => track.capturedIdentified)
            .length,
        variant == 'actual' ? 1 : 0,
        reason: variant,
      );
      if (variant == 'actual') {
        expect(
          tracker.tracks.single.corners
              .map((ScanPoint point) => (point.x, point.y))
              .toList(),
          saved.sourceCorners
              .map((ScanPoint point) => (point.x, point.y))
              .toList(),
        );
      }
    }
  });

  test('actual geometry-only art and body panels keep the proven Bats perimeter through capture without extra receipts', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    final ScanCrop proof = _recordedBats26Proof();
    final ScanCrop weak = _recordedBats25Inset();
    tracker.update(<LiveCardDetection>[
      _cropDetection(proof),
      _cropDetection(weak),
    ]);
    final String id = tracker.tracks
        .firstWhere(
          (LiveScanTrack track) =>
              ScanHints.fromCrop(track.crop).names.contains('Mirkwood Bats'),
        )
        .id;
    final int token = tracker.beginCapture();
    final List<ScanPoint> art = <ScanPoint>[
      const ScanPoint(.6528424620628357, .22816991806030273),
      const ScanPoint(.8558733463287354, .22816991806030273),
      const ScanPoint(.8558733463287354, .33252060413360596),
      const ScanPoint(.6528424620628357, .33252060413360596),
    ];
    final List<ScanPoint> body = <ScanPoint>[
      const ScanPoint(.646956741809845, .3313347101211548),
      const ScanPoint(.8275073766708374, .3313347101211548),
      const ScanPoint(.8275073766708374, .41467469930648804),
      const ScanPoint(.646956741809845, .41467469930648804),
    ];
    for (int index = 0; index < 14; index++) {
      now = now.add(const Duration(seconds: 1));
      tracker.update(
        <LiveCardDetection>[
          LiveCardDetection(
            confidence: .9,
            corners: art,
            lines: const <ScanTextLine>[],
          ),
          LiveCardDetection(
            confidence: .9,
            corners: body,
            lines: const <ScanTextLine>[],
          ),
        ],
        currentGeometry: <List<ScanPoint>>[art, body],
      );
      final LiveScanTrack track = tracker.tracks.singleWhere(
        (LiveScanTrack track) => track.id == id,
      );
      expect(
        track.corners.map((ScanPoint point) => (point.x, point.y)).toList(),
        proof.sourceCorners
            .map((ScanPoint point) => (point.x, point.y))
            .toList(),
      );
      expect(track.crop.lines, proof.lines);
    }
    expect(
      tracker.recentFocusCrops,
      isEmpty,
      reason: 'Geometry never renews OCR proof age',
    );
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[art, body],
    );
    expect(capture.count, 1);
    expect(
      capture.crops.single.sourceCorners
          .map((ScanPoint point) => (point.x, point.y))
          .toList(),
      proof.sourceCorners.map((ScanPoint point) => (point.x, point.y)).toList(),
    );
    expect(tracker.markCaptured(capture), 1);
    tracker.endCapture(token, resumeTracking: true);
    final ScanResolution read = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Card(), const <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.rulesTextMatch,
        }),
      ],
      hints: ScanHints.fromCrop(proof),
      status: ScanResolutionStatus.needsReview,
    );
    expect(tracker.identifyCaptured(proof, read, capture: capture), 1);
    expect(
      tracker.tracks
          .singleWhere((LiveScanTrack track) => track.id == id)
          .capturedIdentified,
      isTrue,
    );
  });

  test('panel geometry cannot retain an expired ordinary proof or collapse two independently proven physical copies', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    final ScanCrop proof = _recordedBats26Proof();
    tracker.update(<LiveCardDetection>[_cropDetection(proof)]);
    now = now.add(const Duration(seconds: 7));
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: .9,
        corners: const <ScanPoint>[
          ScanPoint(.65, .23),
          ScanPoint(.85, .23),
          ScanPoint(.85, .34),
          ScanPoint(.65, .34),
        ],
        lines: const <ScanTextLine>[],
      ),
    ]);
    expect(tracker.tracks, isEmpty);
    tracker.clear();
    final ScanCrop other = ScanCrop(
      imagePath: '',
      width: proof.width,
      height: proof.height,
      rectified: proof.rectified,
      lines: proof.lines,
      warnings: proof.warnings,
      sourceCorners: <ScanPoint>[
        for (final ScanPoint point in proof.sourceCorners)
          ScanPoint(point.x - .3, point.y),
      ],
    );
    tracker.update(<LiveCardDetection>[
      _cropDetection(proof),
      _cropDetection(other),
      _cropDetection(_recordedBats25Inset()),
    ]);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(capture.count, 2);
    expect(tracker.markCaptured(capture), 2);
    expect(
      tracker.tracks.where((LiveScanTrack track) => track.captured).length,
      2,
    );
  });

  test('actual same-row duplicate title passes preserve captured Circle through null-type OCR without accepting another name or printing', () {
    final ScanCrop proof = _recordedCircle26Proof();
    final ScanCrop late = _recordedCircle26Late();
    for (final String variant in <String>[
      'actual',
      'separate-rows',
      'red',
      'rune',
      'printing',
      'one-rule',
    ]) {
      final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
      addTearDown(tracker.dispose);
      final List<ScanTextLine> oldLines = <ScanTextLine>[
        for (final ScanTextLine line in proof.lines)
          ScanTextLine(
            text: line.text,
            confidence: line.confidence,
            glyphHeight: line.glyphHeight,
            bounds: variant == 'separate-rows' && line.text.startsWith('Sirele')
                ? ScanBounds(
                    line.bounds.x,
                    .25,
                    line.bounds.width,
                    line.bounds.height,
                  )
                : line.bounds,
          ),
        if (variant == 'printing')
          const ScanTextLine(
            text: '001 M21 EN',
            confidence: 1,
            bounds: ScanBounds(.05, .91, .4, .025),
          ),
      ];
      final ScanCrop original = ScanCrop(
        imagePath: '',
        width: proof.width,
        height: proof.height,
        rectified: true,
        sourceCorners: proof.sourceCorners,
        lines: oldLines,
        warnings: proof.warnings,
      );
      tracker.update(<LiveCardDetection>[_cropDetection(original)]);
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      expect(tracker.markCaptured(capture), 1);
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_Card(), const <ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.rulesTextMatch,
          }),
        ],
        hints: ScanHints.fromCrop(original),
        status: ScanResolutionStatus.needsReview,
      );
      expect(tracker.identifyCaptured(original, read, capture: capture), 1);
      final ScanResolution saved = tracker.tracks.single.resolution!;
      final List<ScanTextLine> lines = <ScanTextLine>[
        for (final ScanTextLine line in late.lines)
          if (variant != 'one-rule' || !line.text.startsWith('deals damage'))
            ScanTextLine(
              text: variant == 'red'
                  ? line.text.replaceAll('Blue', 'Red').replaceAll('Bhe', 'Red')
                  : variant == 'rune' && line.bounds.y < .13
                  ? 'Rune of Protection: Blue'
                  : line.text,
              confidence: line.confidence,
              glyphHeight: line.glyphHeight,
              bounds:
                  variant == 'separate-rows' && line.text.startsWith('Cirele')
                  ? ScanBounds(
                      line.bounds.x,
                      .25,
                      line.bounds.width,
                      line.bounds.height,
                    )
                  : line.bounds,
            ),
        if (variant == 'printing')
          const ScanTextLine(
            text: '002 M21 EN',
            confidence: 1,
            bounds: ScanBounds(.05, .91, .4, .025),
          ),
      ];
      tracker.update(<LiveCardDetection>[
        LiveCardDetection(
          confidence: 1,
          corners: late.sourceCorners,
          warnings: late.warnings,
          lines: lines,
        ),
      ]);
      expect(
        tracker.tracks.single.capturedIdentified,
        variant == 'actual',
        reason: variant,
      );
      if (variant == 'actual') {
        expect(tracker.tracks.single.resolution, same(saved));
      }
    }
  });

  test('clipped-prefix grace cannot mask a frozen printing conflict after unreadable OCR', () {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    final ScanCrop original = _recordedCircle24Captured();
    final ScanCrop clipped = _recordedCircle24ClippedLater();
    const ScanTextLine receiptFooter = ScanTextLine(
      text: '001 M21 EN',
      confidence: 1,
      bounds: ScanBounds(.05, .91, .4, .025),
    );
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: original.sourceCorners,
        warnings: original.warnings,
        lines: <ScanTextLine>[...original.lines, receiptFooter],
      ),
    ]);
    expect(tracker.markCaptured(tracker.snapshotCapture()), 1);
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: original.sourceCorners,
        warnings: const <String>['incomplete_card'],
        lines: const <ScanTextLine>[
          ScanTextLine(
            text: 'Unreadable lower corner',
            confidence: .7,
            bounds: ScanBounds(.1, .75, .5, .03),
          ),
        ],
      ),
    ]);
    expect(tracker.tracks.single.captured, isTrue);
    final LiveCardDetection replacement = LiveCardDetection(
      confidence: 1,
      corners: original.sourceCorners,
      warnings: clipped.warnings,
      lines: <ScanTextLine>[
        ...clipped.lines,
        const ScanTextLine(
          text: '002 M21 EN',
          confidence: .8,
          bounds: ScanBounds(.05, .91, .4, .025),
        ),
      ],
    );
    expect(
      ScanHints.fromCrop(
        ScanCrop(
          imagePath: '',
          width: 1000,
          height: 1400,
          rectified: false,
          sourceCorners: replacement.corners,
          warnings: replacement.warnings,
          lines: replacement.lines,
        ),
      ).collectorNumber,
      '002',
    );
    tracker.update(<LiveCardDetection>[replacement]);
    expect(tracker.tracks.single.captured, isFalse);
  });

  test('actual six-edit Circle title drift requires tight same-card geometry, type, color and two rules anchors', () {
    final ScanCrop receipt = _recordedCircle25Ack();
    final ScanCrop actualSaved = _recordedCircle25Saved();
    for (final String variant in <String>[
      'actual',
      'red',
      'rune',
      'shift',
      'one-rule',
      'type',
      'printing',
    ]) {
      final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
      addTearDown(tracker.dispose);
      final List<ScanTextLine> receiptLines = <ScanTextLine>[
        ...receipt.lines,
        if (variant == 'printing')
          const ScanTextLine(
            text: '001 M21 EN',
            confidence: 1,
            bounds: ScanBounds(.05, .91, .4, .025),
          ),
      ];
      tracker.update(<LiveCardDetection>[
        LiveCardDetection(
          confidence: 1,
          corners: receipt.sourceCorners,
          lines: receiptLines,
          warnings: receipt.warnings,
        ),
      ]);
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      expect(tracker.markCaptured(capture), 1);
      final ScanCrop saved = ScanCrop(
        imagePath: '',
        width: actualSaved.width,
        height: actualSaved.height,
        rectified: actualSaved.rectified,
        warnings: actualSaved.warnings,
        sourceCorners: <ScanPoint>[
          for (final ScanPoint point in actualSaved.sourceCorners)
            ScanPoint(point.x + (variant == 'shift' ? .035 : 0), point.y),
        ],
        lines: <ScanTextLine>[
          for (final ScanTextLine line in actualSaved.lines)
            if (variant != 'one-rule' || !line.text.startsWith('deals damage'))
              ScanTextLine(
                text: variant == 'red'
                    ? line.text.replaceAll('Blue', 'Red')
                    : variant == 'rune' &&
                          line.text == 'Crele of Protections Blue'
                    ? 'Rune of Protection: Blue'
                    : variant == 'type' && line.text == 'Enchantment'
                    ? 'Artifact'
                    : line.text,
                confidence: line.confidence,
                glyphHeight: line.glyphHeight,
                bounds: line.bounds,
              ),
          if (variant == 'printing')
            const ScanTextLine(
              text: '002 M21 EN',
              confidence: 1,
              bounds: ScanBounds(.05, .91, .4, .025),
            ),
        ],
      );
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_Card(), const <ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.rulesTextMatch,
          }),
        ],
        hints: ScanHints.fromCrop(saved),
        status: ScanResolutionStatus.needsReview,
      );
      expect(
        tracker.identifyCaptured(saved, read, capture: capture),
        variant == 'actual' ? 1 : 0,
        reason: variant,
      );
      expect(
        tracker.tracks
            .where((LiveScanTrack track) => track.capturedIdentified)
            .length,
        variant == 'actual' ? 1 : 0,
        reason: variant,
      );
    }
  });

  test('unreadable desk proposals cannot crowd a recently proven card or its durable receipt at the eight-track cap', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    final ScanCrop proof = _recordedPartialProof();
    tracker.update(<LiveCardDetection>[_cropDetection(proof)]);
    final String id = tracker.tracks.single.id;
    tracker.beginCapture();
    now = now.add(const Duration(seconds: 7));
    final List<LiveCardDetection> desk = <LiveCardDetection>[
      for (int index = 0; index < 8; index++)
        LiveCardDetection(
          confidence: .9,
          corners: <ScanPoint>[
            ScanPoint((index % 4) * .09, (index ~/ 4) * .09),
            ScanPoint((index % 4) * .09 + .045, (index ~/ 4) * .09),
            ScanPoint((index % 4) * .09 + .045, (index ~/ 4) * .09 + .045),
            ScanPoint((index % 4) * .09, (index ~/ 4) * .09 + .045),
          ],
          lines: const <ScanTextLine>[],
        ),
    ];
    tracker.update(desk);
    expect(tracker.tracks.single.id, id);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 1);
    tracker.update(desk.reversed.toList());
    expect(tracker.tracks.single.id, id);
    expect(tracker.tracks.single.captured, isTrue);
  });

  test('capture-bound saved proof displaces hidden geometry rather than failing capacity recovery', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    final ScanCrop proof = _recordedPartialProof();
    tracker.update(<LiveCardDetection>[_cropDetection(proof)]);
    now = now.add(const Duration(seconds: 7));
    tracker.update(const <LiveCardDetection>[]);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(capture.isEmpty, isTrue);
    expect(tracker.markCaptured(capture), 0);
    now = now.add(const Duration(milliseconds: 100));
    tracker.update(
      <LiveCardDetection>[
        for (int index = 0; index < 8; index++)
          LiveCardDetection(
            confidence: .9,
            corners: <ScanPoint>[
              ScanPoint((index % 4) * .09, (index ~/ 4) * .09),
              ScanPoint((index % 4) * .09 + .045, (index ~/ 4) * .09),
              ScanPoint((index % 4) * .09 + .045, (index ~/ 4) * .09 + .045),
              ScanPoint((index % 4) * .09, (index ~/ 4) * .09 + .045),
            ],
            lines: const <ScanTextLine>[],
          ),
      ],
      currentGeometry: <List<ScanPoint>>[proof.sourceCorners],
    );
    final ScanResolution read = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Card(), const <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.rulesTextMatch,
        }),
      ],
      hints: ScanHints.fromCrop(proof),
      status: ScanResolutionStatus.needsReview,
    );
    expect(tracker.identifyCaptured(proof, read, capture: capture), 1);
    expect(tracker.tracks.single.capturedIdentified, isTrue);
  });

  test('actual rotated Bats ACK inset upgrades to its unique full saved identity without a second physical receipt', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    final ScanCrop full = _recordedBats25Full();
    final ScanCrop inset = _recordedBats25Inset();
    tracker.update(<LiveCardDetection>[_cropDetection(full)]);
    now = now.add(const Duration(seconds: 7));
    tracker.update(<LiveCardDetection>[_cropDetection(inset)]);
    final String insetId = tracker.tracks.single.id;
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[inset.sourceCorners],
    );
    expect(capture.count, 1);
    expect(tracker.markCaptured(capture), 1);
    now = now.add(const Duration(milliseconds: 100));
    tracker.update(<LiveCardDetection>[_cropDetection(full)]);
    expect(tracker.tracks.length, 2);
    final ScanResolution read = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Card(), const <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.rulesTextMatch,
        }),
      ],
      hints: ScanHints.fromCrop(full),
      status: ScanResolutionStatus.needsReview,
    );
    expect(tracker.identifyCaptured(full, read, capture: capture), 1);
    expect(tracker.tracks.single.id, insetId);
    expect(tracker.tracks.single.capturedIdentified, isTrue);
    expect(
      ScanHints.fromCrop(tracker.tracks.single.crop).names,
      contains('Mirkwood Bats'),
    );
  });

  test('an inset receipt cannot absorb unrelated names, printing changes, or two full physical copies', () {
    final ScanCrop full = _recordedBats25Full();
    final ScanCrop inset = _recordedBats25Inset();
    for (final String variant in <String>[
      'name',
      'printing',
      'two-copies',
      'no-ack',
      'new-scene',
    ]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
      );
      addTearDown(tracker.dispose);
      tracker.update(<LiveCardDetection>[_cropDetection(full)]);
      now = now.add(const Duration(seconds: 7));
      tracker.update(<LiveCardDetection>[_cropDetection(inset)]);
      final LiveCaptureSnapshot capture = tracker.snapshotCapture(
        currentGeometry: <List<ScanPoint>>[inset.sourceCorners],
      );
      if (variant != 'no-ack') expect(tracker.markCaptured(capture), 1);
      if (variant == 'new-scene') tracker.clear();
      final ScanCrop changed = ScanCrop(
        imagePath: '',
        width: full.width,
        height: full.height,
        rectified: full.rectified,
        sourceCorners: full.sourceCorners,
        warnings: full.warnings,
        lines: <ScanTextLine>[
          for (final ScanTextLine line in full.lines)
            ScanTextLine(
              text: variant == 'name' && line.text == 'Mirkwood Bats'
                  ? 'Graveyard Bats'
                  : line.text,
              confidence: line.confidence,
              glyphHeight: line.glyphHeight,
              bounds: line.bounds,
            ),
          if (variant == 'printing')
            const ScanTextLine(
              text: '095 LTR EN',
              confidence: 1,
              bounds: ScanBounds(.05, .91, .4, .025),
            ),
        ],
      );
      now = now.add(const Duration(milliseconds: 100));
      tracker.update(<LiveCardDetection>[
        _cropDetection(changed),
        if (variant == 'two-copies') _cropDetection(changed),
      ]);
      final ScanCrop saved = variant == 'printing'
          ? ScanCrop(
              imagePath: '',
              width: full.width,
              height: full.height,
              rectified: full.rectified,
              sourceCorners: full.sourceCorners,
              warnings: full.warnings,
              lines: <ScanTextLine>[
                ...full.lines,
                const ScanTextLine(
                  text: '096 LTR EN',
                  confidence: 1,
                  bounds: ScanBounds(.05, .91, .4, .025),
                ),
              ],
            )
          : full;
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_Card(), const <ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.rulesTextMatch,
          }),
        ],
        hints: ScanHints.fromCrop(saved),
        status: ScanResolutionStatus.needsReview,
      );
      expect(
        tracker.identifyCaptured(saved, read, capture: capture),
        0,
        reason: variant,
      );
      expect(
        tracker.tracks.where((LiveScanTrack track) => track.capturedIdentified),
        isEmpty,
        reason: variant,
      );
    }
  });

  test('a one-letter title-only focus read cannot release saved Bats, but real replacement can', () {
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection card = _card(
      .1,
      title: 'Mirkwood Bats',
      footer: '0095 LTR EN',
    );
    tracker.update(
      <LiveCardDetection>[card],
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    final ScanCrop saved = tracker.tracks.single.crop;
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    expect(tracker.markCaptured(capture), 1);
    expect(tracker.rememberSavedCrop(saved, capture), isTrue);
    tracker.update(
      <LiveCardDetection>[_card(.1, title: 'Mirkwood Bals')],
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    expect(tracker.isSaved(card.corners), isTrue);
    expect(tracker.tracks.single.captured, isTrue);
    tracker.update(
      <LiveCardDetection>[_card(.1, title: 'Lightning Bolt')],
      currentGeometry: <List<ScanPoint>>[card.corners],
    );
    expect(tracker.isSaved(card.corners), isFalse);
  });

  test('verified body-only photo retains an owned yellow receipt without identifying a card', () {
    final List<ScanPoint> corners = _card(.1).corners;
    final ScanCrop body = ScanCrop(
      imagePath: 'owned-body.jpg',
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: corners,
      warnings: const <String>[
        'incomplete_card',
        'orientation_ensemble',
        'geometry_adjusted',
      ],
      lines: const <ScanTextLine>[
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
          text: 'deals damage to you more than',
          confidence: 1,
          bounds: ScanBounds(.14, .71, .67, .04),
        ),
        ScanTextLine(
          text: 'once in a turn, you may pay 1',
          confidence: 1,
          bounds: ScanBounds(.14, .75, .64, .04),
        ),
        ScanTextLine(
          text: 'each time to prevent the damage.',
          confidence: 1,
          bounds: ScanBounds(.14, .79, .72, .04),
        ),
      ],
    );
    expect(hasVerifiedSavedBodyLayout(body), isTrue);
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(tracker.dispose);
    tracker.update(
      <LiveCardDetection>[
        LiveCardDetection(
          confidence: 1,
          corners: corners,
          lines: <ScanTextLine>[
            const ScanTextLine(
              text: 'Circle of Protection: Blue',
              confidence: 1,
              bounds: ScanBounds(.1, .04, .7, .03),
            ),
            ...body.lines,
          ],
        ),
      ],
      currentGeometry: <List<ScanPoint>>[corners],
    );
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[corners],
    );
    expect(
      tracker.rememberSavedCrop(body, capture),
      isFalse,
      reason: 'A photo must first be acknowledged.',
    );
    expect(tracker.markCaptured(capture), 1);
    expect(tracker.rememberSavedCrop(body, capture), isTrue);
    expect(tracker.isSaved(corners), isTrue);
    expect(tracker.isCompleted(corners), isFalse);
    expect(tracker.tracks.single.capturedIdentified, isFalse);
    expect(tracker.eligibleTracks, isEmpty);
    final LiveScanTracker foreign = LiveScanTracker(
      resolver: _Resolver(),
      retireIdentified: true,
    );
    addTearDown(foreign.dispose);
    expect(foreign.rememberSavedCrop(body, capture), isFalse);
  });

  test(
    'body-only saved identification cannot choose between different card names',
    () {
      for (final bool ambiguous in <bool>[true, false]) {
        final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
        addTearDown(tracker.dispose);
        final ScanCrop proof = _recordedPartialProof();
        tracker.update(<LiveCardDetection>[_cropDetection(proof)]);
        final LiveCaptureSnapshot capture = tracker.snapshotCapture();
        expect(tracker.markCaptured(capture), 1);
        final ScanResolution read = ScanResolution(
          candidates: <ScanCandidate>[
            ScanCandidate(
              _NamedCard('Circle of Protection: Blue'),
              const <ScanEvidence>{ScanEvidence.rulesTextMatch},
            ),
            ScanCandidate(
              _NamedCard(
                ambiguous
                    ? 'Circle of Protection: Red'
                    : 'Circle of Protection: Blue',
              ),
              const <ScanEvidence>{ScanEvidence.rulesTextMatch},
            ),
          ],
          hints: ScanHints.fromCrop(proof),
          status: ScanResolutionStatus.needsReview,
        );
        expect(
          tracker.identifyCaptured(proof, read, capture: capture),
          ambiguous ? 0 : 1,
        );
        expect(tracker.tracks.single.capturedIdentified, !ambiguous);
      }
    },
  );

  test('historical body identity retires only an acknowledged unambiguous saved card', () {
    for (final String variant in <String>[
      'supported',
      'rules-alternative',
      'ambiguous',
      'no-ack',
      'truncated',
      'clipped-proof',
      'ambiguous-proof',
    ]) {
      final LiveScanTracker tracker = LiveScanTracker(
        resolver: _Resolver(),
        retireIdentified: true,
      );
      addTearDown(tracker.dispose);
      final List<ScanPoint> corners = _card(.1).corners;
      final ScanCrop saved = ScanCrop(
        imagePath: 'owned-historical-body.jpg',
        width: 1000,
        height: 1400,
        rectified: true,
        sourceCorners: corners,
        warnings: const <String>[
          'incomplete_card',
          'orientation_ensemble',
          'geometry_adjusted',
        ],
        lines: const <ScanTextLine>[
          ScanTextLine(
            text: 'Enchantment',
            confidence: 1,
            bounds: ScanBounds(.1, .52, .3, .03),
          ),
          ScanTextLine(
            text: '1: Prevent all damage against you',
            confidence: 1,
            bounds: ScanBounds(.1, .61, .7, .04),
          ),
          ScanTextLine(
            text: 'from one blue source. If a source',
            confidence: 1,
            bounds: ScanBounds(.1, .65, .7, .04),
          ),
          ScanTextLine(
            text: 'deals damage to you more than',
            confidence: 1,
            bounds: ScanBounds(.1, .69, .7, .04),
          ),
          ScanTextLine(
            text: 'once in a turn, you may pay 1',
            confidence: 1,
            bounds: ScanBounds(.1, .73, .7, .04),
          ),
          ScanTextLine(
            text: 'each time to prevent the damage.',
            confidence: 1,
            bounds: ScanBounds(.1, .77, .7, .04),
          ),
          ScanTextLine(
            text: 'Illus. Pete Venters',
            confidence: 1,
            bounds: ScanBounds(.1, .88, .3, .025),
          ),
          ScanTextLine(
            text: '© 1995 Wizards of the Coast',
            confidence: 1,
            bounds: ScanBounds(.1, .92, .5, .025),
          ),
        ],
      );
      tracker.update(
        <LiveCardDetection>[
          LiveCardDetection(
            confidence: 1,
            corners: corners,
            lines: <ScanTextLine>[
              const ScanTextLine(
                text: 'Circle of Protection: Blue',
                confidence: 1,
                bounds: ScanBounds(.1, .04, .7, .03),
              ),
              ...saved.lines,
            ],
          ),
        ],
        currentGeometry: <List<ScanPoint>>[corners],
      );
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      if (variant != 'no-ack') expect(tracker.markCaptured(capture), 1);
      const Set<ScanEvidence> evidence = <ScanEvidence>{
        ScanEvidence.rulesKeywordMatch,
        ScanEvidence.typeLineMatch,
        ScanEvidence.illustratorMatch,
        ScanEvidence.copyrightYearMatch,
      };
      final LiveScanTrack capturedTrack = tracker.tracks.single;
      final ScanHints hints = ScanHints.fromCrop(saved);
      final HistoricalBodyIdentityProof? historicalProof =
          variant.endsWith('-proof')
          ? HistoricalBodyIdentityProof(
              name: 'Circle of Protection: Blue',
              bodySignature: jsonEncode(<String, Object?>{
                'type': hints.typeLine,
                'rules': hints.rulesText,
                'illustrators': <String>['pete venters'],
                'years': <int>[1995],
              }),
            )
          : null;
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_NamedCard('Circle of Protection: Blue'), evidence),
          if (variant == 'clipped-proof') ...<ScanCandidate>[
            ScanCandidate(_NamedCard('Circle of Protection: Blue'), evidence),
            ScanCandidate(_NamedCard('Circle of Protection: Blue'), evidence),
          ],
          if (variant == 'ambiguous' || variant == 'ambiguous-proof')
            ScanCandidate(_NamedCard('Rune of Protection: Blue'), evidence),
          if (variant == 'rules-alternative')
            ScanCandidate(
              _NamedCard('Rune of Protection: Blue'),
              const <ScanEvidence>{ScanEvidence.rulesTextMatch},
            ),
        ],
        hints: ScanHints.fromCrop(saved),
        status: ScanResolutionStatus.needsReview,
        hasMore: variant == 'truncated' || variant.endsWith('-proof'),
        historicalBodyIdentityProof: historicalProof,
      );
      expect(
        tracker.identifyCaptured(saved, read, capture: capture),
        variant == 'supported' ||
                variant == 'rules-alternative' ||
                variant == 'clipped-proof'
            ? 1
            : 0,
        reason: variant,
      );
      expect(
        tracker.isCompleted(corners),
        variant == 'supported' ||
            variant == 'rules-alternative' ||
            variant == 'clipped-proof',
        reason: variant,
      );
      if (variant == 'clipped-proof') {
        expect(
          identical(
            capturedTrack.resolution!.historicalBodyIdentityProof,
            historicalProof,
          ),
          isTrue,
        );
        expect(capturedTrack.resolution!.hasMore, isTrue);
        expect(
          capturedTrack.resolution!.status,
          ScanResolutionStatus.needsReview,
        );
      }
      expect(hasExactPrintingEvidence(saved, read), isFalse);
    }
  });

  test('sideways artist OCR cannot release a captured card, but a horizontal replacement can', () {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    final ScanCrop proof = _recordedPartialProof();
    tracker.update(<LiveCardDetection>[_cropDetection(proof)]);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 1);
    expect(
      tracker.identifyCaptured(proof, _savedRead(proof), capture: capture),
      1,
    );
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: proof.sourceCorners,
        warnings: const <String>['incomplete_card'],
        lines: const <ScanTextLine>[
          ScanTextLine(
            text: 'mason A. Englo',
            confidence: 1,
            glyphHeight: .025,
            bounds: ScanBounds(.0149, .0892, .0336, .1837),
          ),
          ScanTextLine(
            text: 'As Nevermore enters the battlefield,',
            confidence: 1,
            glyphHeight: .03,
            bounds: ScanBounds(.3319, .0332, .1834, .9272),
          ),
        ],
      ),
    ]);
    expect(tracker.tracks.single.capturedIdentified, isTrue);
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: proof.sourceCorners,
        lines: const <ScanTextLine>[
          ScanTextLine(
            text: 'Lightning Bolt',
            confidence: 1,
            bounds: ScanBounds(.1, .04, .7, .03),
          ),
        ],
      ),
    ]);
    expect(tracker.tracks.single.capturedIdentified, isFalse);
  });

  test('confirmed saved metadata survives incomplete-only live OCR while real replacement still clears identification', () async {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    final ScanCrop proof = _recordedPartialProof();
    tracker.update(<LiveCardDetection>[_cropDetection(proof)]);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(tracker.markCaptured(capture), 1);
    final ScanResolution read = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Card(), const <ScanEvidence>{ScanEvidence.nameMatch}),
      ],
      hints: ScanHints.fromCrop(proof),
      status: ScanResolutionStatus.needsReview,
    );
    expect(tracker.identifyCaptured(proof, read, capture: capture), 1);
    final ScanResolution saved = tracker.tracks.single.resolution!;
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: proof.sourceCorners,
        warnings: const <String>['incomplete_card'],
        lines: const <ScanTextLine>[
          ScanTextLine(
            text: 'Unreadable lower corner',
            confidence: .7,
            bounds: ScanBounds(.1, .75, .5, .03),
          ),
        ],
      ),
    ]);
    await _settle();
    expect(tracker.tracks.single.capturedIdentified, isTrue);
    expect(tracker.tracks.single.resolution, same(saved));
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: proof.sourceCorners,
        lines: const <ScanTextLine>[
          ScanTextLine(
            text: 'Lightning Bolt',
            confidence: 1,
            bounds: ScanBounds(.1, .04, .7, .03),
          ),
        ],
      ),
    ]);
    expect(tracker.tracks.single.capturedIdentified, isFalse);
  });

  test('actual saved nameplate outranks unordered title noise and captured green survives corroborated clipped OCR without changing its printing', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    final ScanCrop captured = _recordedCircle24Captured();
    final ScanCrop saved = _recordedCircle24Saved();
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: captured.sourceCorners,
        lines: captured.lines,
        warnings: captured.warnings,
      ),
    ]);
    final String id = tracker.tracks.single.id;
    final LiveCaptureSnapshot capture = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[captured.sourceCorners],
    );
    expect(tracker.markCaptured(capture), 1);
    final ScanResolution read = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Card(), const <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.rulesTextMatch,
        }),
      ],
      hints: ScanHints.fromCrop(saved),
      status: ScanResolutionStatus.needsReview,
    );
    expect(tracker.identifyCaptured(saved, read, capture: capture), 1);
    final ScanResolution identified = tracker.tracks.single.resolution!;
    for (final ScanCrop observed in <ScanCrop>[
      _recordedCircle24Drift(),
      _recordedCircle24Clipped(),
      _recordedCircle24ClippedLater(),
    ]) {
      now = now.add(const Duration(seconds: 2));
      tracker.update(<LiveCardDetection>[
        LiveCardDetection(
          confidence: 1,
          corners: observed.sourceCorners,
          lines: observed.lines,
          warnings: observed.warnings,
        ),
      ]);
      final LiveScanTrack track = tracker.tracks.singleWhere(
        (LiveScanTrack track) => track.id == id,
      );
      expect(track.captured, isTrue);
      expect(track.capturedIdentified, isTrue);
      expect(track.resolution, same(identified));
    }
  });

  test('clipped receipt text below a quote cannot preserve captured status', () {
    final ScanCrop captured = _recordedCircle24Captured();
    final ScanCrop clipped = _recordedCircle24Clipped();
    for (final double confidence in <double>[.80, 1]) {
      for (final double quoteY in <double>[.36, .415, .60]) {
        for (final String quote in <String>['"', '“Remember the old tales']) {
          final String reason =
              'confidence=$confidence, quoteY=$quoteY, quote=$quote';
          final LiveScanTracker tracker = LiveScanTracker(
            resolver: _Resolver(),
          );
          addTearDown(tracker.dispose);
          tracker.update(<LiveCardDetection>[
            LiveCardDetection(
              confidence: 1,
              corners: captured.sourceCorners,
              warnings: captured.warnings,
              lines: captured.lines,
            ),
          ]);
          expect(tracker.markCaptured(tracker.snapshotCapture()), 1);
          final LiveScanTrack track = tracker.tracks.single;
          final String receiptId = track.photoFeedbackId;
          tracker.update(<LiveCardDetection>[
            LiveCardDetection(
              confidence: 1,
              corners: captured.sourceCorners,
              warnings: clipped.warnings,
              lines: <ScanTextLine>[
                ...clipped.lines,
                ScanTextLine(
                  text: quote,
                  confidence: confidence,
                  bounds: ScanBounds(.1, quoteY, .7, .03),
                ),
              ],
            ),
          ]);
          final bool rulesBeforeQuote = quoteY == .60;
          expect(track.captured, rulesBeforeQuote, reason: reason);
          expect(
            track.photoFeedbackId == receiptId,
            rulesBeforeQuote,
            reason: reason,
          );
          expect(track.capturedIdentified, isFalse, reason: reason);
        }
      }
    }
  });

  test('clipped receipt text cannot preserve changed color, name, printing, or desk noise and cannot independently turn green', () {
    final ScanCrop captured = _recordedCircle24Captured();
    final ScanCrop clipped = _recordedCircle24Clipped();
    for (final String condition in <String>[
      'clippedOnly',
      'Fog',
      'Rune',
      'Red',
      'printing',
      'desk',
    ]) {
      final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
      addTearDown(tracker.dispose);
      tracker.update(<LiveCardDetection>[
        LiveCardDetection(
          confidence: 1,
          corners: captured.sourceCorners,
          warnings: captured.warnings,
          lines: <ScanTextLine>[
            ...captured.lines,
            if (condition == 'printing')
              const ScanTextLine(
                text: '001 M21 EN',
                confidence: .99,
                bounds: ScanBounds(.05, .91, .4, .03),
              ),
          ],
        ),
      ]);
      tracker.markCaptured(tracker.snapshotCapture());
      final List<ScanTextLine> lines = <ScanTextLine>[
        for (final ScanTextLine line in clipped.lines)
          if (condition != 'desk' || line.bounds.y < .13)
            if (!<String>['Fog', 'Rune'].contains(condition) ||
                line.bounds.y >= .13)
              ScanTextLine(
                text: condition == 'Red'
                    ? line.text.replaceAll('blue', 'red')
                    : condition == 'desk'
                    ? 'Desk cable'
                    : line.text,
                confidence: line.confidence,
                bounds: line.bounds,
                glyphHeight: line.glyphHeight,
              ),
        if (condition == 'Fog' || condition == 'Rune')
          ScanTextLine(
            text: condition == 'Fog' ? 'Fog' : 'Rune of Protection: Blue',
            confidence: .99,
            bounds: ScanBounds(.05, .02, condition == 'Fog' ? .055 : .60, .03),
          ),
        if (condition == 'printing')
          const ScanTextLine(
            text: '002 M21 EN',
            confidence: .99,
            bounds: ScanBounds(.05, .91, .4, .03),
          ),
      ];
      tracker.update(<LiveCardDetection>[
        LiveCardDetection(
          confidence: 1,
          corners: captured.sourceCorners,
          lines: lines,
          warnings: clipped.warnings,
        ),
      ]);
      final LiveScanTrack track = tracker.tracks.single;
      expect(track.captured, condition == 'clippedOnly', reason: condition);
      expect(track.capturedIdentified, isFalse, reason: condition);
    }
  });

  test('plausible non-Latin nameplates remain meaningful contradictions', () {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[
      _card(.1, title: '対抗呪文', footer: '001 M21 EN'),
    ]);
    tracker.markCaptured(tracker.snapshotCapture());
    expect(tracker.tracks.single.captured, isTrue);
    tracker.update(<LiveCardDetection>[
      _card(.1, title: '稲妻の一撃', footer: '001 M21 EN'),
    ]);
    expect(tracker.tracks.single.captured, isFalse);
  });

  test('actual acknowledged rear-card contour identifies from exact title, type and two distinctive rules with one OCR character error', () {
    final ScanCrop live = _recordedBats23Live();
    final ScanCrop saved = _recordedBats23Saved();
    final List<ScanPoint> admitted = <ScanPoint>[
      const ScanPoint(.6228990, .2250636),
      const ScanPoint(.8546130, .2250636),
      const ScanPoint(.8546130, .4228058),
      const ScanPoint(.6228990, .4228058),
    ];
    for (final String condition in <String>[
      'actual',
      'shifted',
      'differentName',
      'twoRuleErrors',
      'oneRule',
      'printing',
      'twoCopies',
    ]) {
      final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
      addTearDown(tracker.dispose);
      final LiveCardDetection detection = LiveCardDetection(
        confidence: 1,
        corners: admitted,
        lines: <ScanTextLine>[
          ...live.lines,
          if (condition == 'printing')
            const ScanTextLine(
              text: '001 M21 EN',
              confidence: .99,
              bounds: ScanBounds(.05, .91, .4, .03),
            ),
        ],
        warnings: live.warnings,
      );
      tracker.update(<LiveCardDetection>[
        detection,
        if (condition == 'twoCopies') detection,
      ]);
      final LiveCaptureSnapshot capture = tracker.snapshotCapture(
        currentGeometry: <List<ScanPoint>>[admitted],
      );
      expect(tracker.markCaptured(capture), condition == 'twoCopies' ? 2 : 1);
      final ScanCrop candidate = ScanCrop(
        imagePath: '',
        width: saved.width,
        height: saved.height,
        rectified: saved.rectified,
        warnings: saved.warnings,
        sourceCorners: condition == 'shifted'
            ? saved.sourceCorners
                  .map((ScanPoint point) => ScanPoint(point.x - .1, point.y))
                  .toList()
            : saved.sourceCorners,
        lines: <ScanTextLine>[
          for (final ScanTextLine line in saved.lines)
            if (condition != 'oneRule' || !line.text.startsWith('Whenever'))
              ScanTextLine(
                text:
                    condition == 'differentName' && line.text == 'Mirkwood Bats'
                    ? 'Mirkwood Bat'
                    : condition == 'twoRuleErrors'
                    ? line.text
                          .replaceAll('create', 'crcate')
                          .replaceAll('sacrifice', 'sacrificz')
                    : line.text,
                confidence: line.confidence,
                bounds: line.bounds,
                glyphHeight: line.glyphHeight,
              ),
          if (condition == 'printing')
            const ScanTextLine(
              text: '002 M21 EN',
              confidence: .99,
              bounds: ScanBounds(.05, .91, .4, .03),
            ),
        ],
      );
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_Card(), const <ScanEvidence>{
            ScanEvidence.nameMatch,
            ScanEvidence.typeLineMatch,
            ScanEvidence.rulesTextMatch,
          }),
        ],
        hints: ScanHints.fromCrop(candidate),
        status: ScanResolutionStatus.needsReview,
      );
      expect(
        tracker.identifyCaptured(candidate, read, capture: capture),
        condition == 'actual' ? 1 : 0,
        reason: condition,
      );
      expect(
        tracker.tracks.where((LiveScanTrack track) => track.capturedIdentified),
        condition == 'actual' ? hasLength(1) : isEmpty,
        reason: condition,
      );
    }
  });

  test('late catalog completion cannot move frozen OCR proof onto a smaller geometry-only rear-card contour', () async {
    DateTime now = DateTime.utc(2026);
    final _Resolver resolver = _Resolver()
      ..pending = Completer<ScanResolution>();
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: resolver,
      clock: () => now,
    );
    addTearDown(tracker.dispose);
    final ScanCrop proof = _recordedBats22Proof();
    final LiveCardDetection observed = LiveCardDetection(
      confidence: 1,
      corners: proof.sourceCorners,
      lines: proof.lines,
      warnings: proof.warnings,
    );
    tracker.update(<LiveCardDetection>[observed]);
    tracker.update(<LiveCardDetection>[observed]);
    expect(resolver.calls, 1);
    now = now.add(const Duration(seconds: 2));
    final List<ScanPoint> shrunk = <ScanPoint>[
      const ScanPoint(.6540264, .1910708),
      const ScanPoint(.8913285, .1990523),
      const ScanPoint(.8783186, .3748424),
      const ScanPoint(.6502471, .3671846),
    ];
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: shrunk,
        lines: const <ScanTextLine>[],
        warnings: const <String>['geometry_only'],
      ),
    ]);
    final ScanResolution read = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Card(), const <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.rulesTextMatch,
        }),
      ],
      hints: ScanHints.fromCrop(proof),
      status: ScanResolutionStatus.needsReview,
    );
    resolver.pending!.complete(read);
    await _settle();
    expect(tracker.recentFocusCrops.single.sourceCorners, proof.sourceCorners);
    now = now.add(const Duration(seconds: 5));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks, isEmpty);
    tracker.beginCapture();
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(capture.isEmpty, isTrue);
    tracker.markCaptured(capture);
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[proof.sourceCorners],
    );
    expect(tracker.identifyCaptured(proof, read, capture: capture), 1);
    expect(tracker.tracks.single.capturedIdentified, isTrue);
  });

  test('saved card rules can identify its acknowledged tighter live contour without admitting shifted or conflicting cards', () {
    final ScanCrop body = _recordedCircle22Body();
    final ScanCrop saved = _recordedCircle22Saved();
    final List<ScanPoint> admitted = <ScanPoint>[
      const ScanPoint(.1246063, .5519160),
      const ScanPoint(.5703338, .5519160),
      const ScanPoint(.5703338, .8332285),
      const ScanPoint(.1246063, .8332285),
    ];
    for (final String condition in <String>[
      'actual',
      'shifted',
      'differentColor',
      'differentType',
      'onlyOneRule',
      'printing',
      'twoCopies',
    ]) {
      final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
      addTearDown(tracker.dispose);
      tracker.update(<LiveCardDetection>[
        LiveCardDetection(
          confidence: 1,
          corners: admitted,
          lines: <ScanTextLine>[
            ...body.lines,
            if (condition == 'printing')
              const ScanTextLine(
                text: '001 M21 EN',
                confidence: .99,
                bounds: ScanBounds(.05, .91, .4, .03),
              ),
          ],
          warnings: body.warnings,
        ),
        if (condition == 'twoCopies')
          LiveCardDetection(
            confidence: 1,
            corners: admitted,
            lines: body.lines,
            warnings: body.warnings,
          ),
      ]);
      final LiveCaptureSnapshot capture = tracker.snapshotCapture(
        currentGeometry: <List<ScanPoint>>[admitted],
      );
      tracker.markCaptured(capture);
      final ScanCrop candidate = ScanCrop(
        imagePath: '',
        width: saved.width,
        height: saved.height,
        rectified: saved.rectified,
        warnings: saved.warnings,
        sourceCorners: condition == 'shifted'
            ? saved.sourceCorners
                  .map((ScanPoint point) => ScanPoint(point.x + .10, point.y))
                  .toList()
            : saved.sourceCorners,
        lines: <ScanTextLine>[
          for (final ScanTextLine line in saved.lines)
            if (condition != 'onlyOneRule' ||
                line.text == 'Enchantment' ||
                line.text == '1; Prevent all damage against you' ||
                line.text == 'GIrele of Protection: Blue')
              ScanTextLine(
                text: condition == 'differentColor'
                    ? line.text
                          .replaceAll('blue', 'white')
                          .replaceAll('Blue', 'White')
                    : condition == 'differentType' && line.text == 'Enchantment'
                    ? 'Instant'
                    : line.text,
                confidence: line.confidence,
                bounds: line.bounds,
                glyphHeight: line.glyphHeight,
              ),
          if (condition == 'printing')
            const ScanTextLine(
              text: '002 M21 EN',
              confidence: .99,
              bounds: ScanBounds(.05, .91, .4, .03),
            ),
        ],
      );
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_Card(), const <ScanEvidence>{
            ScanEvidence.fuzzyName,
            ScanEvidence.rulesKeywordMatch,
            ScanEvidence.rulesTextMatch,
          }),
        ],
        hints: ScanHints.fromCrop(candidate),
        status: ScanResolutionStatus.needsReview,
      );
      expect(
        tracker.identifyCaptured(candidate, read, capture: capture),
        condition == 'actual' ? 1 : 0,
        reason: condition,
      );
    }
  });

  test('rearming single capture preserves physical tracking and new capture cycles reject old ACK and saved reads', () {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1, footer: '001 M21 EN')]);
    final LiveScanTrack track = tracker.tracks.single;
    final DateTime seen = track.lastSeen;
    final ScanCrop saved = track.crop;
    final ScanResolution read = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Card(), const <ScanEvidence>{ScanEvidence.footerMatch}),
      ],
      hints: ScanHints.fromCrop(saved),
      status: ScanResolutionStatus.needsReview,
    );
    final int first = tracker.beginCapture();
    final LiveCaptureSnapshot old = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[saved.sourceCorners],
    );
    expect(tracker.markCaptured(old), 1);
    expect(tracker.identifyCaptured(saved, read, capture: old), 1);
    tracker.endCapture(first, resumeTracking: true);
    tracker.rearmCaptured();
    expect(tracker.tracks.single, same(track));
    expect(track.lastSeen, seen);
    expect(track.crop.lines, saved.lines);
    expect(track.captured, isFalse);
    expect(track.capturedIdentified, isFalse);
    expect(tracker.markCaptured(old), 0);
    expect(tracker.identifyCaptured(saved, read, capture: old), 0);
    final int next = tracker.beginCapture();
    final LiveCaptureSnapshot current = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[saved.sourceCorners],
    );
    expect(tracker.markCaptured(old), 0);
    expect(tracker.identifyCaptured(saved, read, capture: old), 0);
    expect(tracker.markCaptured(current), 1);
    expect(tracker.identifyCaptured(saved, read, capture: current), 1);
    tracker.endCapture(next, resumeTracking: true);
    tracker.beginCapture();
    expect(tracker.identifyCaptured(saved, read, capture: current), 0);
    expect(track.capturedIdentified, isTrue);
  });

  test('acknowledged capture can recover a fresh uniquely associated saved card without promoting focus memory before ACK', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    final ScanCrop proof = _recordedPartialProof();
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: proof.sourceCorners,
        lines: proof.lines,
        warnings: proof.warnings,
      ),
    ]);
    now = now.add(const Duration(seconds: 7));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks, isEmpty);
    expect(tracker.recentFocusCrops.single.lines, proof.lines);
    final LiveCaptureSnapshot capture = tracker.snapshotCapture();
    expect(capture.isEmpty, isTrue);
    final ScanResolution read = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Card(), const <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.rulesTextMatch,
        }),
      ],
      hints: ScanHints.fromCrop(proof),
      status: ScanResolutionStatus.needsReview,
    );
    now = now.add(const Duration(milliseconds: 100));
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[proof.sourceCorners],
    );
    expect(tracker.identifyCaptured(proof, read, capture: capture), 0);
    expect(tracker.markCaptured(capture), 0);
    expect(tracker.identifyCaptured(proof, read), 0);
    int notifications = 0;
    tracker.addListener(() {
      notifications++;
    });
    expect(tracker.identifyCaptured(proof, read, capture: capture), 1);
    expect(tracker.tracks.single.capturedIdentified, isTrue);
    expect(notifications, 1);
    expect(tracker.identifyCaptured(proof, read, capture: capture), 1);
    expect(notifications, 1);
    now = now.add(const Duration(seconds: 31));
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[proof.sourceCorners],
    );
    expect(tracker.identifyCaptured(proof, read, capture: capture), 0);
  });

  test('small captured rules-panel recovery needs current distinctive OCR and rejects desk-only geometry', () {
    final ScanCrop proof = _recordedBatsProof();
    final List<ScanPoint> inset = <ScanPoint>[
      const ScanPoint(.6771, .3177),
      const ScanPoint(.8578, .3177),
      const ScanPoint(.8578, .3942),
      const ScanPoint(.6771, .3942),
    ];
    for (final bool readable in <bool>[false, true]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
      );
      addTearDown(tracker.dispose);
      tracker.update(<LiveCardDetection>[
        LiveCardDetection(
          confidence: 1,
          corners: proof.sourceCorners,
          lines: proof.lines,
          warnings: proof.warnings,
        ),
      ]);
      now = now.add(const Duration(seconds: 7));
      tracker.update(const <LiveCardDetection>[]);
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      tracker.markCaptured(capture);
      tracker.update(
        <LiveCardDetection>[
          LiveCardDetection(
            confidence: 1,
            corners: inset,
            lines: readable
                ? proof.lines
                      .where((ScanTextLine line) => line.bounds.y >= .13)
                      .toList()
                : const <ScanTextLine>[],
            warnings: proof.warnings,
          ),
        ],
        currentGeometry: <List<ScanPoint>>[inset],
      );
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_Card(), const <ScanEvidence>{
            ScanEvidence.rulesTextMatch,
          }),
        ],
        hints: ScanHints.fromCrop(proof),
        status: ScanResolutionStatus.needsReview,
      );
      expect(
        tracker.identifyCaptured(proof, read, capture: capture),
        readable ? 1 : 0,
      );
      if (readable) {
        expect(tracker.tracks.single.corners, proof.sourceCorners);
        expect(tracker.tracks.single.capturedIdentified, isTrue);
      } else {
        expect(tracker.tracks, isEmpty);
      }
    }
  });

  test('capture-bound recovery rejects removed scenes, replacement printings, stale geometry, and generation changes', () {
    for (final String condition in <String>[
      'removed',
      'replacement',
      'stale',
      'reset',
      'oldProof',
    ]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
      );
      addTearDown(tracker.dispose);
      tracker.update(<LiveCardDetection>[_card(.1, footer: '001 M21 EN')]);
      final ScanCrop saved = tracker.tracks.single.crop;
      now = now.add(Duration(seconds: condition == 'oldProof' ? 13 : 7));
      tracker.update(const <LiveCardDetection>[]);
      final LiveCaptureSnapshot capture = tracker.snapshotCapture();
      tracker.markCaptured(capture);
      if (condition == 'removed') {
        now = now.add(const Duration(seconds: 2));
        tracker.update(const <LiveCardDetection>[]);
      } else if (condition == 'replacement') {
        tracker.update(<LiveCardDetection>[_card(.1, footer: '002 M21 EN')]);
      } else if (condition == 'reset') {
        tracker.clear();
      }
      tracker.update(
        const <LiveCardDetection>[],
        currentGeometry: <List<ScanPoint>>[saved.sourceCorners],
      );
      if (condition == 'stale') now = now.add(const Duration(seconds: 2));
      final ScanResolution read = ScanResolution(
        candidates: <ScanCandidate>[
          ScanCandidate(_Card(), const <ScanEvidence>{
            ScanEvidence.footerMatch,
          }),
        ],
        hints: ScanHints.fromCrop(saved),
        status: ScanResolutionStatus.needsReview,
      );
      expect(
        tracker.identifyCaptured(saved, read, capture: capture),
        0,
        reason: condition,
      );
      expect(
        tracker.tracks.any((LiveScanTrack track) => track.capturedIdentified),
        isFalse,
        reason: condition,
      );
    }
  });

  test('recent focus geometry stays separate from receipt admission and expires without new strong proof', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[
      _card(.1, footer: '001 M21 EN'),
      _card(.6, footer: '001 M21 EN'),
    ]);
    now = now.add(const Duration(seconds: 7));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks, isEmpty);
    expect(tracker.recentFocusCrops, hasLength(2));
    expect(tracker.snapshotCapture().count, 0);
    tracker.update(<LiveCardDetection>[_card(.1, footer: '002 M21 EN')]);
    expect(tracker.recentFocusCrops, hasLength(2));
    expect(
      tracker.recentFocusCrops.any(
        (ScanCrop crop) => ScanHints.fromCrop(crop).collectorNumber == '002',
      ),
      isTrue,
    );
    now = now.add(const Duration(seconds: 13));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.recentFocusCrops, isEmpty);
    tracker.clear();
    expect(tracker.recentFocusCrops, isEmpty);
  });

  test('durable ACK stays awaiting-read until its saved-photo result and cannot be overwritten by late live identification', () async {
    final _Resolver resolver = _Resolver()
      ..pending = Completer<ScanResolution>();
    final LiveScanTracker tracker = LiveScanTracker(resolver: resolver);
    addTearDown(tracker.dispose);
    final MtgCard liveCard = _Card();
    final MtgCard savedCard = _Card();
    tracker.update(<LiveCardDetection>[_card(.1, footer: '001 M21 EN')]);
    tracker.update(<LiveCardDetection>[_card(.1, footer: '001 M21 EN')]);
    final LiveScanTrack track = tracker.tracks.single;
    final ScanCrop savedCrop = track.crop;
    final ScanResolution liveResolution = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(liveCard, const <ScanEvidence>{ScanEvidence.nameMatch}),
      ],
      hints: ScanHints.fromCrop(savedCrop),
      status: ScanResolutionStatus.needsReview,
    );
    track.resolution = liveResolution;
    expect(track.capturedIdentified, isFalse);
    tracker.markCaptured(tracker.snapshotCapture());
    expect(track.captured, isTrue);
    expect(track.capturedIdentified, isFalse);
    final ScanResolution savedResolution = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(savedCard, const <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.footerMatch,
        }),
      ],
      hints: ScanHints.fromCrop(savedCrop),
      status: ScanResolutionStatus.needsReview,
    );
    expect(tracker.identifyCaptured(savedCrop, savedResolution), 1);
    expect(track.capturedIdentified, isTrue);
    expect(track.resolution!.candidates.single.card, same(savedCard));
    resolver.pending!.complete(liveResolution);
    await _settle();
    expect(track.resolution!.candidates.single.card, same(savedCard));
    tracker.update(<LiveCardDetection>[
      _card(.1, title: null, warnings: const <String>['geometry_only']),
    ]);
    expect(track.capturedIdentified, isTrue);
    tracker.update(<LiveCardDetection>[_card(.1, footer: '002 M21 EN')]);
    expect(track.captured, isFalse);
    expect(track.capturedIdentified, isFalse);
    expect(tracker.identifyCaptured(savedCrop, savedResolution), 0);
    tracker.markCaptured(tracker.snapshotCapture());
    expect(track.captured, isTrue);
    expect(track.capturedIdentified, isFalse);
    tracker.clear();
    tracker.update(<LiveCardDetection>[_card(.1, footer: '001 M21 EN')]);
    expect(tracker.tracks.single.capturedIdentified, isFalse);
  });

  test('saved identification needs corroboration and matching physical printing without replacing live data on rejection', () {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1, footer: '001 M21 EN')]);
    final LiveScanTrack track = tracker.tracks.single;
    final ScanCrop saved = track.crop;
    final ScanResolution original = _resolution(saved);
    track.resolution = original;
    ScanResolution result(
      Set<ScanEvidence> evidence, {
      ScanResolutionStatus status = ScanResolutionStatus.needsReview,
    }) => ScanResolution(
      candidates: <ScanCandidate>[ScanCandidate(_Card(), evidence)],
      hints: ScanHints.fromCrop(saved),
      status: status,
    );
    expect(
      tracker.identifyCaptured(
        saved,
        result(const <ScanEvidence>{ScanEvidence.nameMatch}),
      ),
      0,
    );
    tracker.markCaptured(tracker.snapshotCapture());
    for (final Set<ScanEvidence> evidence in <Set<ScanEvidence>>[
      const <ScanEvidence>{ScanEvidence.fuzzyName},
      const <ScanEvidence>{
        ScanEvidence.fuzzyName,
        ScanEvidence.rulesKeywordMatch,
      },
      const <ScanEvidence>{
        ScanEvidence.nameMatch,
        ScanEvidence.printingMismatch,
      },
      const <ScanEvidence>{ScanEvidence.footerMatch, ScanEvidence.nameMismatch},
    ]) {
      expect(tracker.identifyCaptured(saved, result(evidence)), 0);
      expect(track.capturedIdentified, isFalse);
      expect(track.resolution, same(original));
    }
    expect(
      tracker.identifyCaptured(
        saved,
        result(const <ScanEvidence>{
          ScanEvidence.nameMatch,
        }, status: ScanResolutionStatus.noMatch),
      ),
      0,
    );
    for (final LiveCardDetection detection in <LiveCardDetection>[
      _card(.1, footer: '002 M21 EN'),
      _card(.1, title: 'Shock', footer: '001 M21 EN'),
      _card(.6, footer: '001 M21 EN'),
    ]) {
      final ScanCrop mismatched = LiveScanTrack(
        id: 'saved',
        detection: detection,
        lastSeen: DateTime.now(),
      ).crop;
      expect(
        tracker.identifyCaptured(
          mismatched,
          result(const <ScanEvidence>{ScanEvidence.footerMatch}),
        ),
        0,
      );
      expect(track.resolution, same(original));
      expect(track.capturedIdentified, isFalse);
    }
  });

  test('saved-photo identification marks only one physical copy and exposes only eligible saved candidates', () {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1), _card(.6)]);
    tracker.markCaptured(tracker.snapshotCapture());
    final ScanCrop first = tracker.tracks.first.crop;
    final MtgCard supported = _Card();
    final ScanResolution read = ScanResolution(
      candidates: <ScanCandidate>[
        ScanCandidate(_Card(), const <ScanEvidence>{
          ScanEvidence.nameMatch,
          ScanEvidence.nameMismatch,
        }),
        ScanCandidate(supported, const <ScanEvidence>{
          ScanEvidence.rulesTextMatch,
        }),
      ],
      hints: ScanHints.fromCrop(first),
      status: ScanResolutionStatus.needsReview,
    );
    expect(tracker.identifyCaptured(first, read), 1);
    expect(tracker.tracks.first.capturedIdentified, isTrue);
    expect(tracker.tracks.last.capturedIdentified, isFalse);
    expect(
      tracker.tracks.first.resolution!.candidates.single.card,
      same(supported),
    );
    final String movingId = tracker.tracks.first.id;
    tracker.update(<LiveCardDetection>[_card(.2), _card(.6)]);
    expect(tracker.tracks.first.id, movingId);
    expect(tracker.identifyCaptured(first, read), 1);
    expect(tracker.tracks.first.capturedIdentified, isTrue);
    expect(tracker.tracks.last.capturedIdentified, isFalse);
    tracker.clear();
    tracker.update(<LiveCardDetection>[_card(.1), _card(.1)]);
    tracker.markCaptured(tracker.snapshotCapture());
    expect(tracker.identifyCaptured(first, read), 0);
    expect(
      tracker.tracks.every((LiveScanTrack track) => !track.capturedIdentified),
      isTrue,
    );
  });

  test('admitted real native proof can cross its OCR age deadline during a bounded capture and remain marked after ACK', () {
    final ScanCrop crop = _recordedCapture16Proof();
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: crop.sourceCorners,
        lines: crop.lines,
        warnings: crop.warnings,
      ),
    ]);
    final String physicalId = tracker.tracks.single.id;
    now = now.add(const Duration(seconds: 24));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks, isEmpty);
    final int capture = tracker.beginCapture();
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[crop.sourceCorners],
    );
    expect(snapshot.count, 1);
    now = now.add(const Duration(milliseconds: 15618));
    expect(tracker.markCaptured(snapshot), 1);
    tracker.endCapture(capture, resumeTracking: true);
    expect(tracker.tracks.single.id, physicalId);
    expect(tracker.tracks.single.captured, isTrue);
    now = now.add(const Duration(seconds: 29));
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[crop.sourceCorners],
    );
    expect(tracker.tracks.single.captured, isTrue);
    now = now.add(const Duration(seconds: 2));
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[crop.sourceCorners],
    );
    expect(tracker.tracks, isEmpty);
  });

  test('active capture cannot pin an expired-at-admission or weak remembered proof', () {
    final ScanCrop crop = _recordedCapture16Proof();
    for (final bool expired in <bool>[true, false]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
      );
      addTearDown(tracker.dispose);
      tracker.update(<LiveCardDetection>[
        LiveCardDetection(
          confidence: 1,
          corners: crop.sourceCorners,
          lines: expired
              ? crop.lines
              : crop.lines
                    .where((ScanTextLine line) => line.text == 'Nevermore')
                    .toList(),
          warnings: expired ? crop.warnings : const <String>[],
        ),
      ]);
      now = now.add(Duration(seconds: expired ? 31 : 24));
      tracker.update(const <LiveCardDetection>[]);
      final int capture = tracker.beginCapture();
      final LiveCaptureSnapshot snapshot = tracker.snapshotCapture(
        currentGeometry: <List<ScanPoint>>[crop.sourceCorners],
      );
      if (expired) expect(snapshot.isEmpty, isTrue);
      now = now.add(const Duration(seconds: 15));
      expect(tracker.markCaptured(snapshot), 0);
      tracker.endCapture(capture, resumeTracking: true);
      expect(
        tracker.tracks.where((LiveScanTrack track) => track.captured),
        isEmpty,
      );
    }
  });

  test('current geometry confirmed remembered native proof is visibly marked on durable ACK with a bounded saved-footprint lifetime', () {
    final ScanCrop crop = _recordedPartialProof();
    expect(ScanHints.fromCrop(crop).typeLine, 'enchantment');
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: crop.sourceCorners,
        lines: crop.lines,
        warnings: crop.warnings,
      ),
    ]);
    final String physicalId = tracker.tracks.single.id;
    now = now.add(const Duration(seconds: 2));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks, isEmpty);
    final int capture = tracker.beginCapture();
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[crop.sourceCorners],
    );
    expect(snapshot.count, 1);
    now = now.add(const Duration(seconds: 10));
    expect(tracker.markCaptured(snapshot), 1);
    expect(tracker.tracks.single.id, physicalId);
    expect(tracker.tracks.single.captured, isTrue);
    expect(
      ScanHints.fromCrop(tracker.tracks.single.crop).names,
      contains('Nevermore'),
    );
    tracker.endCapture(capture, resumeTracking: true);
    now = now.add(const Duration(seconds: 19));
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[crop.sourceCorners],
    );
    expect(tracker.tracks.single.captured, isTrue);
    now = now.add(const Duration(seconds: 12));
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[crop.sourceCorners],
    );
    expect(tracker.tracks, isEmpty);
  });

  test('remembered ACK rejects absent geometry, expired proof and newer desk or printing replacement observations', () {
    final ScanCrop crop = _recordedPartialProof();
    for (final String scenario in <String>[
      'no geometry',
      'expired',
      'desk',
      'printing',
    ]) {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
      );
      addTearDown(tracker.dispose);
      LiveCardDetection observed({bool desk = false, String number = '001'}) =>
          LiveCardDetection(
            confidence: 1,
            corners: crop.sourceCorners,
            warnings: crop.warnings,
            lines: desk
                ? const <ScanTextLine>[]
                : <ScanTextLine>[
                    ...crop.lines,
                    ScanTextLine(
                      text: '$number M21 EN',
                      confidence: 1,
                      bounds: const ScanBounds(.05, .92, .4, .03),
                    ),
                  ],
          );
      tracker.update(<LiveCardDetection>[observed()]);
      final LiveCaptureSnapshot? unconfirmed = scenario == 'no geometry'
          ? tracker.snapshotCapture()
          : null;
      now = now.add(const Duration(seconds: 2));
      tracker.update(const <LiveCardDetection>[]);
      final LiveCaptureSnapshot snapshot =
          unconfirmed ??
          tracker.snapshotCapture(
            currentGeometry: <List<ScanPoint>>[crop.sourceCorners],
          );
      if (scenario == 'expired') now = now.add(const Duration(seconds: 29));
      if (scenario == 'desk' || scenario == 'printing') {
        tracker.update(<LiveCardDetection>[
          observed(desk: scenario == 'desk', number: '002'),
        ]);
      }
      expect(tracker.markCaptured(snapshot), 0, reason: scenario);
      expect(
        tracker.tracks.where((LiveScanTrack track) => track.captured),
        isEmpty,
        reason: scenario,
      );
      if (scenario == 'expired' ||
          scenario == 'desk' ||
          scenario == 'printing') {
        tracker.update(<LiveCardDetection>[observed()]);
        expect(
          tracker.tracks.where((LiveScanTrack track) => track.captured),
          isEmpty,
          reason: scenario,
        );
      }
    }
  });

  test('partial proof rejects flavor-only companions and ordinary incomplete crop tags', () {
    final ScanCrop actual = _recordedPartialProof();
    for (final bool flavorOnly in <bool>[true, false]) {
      final List<ScanTextLine> lines = flavorOnly
          ? actual.lines
                .where(
                  (ScanTextLine line) =>
                      line.text == 'Enchantment' ||
                      line.text == 'Nevermore' ||
                      line.text.startsWith('«'),
                )
                .toList()
          : actual.lines;
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
      );
      addTearDown(tracker.dispose);
      tracker.update(<LiveCardDetection>[
        LiveCardDetection(
          confidence: 1,
          corners: actual.sourceCorners,
          lines: lines,
          warnings: flavorOnly
              ? actual.warnings
              : const <String>['incomplete_card'],
        ),
      ]);
      now = now.add(const Duration(seconds: 8));
      tracker.update(
        const <LiveCardDetection>[],
        currentGeometry: <List<ScanPoint>>[actual.sourceCorners],
      );
      expect(tracker.tracks, isEmpty);
    }
  });

  test('recent rear-card proof survives its contained artwork rectangle without shrinking the polygon or renewing proof', () {
    final List<Object?> fixture = jsonDecode(
      File('test/fixtures/live_capture_mounted_scene.json').readAsStringSync(),
    ) as List<Object?>;
    final ScanCrop nativeProof = ScanCrop.fromMap(
      (fixture.last as List<Object?>)[2] as Map<Object?, Object?>,
    );
    final List<ScanPoint> provenCorners = <ScanPoint>[
      const ScanPoint(.6687480142446874, .19338079242303807),
      const ScanPoint(.9337952988874421, .19338079242303807),
      const ScanPoint(.9337952988874421, .45841064418044397),
      const ScanPoint(.6687480142446874, .45841064418044397),
    ];
    final List<ScanPoint> artwork = <ScanPoint>[
      const ScanPoint(.679, .186),
      const ScanPoint(.908, .186),
      const ScanPoint(.908, .321),
      const ScanPoint(.679, .321),
    ];
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: provenCorners,
        lines: nativeProof.lines,
        warnings: nativeProof.warnings,
      ),
    ]);
    final String id = tracker.tracks.single.id;
    now = now.add(const Duration(seconds: 4));
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[artwork],
    );
    expect(tracker.tracks.single.id, id);
    for (int index = 0; index < provenCorners.length; index++) {
      expect(
        tracker.tracks.single.corners[index].x,
        closeTo(provenCorners[index].x, 1e-9),
      );
      expect(
        tracker.tracks.single.corners[index].y,
        closeTo(provenCorners[index].y, 1e-9),
      );
    }
    expect(tracker.snapshotCapture().count, 1);
    expect(
      ScanHints.fromCrop(tracker.snapshotCapture().crops.single).names,
      contains('Mirkwood Bats'),
    );
    now = now.add(const Duration(seconds: 3));
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[artwork],
    );
    expect(tracker.tracks, isEmpty);
    expect(
      tracker
          .snapshotCapture(currentGeometry: <List<ScanPoint>>[artwork])
          .isEmpty,
      isTrue,
    );
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[
        const <ScanPoint>[
          ScanPoint(.3, .1),
          ScanPoint(.99, .1),
          ScanPoint(.99, .9),
          ScanPoint(.3, .9),
        ],
      ],
    );
    expect(tracker.tracks, isEmpty);
  });

  test('durable partial footprint follows its contained artwork after OCR expires without moving to broad desk geometry', () {
    final ScanCrop crop = _recordedPartialProof();
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: crop.sourceCorners,
        lines: crop.lines,
        warnings: crop.warnings,
      ),
    ]);
    tracker.markCaptured(tracker.snapshotCapture());
    final String id = tracker.tracks.single.id;
    final List<ScanPoint> artwork = <ScanPoint>[
      const ScanPoint(.60, .59),
      const ScanPoint(.87, .59),
      const ScanPoint(.87, .72),
      const ScanPoint(.60, .72),
    ];
    now = now.add(const Duration(seconds: 20));
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[artwork],
    );
    expect(tracker.tracks.single.id, id);
    expect(tracker.tracks.single.captured, isTrue);
    expect(tracker.tracks.single.lastSeen, now);
    for (int index = 0; index < 4; index++) {
      expect(
        tracker.tracks.single.corners[index].x,
        closeTo(crop.sourceCorners[index].x, 1e-9),
      );
      expect(
        tracker.tracks.single.corners[index].y,
        closeTo(crop.sourceCorners[index].y, 1e-9),
      );
    }
    now = now.add(const Duration(seconds: 3));
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[
        const <ScanPoint>[
          ScanPoint(0, 0),
          ScanPoint(.99, 0),
          ScanPoint(.99, .99),
          ScanPoint(0, .99),
        ],
      ],
    );
    expect(
      tracker.tracks.single.lastSeen,
      now.subtract(const Duration(seconds: 3)),
    );
    now = now.add(const Duration(seconds: 8));
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[artwork],
    );
    expect(tracker.tracks, isEmpty);
  });

  test('mounted scene keeps three proven capture footprints through OCR drift and an incomplete geometry frame', () {
    final List<Object?> fixture = jsonDecode(
      File('test/fixtures/live_capture_mounted_scene.json').readAsStringSync(),
    ) as List<Object?>;
    final List<List<ScanCrop>> frames = fixture
        .map(
          (Object? value) => (value as List<Object?>)
              .map(
                (Object? crop) =>
                    ScanCrop.fromMap(crop as Map<Object?, Object?>),
              )
              .toList(),
        )
        .toList();
    LiveCardDetection detection(ScanCrop crop, {bool geometryOnly = false}) =>
        LiveCardDetection(
          confidence: 1,
          corners: crop.sourceCorners,
          lines: geometryOnly ? const <ScanTextLine>[] : crop.lines,
          warnings: geometryOnly
              ? const <String>['incomplete_card']
              : crop.warnings,
        );
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(frames.first.map(detection).toList());
    now = now.add(const Duration(seconds: 4));
    tracker.update(
      frames[1].map(detection).toList(),
      currentGeometry: frames[1].map((ScanCrop crop) => crop.sourceCorners),
    );
    final String circleId = tracker.tracks.first.id;
    now = now.add(const Duration(seconds: 2));
    tracker.update(<LiveCardDetection>[
      detection(frames[2][0], geometryOnly: true),
      detection(frames[2][1], geometryOnly: true),
      detection(frames[2][2]),
    ], currentGeometry: frames[2].map((ScanCrop crop) => crop.sourceCorners));
    for (int second = 0; second < 8; second++) {
      now = now.add(const Duration(seconds: 1));
      tracker.update(<LiveCardDetection>[
        detection(frames[2][2], geometryOnly: true),
      ], currentGeometry: frames[2].map((ScanCrop crop) => crop.sourceCorners));
    }
    expect(tracker.tracks, hasLength(3));
    expect(tracker.tracks.first.id, circleId);
    final int capture = tracker.beginCapture();
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture(
      currentGeometry: frames[2].map((ScanCrop crop) => crop.sourceCorners),
    );
    expect(snapshot.count, 3);
    final ScanCrop nevermore = snapshot.crops.singleWhere(
      (ScanCrop crop) =>
          crop.lines.any((ScanTextLine line) => line.text == 'Nevermore'),
    );
    expect(nevermore.rectified, isFalse);
    expect(nevermore.warnings, contains('partial_card'));
    expect(ScanHints.fromCrop(nevermore).names, contains('Nevermore'));
    now = now.add(const Duration(seconds: 15));
    expect(tracker.markCaptured(snapshot), 3);
    tracker.endCapture(capture, resumeTracking: true);
    final List<String> savedIds = tracker.tracks
        .map((LiveScanTrack track) => track.id)
        .toList();
    now = now.add(const Duration(milliseconds: 100));
    tracker.update(const <LiveCardDetection>[]);
    now = now.add(const Duration(seconds: 3));
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[
        _card(.05, y: .05, title: null).corners,
      ],
    );
    expect(tracker.tracks, hasLength(3));
    expect(tracker.tracks.map((LiveScanTrack track) => track.id), savedIds);
    expect(tracker.snapshotCapture().isEmpty, isTrue);
    expect(
      tracker.tracks.every((LiveScanTrack track) => track.captured),
      isTrue,
    );
    now = now.add(const Duration(seconds: 28));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks, isEmpty);
    tracker.update(frames.first.map(detection).toList());
    expect(
      tracker.tracks.every((LiveScanTrack track) => !track.captured),
      isTrue,
    );
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: frames[2].map((ScanCrop crop) => crop.sourceCorners),
    );
    expect(
      tracker.tracks.where((LiveScanTrack track) => track.captured),
      isEmpty,
    );
    expect(
      tracker.tracks.any((LiveScanTrack track) => savedIds.contains(track.id)),
      isFalse,
    );
  });

  test('corroborated title OCR drift preserves a saved physical card but different rules and printing do not', () {
    LiveCardDetection enchantment(
      String title,
      String color, {
      String? footer,
    }) {
      final LiveCardDetection card = _card(.1, title: title, footer: footer);
      return LiveCardDetection(
        confidence: card.confidence,
        corners: card.corners,
        lines: <ScanTextLine>[
          ...card.lines,
          const ScanTextLine(
            text: 'Enchantment',
            confidence: .99,
            bounds: ScanBounds(.1, .51, .6, .03),
          ),
          const ScanTextLine(
            text: 'Prevent all damage against you',
            confidence: .99,
            bounds: ScanBounds(.1, .55, .8, .03),
          ),
          ScanTextLine(
            text: 'from one $color source. If a source',
            confidence: .99,
            bounds: const ScanBounds(.1, .60, .8, .03),
          ),
          const ScanTextLine(
            text: 'each time to prevent the damage.',
            confidence: .99,
            bounds: ScanBounds(.1, .65, .8, .03),
          ),
        ],
      );
    }

    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[
      enchantment('Cirele of Protection Clue', 'blue', footer: '001 M21 EN'),
    ]);
    tracker.markCaptured(tracker.snapshotCapture());
    tracker.update(<LiveCardDetection>[
      enchantment('Strele of Protections Clue', 'blue', footer: '001 M21 EN'),
    ]);
    expect(tracker.tracks.single.captured, isTrue);
    tracker.update(<LiveCardDetection>[
      enchantment('Circle of Protection White', 'white', footer: '001 M21 EN'),
    ]);
    expect(tracker.tracks.single.captured, isFalse);
    tracker.markCaptured(tracker.snapshotCapture());
    tracker.update(<LiveCardDetection>[
      enchantment('Circle of Protection White', 'white', footer: '002 M21 EN'),
    ]);
    expect(tracker.tracks.single.captured, isFalse);
  });

  test('strong recent OCR cannot promote a broad desk proposal or survive its bounded proof deadline', () {
    final List<Object?> fixture = jsonDecode(
      File('test/fixtures/live_capture_mounted_scene.json').readAsStringSync(),
    ) as List<Object?>;
    final ScanCrop proof = ScanCrop.fromMap(
      (fixture.first as List<Object?>)[1] as Map<Object?, Object?>,
    );
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: proof.sourceCorners,
        lines: proof.lines,
        warnings: proof.warnings,
      ),
    ]);
    now = now.add(const Duration(seconds: 2));
    tracker.update(const <LiveCardDetection>[]);
    expect(
      tracker
          .snapshotCapture(
            currentGeometry: <List<ScanPoint>>[
              _card(.1).corners,
              const <ScanPoint>[
                ScanPoint(.1, .1),
                ScanPoint(.99, .1),
                ScanPoint(.99, .99),
                ScanPoint(.1, .99),
              ],
            ],
          )
          .isEmpty,
      isTrue,
    );
    expect(
      tracker
          .snapshotCapture(
            currentGeometry: <List<ScanPoint>>[proof.sourceCorners],
          )
          .count,
      1,
    );
    now = now.add(const Duration(seconds: 29));
    expect(
      tracker
          .snapshotCapture(
            currentGeometry: <List<ScanPoint>>[proof.sourceCorners],
          )
          .isEmpty,
      isTrue,
    );
    tracker.update(
      const <LiveCardDetection>[],
      currentGeometry: <List<ScanPoint>>[proof.sourceCorners],
    );
    expect(tracker.tracks, isEmpty);
  });

  test('capture scene union marks strongly proven missing cards only at fresh matching geometry and preserves readable reacquisition', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[
      _card(.1, title: 'Shock', footer: '001 M21 EN'),
    ]);
    now = now.add(const Duration(seconds: 2));
    tracker.update(<LiveCardDetection>[_card(.6)]);
    expect(tracker.tracks, hasLength(1));
    expect(tracker.snapshotCapture().count, 1);
    expect(
      tracker
          .snapshotCapture(
            currentGeometry: <List<ScanPoint>>[_card(.0, y: .5).corners],
          )
          .count,
      1,
    );
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[_card(.1).corners],
    );
    expect(snapshot.count, 2);
    expect(tracker.markCaptured(snapshot), 2);
    tracker.update(<LiveCardDetection>[
      _card(.6),
      _card(.1, title: null, warnings: const <String>['geometry_only']),
    ]);
    expect(tracker.tracks, hasLength(2));
    tracker.update(<LiveCardDetection>[_card(.6), _card(.1, title: 'Shock')]);
    expect(tracker.tracks, hasLength(2));
    expect(
      tracker.tracks.every((LiveScanTrack track) => track.captured),
      isTrue,
    );
    expect(
      tracker
          .snapshotCapture(
            currentGeometry: <List<ScanPoint>>[
              _card(.1).corners,
              _card(.6).corners,
            ],
          )
          .isEmpty,
      isTrue,
    );
    tracker.clear();
    expect(
      tracker
          .snapshotCapture(
            currentGeometry: <List<ScanPoint>>[_card(.1).corners],
          )
          .isEmpty,
      isTrue,
    );
  });

  test('recent proof capture rejects expired memory and replacements during missing-track acknowledgement', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1, footer: '001 M21 EN')]);
    now = now.add(const Duration(seconds: 2));
    tracker.update(const <LiveCardDetection>[]);
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture(
      currentGeometry: <List<ScanPoint>>[_card(.1).corners],
    );
    expect(snapshot.count, 1);
    tracker.markCaptured(snapshot);
    tracker.update(<LiveCardDetection>[_card(.1, title: 'Shock')]);
    expect(tracker.tracks.single.captured, isFalse);
    now = now.add(const Duration(seconds: 31));
    tracker.update(const <LiveCardDetection>[]);
    expect(
      tracker
          .snapshotCapture(
            currentGeometry: <List<ScanPoint>>[_card(.1).corners],
          )
          .isEmpty,
      isTrue,
    );
  });

  test('durable capture marks physical copies independently and follows motion without covering a new identical card', () {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1), _card(.6)]);
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture();
    expect(snapshot.count, 2);
    expect(
      tracker.tracks.every((LiveScanTrack track) => !track.captured),
      isTrue,
    );
    expect(tracker.markCaptured(snapshot), 2);
    expect(tracker.snapshotCapture().isEmpty, isTrue);
    expect(tracker.markCaptured(snapshot), 0);
    final String firstId = tracker.tracks.first.id;
    tracker.update(<LiveCardDetection>[
      _card(.61),
      _card(.12),
      _card(.35, y: .6),
    ]);
    expect(tracker.tracks.first.id, firstId);
    expect(
      tracker.tracks.take(2).every((LiveScanTrack track) => track.captured),
      isTrue,
    );
    expect(tracker.uncapturedTracks, hasLength(1));
    expect(tracker.uncapturedTracks.single.corners.first.y, .6);
    expect(snapshot.crops.first.sourceCorners.first.x, .1);
    expect(
      () => snapshot.crops.first.sourceCorners.clear(),
      throwsUnsupportedError,
    );
  });

  test('replacement name or printing clears capture and delayed old acknowledgement cannot mark it', () {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1, footer: '001 M21 EN')]);
    final LiveCaptureSnapshot old = tracker.snapshotCapture();
    tracker.markCaptured(old);
    tracker.update(<LiveCardDetection>[
      _card(.1, title: 'Shock', footer: '001 M21 EN'),
    ]);
    expect(tracker.tracks.single.captured, isFalse);
    expect(tracker.markCaptured(old), 0);
    tracker.markCaptured(tracker.snapshotCapture());
    expect(tracker.tracks.single.captured, isTrue);
    tracker.update(<LiveCardDetection>[
      _card(.1, title: 'Shock', footer: '002 M21 EN'),
    ]);
    expect(tracker.tracks.single.captured, isFalse);
  });

  test('saved capture survives slow acknowledgement and bounded geometry-only reacquisition but not removal', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    final int token = tracker.beginCapture();
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture();
    now = now.add(const Duration(seconds: 20));
    expect(tracker.markCaptured(snapshot), 1);
    tracker.endCapture(token, resumeTracking: true);
    for (int second = 0; second < 29; second++) {
      now = now.add(const Duration(seconds: 1));
      tracker.update(<LiveCardDetection>[
        _card(.1, title: null, warnings: const <String>['geometry_only']),
      ]);
      expect(tracker.tracks.single.captured, isTrue);
    }
    now = now.add(const Duration(seconds: 2));
    tracker.update(<LiveCardDetection>[
      _card(.1, title: null, warnings: const <String>['geometry_only']),
    ]);
    expect(tracker.tracks, isEmpty);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    expect(tracker.tracks.single.captured, isFalse);
  });

  test('readable proofs keep captured cards tracked while an observed removal makes the next copy new', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    tracker.markCaptured(tracker.snapshotCapture());
    for (int second = 0; second < 40; second++) {
      now = now.add(const Duration(seconds: 1));
      tracker.update(<LiveCardDetection>[_card(.1)]);
    }
    expect(tracker.tracks.single.captured, isTrue);
    final String savedId = tracker.tracks.single.id;
    now = now.add(const Duration(seconds: 2));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks, isEmpty);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    expect(tracker.tracks.single.id, isNot(savedId));
    expect(tracker.tracks.single.captured, isFalse);
  });

  test('missing-track acknowledgement restores only readable matching footprint and rejects broad desk geometry', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture();
    now = now.add(const Duration(seconds: 2));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.markCaptured(snapshot), 0);
    tracker.update(<LiveCardDetection>[_card(.1, title: null)]);
    expect(tracker.tracks, isEmpty);
    tracker.update(<LiveCardDetection>[
      LiveCardDetection(
        confidence: 1,
        corners: const <ScanPoint>[
          ScanPoint(0, 0),
          ScanPoint(.9, 0),
          ScanPoint(.9, .9),
          ScanPoint(0, .9),
        ],
        lines: _card(.1).lines,
      ),
    ]);
    expect(tracker.tracks.single.captured, isFalse);
    tracker.update(<LiveCardDetection>[_card(.11)]);
    expect(
      tracker.tracks.where((LiveScanTrack track) => track.captured),
      hasLength(1),
    );
    expect(
      tracker.tracks
          .singleWhere((LiveScanTrack track) => track.captured)
          .corners
          .first
          .x,
      closeTo(.1065, .0001),
    );
  });

  test('missing-track replacement invalidates the frozen footprint and camera resets or stalls reject stale acknowledgement', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    final LiveCaptureSnapshot snapshot = tracker.snapshotCapture();
    now = now.add(const Duration(seconds: 2));
    tracker.update(const <LiveCardDetection>[]);
    tracker.markCaptured(snapshot);
    tracker.update(<LiveCardDetection>[_card(.1, title: 'Shock')]);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    expect(tracker.tracks.single.captured, isFalse);
    final LiveCaptureSnapshot stale = tracker.snapshotCapture();
    tracker.clear();
    tracker.update(<LiveCardDetection>[_card(.1)]);
    expect(tracker.markCaptured(stale), 0);
    final LiveCaptureSnapshot stalled = tracker.snapshotCapture();
    now = now.add(const Duration(seconds: 31));
    tracker.update(<LiveCardDetection>[_card(.1)]);
    expect(tracker.markCaptured(stalled), 0);
    expect(tracker.tracks.single.captured, isFalse);
  });

  test('live keyword matches need a close title or one unambiguous card', () {
    final LiveScanTrack track = LiveScanTrack(
      id: 'card-1',
      detection: _card(.1),
      lastSeen: DateTime.utc(2026),
    );
    final MtgCard first = _Card();
    final MtgCard second = _Card();
    void candidates(List<ScanCandidate> values) {
      track.resolution = ScanResolution(
        candidates: values,
        hints: ScanHints.fromCrop(track.crop),
        status: ScanResolutionStatus.needsReview,
      );
    }

    candidates(<ScanCandidate>[
      ScanCandidate(first, const <ScanEvidence>{
        ScanEvidence.rulesKeywordMatch,
      }),
      ScanCandidate(second, const <ScanEvidence>{
        ScanEvidence.rulesKeywordMatch,
      }),
    ]);
    expect(track.hasCatalogMatch, isFalse);
    candidates(<ScanCandidate>[
      ScanCandidate(first, const <ScanEvidence>{
        ScanEvidence.rulesKeywordMatch,
        ScanEvidence.fuzzyName,
      }),
      ScanCandidate(second, const <ScanEvidence>{
        ScanEvidence.rulesKeywordMatch,
      }),
    ]);
    expect(track.hasCatalogMatch, isTrue);
    candidates(<ScanCandidate>[
      ScanCandidate(first, const <ScanEvidence>{
        ScanEvidence.rulesKeywordMatch,
      }),
    ]);
    expect(track.hasCatalogMatch, isTrue);
    candidates(<ScanCandidate>[
      ScanCandidate(first, const <ScanEvidence>{
        ScanEvidence.rulesKeywordMatch,
        ScanEvidence.nameMismatch,
      }),
    ]);
    expect(track.hasCatalogMatch, isFalse);
  });

  test('verified live partials retain unrectified name evidence across bounded geometry refreshes', () async {
    DateTime now = DateTime.utc(2026, 10, 10);
    final _Resolver resolver = _Resolver();
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: resolver,
      clock: () => now,
    );
    addTearDown(tracker.dispose);
    final LiveCardDetection partial = LiveCardDetection(
      confidence: .95,
      corners: _card(.1).corners,
      warnings: const <String>[
        'partial_card',
        'incomplete_card',
        'no_card_rectangle',
      ],
      lines: const <ScanTextLine>[
        ScanTextLine(
          text: 'Nevermore',
          confidence: 1,
          bounds: ScanBounds(.05, .04, .35, .058),
        ),
        ScanTextLine(
          text: 'Enchantment',
          confidence: 1,
          bounds: ScanBounds(.04, .45, .40, .082),
        ),
        ScanTextLine(
          text: 'As Nevermore enters the battlefield,',
          confidence: 1,
          bounds: ScanBounds(.03, .52, .80, .15),
        ),
        ScanTextLine(
          text: 'name a nonland card.',
          confidence: 1,
          bounds: ScanBounds(.03, .56, .70, .14),
        ),
      ],
    );
    tracker.update(<LiveCardDetection>[partial]);
    tracker.update(<LiveCardDetection>[partial]);
    await _settle();
    final LiveScanTrack track = tracker.tracks.single;
    expect(track.crop.rectified, isFalse);
    expect(resolver.crops.single.rectified, isFalse);
    expect(resolver.crops.single.warnings, contains('partial_card'));
    expect(ScanHints.fromCrop(resolver.crops.single).names, <String>[
      'Nevermore',
    ]);
    final ScanResolution resolved = track.resolution!;
    expect(hasExactPrintingEvidence(track.crop, resolved), isFalse);
    final LiveCardDetection geometry = LiveCardDetection(
      confidence: .95,
      corners: partial.corners,
      warnings: const <String>[
        'partial_card',
        'incomplete_card',
        'no_card_rectangle',
        'geometry_only',
      ],
    );
    for (int second = 1; second <= 5; second++) {
      now = now.add(const Duration(seconds: 1));
      tracker.update(<LiveCardDetection>[geometry]);
      await _settle();
      expect(tracker.tracks.single.id, track.id);
      expect(tracker.tracks.single.resolution, same(resolved));
    }
    expect(resolver.calls, 1);
    now = now.add(const Duration(seconds: 2));
    tracker.update(<LiveCardDetection>[geometry]);
    await _settle();
    expect(tracker.tracks, isEmpty);
    expect(resolver.calls, 1);
  });

  test(
    'empty desk rectangles stay invisible and make no catalog requests',
    () async {
      final _Resolver resolver = _Resolver();
      final LiveScanTracker tracker = LiveScanTracker(resolver: resolver);
      addTearDown(tracker.dispose);
      final List<LiveCardDetection> desk = <LiveCardDetection>[
        _card(.1, title: null),
        _card(.12, y: .12, title: null),
        _card(.6, title: null),
        _card(.62, y: .12, title: null),
        _card(.4, y: .6, title: null),
      ];
      for (int frame = 0; frame < 6; frame++) {
        tracker.update(desk);
        await _settle();
      }
      expect(tracker.tracks, isEmpty);
      expect(resolver.calls, 0);
    },
  );

  test('readable cards acquire immediately after blank geometry and recover after text loss', () async {
    DateTime now = DateTime.utc(2026);
    final _Resolver resolver = _Resolver();
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: resolver,
      clock: () => now,
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1, title: null)]);
    tracker.update(<LiveCardDetection>[_card(.1, title: null)]);
    expect(tracker.tracks, isEmpty);
    tracker.update(<LiveCardDetection>[_card(.1, title: 'Nevermore')]);
    final String id = tracker.tracks.single.id;
    expect(tracker.tracks.single.hasCatalogMatch, isFalse);
    await _settle();
    expect(resolver.calls, 1);
    now = now.add(const Duration(milliseconds: 600));
    tracker.update(<LiveCardDetection>[_card(.11, title: null)]);
    expect(tracker.tracks.single.id, id);
    for (int second = 0; second < 7; second++) {
      now = now.add(const Duration(seconds: 1));
      tracker.update(<LiveCardDetection>[_card(.11, title: null)]);
    }
    expect(
      tracker.tracks,
      isEmpty,
      reason: 'Desk geometry must not keep an earlier card label alive',
    );
    tracker.update(<LiveCardDetection>[_card(.11, title: 'Nevermore')]);
    expect(tracker.tracks.single.id, isNot(id));
    expect(
      ScanHints.fromCrop(tracker.tracks.single.crop).names,
      contains('Nevermore'),
    );
  });

  test('partial cards use readable rules or footer without requiring a title or exact printing', () async {
    final _Resolver resolver = _Resolver();
    final LiveScanTracker tracker = LiveScanTracker(resolver: resolver);
    addTearDown(tracker.dispose);
    final List<LiveCardDetection> partial = <LiveCardDetection>[
      LiveCardDetection(
        confidence: .9,
        corners: _card(.1).corners,
        warnings: const <String>['incomplete_card'],
        lines: const <ScanTextLine>[
          ScanTextLine(
            text: 'Destroy target nonartifact creature.',
            confidence: .9,
            bounds: ScanBounds(.1, .55, .7, .03),
          ),
        ],
      ),
      _card(
        .6,
        title: null,
        footer: '174 MH3 EN',
        warnings: const <String>['incomplete_card'],
      ),
    ];
    tracker.update(partial);
    expect(tracker.tracks, hasLength(2));
    tracker.update(partial);
    await _settle();
    expect(resolver.calls, 2);
    expect(
      tracker.tracks.every((LiveScanTrack track) => !track.hasCatalogMatch),
      isTrue,
    );
    expect(
      tracker.tracks.every(
        (LiveScanTrack track) =>
            track.crop.warnings.contains('incomplete_card'),
      ),
      isTrue,
    );
  });

  test(
    'capture and first resumed frame preserve IDs through slow durable handoff',
    () {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
      );
      addTearDown(tracker.dispose);
      tracker.update(<LiveCardDetection>[_card(.1), _card(.6)]);
      final List<String> ids = tracker.tracks
          .map((LiveScanTrack track) => track.id)
          .toList();
      final int capture = tracker.beginCapture();
      now = now.add(const Duration(seconds: 4));
      tracker.endCapture(capture, resumeTracking: true);
      expect(tracker.tracks.map((LiveScanTrack track) => track.id), ids);
      now = now.add(const Duration(seconds: 3));
      tracker.update(<LiveCardDetection>[_card(.61), _card(.11)]);
      expect(tracker.tracks.map((LiveScanTrack track) => track.id), ids);
      now = now.add(const Duration(seconds: 2));
      tracker.update(const <LiveCardDetection>[]);
      expect(tracker.tracks, isEmpty);
    },
  );

  test('stalled capture and stream restart have finite independent limits', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    final int stalled = tracker.beginCapture();
    now = now.add(const Duration(seconds: 31));
    tracker.endCapture(stalled, resumeTracking: true);
    expect(tracker.tracks, isEmpty);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    final int resumed = tracker.beginCapture();
    now = now.add(const Duration(seconds: 2));
    tracker.endCapture(resumed, resumeTracking: true);
    now = now.add(const Duration(seconds: 9));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks, isEmpty);
  });

  test('restart failure releases capture grace and an empty resumed frame clears stale outlines', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    final int failed = tracker.beginCapture();
    now = now.add(const Duration(seconds: 2));
    tracker.endCapture(failed, resumeTracking: false);
    expect(tracker.tracks, isEmpty);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    final int resumed = tracker.beginCapture();
    now = now.add(const Duration(seconds: 2));
    tracker.endCapture(resumed, resumeTracking: true);
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks, isEmpty);
  });

  test(
    'camera reset invalidates capture tokens without protecting old outlines',
    () {
      DateTime now = DateTime.utc(2026);
      final LiveScanTracker tracker = LiveScanTracker(
        clock: () => now,
        resolver: _Resolver(),
      );
      addTearDown(tracker.dispose);
      tracker.update(<LiveCardDetection>[_card(.1)]);
      final int old = tracker.beginCapture();
      tracker.clear();
      expect(tracker.tracks, isEmpty);
      tracker.update(<LiveCardDetection>[_card(.6)]);
      final String fresh = tracker.tracks.single.id;
      final int current = tracker.beginCapture();
      tracker.endCapture(old, resumeTracking: false);
      now = now.add(const Duration(seconds: 2));
      tracker.endCapture(current, resumeTracking: true);
      tracker.update(<LiveCardDetection>[_card(.61)]);
      expect(tracker.tracks.single.id, fresh);
    },
  );

  test('moving cards retain distinct IDs when detection order changes', () {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1), _card(.6)]);
    final List<String> original = tracker.tracks
        .map((LiveScanTrack track) => track.id)
        .toList();
    tracker.update(<LiveCardDetection>[_card(.61), _card(.12)]);
    expect(tracker.tracks.map((LiveScanTrack track) => track.id), original);
    expect(tracker.tracks[0].corners.first.x, closeTo(.113, .0001));
    expect(tracker.tracks[1].corners.first.x, closeTo(.6065, .0001));
  });

  test(
    'matching names share lookup work without merging physical cards',
    () async {
      final _Resolver resolver = _Resolver();
      final LiveScanTracker tracker = LiveScanTracker(resolver: resolver);
      addTearDown(tracker.dispose);
      final List<LiveCardDetection> cards = <LiveCardDetection>[
        _card(.1, title: 'Lightning Bolt'),
        _card(.6, title: 'Lightning Bolt'),
      ];
      tracker.update(cards);
      expect(resolver.calls, 0);
      tracker.update(cards);
      await _settle();
      expect(resolver.calls, 1);
      expect(tracker.tracks.length, 2);
      expect(tracker.tracks[0].id, isNot(tracker.tracks[1].id));
      expect(
        tracker.tracks.every((LiveScanTrack track) => track.resolution != null),
        isTrue,
      );
      tracker.update(cards);
      await _settle();
      expect(resolver.calls, 1);
    },
  );

  test('temporary occlusion retains IDs but expired cards disappear', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    final String id = tracker.tracks.single.id;
    now = now.add(const Duration(milliseconds: 600));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks.single.id, id);
    tracker.update(<LiveCardDetection>[_card(.12)]);
    expect(tracker.tracks.single.id, id);
    now = now.add(const Duration(seconds: 2));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks, isEmpty);
  });

  test('slow native frames preserve IDs and allow identification', () async {
    DateTime now = DateTime.utc(2026);
    final _Resolver resolver = _Resolver();
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: resolver,
    );
    addTearDown(tracker.dispose);
    final List<LiveCardDetection> cards = <LiveCardDetection>[
      _card(.1, title: 'Lightning Bolt'),
    ];
    tracker.update(cards);
    final String id = tracker.tracks.single.id;
    final int analysis = tracker.beginFrameAnalysis();
    now = now.add(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(tracker.tracks.single.id, id);
    tracker.update(cards);
    tracker.endFrameAnalysis(analysis);
    await _settle();
    expect(tracker.tracks.single.id, id);
    expect(tracker.tracks.single.stableFrames, 2);
    expect(tracker.tracks.single.resolution, isNotNull);
    expect(resolver.calls, 1);
  });

  test('missing cards expire when their pending frame completes', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    final int analysis = tracker.beginFrameAnalysis();
    now = now.add(const Duration(seconds: 2));
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks, hasLength(1));
    tracker.endFrameAnalysis(analysis);
    expect(tracker.tracks, isEmpty);
  });

  test('stalled native requests cannot retain outlines indefinitely', () async {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1)]);
    final int analysis = tracker.beginFrameAnalysis();
    now = now.add(const Duration(seconds: 9));
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(tracker.tracks, isEmpty);
    tracker.endFrameAnalysis(analysis);
  });

  test('old camera analysis cannot release a new camera frame', () {
    DateTime now = DateTime.utc(2026);
    final LiveScanTracker tracker = LiveScanTracker(
      clock: () => now,
      resolver: _Resolver(),
    );
    addTearDown(tracker.dispose);
    final int previous = tracker.beginFrameAnalysis();
    tracker.clear();
    tracker.update(<LiveCardDetection>[_card(.6)]);
    final int current = tracker.beginFrameAnalysis();
    now = now.add(const Duration(seconds: 2));
    tracker.endFrameAnalysis(previous);
    tracker.update(const <LiveCardDetection>[]);
    expect(tracker.tracks, hasLength(1));
    tracker.endFrameAnalysis(current);
    expect(tracker.tracks, isEmpty);
  });

  test(
    'changing cards clears old identity and drops late lookup results',
    () async {
      final _Resolver resolver = _Resolver()
        ..pending = Completer<ScanResolution>();
      final LiveScanTracker tracker = LiveScanTracker(resolver: resolver);
      addTearDown(tracker.dispose);
      tracker.update(<LiveCardDetection>[_card(.1, title: 'Lightning Bolt')]);
      tracker.update(<LiveCardDetection>[_card(.1, title: 'Lightning Bolt')]);
      expect(tracker.tracks.single.resolving, isTrue);
      tracker.update(<LiveCardDetection>[_card(.1, title: 'Nevermore')]);
      resolver.pending!.complete(_resolution(tracker.tracks.single.crop));
      await _settle();
      expect(tracker.tracks.single.resolution, isNull);
      expect(tracker.tracks.single.resolving, isFalse);
      expect(resolver.calls, 1);
    },
  );

  test(
    'lens reset discards pending results before new tracks are read',
    () async {
      final _Resolver resolver = _Resolver()
        ..pending = Completer<ScanResolution>();
      final LiveScanTracker tracker = LiveScanTracker(resolver: resolver);
      addTearDown(tracker.dispose);
      tracker.update(<LiveCardDetection>[_card(.1, title: 'Lightning Bolt')]);
      tracker.update(<LiveCardDetection>[_card(.1, title: 'Lightning Bolt')]);
      final ScanCrop oldCrop = tracker.tracks.single.crop;
      tracker.clear();
      resolver.pending!.complete(_resolution(oldCrop));
      await _settle();
      expect(tracker.tracks, isEmpty);
      tracker.update(<LiveCardDetection>[_card(.1, title: 'Lightning Bolt')]);
      tracker.update(<LiveCardDetection>[_card(.1, title: 'Lightning Bolt')]);
      await _settle();
      expect(resolver.calls, 2);
    },
  );

  test(
    'different printing clears a cached identity with the same name',
    () async {
      final _Resolver resolver = _Resolver();
      final LiveScanTracker tracker = LiveScanTracker(resolver: resolver);
      addTearDown(tracker.dispose);
      final LiveCardDetection original = _card(
        .1,
        title: 'Lightning Bolt',
        footer: 'MOM EN',
      );
      tracker.update(<LiveCardDetection>[original]);
      tracker.update(<LiveCardDetection>[original]);
      await _settle();
      expect(tracker.tracks.single.resolution, isNotNull);
      tracker.update(<LiveCardDetection>[
        _card(.1, title: 'Lightning Bolt', footer: 'MH3 EN'),
      ]);
      expect(tracker.tracks.single.resolution, isNull);
      expect(tracker.tracks.single.stableFrames, 1);
      expect(resolver.calls, 1);
    },
  );

  test('incomplete geometry discards a previously complete result', () async {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[_card(.1, title: 'Lightning Bolt')]);
    tracker.update(<LiveCardDetection>[_card(.1, title: 'Lightning Bolt')]);
    await _settle();
    expect(tracker.tracks.single.resolution, isNotNull);
    tracker.update(<LiveCardDetection>[
      _card(.1, warnings: const <String>['incomplete_card']),
    ]);
    expect(tracker.tracks.single.resolution, isNull);
    expect(tracker.tracks.single.crop.warnings, contains('incomplete_card'));
    tracker.update(<LiveCardDetection>[_card(.1, title: null)]);
    expect(tracker.tracks.single.crop.warnings, contains('incomplete_card'));
    tracker.update(<LiveCardDetection>[_card(.1, title: 'Lightning Bolt')]);
    expect(tracker.tracks.single.crop.warnings, isEmpty);
  });

  test('malformed geometry is ignored and tracking stays bounded at eight', () {
    final LiveScanTracker tracker = LiveScanTracker(resolver: _Resolver());
    addTearDown(tracker.dispose);
    tracker.update(<LiveCardDetection>[
      const LiveCardDetection(corners: <ScanPoint>[], confidence: 1),
      const LiveCardDetection(
        corners: <ScanPoint>[
          ScanPoint(double.nan, .1),
          ScanPoint(.2, .1),
          ScanPoint(.2, .3),
          ScanPoint(.1, .3),
        ],
        confidence: 1,
      ),
      for (int index = 0; index < 10; index++) _card(.01 + index * .06),
    ]);
    expect(tracker.tracks.length, 8);
  });

  test(
    'newly readable body text invalidates a low-confidence lookup',
    () async {
      DateTime now = DateTime.utc(2026);
      final _Resolver resolver = _Resolver();
      final LiveScanTracker tracker = LiveScanTracker(
        resolver: resolver,
        clock: () => now,
      );
      addTearDown(tracker.dispose);
      LiveCardDetection body(double confidence) => LiveCardDetection(
        corners: _card(.1).corners,
        confidence: .95,
        lines: <ScanTextLine>[
          ScanTextLine(
            text: 'Destroy target nonartifact creature.',
            confidence: confidence,
            bounds: const ScanBounds(.1, .5, .7, .03),
          ),
        ],
      );
      tracker.update(<LiveCardDetection>[body(.70)]);
      tracker.update(<LiveCardDetection>[body(.70)]);
      await _settle();
      expect(resolver.calls, 1);
      expect(resolver.crops.last.lines.single.confidence, .70);
      now = now.add(const Duration(seconds: 4));
      tracker.update(<LiveCardDetection>[body(.95)]);
      tracker.update(<LiveCardDetection>[body(.95)]);
      await _settle();
      expect(resolver.calls, 2);
      expect(resolver.crops.last.lines.single.confidence, .95);
    },
  );

  test('unattempted cards precede retries after a slow lookup', () async {
    DateTime now = DateTime.utc(2026);
    final _Resolver resolver = _Resolver()
      ..pending = Completer<ScanResolution>();
    final LiveScanTracker tracker = LiveScanTracker(
      resolver: resolver,
      clock: () => now,
      expiry: const Duration(seconds: 10),
    );
    addTearDown(tracker.dispose);
    final List<LiveCardDetection> cards = <LiveCardDetection>[
      _card(.1, title: 'Lightning Bolt'),
      _card(.4, title: 'Nevermore'),
      _card(.7, title: 'Go for the Throat'),
    ];
    tracker.update(cards);
    tracker.update(cards);
    expect(resolver.calls, 1);
    now = now.add(const Duration(seconds: 4));
    tracker.update(<LiveCardDetection>[
      _card(.1, title: 'Lightning Bolt', footer: 'MH3 EN'),
      ...cards.skip(1),
    ]);
    final Completer<ScanResolution> first = resolver.pending!;
    resolver.pending = Completer<ScanResolution>();
    first.complete(_resolution(resolver.crops.first));
    await _settle();
    expect(resolver.calls, 2);
    expect(
      ScanHints.fromCrop(resolver.crops.last).names,
      contains('Nevermore'),
    );
    resolver.pending!.complete(_resolution(resolver.crops.last));
    await _settle();
  });
}
