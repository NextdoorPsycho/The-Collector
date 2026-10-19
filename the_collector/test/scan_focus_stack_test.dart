import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:the_collector/utils/scanning/live_scan_detector.dart';
import 'package:the_collector/utils/scanning/scan_draft_store.dart';
import 'package:the_collector/utils/scanning/scan_focus_stack.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';
import 'package:the_collector/utils/scanning/scan_session.dart';

List<ScanPoint> _corners(
  double x,
  double y, {
  double width = .22,
  double height = .30,
}) => <ScanPoint>[
  ScanPoint(x, y),
  ScanPoint(x + width, y),
  ScanPoint(x + width, y + height),
  ScanPoint(x, y + height),
];

List<ScanCrop> _recordedMissingGlyphNameplates() =>
    (jsonDecode(
          r'''[{"imagePath":"","width":2509,"height":3505,"rectified":true,"warnings":["geometry_adjusted"],"sharpness":0.8171000436223314,"sourceCorners":[{"x":0.23454016029834748,"y":0.5153022992610932},{"x":0.4879757297039032,"y":0.5259863150119781},{"x":0.5217621326446533,"y":0.7279763519763947},{"x":0.13155525922775269,"y":0.7172440886497498}],"lines":[{"text":"Enchantment","confidence":1.0,"alternatives":["Enchantmen","Enchantent"],"glyphHeight":0.028836659025141865,"bounds":{"x":0.04995238945801481,"y":0.601302024889211,"width":0.30987685002178783,"height":0.0345017302056686}},{"text":"As Nevermore enters the battlefield,","confidence":1.0,"alternatives":["As Nevermore enter the battlefield,","As Nevermore enters the battlefield"],"glyphHeight":0.04364113337097342,"bounds":{"x":0.05070993520886662,"y":0.6685681677958347,"width":0.9208925042019422,"height":0.04364113337097342}},{"text":"name a nonland card.","confidence":1.0,"alternatives":["name a noland card.","name a nonland card"],"glyphHeight":0.03619020950423038,"bounds":{"x":0.05022367596293049,"y":0.7060517312785773,"width":0.5590494467442728,"height":0.04270723542008348}},{"text":"The named card can't be cast.","confidence":1.0,"alternatives":["The named card can't be cast","The named card can't becast."],"glyphHeight":0.036337208897470386,"bounds":{"x":0.050709943149234576,"y":0.7572674420559581,"width":0.7728194643301793,"height":0.036337208897470386}},{"text":"\"By the law of Avacyn, the following","confidence":1.0,"alternatives":[],"glyphHeight":0.04992386839506709,"bounds":{"x":0.050184939543084665,"y":0.8066328239152966,"width":0.8470810118899402,"height":0.05692128083551794}},{"text":"thoughts, words, and deeds are","confidence":1.0,"alternatives":[],"glyphHeight":0.04626784181747046,"bounds":{"x":0.05015750717368311,"y":0.8481292105942398,"width":0.6930739444565489,"height":0.05278593433220578}},{"text":"henceforth disallowed.\"","confidence":1.0,"alternatives":[],"glyphHeight":0.044636679239599415,"bounds":{"x":0.04941861192967616,"y":0.8847750859795713,"width":0.5377906829712401,"height":0.044636679239599415}},{"text":"-Jason A. Engle","confidence":1.0,"alternatives":[],"glyphHeight":0.02239562824460524,"bounds":{"x":0.07357868668377814,"y":0.9561069797365176,"width":0.2687341454494522,"height":0.028269406597877175}},{"text":"The named card can't","confidence":1.0,"alternatives":[],"glyphHeight":0.032030235230202125,"bounds":{"x":0.06304191376217658,"y":0.760528704956623,"width":0.5588341694252165,"height":0.03504175362847481}},{"text":"\"By the law of Avacyn, th","confidence":1.0,"alternatives":[],"glyphHeight":0.04246944159835261,"bounds":{"x":0.05257558535326013,"y":0.8073651788029301,"width":0.5974244146467399,"height":0.053353349771748805}},{"text":"thoughts, words, and deeds","confidence":1.0,"alternatives":[],"glyphHeight":0.03588842404178708,"bounds":{"x":0.05255546431967411,"y":0.855800647295758,"width":0.5967364255119773,"height":0.0395975014149718}},{"text":"henceforth disallowedạẠạỊạ","confidence":1.0,"alternatives":[],"glyphHeight":0.034549483044433074,"bounds":{"x":0.05172777204666473,"y":0.8904104040722599,"width":0.5237313289268344,"height":0.03666120733048173}},{"text":"Jason A. Engle","confidence":1.0,"alternatives":[],"glyphHeight":0.02513000094827774,"bounds":{"x":0.08014911510822137,"y":0.9519264584643613,"width":0.27056315926944513,"height":0.034703918602007854}},{"text":"Nevermor","confidence":1.0,"alternatives":["Nevermo","evermor"],"glyphHeight":0.03644211131440195,"bounds":{"x":0.03869639780954018,"y":0.060811779957581136,"width":0.28877264379980083,"height":0.0376776992906584}}]},{"imagePath":"","width":2471,"height":3451,"rectified":true,"warnings":["geometry_adjusted"],"sharpness":0.6488541732042824,"sourceCorners":[{"x":0.23358964920043945,"y":0.5248166620731354},{"x":0.4924563765525818,"y":0.5340557098388672},{"x":0.5207098722457886,"y":0.7262557446956635},{"x":0.13426199555397034,"y":0.714968740940094}],"lines":[{"text":"Enchantment","confidence":1.0,"alternatives":["Enchantmen","Enchantent"],"glyphHeight":0.03289013266189514,"bounds":{"x":0.05129695364605222,"y":0.5672289260348296,"width":0.31303897104602807,"height":0.04083839849690851}},{"text":"As Nevermore enters the battlefield,","confidence":1.0,"alternatives":["As Nevermore enters the battlefield","As Nevermore enter the battlefield,"],"glyphHeight":0.04505813881530407,"bounds":{"x":0.048681567640230544,"y":0.6409883724048788,"width":0.9168356491138248,"height":0.04505813881530407}},{"text":"name a nonland card.","confidence":1.0,"alternatives":["name a nonland card","name a noland card."],"glyphHeight":0.03939745075318657,"bounds":{"x":0.04868154092958169,"y":0.6859791419345251,"width":0.5638945249292071,"height":0.03939745075318657}},{"text":"\"The named card can't be cast.","confidence":1.0,"alternatives":[],"glyphHeight":0.03974235482629599,"bounds":{"x":0.04926391059970708,"y":0.7353450069506672,"width":0.7721351697606949,"height":0.0476499991987663}},{"text":"e following","confidence":1.0,"alternatives":[],"glyphHeight":0.038499753401073825,"bounds":{"x":0.6445169284864778,"y":0.79547626043794,"width":0.2529445265489103,"height":0.04179637717464255}},{"text":"thoughts, words, and deeds are","confidence":1.0,"alternatives":[],"glyphHeight":0.042730572283079554,"bounds":{"x":0.04961214343260117,"y":0.8363414697506076,"width":0.700729567641965,"height":0.04651123032146438}},{"text":"wceforeh disall.","confidence":1.0,"alternatives":[],"glyphHeight":0.04146724160532567,"bounds":{"x":0.09905131810967148,"y":0.8731344751312695,"width":0.3437382966569326,"height":0.049548331006613475}},{"text":"Nevermore","confidence":1.0,"alternatives":["nevermore","evermore"],"glyphHeight":0.028680455330872615,"bounds":{"x":0.03823676012795537,"y":0.0,"width":0.31363559463649127,"height":0.0318634655000601}}]}]''',
        ) as List<Object?>)
        .map(
          (Object? value) => ScanCrop.fromMap(value as Map<Object?, Object?>),
        )
        .toList();

ScanCrop _crop(
  String name,
  double x,
  double y, {
  double confidence = .97,
  double sharpness = .5,
  String imagePath = '',
}) => ScanCrop(
  imagePath: imagePath,
  width: 1000,
  height: 1400,
  rectified: true,
  sourceCorners: _corners(x, y),
  sharpness: sharpness,
  lines: <ScanTextLine>[
    if (name.isNotEmpty)
      ScanTextLine(
        text: name,
        confidence: confidence,
        bounds: const ScanBounds(.05, .04, .75, .025),
      ),
  ],
);

ScanRecognition _photo(List<ScanCrop> crops) =>
    ScanRecognition(imagePath: '', width: 4000, height: 6000, crops: crops);

ScanCrop _corroborated(String name, double x, double y) {
  final ScanCrop crop = _crop(name, x, y);
  return ScanCrop(
    imagePath: crop.imagePath,
    width: crop.width,
    height: crop.height,
    rectified: crop.rectified,
    sourceCorners: crop.sourceCorners,
    lines: <ScanTextLine>[
      ...crop.lines,
      const ScanTextLine(
        text: 'Creature',
        confidence: .99,
        bounds: ScanBounds(.05, .55, .70, .025),
      ),
      const ScanTextLine(
        text: 'Whenever you sacrifice a token, draw a card.',
        confidence: .99,
        bounds: ScanBounds(.05, .62, .70, .025),
      ),
    ],
  );
}

class _SceneRecognizer implements CardRecognizer {
  final List<List<ScanCrop>> scenes;
  final Completer<void>? firstStarted;
  final Completer<void>? firstRelease;
  int calls = 0;
  final List<int> sourceIndexes = <int>[];

  _SceneRecognizer(this.scenes, {this.firstStarted, this.firstRelease});

  @override
  Future<ScanRecognition> recognize(
    String imagePath, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    final int index = (await File(imagePath).readAsBytes()).first;
    calls++;
    sourceIndexes.add(index);
    if (calls == 1 && firstRelease != null) {
      firstStarted?.complete();
      await firstRelease!.future;
    }
    return _photo(scenes[index]);
  }
}

class _ReviewResolver extends ScanResolver {
  final List<List<ScanCrop>> batches = <List<ScanCrop>>[];

  @override
  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async {
    batches.add(crops);
    return crops
        .map(
          (ScanCrop crop) => ScanResolution(
            candidates: const <ScanCandidate>[],
            hints: ScanHints.fromCrop(crop),
            status: ScanResolutionStatus.needsReview,
          ),
        )
        .toList();
  }
}

class _InterruptedGroupBox extends Fake implements Box<String> {
  final Box<String> delegate;
  _InterruptedGroupBox(this.delegate);
  @override
  String? get path => delegate.path;
  @override
  String? get(Object? key, {String? defaultValue}) =>
      delegate.get(key, defaultValue: defaultValue);
  @override
  Future<void> put(Object? key, String value) => delegate.put(key, value);
  @override
  Future<void> putAll(Map<Object?, String> entries) => delegate.putAll(entries);
  @override
  Future<void> flush() => delegate.flush();
  @override
  Future<void> delete(Object? key) async => throw const FileSystemException(
    'Interrupted after durable group source transfer.',
  );
}

class _LostGroupAcknowledgementBox extends Fake implements Box<String> {
  final Box<String> delegate;
  _LostGroupAcknowledgementBox(this.delegate);
  bool failed = false;
  @override
  String? get path => delegate.path;
  @override
  String? get(Object? key, {String? defaultValue}) =>
      delegate.get(key, defaultValue: defaultValue);
  @override
  bool containsKey(Object? key) => delegate.containsKey(key);
  @override
  Future<void> put(Object? key, String value) => delegate.put(key, value);
  @override
  Future<void> flush() async {
    await delegate.flush();
    if (!failed) {
      failed = true;
      throw const FileSystemException('Durable group acknowledgement lost.');
    }
  }
}

Future<void> _settled(ScanSession session) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
  while (session.running || session.remainingPhotos > 0) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Focus-stack session did not settle.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

// Native OCR and corners for the mounted scene; local image paths are omitted.
List<ScanCrop> _recordedCircleDepthPair() {
  const String source = r'''[
  {
    "imagePath": "",
    "width": 2896,
    "height": 3786,
    "rectified": true,
    "warnings": [
      "geometry_adjusted"
    ],
    "sharpness": 0.8897256519252477,
    "sourceCorners": [
      {
        "x": 0.3024496805667877,
        "y": 0.5399896585941315
      },
      {
        "x": 0.5680259490013122,
        "y": 0.5761374211311341
      },
      {
        "x": 0.5595053434371948,
        "y": 0.8407302647829056
      },
      {
        "x": 0.1155131608247757,
        "y": 0.7838799953460693
      }
    ],
    "lines": [
      {
        "text": "1\u7c73",
        "confidence": 0.30000001192092896,
        "alternatives": [],
        "glyphHeight": 0.032025884838880136,
        "bounds": {
          "x": 0.865275142365958,
          "y": 0.09297411561843649,
          "width": 0.10626185928260423,
          "height": 0.03202588383130023
        }
      },
      {
        "text": "Enchantment",
        "confidence": 1.0,
        "alternatives": [
          "Enchaniment",
          "Enchanment"
        ],
        "glyphHeight": 0.027157676155976584,
        "bounds": {
          "x": 0.0337725071105594,
          "y": 0.604349134586288,
          "width": 0.3100159155071111,
          "height": 0.03069288492580602
        }
      },
      {
        "text": "; Prevent all damage against you",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.034648302377299586,
        "bounds": {
          "x": 0.12752754196281346,
          "y": 0.7,
          "width": 0.7463171521603074,
          "height": 0.03904212965382958
        }
      },
      {
        "text": "from one blue source. If a source",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03431095523806075,
        "bounds": {
          "x": 0.08851360042742439,
          "y": 0.7269690639715578,
          "width": 0.7749800708412464,
          "height": 0.037039949524570515
        }
      },
      {
        "text": "deals damage to you mo",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03367479711720986,
        "bounds": {
          "x": 0.09422134592885249,
          "y": 0.76,
          "width": 0.5508719474646696,
          "height": 0.041994820519620245
        }
      },
      {
        "text": "once in a turn, you may",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03094656569669348,
        "bounds": {
          "x": 0.09444919133433627,
          "y": 0.7957414679694851,
          "width": 0.5450502723645253,
          "height": 0.036641663939088236
        }
      },
      {
        "text": "each time to prevent the",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.0331034485533997,
        "bounds": {
          "x": 0.09479166232914235,
          "y": 0.8282758619205737,
          "width": 0.5525000084231108,
          "height": 0.0331034485533997
        }
      },
      {
        "text": "Cirele of Protection: Blue",
        "confidence": 1.0,
        "alternatives": [
          "Cirele of Protection Blue",
          "Cirele of Protection: Blae"
        ],
        "glyphHeight": 0.03484334101075652,
        "bounds": {
          "x": 0.029166667835804842,
          "y": 0.09157894816816481,
          "width": 0.6583333305232433,
          "height": 0.03484333899713333
        }
      }
    ]
  },
  {
    "imagePath": "",
    "width": 3324,
    "height": 4096,
    "rectified": true,
    "warnings": [],
    "sharpness": 0.8485223244088836,
    "sourceCorners": [
      {
        "x": 0.27109721302986145,
        "y": 0.545676589012146
      },
      {
        "x": 0.6126383543014526,
        "y": 0.545676589012146
      },
      {
        "x": 0.5881348252296448,
        "y": 0.867768868803978
      },
      {
        "x": 0.045842740684747696,
        "y": 0.8123952597379684
      }
    ],
    "lines": [
      {
        "text": "Enchantment",
        "confidence": 1.0,
        "alternatives": [
          "Enchaniment",
          "Enchanment"
        ],
        "glyphHeight": 0.027338026611171986,
        "bounds": {
          "x": 0.12041792314897436,
          "y": 0.5292732554482821,
          "width": 0.3000586027038126,
          "height": 0.06133720988319036
        }
      },
      {
        "text": "Prevent all damage against you",
        "confidence": 1.0,
        "alternatives": [
          "Preventall damage against you",
          "Prevent all damage agains you"
        ],
        "glyphHeight": 0.03297092676752825,
        "bounds": {
          "x": 0.24064083168026104,
          "y": 0.6339481794824766,
          "width": 0.6054403216448272,
          "height": 0.08950588059803799
        }
      },
      {
        "text": "suc source, ir a source",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.037232409310390374,
        "bounds": {
          "x": 0.41473053106557256,
          "y": 0.7,
          "width": 0.4268837065279625,
          "height": 0.04875879286432674
        }
      },
      {
        "text": "damage to you more than",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03251144907499559,
        "bounds": {
          "x": 0.3064610687370458,
          "y": 0.7,
          "width": 0.5000934285193189,
          "height": 0.07673164197518782
        }
      },
      {
        "text": "in a turn, you may pay 1",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03582232004641828,
        "bounds": {
          "x": 0.30255642573309877,
          "y": 0.7336186251096277,
          "width": 0.4790013811548833,
          "height": 0.06533022505787617
        }
      },
      {
        "text": "Time",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.02313324609448486,
        "bounds": {
          "x": 0.2955799398130096,
          "y": 0.762306393726302,
          "width": 0.10681541096080432,
          "height": 0.03478084358626495
        }
      },
      {
        "text": "Hsyoum",
        "confidence": 0.30000001192092896,
        "alternatives": [],
        "glyphHeight": 0.020778373003045202,
        "bounds": {
          "x": 0.4487217537425874,
          "y": 0.76,
          "width": 0.18596569824218748,
          "height": 0.022648788348282076
        }
      },
      {
        "text": "prevenr",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.018901103681559332,
        "bounds": {
          "x": 0.46111637210797746,
          "y": 0.7820914895653146,
          "width": 0.16714502369273798,
          "height": 0.026834641873479607
        }
      },
      {
        "text": "ele of Drorcerione BI",
        "confidence": 1.0,
        "alternatives": [
          "ele of Drorcerione Bi",
          "ele of Drorcerion BI"
        ],
        "glyphHeight": 0.029821130020635113,
        "bounds": {
          "x": 0.19606397012953294,
          "y": 0.07362295468499269,
          "width": 0.44211504419926495,
          "height": 0.10637704531500734
        }
      }
    ]
  }
]''';
  return (jsonDecode(source) as List<Object?>)
      .map((Object? crop) => ScanCrop.fromMap(crop as Map<Object?, Object?>))
      .toList();
}

// Native depth observations with the final title word absent in one crop.
List<ScanCrop> _recordedSuffixDepthPair() {
  const String source = r'''[
  {
    "imagePath": "",
    "width": 2894,
    "height": 3603,
    "rectified": true,
    "warnings": [],
    "sharpness": 0.8626987646155565,
    "sourceCorners": [
      {
        "x": 0.28343665599823,
        "y": 0.5493696630001068
      },
      {
        "x": 0.5745145678520203,
        "y": 0.5732924342155457
      },
      {
        "x": 0.5678433179855347,
        "y": 0.8467259705066681
      },
      {
        "x": 0.09699477255344391,
        "y": 0.7845738679170609
      }
    ],
    "lines": [
      {
        "text": "Enchantment",
        "confidence": 1.0,
        "alternatives": [
          "Enchaniment",
          "Enchanument"
        ],
        "glyphHeight": 0.026921936100320655,
        "bounds": {
          "x": 0.06343010331845242,
          "y": 0.5568800187477108,
          "width": 0.31418451969592265,
          "height": 0.042669438098564605
        }
      },
      {
        "text": "1; Prevent all damage against you",
        "confidence": 1.0,
        "alternatives": [
          "1: Prevent all damage against you",
          "1 ; Prevent all damage against you"
        ],
        "glyphHeight": 0.035462370946913284,
        "bounds": {
          "x": 0.13079136569359187,
          "y": 0.6565512329151192,
          "width": 0.7366214480660418,
          "height": 0.061671884687044765
        }
      },
      {
        "text": "ne blue source. If a source",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03410983846039004,
        "bounds": {
          "x": 0.2828576888159966,
          "y": 0.7,
          "width": 0.5754842487960004,
          "height": 0.04124745422865369
        }
      },
      {
        "text": "deals damage to you more than",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03734563009224988,
        "bounds": {
          "x": 0.1278704325541057,
          "y": 0.7288981773610461,
          "width": 0.6898977916324724,
          "height": 0.05664262753978454
        }
      },
      {
        "text": "once in a turn, you may pay -",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03329603496900237,
        "bounds": {
          "x": 0.1242697974903685,
          "y": 0.7671367900585535,
          "width": 0.659880178750756,
          "height": 0.046247246084724476
        }
      },
      {
        "text": "e to prevent the damage.",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.036392872450734526,
        "bounds": {
          "x": 0.31776896934412313,
          "y": 0.8000112601810957,
          "width": 0.5389642616593598,
          "height": 0.04316919577099698
        }
      },
      {
        "text": "n, you ma",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.024030439326948164,
        "bounds": {
          "x": 0.4183156693644319,
          "y": 0.7772764752358619,
          "width": 0.21203355779049882,
          "height": 0.025492550186967736
        }
      },
      {
        "text": "each time to prevent th",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03436053522239588,
        "bounds": {
          "x": 0.1295908692804016,
          "y": 0.8006444316472283,
          "width": 0.5071890754983478,
          "height": 0.03917362627201215
        }
      },
      {
        "text": "\u6c34T",
        "confidence": 0.30000001192092896,
        "alternatives": [],
        "glyphHeight": 0.026913939021183893,
        "bounds": {
          "x": 0.8606906213566478,
          "y": 0.08849330930300936,
          "width": 0.0888225605509243,
          "height": 0.026913945359450114
        }
      },
      {
        "text": "Cirele of Drotection: Blue",
        "confidence": 1.0,
        "alternatives": [
          "Cirele of Drorection: Blue",
          "Cirele of Drotection: Blae"
        ],
        "glyphHeight": 0.04112329462491497,
        "bounds": {
          "x": 0.054070983433861415,
          "y": 0.010087076708985898,
          "width": 0.6465970812456807,
          "height": 0.0918807621882512
        }
      }
    ]
  },
  {
    "imagePath": "",
    "width": 3299,
    "height": 4096,
    "rectified": true,
    "warnings": [],
    "sharpness": 0.8492947857484905,
    "sourceCorners": [
      {
        "x": 0.2722156345844269,
        "y": 0.545676589012146
      },
      {
        "x": 0.6126383543014526,
        "y": 0.545676589012146
      },
      {
        "x": 0.5881266593933105,
        "y": 0.8678772002458572
      },
      {
        "x": 0.043639808893203735,
        "y": 0.8123147487640381
      }
    ],
    "lines": [
      {
        "text": "1",
        "confidence": 1.0,
        "alternatives": [
          "I"
        ],
        "glyphHeight": 0.017441860174418622,
        "bounds": {
          "x": 0.8122743681639119,
          "y": 0.21511627949648238,
          "width": 0.01624548728830122,
          "height": 0.01744185932098874
        }
      },
      {
        "text": "Enchantment",
        "confidence": 1.0,
        "alternatives": [
          "Finchantment",
          "Finchanument"
        ],
        "glyphHeight": 0.027082116056899433,
        "bounds": {
          "x": 0.12116512414391128,
          "y": 0.5308750958296442,
          "width": 0.3009169066480815,
          "height": 0.06507412592569994
        }
      },
      {
        "text": "1; Prevent all damage against you",
        "confidence": 1.0,
        "alternatives": [
          "1: Prevent all damage against you",
          "1 ; Prevent all damage against you"
        ],
        "glyphHeight": 0.0338231476034321,
        "bounds": {
          "x": 0.1875954922415606,
          "y": 0.6299369410248622,
          "width": 0.6609273074295721,
          "height": 0.09611375748165074
        }
      },
      {
        "text": "Fyyou",
        "confidence": 0.30000001192092896,
        "alternatives": [],
        "glyphHeight": 0.017509727054843827,
        "bounds": {
          "x": 0.7223837223071969,
          "y": 0.7000000002727407,
          "width": 0.12209302031965685,
          "height": 0.017509727054843827
        }
      },
      {
        "text": "ut sourcea a source",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.031952903002009723,
        "bounds": {
          "x": 0.4151399798776363,
          "y": 0.7,
          "width": 0.42652442156563974,
          "height": 0.04985031034148728
        }
      },
      {
        "text": "deals damage to you more man",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.036462829893284046,
        "bounds": {
          "x": 0.18773326816572997,
          "y": 0.7,
          "width": 0.6237640741587248,
          "height": 0.08403322341083089
        }
      },
      {
        "text": "once in a turn, you may pay 1",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.02948320354808738,
        "bounds": {
          "x": 0.19373329505760484,
          "y": 0.7280288317341428,
          "width": 0.5875551120045619,
          "height": 0.0712646266737755
        }
      },
      {
        "text": "cn time",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.0198523594463388,
        "bounds": {
          "x": 0.2470965486406988,
          "y": 0.7613028584516268,
          "width": 0.17104637978293677,
          "height": 0.03526686383237933
        }
      },
      {
        "text": "usyoum",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.02039278135445221,
        "bounds": {
          "x": 0.4594320401088254,
          "y": 0.76,
          "width": 0.17272921198064622,
          "height": 0.024663845379365838
        }
      },
      {
        "text": "Lirele of Protections",
        "confidence": 1.0,
        "alternatives": [
          "Lirele of Protection:",
          "Lirele of Protection"
        ],
        "glyphHeight": 0.030683894101641268,
        "bounds": {
          "x": 0.12259641326893952,
          "y": 0.057200842881926506,
          "width": 0.4558342106235225,
          "height": 0.12243509740502348
        }
      }
    ]
  }
]''';
  return (jsonDecode(source) as List<Object?>)
      .map((Object? crop) => ScanCrop.fromMap(crop as Map<Object?, Object?>))
      .toList();
}

// Native OCR and physical corners from the mounted split-nameplate scene.
List<ScanCrop> _recordedSplitNameplatePair() =>
    (jsonDecode(r'''[
  {
    "imagePath": "",
    "width": 2563,
    "height": 3580,
    "rectified": true,
    "warnings": [
      "geometry_adjusted"
    ],
    "sharpness": 0.8276808461559894,
    "sourceCorners": [
      {
        "x": 0.28108805418014526,
        "y": 0.5516548454761505
      },
      {
        "x": 0.5713298320770264,
        "y": 0.5911073386669159
      },
      {
        "x": 0.5664791464805603,
        "y": 0.8453986942768097
      },
      {
        "x": 0.0918872058391571,
        "y": 0.7834618985652924
      }
    ],
    "lines": [
      {
        "text": "Enchantment",
        "confidence": 1.0,
        "alternatives": [
          "Enchantent",
          "Enchanament"
        ],
        "glyphHeight": 0.02470930301943297,
        "bounds": {
          "x": 0.07505071358688868,
          "y": 0.5624999995880497,
          "width": 0.29006084376675845,
          "height": 0.02470930301943297
        }
      },
      {
        "text": "1: Prevent all damage against you",
        "confidence": 1.0,
        "alternatives": [
          "1; Prevent all damage against you",
          "1 Prevent all damage against you"
        ],
        "glyphHeight": 0.03847392415741908,
        "bounds": {
          "x": 0.1357752011113769,
          "y": 0.6605720808712504,
          "width": 0.7284320706324348,
          "height": 0.04020166663484204
        }
      },
      {
        "text": "from one blue source. I1 a source",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.030985164332714463,
        "bounds": {
          "x": 0.12886507201314162,
          "y": 0.7,
          "width": 0.7255346622556309,
          "height": 0.03381361746570389
        }
      },
      {
        "text": "deals damage to you more than",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.036318461030972415,
        "bounds": {
          "x": 0.13352704265741222,
          "y": 0.7318755946170588,
          "width": 0.6748763871453295,
          "height": 0.03989813181275097
        }
      },
      {
        "text": "pay 1",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.029105577250337945,
        "bounds": {
          "x": 0.6429928916285537,
          "y": 0.7683229953250668,
          "width": 0.1356873891654885,
          "height": 0.036664564249901783
        }
      },
      {
        "text": "e so nrevenr ma",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.02196606181612265,
        "bounds": {
          "x": 0.3193008001233607,
          "y": 0.8075780726407592,
          "width": 0.32788171634287244,
          "height": 0.02622755679338339
        }
      },
      {
        "text": "once",
        "confidence": 0.30000001192092896,
        "alternatives": [],
        "glyphHeight": 0.027096773369367718,
        "bounds": {
          "x": 0.13541666662186275,
          "y": 0.771612903366929,
          "width": 0.11645833412710788,
          "height": 0.027096773369367718
        }
      },
      {
        "text": "in a turn, you ma",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.02884431144750516,
        "bounds": {
          "x": 0.2459105312276686,
          "y": 0.7713067223300942,
          "width": 0.3747262283819778,
          "height": 0.033084126317223836
        }
      },
      {
        "text": "each time to prevent th",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.0352385528728049,
        "bounds": {
          "x": 0.13230873919100855,
          "y": 0.8003241219169644,
          "width": 0.49655269700653704,
          "height": 0.040156930612963306
        }
      },
      {
        "text": "Circle of Protection: Blue",
        "confidence": 1.0,
        "alternatives": [
          "Circle of Protection Blue",
          "Circle of Protection: Blae"
        ],
        "glyphHeight": 0.03969157096703066,
        "bounds": {
          "x": 0.06796519390207781,
          "y": 0.0,
          "width": 0.6209256414690182,
          "height": 0.04437989612762987
        }
      }
    ]
  },
  {
    "imagePath": "",
    "width": 3317,
    "height": 4096,
    "rectified": true,
    "warnings": [],
    "sharpness": 0.8460907699485647,
    "sourceCorners": [
      {
        "x": 0.2704157531261444,
        "y": 0.545676589012146
      },
      {
        "x": 0.6104201078414917,
        "y": 0.545676589012146
      },
      {
        "x": 0.5886127352714539,
        "y": 0.8681817799806595
      },
      {
        "x": 0.04581880196928978,
        "y": 0.8118046075105667
      }
    ],
    "lines": [
      {
        "text": "Enchantment",
        "confidence": 1.0,
        "alternatives": [
          "Finchantment",
          "Finchaniment"
        ],
        "glyphHeight": 0.028254322462768988,
        "bounds": {
          "x": 0.1198720116148133,
          "y": 0.5301195810769825,
          "width": 0.3024996344618321,
          "height": 0.0671249949742877
        }
      },
      {
        "text": "; Prevent all damage against you",
        "confidence": 1.0,
        "alternatives": [
          ": Prevent all damage against you",
          "Prevent all damage against you"
        ],
        "glyphHeight": 0.032445740268949814,
        "bounds": {
          "x": 0.21276701067418818,
          "y": 0.6310998663636641,
          "width": 0.6347842382932105,
          "height": 0.09482852996341773
        }
      },
      {
        "text": "Pyou",
        "confidence": 0.30000001192092896,
        "alternatives": [],
        "glyphHeight": 0.017417972570852966,
        "bounds": {
          "x": 0.7392308180028666,
          "y": 0.7,
          "width": 0.10721902022156882,
          "height": 0.0180843615991761
        }
      },
      {
        "text": "ae source, Ha source",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.026026513986992197,
        "bounds": {
          "x": 0.44188477664038833,
          "y": 0.7,
          "width": 0.399308445455047,
          "height": 0.04695062369053358
        }
      },
      {
        "text": "deals damage to you more man",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03581801740735541,
        "bounds": {
          "x": 0.18776307202373502,
          "y": 0.7,
          "width": 0.6236451560430768,
          "height": 0.08377548508647029
        }
      },
      {
        "text": "once in a turn, you may pay 1",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03546680750785607,
        "bounds": {
          "x": 0.18924092428606834,
          "y": 0.7245880408462959,
          "width": 0.5926150478567356,
          "height": 0.07631328764415919
        }
      },
      {
        "text": "each time to prevent the damage.",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03449456643046993,
        "bounds": {
          "x": 0.19067800588867972,
          "y": 0.7527805309179926,
          "width": 0.6538848248280238,
          "height": 0.0843389238630022
        }
      },
      {
        "text": "u nof s",
        "confidence": 0.30000001192092896,
        "alternatives": [],
        "glyphHeight": 0.02146681696845474,
        "bounds": {
          "x": 0.45412390114579376,
          "y": 0.76,
          "width": 0.18855919333065269,
          "height": 0.024161446418709636
        }
      },
      {
        "text": "Cirale",
        "confidence": 0.5,
        "alternatives": [
          "Cirele",
          "Ciree"
        ],
        "glyphHeight": 0.02665470172385608,
        "bounds": {
          "x": 0.12294069074488718,
          "y": 0.05870124091067297,
          "width": 0.1517782138332751,
          "height": 0.06257716587611609
        }
      },
      {
        "text": "of Protection: Blue",
        "confidence": 1.0,
        "alternatives": [
          "of Protection Blue",
          "of Protection: Bluc"
        ],
        "glyphHeight": 0.02901807234480483,
        "bounds": {
          "x": 0.2664446017133064,
          "y": 0.08871261073028902,
          "width": 0.4203099637539546,
          "height": 0.11628488813127788
        }
      },
      {
        "text": "1",
        "confidence": 0.5,
        "alternatives": [],
        "glyphHeight": 0.020999999737499983,
        "bounds": {
          "x": 0.8145859080456169,
          "y": 0.21100000023205445,
          "width": 0.02101359779937184,
          "height": 0.020999999273390992
        }
      }
    ]
  }
]''') as List<Object?>)
        .map(
          (Object? value) => ScanCrop.fromMap(value as Map<Object?, Object?>),
        )
        .toList();

// Native split title and one-letter type OCR loss from the latest depth pair.
List<ScanCrop> _recordedNativeTypeTypoPair() =>
    (jsonDecode(r'''[
  {
    "imagePath": "",
    "width": 3188,
    "height": 4096,
    "rectified": true,
    "warnings": [],
    "sharpness": 0.8413299387009907,
    "sourceCorners": [
      {
        "x": 0.2716580629348755,
        "y": 0.545676589012146
      },
      {
        "x": 0.5989701747894287,
        "y": 0.545676589012146
      },
      {
        "x": 0.5887516140937805,
        "y": 0.8669389486312866
      },
      {
        "x": 0.04475529119372368,
        "y": 0.811247244477272
      }
    ],
    "lines": [
      {
        "text": "Enchanment",
        "confidence": 1.0,
        "alternatives": [
          "Enchanmment",
          "Enchanent"
        ],
        "glyphHeight": 0.021949489739247506,
        "bounds": {
          "x": 0.12918607435609486,
          "y": 0.5412537830478223,
          "width": 0.2957641134754422,
          "height": 0.05686737999083502
        }
      },
      {
        "text": "1: Prevent",
        "confidence": 1.0,
        "alternatives": [
          "1; Prevent",
          "1 : Prevent"
        ],
        "glyphHeight": 0.03175347834734055,
        "bounds": {
          "x": 0.18600773804492762,
          "y": 0.6414677831299461,
          "width": 0.23991632309592095,
          "height": 0.0456403948011852
        }
      },
      {
        "text": "all damage agamnst you",
        "confidence": 1.0,
        "alternatives": [
          "all damage agamst you",
          "all damage agast you"
        ],
        "glyphHeight": 0.028651165514607495,
        "bounds": {
          "x": 0.41543196007484023,
          "y": 0.6582666825415848,
          "width": 0.43990367259699653,
          "height": 0.076003490932404
        }
      },
      {
        "text": "ouc source.",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.02034874330672449,
        "bounds": {
          "x": 0.3937314028032592,
          "y": 0.7,
          "width": 0.2475903378028959,
          "height": 0.032277354863256204
        }
      },
      {
        "text": "If a source",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.0279554697395336,
        "bounds": {
          "x": 0.6429879717472096,
          "y": 0.705141346913405,
          "width": 0.20852096593689973,
          "height": 0.05187124512279565
        }
      },
      {
        "text": "deals damage to you more than",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.039389784351096004,
        "bounds": {
          "x": 0.18728668840220122,
          "y": 0.7,
          "width": 0.6289391483820922,
          "height": 0.09202236672624364
        }
      },
      {
        "text": "once in a turn, you may pay 1",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03633714821975467,
        "bounds": {
          "x": 0.1883404959653736,
          "y": 0.7280722199181009,
          "width": 0.6028637536592236,
          "height": 0.08289072057189471
        }
      },
      {
        "text": "each time to prevent",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.02564652238524299,
        "bounds": {
          "x": 0.19532507097517227,
          "y": 0.7654857006850211,
          "width": 0.42160223943536934,
          "height": 0.05830596222274605
        }
      },
      {
        "text": "Cirele",
        "confidence": 0.5,
        "alternatives": [
          "Círele",
          "Cirele"
        ],
        "glyphHeight": 0.03038126888956835,
        "bounds": {
          "x": 0.118488954615713,
          "y": 0.05899310653991652,
          "width": 0.170189354718436,
          "height": 0.062050395395563944
        }
      },
      {
        "text": "of Protection Blue",
        "confidence": 1.0,
        "alternatives": [
          "of Protection: Blue",
          "of Protections Blue"
        ],
        "glyphHeight": 0.030881042150621107,
        "bounds": {
          "x": 0.27076128808508415,
          "y": 0.09074917678222127,
          "width": 0.43124952383920656,
          "height": 0.12159303160919538
        }
      }
    ]
  },
  {
    "imagePath": "",
    "width": 2906,
    "height": 3810,
    "rectified": true,
    "warnings": [
      "geometry_adjusted"
    ],
    "sharpness": 0.88646600195598,
    "sourceCorners": [
      {
        "x": 0.3027878564596176,
        "y": 0.5397635054588318
      },
      {
        "x": 0.5672898554801941,
        "y": 0.5763931894302368
      },
      {
        "x": 0.5596041679382324,
        "y": 0.8408125638961792
      },
      {
        "x": 0.1151362732052803,
        "y": 0.7838845551013947
      }
    ],
    "lines": [
      {
        "text": "Enchantment",
        "confidence": 1.0,
        "alternatives": [
          "Finchantment",
          "Fincharment"
        ],
        "glyphHeight": 0.025742246172967383,
        "bounds": {
          "x": 0.03200172032434784,
          "y": 0.6058267697931525,
          "width": 0.3092895003736881,
          "height": 0.02896805009816883
        }
      },
      {
        "text": "1; Prevent all damage against you",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.0342395129369672,
        "bounds": {
          "x": 0.09835294843553934,
          "y": 0.7,
          "width": 0.7740990992504732,
          "height": 0.03909581015525341
        }
      },
      {
        "text": "from one blue source. If a source",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.031730769230769215,
        "bounds": {
          "x": 0.09166666524124657,
          "y": 0.7314685319424417,
          "width": 0.7666666722675068,
          "height": 0.031730769230769215
        }
      },
      {
        "text": "deals damage to you mo",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.032442787037519155,
        "bounds": {
          "x": 0.09435860341250142,
          "y": 0.7623378147809778,
          "width": 0.5506159803602432,
          "height": 0.03852061708941732
        }
      },
      {
        "text": "once in a turn, you may",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03251986576654026,
        "bounds": {
          "x": 0.09435544668843693,
          "y": 0.7954088742782615,
          "width": 0.5424890491949819,
          "height": 0.03846449406386462
        }
      },
      {
        "text": "each time to prevent the",
        "confidence": 1.0,
        "alternatives": [],
        "glyphHeight": 0.03196092185103198,
        "bounds": {
          "x": 0.09460813601139885,
          "y": 0.8274746744476916,
          "width": 0.5474610440693205,
          "height": 0.03455059867758939
        }
      },
      {
        "text": "Circle of Protections Blue",
        "confidence": 1.0,
        "alternatives": [
          "Circle of Protection: Blue",
          "Circle of Protection Blue"
        ],
        "glyphHeight": 0.03429933163413071,
        "bounds": {
          "x": 0.03117236705386845,
          "y": 0.09064716594797495,
          "width": 0.654119356369365,
          "height": 0.03961864221564548
        }
      },
      {
        "text": "1 Ж",
        "confidence": 0.30000001192092896,
        "alternatives": [
          "1 ж",
          "1 *"
        ],
        "glyphHeight": 0.02709606920267298,
        "bounds": {
          "x": 0.8687664043788512,
          "y": 0.09499999957911265,
          "width": 0.09842519635425628,
          "height": 0.027096070202156968
        }
      }
    ]
  }
]''') as List<Object?>)
        .map(
          (Object? value) => ScanCrop.fromMap(value as Map<Object?, Object?>),
        )
        .toList();

void main() {
  test('saved no-text card contours remain unresolved selections without identity evidence', () {
    ScanCrop unreadable(double x, String path, double sharpness) => ScanCrop(
      imagePath: path,
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: _corners(x, .2),
      lines: const <ScanTextLine>[],
      warnings: const <String>['incomplete_card', 'no_text'],
      sharpness: sharpness,
    );
    final ScanCrop first = unreadable(.1, '/tmp/first-card.jpg', .1);
    final ScanCrop clearer = unreadable(.1, '/tmp/clearer-card.jpg', .8);
    final ScanCrop copy = unreadable(.6, '/tmp/second-card.jpg', .2);
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[first, copy]),
      ]),
      isEmpty,
      reason: 'Untargeted rectangles alone do not prove cards are present.',
    );
    final List<ScanFocusSelection> selections = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[first, copy]),
        _photo(<ScanCrop>[clearer]),
      ],
      retainUnreadableContours: true,
    );
    expect(selections, hasLength(2));
    final ScanFocusSelection retained = selections.singleWhere(
      (ScanFocusSelection value) => identical(value.crop, clearer),
    );
    expect(retained.observations, 2);
    expect(retained.photoIndex, 1);
    for (final ScanFocusSelection selection in selections) {
      final ScanHints hints = ScanHints.fromCrop(selection.crop);
      expect(hints.names, isEmpty);
      expect(hints.rulesText, isEmpty);
      expect(hints.collectorNumber, isNull);
      expect(hints.setCode, isNull);
    }
  });

  test('image-only focus selection rejects live metadata and invalid or fallback geometry', () {
    ScanCrop crop({
      String path = '/tmp/unreadable-card.jpg',
      bool rectified = true,
      int width = 1000,
      int height = 1400,
      List<ScanPoint>? corners,
      List<String> warnings = const <String>['incomplete_card', 'no_text'],
    }) => ScanCrop(
      imagePath: path,
      width: width,
      height: height,
      rectified: rectified,
      sourceCorners: corners ?? _corners(.1, .2),
      lines: const <ScanTextLine>[],
      warnings: warnings,
    );
    for (final ScanCrop invalid in <ScanCrop>[
      crop(path: ''),
      crop(rectified: false),
      crop(width: 30, height: 42),
      crop(width: 1400, height: 1000),
      crop(warnings: const <String>['partial_card', 'no_text']),
      crop(warnings: const <String>['no_card_rectangle', 'no_text']),
      crop(warnings: const <String>['unknown_warning', 'no_text']),
      crop(corners: const <ScanPoint>[]),
      crop(corners: _corners(-.1, .2)),
      crop(
        corners: const <ScanPoint>[
          ScanPoint(.1, .2),
          ScanPoint(.3, .5),
          ScanPoint(.3, .2),
          ScanPoint(.1, .5),
        ],
      ),
      crop(
        corners: const <ScanPoint>[
          ScanPoint(.1, .2),
          ScanPoint(.3, .2),
          ScanPoint(.15, .25),
          ScanPoint(.1, .5),
        ],
      ),
      crop(corners: List<ScanPoint>.filled(4, const ScanPoint(.1, .2))),
    ]) {
      expect(
        mergeScanFocusStack(<ScanRecognition>[
          _photo(<ScanCrop>[invalid]),
        ], retainUnreadableContours: true),
        isEmpty,
      );
    }
  });

  test('recorded same foreground card with one missing title glyph selects the complete observed name', () {
    final List<ScanCrop> crops = _recordedMissingGlyphNameplates();
    expect(ScanHints.fromCrop(crops.first).names, <String>['Nevermor']);
    expect(ScanHints.fromCrop(crops.last).names, <String>['Nevermore']);
    final List<ScanFocusSelection> selected = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[crops.first]),
        _photo(<ScanCrop>[crops.last]),
      ],
    );
    expect(selected, hasLength(1));
    expect(selected.single.photoIndex, 1);
    expect(selected.single.observations, 2);
    expect(ScanHints.fromCrop(selected.single.crop).names, <String>[
      'Nevermore',
    ]);
    expect(selected.single.crop, same(crops.last));
  });

  test('missing title glyph cannot merge adjacent copies, replacements, or conflicting printing evidence', () {
    final List<ScanCrop> crops = _recordedMissingGlyphNameplates();
    final ScanCrop first = crops.first;
    final ScanCrop second = crops.last;
    ScanCrop changed(
      ScanCrop crop, {
      double dx = 0,
      List<ScanTextLine>? lines,
    }) => ScanCrop(
      imagePath: crop.imagePath,
      width: crop.width,
      height: crop.height,
      rectified: crop.rectified,
      warnings: crop.warnings,
      sharpness: crop.sharpness,
      sourceCorners: crop.sourceCorners
          .map((ScanPoint point) => ScanPoint(point.x + dx, point.y))
          .toList(),
      lines: lines ?? crop.lines,
    );
    ScanTextLine text(ScanTextLine line, String value) => ScanTextLine(
      text: value,
      confidence: line.confidence,
      bounds: line.bounds,
      glyphHeight: line.glyphHeight,
      alternatives: const <String>[],
    );
    ScanCrop replaced(String before, String after) => changed(
      second,
      lines: second.lines
          .map(
            (ScanTextLine line) =>
                text(line, line.text.replaceAll(before, after)),
          )
          .toList(),
    );
    ScanCrop footer(
      ScanCrop crop, {
      String set = 'M21',
      String number = '001',
      String language = 'EN',
    }) => changed(
      crop,
      lines: <ScanTextLine>[
        ...crop.lines,
        ScanTextLine(
          text: '$number $set $language',
          confidence: 1,
          bounds: const ScanBounds(.02, .94, .45, .025),
        ),
      ],
    );
    for (final (ScanCrop, ScanCrop) pair in <(ScanCrop, ScanCrop)>[
      (first, changed(second, dx: .08)),
      (first, changed(second, dx: .025)),
      (first, replaced('Enchantment', 'Creature')),
      (first, replaced('nonland', 'noncreature')),
      (first, replaced('name a nonland card.', 'name a blue nonland card.')),
      (first, replaced('Nevermore', 'Nevermort')),
      (
        first,
        changed(
          second,
          lines: second.lines
              .where((ScanTextLine line) => line.text != 'name a nonland card.')
              .toList(),
        ),
      ),
      (footer(first), footer(second, number: '002')),
      (footer(first), footer(second, set: 'ONE')),
      (footer(first), footer(second, language: 'FR')),
    ]) {
      expect(
        mergeScanFocusStack(<ScanRecognition>[
          _photo(<ScanCrop>[pair.$1]),
          _photo(<ScanCrop>[pair.$2]),
        ]),
        hasLength(2),
      );
    }
    expect(
      ScanHints.fromCrop(footer(second, number: '002')).collectorNumber,
      '002',
    );
    expect(ScanHints.fromCrop(footer(second, language: 'FR')).language, 'fr');
    final ScanCrop fullCopy = changed(second, dx: .35);
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[first, fullCopy]),
        _photo(<ScanCrop>[second, fullCopy]),
      ]),
      hasLength(2),
    );
  });

  test('unknown geometry gets bounded stable focus probes and can return after removal', () {
    DateTime now = DateTime.utc(2026);
    final ScanFocusDiscoveryBudget budget = ScanFocusDiscoveryBudget(
      clock: () => now,
    );
    final List<ScanPoint> corners = _corners(.2, .3);
    const ScanPoint point = ScanPoint(.31, .45);
    budget.observe(<List<ScanPoint>>[corners, corners]);
    expect(budget.allows(point), isFalse);
    expect(budget.allowsInitial(point), isFalse);
    now = now.add(const Duration(milliseconds: 500));
    budget.observe(<List<ScanPoint>>[corners]);
    expect(budget.allows(point), isTrue);
    expect(budget.allowsInitial(point), isTrue);
    budget.record(point);
    expect(budget.allows(point), isTrue);
    expect(budget.allowsInitial(point), isFalse);
    budget.record(point);
    expect(budget.allows(point), isFalse);
    now = now.add(const Duration(seconds: 5));
    budget.observe(<List<ScanPoint>>[corners]);
    expect(budget.allows(point), isFalse);
    now = now.add(const Duration(seconds: 12));
    budget.observe(const <List<ScanPoint>>[]);
    expect(budget.allows(point), isFalse);
    budget.observe(<List<ScanPoint>>[corners]);
    expect(budget.allows(point), isFalse);
    now = now.add(const Duration(milliseconds: 500));
    budget.observe(<List<ScanPoint>>[corners]);
    expect(budget.allows(point), isTrue);
    expect(budget.allowsInitial(point), isTrue);
    budget.clear();
    expect(budget.allows(point), isFalse);
  });

  test('unread photo evidence grants only two extra focus probes per unchanged region', () {
    DateTime now = DateTime.utc(2026);
    final ScanFocusDiscoveryBudget budget = ScanFocusDiscoveryBudget(
      clock: () => now,
    );
    final List<ScanPoint> corners = _corners(.2, .3);
    const ScanPoint point = ScanPoint(.31, .45);
    budget.observe(<List<ScanPoint>>[corners]);
    expect(budget.grantUnreadRecovery(point), isFalse);
    now = now.add(const Duration(milliseconds: 500));
    budget.observe(<List<ScanPoint>>[corners]);
    budget.record(point);
    budget.record(point);
    expect(budget.allowsImmediate(point), isFalse);
    expect(budget.grantUnreadRecovery(point), isTrue);
    expect(budget.allowsImmediate(point), isTrue);
    budget.record(point);
    expect(budget.allowsImmediate(point), isTrue);
    budget.record(point);
    expect(budget.allowsImmediate(point), isFalse);
    expect(budget.grantUnreadRecovery(point), isFalse);
    expect(budget.grantUnreadRecovery(const ScanPoint(.75, .7)), isFalse);
    now = now.add(const Duration(seconds: 12));
    budget.observe(const <List<ScanPoint>>[]);
    expect(budget.grantUnreadRecovery(point), isFalse);
  });

  test('two discarded regions mature independently without resetting earlier recovery', () {
    DateTime now = DateTime.utc(2026);
    final ScanFocusDiscoveryBudget budget = ScanFocusDiscoveryBudget(
      clock: () => now,
    );
    final List<ScanPoint> first = _corners(.2, .3);
    final List<ScanPoint> second = _corners(.65, .3);
    const ScanPoint firstPoint = ScanPoint(.31, .45);
    const ScanPoint secondPoint = ScanPoint(.76, .45);
    budget.observe(<List<ScanPoint>>[first]);
    now = now.add(const Duration(milliseconds: 500));
    budget.observe(<List<ScanPoint>>[first, second]);
    budget.record(firstPoint);
    budget.record(firstPoint);
    expect(budget.grantUnreadRecovery(firstPoint), isTrue);
    expect(budget.grantUnreadRecovery(secondPoint), isFalse);
    budget.record(firstPoint);
    budget.record(firstPoint);
    now = now.add(const Duration(milliseconds: 500));
    budget.observe(<List<ScanPoint>>[first, second]);
    budget.record(secondPoint);
    budget.record(secondPoint);
    expect(budget.grantUnreadRecovery(firstPoint), isFalse);
    expect(budget.allowsImmediate(firstPoint), isFalse);
    expect(budget.grantUnreadRecovery(secondPoint), isTrue);
    expect(budget.allowsImmediate(secondPoint), isTrue);
    budget.record(secondPoint);
    budget.record(secondPoint);
    expect(budget.grantUnreadRecovery(secondPoint), isFalse);
    expect(budget.allowsImmediate(secondPoint), isFalse);
  });

  test('detected focus planning uses one photo per physical region without desk coverage', () {
    final List<ScanPoint> only = _corners(.15, .3);
    final List<ScanPoint> jitter = _corners(.18, .32);
    final List<ScanPoint> adjacent = _corners(.39, .3);
    final List<ScanPoint> distant = _corners(.67, .65);
    expect(
      planDetectedScanFocusPoints(regions: <List<ScanPoint>>[only]),
      hasLength(1),
    );
    final List<ScanPoint> planned = planDetectedScanFocusPoints(
      regions: <List<ScanPoint>>[only, jitter, adjacent, distant],
    );
    expect(planned, hasLength(3));
    expect(planned.first.x, closeTo(.26, .0001));
    expect(planned.first.y, closeTo(.45, .0001));
    expect(
      planDetectedScanFocusPoints(regions: const <List<ScanPoint>>[]),
      isEmpty,
    );
    expect(
      planDetectedScanFocusPoints(
        regions: <List<ScanPoint>>[
          <ScanPoint>[const ScanPoint(double.nan, .2)],
        ],
      ),
      isEmpty,
    );
    expect(
      planDetectedScanFocusPoints(
        regions: <List<ScanPoint>>[only, adjacent, distant],
        maximumPoints: 2,
      ),
      hasLength(2),
    );
    expect(
      () => planDetectedScanFocusPoints(
        regions: <List<ScanPoint>>[only],
        maximumPoints: 0,
      ),
      throwsArgumentError,
    );
  });

  test('native split title with a single type OCR loss merges only its corroborated depth pair', () {
    final List<ScanCrop> crops = _recordedNativeTypeTypoPair();
    expect(ScanHints.fromCrop(crops[0]).typeLine, isNull);
    expect(ScanHints.fromCrop(crops[1]).typeLine, 'enchantment');
    final List<ScanFocusSelection> selected = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[crops[0]]),
        _photo(<ScanCrop>[crops[1]]),
      ],
    );
    expect(selected, hasLength(1));
    expect(selected.single.observations, 2);
    expect(selected.single.photoIndex, 1);
    expect(selected.single.crop, same(crops[1]));
    expect(
      ScanHints.fromCrop(selected.single.crop).names.first,
      'Circle of Protections Blue',
    );

    ScanCrop changed(
      ScanCrop original, {
      String? fullTitle,
      String? color,
      String? footer,
      double shift = 0,
      bool weakTypeGlyph = false,
      bool conflictingBody = false,
    }) => ScanCrop(
      imagePath: '',
      width: original.width,
      height: original.height,
      rectified: original.rectified,
      sourceCorners: original.sourceCorners
          .map((ScanPoint point) => ScanPoint(point.x + shift, point.y))
          .toList(),
      warnings: original.warnings,
      sharpness: original.sharpness,
      lines: <ScanTextLine>[
        if (fullTitle != null)
          ScanTextLine(
            text: fullTitle,
            confidence: 1,
            bounds: const ScanBounds(.05, .04, .7, .03),
          ),
        for (final ScanTextLine line in original.lines)
          if ((fullTitle == null || line.bounds.y >= .13) &&
              (!conflictingBody || line.bounds.y < .60))
            ScanTextLine(
              text: color == null
                  ? line.text
                  : line.text
                        .replaceAll('Blue', color)
                        .replaceAll('blue', color.toLowerCase()),
              confidence: line.confidence,
              bounds: line.bounds,
              glyphHeight: weakTypeGlyph && line.text == 'Enchanment'
                  ? .12
                  : line.glyphHeight,
              alternatives: color == null
                  ? line.alternatives
                  : const <String>[],
            ),
        if (conflictingBody) ...<ScanTextLine>[
          const ScanTextLine(
            text: 'Destroy target enchantment.',
            confidence: 1,
            bounds: ScanBounds(.1, .65, .7, .03),
          ),
          const ScanTextLine(
            text: 'Draw one card.',
            confidence: 1,
            bounds: ScanBounds(.1, .72, .7, .03),
          ),
        ],
        if (footer != null)
          ScanTextLine(
            text: footer,
            confidence: 1,
            bounds: const ScanBounds(.05, .94, .4, .025),
          ),
      ],
    );
    for (final ScanCrop mismatch in <ScanCrop>[
      changed(crops[0], fullTitle: 'Rune of Protection: Blue'),
      changed(crops[0], color: 'White'),
      changed(crops[0], weakTypeGlyph: true),
      changed(crops[0], conflictingBody: true),
      changed(crops[0], shift: .08),
    ]) {
      expect(
        mergeScanFocusStack(<ScanRecognition>[
          _photo(<ScanCrop>[mismatch]),
          _photo(<ScanCrop>[crops[1]]),
        ]),
        hasLength(2),
      );
    }
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[changed(crops[0], footer: '001 M21 EN')]),
        _photo(<ScanCrop>[changed(crops[1], footer: '002 M21 EN')]),
      ]),
      hasLength(2),
    );
    final List<ScanFocusSelection> separate = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[crops[0], changed(crops[0], shift: .4)]),
        _photo(<ScanCrop>[crops[1]]),
      ],
    );
    expect(separate, hasLength(2));
    expect(
      separate.map((ScanFocusSelection card) => card.observations),
      containsAll(<int>[2, 1]),
    );
  });

  test('real split native nameplate merges only its corroborated physical card and keeps the complete observed title', () {
    final List<ScanCrop> crops = _recordedSplitNameplatePair();
    final List<ScanFocusSelection> selected = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[crops[0]]),
        _photo(<ScanCrop>[crops[1]]),
      ],
    );
    expect(selected, hasLength(1));
    expect(selected.single.observations, 2);
    expect(selected.single.photoIndex, 0);
    expect(selected.single.crop, same(crops[0]));
    expect(
      ScanHints.fromCrop(selected.single.crop).names.first,
      'Circle of Protection: Blue',
    );

    ScanCrop changed(
      ScanCrop original, {
      String? fullTitle,
      String? color,
      String? footer,
      double shift = 0,
      bool oneRule = false,
    }) => ScanCrop(
      imagePath: '',
      width: original.width,
      height: original.height,
      rectified: original.rectified,
      sourceCorners: original.sourceCorners
          .map((ScanPoint point) => ScanPoint(point.x + shift, point.y))
          .toList(),
      warnings: original.warnings,
      sharpness: original.sharpness,
      lines: <ScanTextLine>[
        if (fullTitle != null)
          ScanTextLine(
            text: fullTitle,
            confidence: 1,
            bounds: const ScanBounds(.05, .03, .7, .03),
          ),
        for (final ScanTextLine line in original.lines)
          if ((fullTitle == null || line.bounds.y >= .13) &&
              (!oneRule ||
                  line.bounds.y < .60 ||
                  line.text.contains('Prevent')))
            ScanTextLine(
              text: color == null
                  ? line.text
                  : line.text
                        .replaceAll('Blue', color)
                        .replaceAll('blue', color.toLowerCase()),
              confidence: line.confidence,
              bounds: line.bounds,
              glyphHeight: line.glyphHeight,
              alternatives: color == null
                  ? line.alternatives
                  : const <String>[],
            ),
        if (footer != null)
          ScanTextLine(
            text: footer,
            confidence: 1,
            bounds: const ScanBounds(.05, .94, .4, .025),
          ),
      ],
    );
    final List<ScanCrop> mismatches = <ScanCrop>[
      changed(crops[1], fullTitle: 'Rune of Protection: Blue'),
      changed(crops[1], color: 'White'),
      changed(crops[1], shift: .08),
      changed(crops[1], oneRule: true),
    ];
    for (final ScanCrop mismatch in mismatches) {
      expect(
        mergeScanFocusStack(<ScanRecognition>[
          _photo(<ScanCrop>[crops[0]]),
          _photo(<ScanCrop>[mismatch]),
        ]),
        hasLength(2),
      );
    }
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[changed(crops[0], footer: '001 M21 EN')]),
        _photo(<ScanCrop>[changed(crops[1], footer: '002 M21 EN')]),
      ]),
      hasLength(2),
    );
    final List<ScanFocusSelection> separateCopies = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[crops[0], changed(crops[0], shift: .4)]),
        _photo(<ScanCrop>[crops[1]]),
      ],
    );
    expect(separateCopies, hasLength(2));
    expect(
      separateCopies.map(
        (ScanFocusSelection selection) => selection.observations,
      ),
      containsAll(<int>[2, 1]),
    );
  });

  test('recorded suffix-truncated depth title stays one physical card with its intact observed title', () {
    final List<ScanCrop> crops = _recordedSuffixDepthPair();
    final List<ScanFocusSelection> selected = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[crops[0]]),
        _photo(<ScanCrop>[crops[1]]),
      ],
    );
    expect(selected, hasLength(1));
    expect(selected.single.observations, 2);
    expect(selected.single.photoIndex, 0);
    expect(
      ScanHints.fromCrop(selected.single.crop).names,
      contains('Cirele of Drotection: Blue'),
    );
    final ScanCrop intactOther = ScanCrop(
      imagePath: '',
      width: crops[1].width,
      height: crops[1].height,
      rectified: crops[1].rectified,
      sourceCorners: crops[1].sourceCorners,
      lines: crops[1].lines
          .map(
            (ScanTextLine line) => ScanTextLine(
              text: line.bounds.y < .13 && line.bounds.x < .6
                  ? 'Rune of Protection: Blue'
                  : line.text,
              confidence: line.confidence,
              bounds: line.bounds,
              glyphHeight: line.glyphHeight,
            ),
          )
          .toList(),
    );
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[crops[0]]),
        _photo(<ScanCrop>[intactOther]),
      ]),
      hasLength(2),
    );
  });

  test('recorded damaged depth crop merges with its intact Circle footprint and selects the readable original', () {
    final List<ScanCrop> crops = _recordedCircleDepthPair();
    final List<ScanFocusSelection> selected = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[crops[0]]),
        _photo(<ScanCrop>[crops[1]]),
      ],
    );
    expect(selected, hasLength(1));
    expect(selected.single.observations, 2);
    expect(selected.single.photoIndex, 0);
    expect(selected.single.crop, same(crops.first));
    expect(
      ScanHints.fromCrop(selected.single.crop).names,
      contains('Cirele of Protection: Blue'),
    );
  });

  test('damaged nameplates require two body agreements at the same footprint and cannot merge full conflicting titles or printing', () {
    final List<ScanCrop> crops = _recordedCircleDepthPair();
    ScanCrop changed(
      ScanCrop crop, {
      String? title,
      String? footer,
      double shift = 0,
      bool removeSecondAgreement = false,
      bool white = false,
    }) => ScanCrop(
      imagePath: '',
      width: crop.width,
      height: crop.height,
      rectified: crop.rectified,
      warnings: crop.warnings,
      sharpness: crop.sharpness,
      sourceCorners: crop.sourceCorners
          .map((ScanPoint point) => ScanPoint(point.x + shift, point.y))
          .toList(),
      lines: <ScanTextLine>[
        for (final ScanTextLine line in crop.lines)
          ScanTextLine(
            text: title != null && line.bounds.y < .13
                ? title
                : removeSecondAgreement &&
                      line.text == 'damage to you more than'
                ? 'Draw two cards instead.'
                : white && line.text == 'suc source, ir a source'
                ? 'from one white source. If a source'
                : line.text,
            confidence: line.confidence,
            bounds: line.bounds,
            glyphHeight: line.glyphHeight,
          ),
        if (footer != null)
          ScanTextLine(
            text: footer,
            confidence: 1,
            bounds: const ScanBounds(.05, .92, .4, .03),
          ),
      ],
    );
    for (final ScanCrop other in <ScanCrop>[
      changed(crops[1], title: 'Rune of Protection: Blue'),
      changed(crops[1], shift: .08),
      changed(crops[1], removeSecondAgreement: true),
      changed(crops[1], white: true),
    ]) {
      expect(
        mergeScanFocusStack(<ScanRecognition>[
          _photo(<ScanCrop>[crops[0]]),
          _photo(<ScanCrop>[other]),
        ]),
        hasLength(2),
      );
    }
    for (final String footer in <String>['002 M21 EN', '001 M21 DE']) {
      expect(
        mergeScanFocusStack(<ScanRecognition>[
          _photo(<ScanCrop>[changed(crops[0], footer: '001 M21 EN')]),
          _photo(<ScanCrop>[changed(crops[1], footer: footer)]),
        ]),
        hasLength(2),
      );
    }
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[crops[0]]),
        _photo(<ScanCrop>[changed(crops[0], shift: .35)]),
      ]),
      hasLength(2),
    );
  });

  test('focus target memory preserves proven depths through a scan cycle and expires or resets them', () {
    DateTime now = DateTime.utc(2026, 10, 10);
    final ScanFocusTargetMemory memory = ScanFocusTargetMemory(
      clock: () => now,
    );
    final List<ScanPoint> rear = _corners(.61, .20);
    final List<ScanPoint> front = _corners(.20, .57);
    memory.update(<List<ScanPoint>>[rear, front]);
    now = now.add(const Duration(seconds: 20));
    memory.update(const <List<ScanPoint>>[]);
    expect(memory.targets, hasLength(2));
    final List<ScanPoint> refreshedRear = _corners(.62, .21);
    memory.update(<List<ScanPoint>>[refreshedRear]);
    expect(memory.targets, hasLength(2));
    now = now.add(const Duration(seconds: 10));
    expect(memory.targets, hasLength(1));
    expect(memory.targets.single.first.x, .62);
    now = now.add(const Duration(seconds: 20));
    expect(memory.targets, isEmpty);
    memory.update(<List<ScanPoint>>[front]);
    memory.clear();
    expect(memory.targets, isEmpty);
    memory.update(<List<ScanPoint>>[
      for (int index = 0; index < 9; index++)
        _corners(
          (index % 3) * .33,
          (index ~/ 3) * .33,
          width: .04,
          height: .04,
        ),
      <ScanPoint>[const ScanPoint(double.nan, 0)],
    ]);
    expect(memory.targets, hasLength(8));
    expect(memory.targets.first.first.x, .33);
    expect(() => memory.targets.clear(), throwsUnsupportedError);
    expect(() => memory.targets.first.clear(), throwsUnsupportedError);
  });

  test(
    'proven rear and front targets precede farther unproven desk geometry',
    () {
      final List<List<ScanPoint>> tracked = <List<ScanPoint>>[
        _corners(.60, .20),
        _corners(.20, .57),
        _corners(.66, .57),
      ];
      final List<ScanPoint> points = planScanFocusPoints(
        trackedCorners: tracked,
        candidates: <LiveCardDetection>[
          for (final List<ScanPoint> corners in <List<ScanPoint>>[
            _corners(.01, .01, width: .04, height: .04),
            _corners(.90, .01, width: .04, height: .04),
            _corners(.01, .90, width: .04, height: .04),
            _corners(.90, .90, width: .04, height: .04),
          ])
            LiveCardDetection(corners: corners, confidence: 1),
        ],
      );
      expect(points, hasLength(5));
      for (final List<ScanPoint> corners in tracked) {
        final double x =
            corners
                .map((ScanPoint point) => point.x)
                .reduce((double a, double b) => a + b) /
            4;
        final double y =
            corners
                .map((ScanPoint point) => point.y)
                .reduce((double a, double b) => a + b) /
            4;
        expect(
          points
              .take(4)
              .any(
                (ScanPoint point) =>
                    (point.x - x).abs() < .001 && (point.y - y).abs() < .001,
              ),
          isTrue,
        );
      }
    },
  );

  test('focus planning reaches unreadable rear geometry and covers missing rectangles within five shots', () {
    final List<ScanPoint> points = planScanFocusPoints(
      candidates: <LiveCardDetection>[
        LiveCardDetection(
          corners: _corners(.60, .347, width: .256, height: .127),
          confidence: 1,
        ),
        LiveCardDetection(
          corners: _corners(.331, .331, width: .268, height: .256),
          confidence: 1,
        ),
      ],
      trackedCorners: <List<ScanPoint>>[_corners(.20, .60)],
    );
    expect(points, hasLength(5));
    expect(
      points.any(
        (ScanPoint point) =>
            (point.x - .728).abs() < .01 && (point.y - .4105).abs() < .01,
      ),
      isTrue,
    );
    expect(
      points.any((ScanPoint point) => point.x < .4 && point.y < .4),
      isTrue,
    );
    expect(
      planScanFocusPoints(candidates: const <LiveCardDetection>[]),
      hasLength(5),
    );
    expect(
      () => planScanFocusPoints(
        candidates: const <LiveCardDetection>[],
        maximumPoints: 6,
      ),
      throwsArgumentError,
    );
  });

  test('three depths select clear evidence per physical card rather than nine quantities', () {
    final List<ScanRecognition> photos = <ScanRecognition>[
      _photo(<ScanCrop>[
        _crop('Nevermore', .60, .55),
        _crop('', .20, .55),
        _crop('', .60, .15),
      ]),
      _photo(<ScanCrop>[
        _crop('', .60, .55),
        _crop('Circle of Protection: Blue', .20, .55),
        _crop('', .60, .15),
      ]),
      _photo(<ScanCrop>[
        _crop('', .60, .55),
        _crop('', .20, .55),
        _crop('Mirkwood Bats', .60, .15),
      ]),
    ];
    final List<ScanFocusSelection> selected = mergeScanFocusStack(photos);
    expect(selected, hasLength(3));
    expect(
      selected
          .map(
            (ScanFocusSelection selection) =>
                ScanHints.fromCrop(selection.crop).names.single,
          )
          .toSet(),
      <String>{'Nevermore', 'Circle of Protection: Blue', 'Mirkwood Bats'},
    );
    expect(
      selected
          .map((ScanFocusSelection selection) => selection.photoIndex)
          .toSet(),
      <int>{0, 1, 2},
    );
    expect(
      selected.every(
        (ScanFocusSelection selection) => selection.observations == 3,
      ),
      isTrue,
    );
  });

  test('identical printed cards at distinct positions stay separate and weak OCR does not split a burst', () {
    final List<ScanFocusSelection> selected = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[
          _crop('Lightning Bolt', .10, .30),
          _crop('Lightning Bolt', .60, .30),
        ]),
        _photo(<ScanCrop>[
          _crop('Lightring Bclt', .11, .30, confidence: .45),
          _crop('Lightning Bolt', .60, .30, sharpness: .9),
        ]),
        _photo(<ScanCrop>[
          _crop('Lightning Bolt', .10, .30, sharpness: .95),
          _crop('Lightning Bolt', .60, .30),
        ]),
      ],
    );
    expect(selected, hasLength(2));
    expect(
      selected.every(
        (ScanFocusSelection selection) => selection.observations == 3,
      ),
      isTrue,
    );
    expect(
      selected
          .map((ScanFocusSelection selection) => selection.photoIndex)
          .toSet(),
      <int>{1, 2},
    );
  });

  test('unproven desk geometry disappears and conflicting readable cards are not silently merged', () {
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[_crop('', .1, .1)]),
        _photo(<ScanCrop>[_crop('', .1, .1)]),
      ]),
      isEmpty,
    );
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[_corroborated('Nevermore', .1, .1)]),
        _photo(<ScanCrop>[_corroborated('Mirkwood Bats', .1, .1)]),
      ]),
      hasLength(2),
    );
  });

  test('actual blurred Head Bats border merges into the later sharp corroborated Bats ROI', () {
    const ScanCrop blurred = ScanCrop(
      imagePath: 'photo0-blurred.jpg',
      width: 1541,
      height: 2232,
      rectified: true,
      sharpness: .331517,
      sourceCorners: <ScanPoint>[
        ScanPoint(.637978, .204991),
        ScanPoint(.889805, .223782),
        ScanPoint(.829402, .477118),
        ScanPoint(.595332, .458619),
      ],
      lines: <ScanTextLine>[
        ScanTextLine(
          text: 'Head Bats',
          confidence: 1,
          bounds: ScanBounds(.2375, .03985, .20417, .03179),
        ),
      ],
    );
    const ScanCrop sharp = ScanCrop(
      imagePath: 'photo3-sharp.jpg',
      width: 1826,
      height: 2556,
      rectified: false,
      sharpness: .787655,
      warnings: <String>[
        'no_card_rectangle',
        'partial_card',
        'incomplete_card',
      ],
      sourceCorners: <ScanPoint>[
        ScanPoint(.614641, .209087),
        ScanPoint(.916359, .209087),
        ScanPoint(.916359, .526017),
        ScanPoint(.614641, .526017),
      ],
      lines: <ScanTextLine>[
        ScanTextLine(
          text: 'Mirkwood Bats',
          confidence: 1,
          bounds: ScanBounds(.12247, .03766, .30994, .05189),
        ),
        ScanTextLine(
          text: 'Creature - Bat',
          confidence: 1,
          bounds: ScanBounds(.04607, .47266, .24677, .04080),
        ),
        ScanTextLine(
          text: 'Whenever you create or sacrifice a',
          confidence: 1,
          bounds: ScanBounds(.03145, .56785, .61378, .07321),
        ),
        ScanTextLine(
          text: 'token, each opponent loses 1 life.',
          confidence: 1,
          bounds: ScanBounds(.02299, .59627, .59877, .07477),
        ),
      ],
    );
    final List<ScanFocusSelection> selected = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[blurred]),
        _photo(const <ScanCrop>[]),
        _photo(const <ScanCrop>[]),
        _photo(<ScanCrop>[sharp]),
      ],
    );
    expect(selected, hasLength(1));
    expect(selected.single.photoIndex, 3);
    expect(selected.single.observations, 2);
    expect(selected.single.crop.imagePath, 'photo3-sharp.jpg');
    expect(ScanHints.fromCrop(selected.single.crop).names, <String>[
      'Mirkwood Bats',
    ]);
    expect(selected.single.crop.rectified, isFalse);
    expect(selected.single.crop.warnings, contains('partial_card'));
  });

  test('recorded unreadable Circle title and type retain distinctive rules for manual catalog lookup', () async {
    final List<Object?> recorded = jsonDecode(
      await File('test/fixtures/focus_stack_body_only_scene.json')
          .readAsString(),
    ) as List<Object?>;
    final List<ScanRecognition> photos = recorded
        .map(
          (Object? value) =>
              ScanRecognition.fromMap(value as Map<Object?, Object?>),
        )
        .toList();
    final List<ScanFocusSelection> selected = mergeScanFocusStack(photos);
    expect(selected, hasLength(1));
    expect(selected.single.observations, 4);
    final ScanCrop crop = selected.single.crop;
    final ScanHints hints = ScanHints.fromCrop(crop);
    expect(hints.names, isEmpty);
    expect(hints.typeLine, isNull);
    expect(crop.warnings, contains('incomplete_card'));
    expect(hints.rulesText, contains('1; Prevent all damage against you'));
    expect(ScanResolver.rulesSearchPhrase(hints.rulesText), isNotNull);
    expect(crop, same(photos[selected.single.photoIndex].crops.single));
    final ScanCrop noise = ScanCrop(
      imagePath: '',
      width: 1000,
      height: 1400,
      rectified: true,
      sourceCorners: crop.sourceCorners,
      warnings: const <String>['incomplete_card'],
      lines: const <ScanTextLine>[
        ScanTextLine(
          text: 'draw a card',
          confidence: 1,
          bounds: ScanBounds(.05, .62, .7, .025),
        ),
        ScanTextLine(
          text: 'gain life',
          confidence: 1,
          bounds: ScanBounds(.05, .68, .7, .025),
        ),
      ],
    );
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[noise]),
      ]),
      isEmpty,
    );
  });

  test(
    'recorded complete title and color survive a cleaner truncated focus pass',
    () async {
      final List<Object?> recorded = jsonDecode(
        await File('test/fixtures/focus_stack_complete_suffix_scene.json')
            .readAsString(),
      ) as List<Object?>;
      final List<ScanRecognition> photos = recorded
          .map(
            (Object? value) =>
                ScanRecognition.fromMap(value as Map<Object?, Object?>),
          )
          .toList();
      final List<ScanFocusSelection> selected = mergeScanFocusStack(photos);
      expect(selected, hasLength(3));
      final ScanFocusSelection circle = selected.singleWhere(
        (ScanFocusSelection selection) => selection.crop.lines.any(
          (ScanTextLine line) => line.text.contains('Protection'),
        ),
      );
      expect(circle.photoIndex, 0);
      expect(circle.crop, same(photos[0].crops[0]));
      final ScanHints hints = ScanHints.fromCrop(circle.crop);
      expect(hints.names, isEmpty);
      expect(
        circle.crop.lines.any(
          (ScanTextLine line) => line.text == 'Cirele of Protection: Blue',
        ),
        isTrue,
      );
      expect(
        hints.rulesText.any((String text) => text.contains('blue source')),
        isTrue,
      );
      expect(hints.typeLine, isNull);
      expect(circle.crop.warnings, contains('incomplete_card'));
    },
  );

  test('refocus raw scene merges the repaired clipped Circle into the clean full name without inventing unreadable Bats evidence', () async {
    final List<Object?> recorded = jsonDecode(
      await File('test/fixtures/focus_stack_mounted_scene_refocus.json')
          .readAsString(),
    ) as List<Object?>;
    final List<ScanRecognition> photos = recorded
        .map(
          (Object? value) =>
              ScanRecognition.fromMap(value as Map<Object?, Object?>),
        )
        .toList();
    final List<ScanFocusSelection> selected = mergeScanFocusStack(photos);
    expect(selected, hasLength(3));
    final ScanFocusSelection circle = selected.singleWhere(
      (ScanFocusSelection selection) =>
          ScanHints.fromCrop(selection.crop).names.firstOrNull
              ?.contains('Protection') ==
          true,
    );
    expect(circle.photoIndex, 4);
    expect(circle.observations, 5);
    expect(circle.crop, same(photos[4].crops[0]));
    expect(
      ScanHints.fromCrop(circle.crop).names.first,
      'Circle of Protection: Blue',
    );
    final ScanCrop repaired = photos[0].crops[1];
    final ScanCrop ordinaryDifferentName = ScanCrop(
      imagePath: repaired.imagePath,
      width: repaired.width,
      height: repaired.height,
      rectified: repaired.rectified,
      sourceCorners: repaired.sourceCorners,
      lines: repaired.lines,
    );
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[ordinaryDifferentName]),
        _photo(<ScanCrop>[circle.crop]),
      ]),
      hasLength(2),
    );
    final ScanFocusSelection unreadable = selected.singleWhere(
      (ScanFocusSelection selection) =>
          selection.photoIndex == 1 && selection.crop.rectified,
    );
    expect(unreadable.crop, same(photos[1].crops[1]));
    expect(unreadable.crop.lines.single.confidence, .5);
    expect(unreadable.crop.warnings, contains('low_text_confidence'));
    final ScanCrop original = photos[4].crops[0];
    final ScanCrop differentColor = ScanCrop(
      imagePath: original.imagePath,
      width: original.width,
      height: original.height,
      rectified: original.rectified,
      sourceCorners: original.sourceCorners,
      warnings: original.warnings,
      lines: original.lines
          .map(
            (ScanTextLine line) => ScanTextLine(
              text: line.text.replaceAll('Blue', 'White'),
              confidence: line.confidence,
              bounds: line.bounds,
            ),
          )
          .toList(),
    );
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[original]),
        _photo(<ScanCrop>[differentColor]),
      ]),
      hasLength(2),
    );
  });

  test('all raw mounted-scene observations merge into three cards while retaining the intact observed Circle title', () async {
    final List<Object?> recorded = jsonDecode(
      await File('test/fixtures/focus_stack_mounted_scene.json').readAsString(),
    ) as List<Object?>;
    final List<ScanRecognition> photos = recorded
        .map(
          (Object? value) =>
              ScanRecognition.fromMap(value as Map<Object?, Object?>),
        )
        .toList();
    final List<ScanFocusSelection> selected = mergeScanFocusStack(photos);
    expect(
      selected,
      hasLength(3),
      reason: selected.map((ScanFocusSelection selection) {
        final ScanHints hints = ScanHints.fromCrop(selection.crop);
        return 'photo ${selection.photoIndex}: ${hints.names}; '
            'type ${hints.typeLine}; observations ${selection.observations}';
      }).join('\n'),
    );
    final ScanFocusSelection circle = selected.singleWhere(
      (ScanFocusSelection selection) =>
          ScanHints.fromCrop(selection.crop).names.firstOrNull
              ?.contains('Protection') ==
          true,
    );
    expect(circle.photoIndex, 0);
    expect(circle.observations, 5);
    expect(circle.crop, same(photos[0].crops[0]));
    expect(
      ScanHints.fromCrop(circle.crop).names.first,
      'Strele of Protection: Blue',
    );
    expect(
      circle.crop.warnings,
      containsAll(<String>['geometry_adjusted', 'orientation_ensemble']),
    );
    expect(
      selected.map(
        (ScanFocusSelection selection) =>
            ScanHints.fromCrop(selection.crop).names.first,
      ),
      containsAll(<String>['Mirkwood Bats', 'Nevermore']),
    );
    final ScanCrop truncated = photos[4].crops[0];
    final ScanCrop white = ScanCrop(
      imagePath: truncated.imagePath,
      width: truncated.width,
      height: truncated.height,
      rectified: truncated.rectified,
      sourceCorners: truncated.sourceCorners,
      warnings: truncated.warnings,
      sharpness: truncated.sharpness,
      lines: truncated.lines
          .map(
            (ScanTextLine line) => ScanTextLine(
              text: line.text.replaceAll('blue', 'white'),
              confidence: line.confidence,
              bounds: line.bounds,
              alternatives: const <String>[],
            ),
          )
          .toList(),
    );
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[circle.crop]),
        _photo(<ScanCrop>[white]),
      ]),
      hasLength(2),
    );
    final ScanCrop separate = ScanCrop(
      imagePath: circle.crop.imagePath,
      width: circle.crop.width,
      height: circle.crop.height,
      rectified: circle.crop.rectified,
      sourceCorners: circle.crop.sourceCorners
          .map((ScanPoint point) => ScanPoint(.50 + point.x * .4, point.y))
          .toList(),
      warnings: circle.crop.warnings,
      sharpness: circle.crop.sharpness,
      lines: circle.crop.lines,
    );
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[circle.crop]),
        _photo(<ScanCrop>[separate]),
      ]),
      hasLength(2),
    );
  });

  test('mounted split title distinguishes absent type from failed type evidence in either order', () async {
    final List<Object?> recorded = jsonDecode(
      await File('test/fixtures/focus_stack_mounted_scene.json').readAsString(),
    ) as List<Object?>;
    final List<ScanRecognition> photos = recorded
        .map(
          (Object? value) =>
              ScanRecognition.fromMap(value as Map<Object?, Object?>),
        )
        .toList();
    final ScanCrop intact = photos[0].crops[0];
    final ScanCrop split = photos[4].crops[0];
    expect(ScanHints.fromCrop(intact).typeLine, 'enchantment');
    expect(ScanHints.fromCrop(split).typeLine, isNull);
    expect(ScanHints.fromCrop(split).names.first, 'Cirele of Protection: B');

    ScanCrop withType(
      String text, {
      double confidence = 1,
      double glyphHeight = .03,
    }) => ScanCrop(
      imagePath: split.imagePath,
      width: split.width,
      height: split.height,
      rectified: split.rectified,
      sourceCorners: split.sourceCorners,
      warnings: split.warnings,
      sharpness: split.sharpness,
      lines: <ScanTextLine>[
        ...split.lines,
        ScanTextLine(
          text: text,
          confidence: confidence,
          bounds: const ScanBounds(.05, .55, .3, .03),
          glyphHeight: glyphHeight,
        ),
      ],
    );

    final Map<String, (ScanCrop, int)> cases = <String, (ScanCrop, int)>{
      'absent type': (split, 1),
      'supported type typo': (withType('Enchanment'), 1),
      'weak type confidence': (
        withType('Enchanment', confidence: .5),
        2,
      ),
      'invalid measured type glyph': (
        withType('Enchanment', glyphHeight: .12),
        2,
      ),
      'contradictory type': (withType('Creature'), 2),
    };
    for (final MapEntry<String, (ScanCrop, int)> entry in cases.entries) {
      for (final bool reversed in <bool>[false, true]) {
        final List<ScanFocusSelection> selected = mergeScanFocusStack(
          <ScanRecognition>[
            _photo(<ScanCrop>[reversed ? entry.value.$1 : intact]),
            _photo(<ScanCrop>[reversed ? intact : entry.value.$1]),
          ],
        );
        expect(
          selected,
          hasLength(entry.value.$2),
          reason: '${entry.key}, reversed=$reversed',
        );
        if (entry.value.$2 == 1) {
          expect(selected.single.crop, same(intact));
          expect(selected.single.observations, 2);
        }
      }
    }
  });

  test('mounted split suffix cannot merge a different color when its body color is unreadable', () async {
    final List<Object?> recorded = jsonDecode(
      await File('test/fixtures/focus_stack_mounted_scene.json').readAsString(),
    ) as List<Object?>;
    final List<ScanRecognition> photos = recorded
        .map(
          (Object? value) =>
              ScanRecognition.fromMap(value as Map<Object?, Object?>),
        )
        .toList();
    ScanCrop changed(
      ScanCrop source, {
      String? color,
      bool removeBodyColor = false,
      bool removeSuffix = false,
      bool alternativeOnly = false,
    }) => ScanCrop(
      imagePath: source.imagePath,
      width: source.width,
      height: source.height,
      rectified: source.rectified,
      sourceCorners: source.sourceCorners,
      warnings: source.warnings,
      sharpness: source.sharpness,
      lines: <ScanTextLine>[
        for (final ScanTextLine line in source.lines)
          if ((!removeBodyColor ||
                  line.bounds.y < .5 ||
                  !line.text.toLowerCase().contains('blue')) &&
              (!removeSuffix || line.text != 'lue'))
            ScanTextLine(
              text: alternativeOnly && line.text == 'lue'
                  ? 'red'
                  : color == null
                  ? line.text
                  : line.text
                        .replaceAll('Blue', color)
                        .replaceAll('blue', color.toLowerCase()),
              confidence: line.confidence,
              bounds: line.bounds,
              glyphHeight: line.glyphHeight,
              alternatives: alternativeOnly && line.text == 'lue'
                  ? const <String>['lue']
                  : const <String>[],
            ),
      ],
    );
    final ScanCrop split = changed(photos[4].crops[0], removeBodyColor: true);
    final Map<String, (ScanCrop, ScanCrop)> cases =
        <String, (ScanCrop, ScanCrop)>{
          for (final String color in <String>['Red', 'Black'])
            color: (changed(photos[0].crops[0], color: color), split),
          'missing suffix': (
            photos[0].crops[0],
            changed(split, removeSuffix: true),
          ),
          'alternative suffix only': (
            photos[0].crops[0],
            changed(split, alternativeOnly: true),
          ),
        };
    for (final MapEntry<String, (ScanCrop, ScanCrop)> entry in cases.entries) {
      for (final bool reversed in <bool>[false, true]) {
        expect(
          mergeScanFocusStack(<ScanRecognition>[
            _photo(<ScanCrop>[reversed ? entry.value.$2 : entry.value.$1]),
            _photo(<ScanCrop>[reversed ? entry.value.$1 : entry.value.$2]),
          ]),
          hasLength(2),
          reason: '${entry.key}, reversed=$reversed',
        );
      }
    }
  });

  test('observed split suffix overrides a close fuzzy title and rejects ambiguous completions', () {
    ScanCrop card({String? color, List<String> suffixes = const <String>[]}) =>
        ScanCrop(
          imagePath: '/local/suffix-${color ?? 'split'}.jpg',
          width: 1000,
          height: 1400,
          rectified: true,
          sourceCorners: _corners(.2, .3),
          lines: <ScanTextLine>[
            if (color != null) ...<ScanTextLine>[
              ScanTextLine(
                text: 'Circle of Protection: $color',
                confidence: 1,
                bounds: const ScanBounds(.05, .04, .7, .03),
              ),
              const ScanTextLine(
                text: 'Enchantment',
                confidence: 1,
                bounds: ScanBounds(.05, .55, .3, .03),
              ),
            ] else ...<ScanTextLine>[
              const ScanTextLine(
                text: 'Circle',
                confidence: 1,
                bounds: ScanBounds(.05, .04, .15, .03),
              ),
              const ScanTextLine(
                text: 'of Protection: Bl',
                confidence: 1,
                bounds: ScanBounds(.21, .04, .38, .03),
              ),
              for (final String suffix in suffixes)
                ScanTextLine(
                  text: suffix,
                  confidence: 1,
                  bounds: const ScanBounds(.61, .04, .08, .03),
                ),
            ],
            const ScanTextLine(
              text: 'Prevent all combat damage to you this turn.',
              confidence: 1,
              bounds: ScanBounds(.05, .66, .8, .03),
            ),
            const ScanTextLine(
              text: 'Destroy target nonartifact creature with flying.',
              confidence: 1,
              bounds: ScanBounds(.05, .72, .8, .03),
            ),
          ],
        );
    final ScanCrop blackSuffix = card(suffixes: <String>['ack']);
    expect(ScanHints.fromCrop(blackSuffix).typeLine, isNull);
    expect(ScanHints.fromCrop(blackSuffix).names.first, 'Circle of Protection: Bl');
    for (final (String, List<String>, int) fixture
        in <(String, List<String>, int)>[
          ('Blue', <String>['ack'], 2),
          ('Black', <String>['ack'], 1),
          ('Blue', <String>['ue'], 1),
          ('Blue', <String>[], 1),
          ('Blue', <String>['ack', 'ue'], 2),
          ('Black', <String>['ack', 'ue'], 2),
        ]) {
      final ScanCrop complete = card(color: fixture.$1);
      final ScanCrop split = card(suffixes: fixture.$2);
      for (final bool reversed in <bool>[false, true]) {
        expect(
          mergeScanFocusStack(<ScanRecognition>[
            _photo(<ScanCrop>[reversed ? split : complete]),
            _photo(<ScanCrop>[reversed ? complete : split]),
          ]),
          hasLength(fixture.$3),
          reason: '${fixture.$1}, suffixes=${fixture.$2}, reversed=$reversed',
        );
      }
    }
  });

  test('quoted body continuations cannot complete specialized focus merge evidence', () {
    List<ScanRecognition> photos(String fixture) =>
        (jsonDecode(File(fixture).readAsStringSync()) as List<Object?>)
            .map(
              (Object? value) =>
                  ScanRecognition.fromMap(value as Map<Object?, Object?>),
            )
            .toList();
    final List<ScanRecognition> alternative = photos(
      'test/fixtures/focus_stack_automatic_duplicate_scene.json',
    );
    final List<ScanRecognition> split = photos(
      'test/fixtures/focus_stack_mounted_scene.json',
    );
    final List<ScanCrop> missingGlyph = _recordedMissingGlyphNameplates();
    final Map<String, (ScanCrop, ScanCrop)> pairs = <String, (ScanCrop, ScanCrop)>{
      'missing glyph': (missingGlyph.first, missingGlyph.last),
      'observed alternative': (alternative[1].crops[0], alternative[2].crops[0]),
      'split suffix': (split[0].crops[0], split[4].crops[0]),
    };
    ScanCrop body(
      ScanCrop original, {
      required bool twoRules,
      required double quoteConfidence,
      required double quoteHeight,
    }) => ScanCrop(
      imagePath: original.imagePath,
      width: original.width,
      height: original.height,
      rectified: original.rectified,
      sourceCorners: original.sourceCorners,
      warnings: original.warnings,
      sharpness: original.sharpness,
      lines: <ScanTextLine>[
        for (final ScanTextLine line in original.lines)
          if (line.bounds.y < .13 ||
              (line.bounds.y >= .45 &&
                  line.bounds.y < .65 &&
                  ScanHints.observedCardType(line.text) != null))
            line,
        const ScanTextLine(
          text: 'Whenever Nevermore enters the battlefield, prevent all damage.',
          confidence: 1,
          bounds: ScanBounds(.05, .66, .85, .03),
        ),
        if (twoRules)
          const ScanTextLine(
            text: 'Destroy target nonartifact creature with flying.',
            confidence: 1,
            bounds: ScanBounds(.05, .70, .85, .03),
          ),
        ScanTextLine(
          text: '"An old story begins',
          confidence: quoteConfidence,
          bounds: ScanBounds(.05, .74, .85, quoteHeight),
          glyphHeight: .03,
        ),
        const ScanTextLine(
          text: 'Destroy target nonartifact creature with flying.',
          confidence: 1,
          bounds: ScanBounds(.05, .80, .85, .03),
        ),
      ],
    );
    for (final MapEntry<String, (ScanCrop, ScanCrop)> pair in pairs.entries) {
      for (final bool twoRules in <bool>[false, true]) {
        for (final (double, double) quote in <(double, double)>[
          (.80, .03),
          (1, .03),
          (.80, .13),
        ]) {
          final ScanCrop first = body(
            pair.value.$1,
            twoRules: twoRules,
            quoteConfidence: quote.$1,
            quoteHeight: quote.$2,
          );
          final ScanCrop second = body(
            pair.value.$2,
            twoRules: twoRules,
            quoteConfidence: quote.$1,
            quoteHeight: quote.$2,
          );
          expect(ScanHints.fromCrop(first).rulesText, hasLength(twoRules ? 2 : 1));
          expect(ScanHints.fromCrop(second).rulesText, hasLength(twoRules ? 2 : 1));
          for (final bool reversed in <bool>[false, true]) {
            expect(
              mergeScanFocusStack(<ScanRecognition>[
                _photo(<ScanCrop>[reversed ? second : first]),
                _photo(<ScanCrop>[reversed ? first : second]),
              ]),
              hasLength(twoRules ? 1 : 2),
              reason: '${pair.key}, twoRules=$twoRules, quote=$quote, '
                  'reversed=$reversed',
            );
          }
        }
      }
    }
  });

  test('actual Circle OCR variants merge spatially and select the intact title over clipped prefix and suffix', () {
    ScanCrop circle(String name, int photo, {String color = 'blue'}) {
      const List<List<ScanPoint>> corners = <List<ScanPoint>>[
        <ScanPoint>[
          ScanPoint(.285480, .552887),
          ScanPoint(.570700, .595917),
          ScanPoint(.538431, .850981),
          ScanPoint(.080807, .778988),
        ],
        <ScanPoint>[
          ScanPoint(.271785, .544706),
          ScanPoint(.669272, .602764),
          ScanPoint(.568213, .886549),
          ScanPoint(.020379, .800482),
        ],
        <ScanPoint>[
          ScanPoint(.285839, .553093),
          ScanPoint(.570861, .595897),
          ScanPoint(.538064, .850921),
          ScanPoint(.080478, .778975),
        ],
        <ScanPoint>[
          ScanPoint(.287873, .551693),
          ScanPoint(.570808, .590324),
          ScanPoint(.538046, .849262),
          ScanPoint(.082374, .777893),
        ],
      ];
      return ScanCrop(
        imagePath: 'circle-$photo.jpg',
        width: 2536,
        height: 3542,
        rectified: true,
        sourceCorners: corners[photo],
        sharpness: photo == 0 ? .872 : .99,
        warnings: const <String>['geometry_adjusted'],
        lines: <ScanTextLine>[
          ScanTextLine(
            text: name,
            confidence: 1,
            bounds: const ScanBounds(.05, .02, .63, .035),
          ),
          ScanTextLine(
            text: 'Enchantment',
            confidence: 1,
            bounds: ScanBounds(.05, photo == 1 ? .482 : .552, .30, .032),
          ),
          const ScanTextLine(
            text: '1; Prevent all damage against you',
            confidence: 1,
            bounds: ScanBounds(.10, .65, .75, .04),
          ),
          ScanTextLine(
            text: 'from one $color source. If a source',
            confidence: 1,
            bounds: const ScanBounds(.10, .70, .74, .03),
          ),
          const ScanTextLine(
            text: 'deals damage to you more than',
            confidence: 1,
            bounds: ScanBounds(.10, .73, .69, .04),
          ),
          if (photo != 1)
            const ScanTextLine(
              text: 'once in a turn, you may pay -',
              confidence: 1,
              bounds: ScanBounds(.10, .76, .65, .04),
            ),
          if (photo != 1)
            const ScanTextLine(
              text: 'each time to prevent the damage.',
              confidence: 1,
              bounds: ScanBounds(.10, .80, .72, .04),
            ),
        ],
      );
    }

    final List<ScanFocusSelection> selected = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[
          circle('Strele of Protection: Blue', 0),
          _corroborated('Nevermore', .65, .60),
        ]),
        _photo(<ScanCrop>[_corroborated('Mirkwood Bats', .60, .15)]),
        _photo(<ScanCrop>[circle('Cirele of Protection: Blue', 1)]),
        _photo(<ScanCrop>[circle('rele of Protection Blue', 2)]),
        _photo(<ScanCrop>[circle('Cirele of Protection: B', 3)]),
      ],
    );
    expect(selected, hasLength(3));
    final ScanFocusSelection chosen = selected.singleWhere(
      (ScanFocusSelection item) => item.crop.imagePath.startsWith('circle-'),
    );
    expect(chosen.observations, 4);
    expect(chosen.photoIndex, 0);
    expect(
      ScanHints.fromCrop(chosen.crop).names.first,
      'Strele of Protection: Blue',
    );
    expect(chosen.crop.warnings, contains('geometry_adjusted'));
    final List<ScanFocusSelection> differentColors = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[circle('Circle of Protection: Blue', 0)]),
        _photo(<ScanCrop>[
          circle('Circle of Protection: White', 0, color: 'white'),
        ]),
      ],
    );
    expect(differentColors, hasLength(2));
  });

  test('recorded orientation repair merges its clipped suffix into the intact physical card', () async {
    final List<Object?> recorded = jsonDecode(
      await File('test/fixtures/focus_stack_orientation_clipped_scene.json')
          .readAsString(),
    ) as List<Object?>;
    final List<ScanRecognition> photos = recorded
        .map(
          (Object? value) =>
              ScanRecognition.fromMap(value as Map<Object?, Object?>),
        )
        .toList();
    final List<ScanFocusSelection> selected = mergeScanFocusStack(photos);
    expect(selected, hasLength(3));
    final ScanFocusSelection circle = selected.singleWhere(
      (ScanFocusSelection selection) =>
          ScanHints.fromCrop(selection.crop).names
              .contains('Circle of Protection: Blue'),
    );
    expect(circle.observations, 5);
    expect(circle.photoIndex, 0);
    expect(circle.crop, same(photos[0].crops[0]));
    expect(circle.crop.warnings, contains('geometry_adjusted'));
    expect(
      selected.map(
        (ScanFocusSelection selection) =>
            ScanHints.fromCrop(selection.crop).names.first,
      ),
      containsAll(<String>[
        'Mirkwood Bats',
        'Circle of Protection: Blue',
        'Nevermore',
      ]),
    );

    final ScanCrop complete = photos[0].crops[0];
    final ScanCrop damaged = photos[2].crops[0];
    expect(damaged.warnings, contains('orientation_ensemble'));
    expect(ScanHints.fromCrop(damaged).names.first, 'trele of Protection L');
    ScanCrop shifted(ScanCrop crop, double offset, String path) => ScanCrop(
      imagePath: path,
      width: crop.width,
      height: crop.height,
      rectified: crop.rectified,
      sourceCorners: crop.sourceCorners
          .map((ScanPoint point) => ScanPoint(point.x + offset, point.y))
          .toList(),
      sharpness: crop.sharpness,
      warnings: crop.warnings,
      lines: crop.lines,
    );
    final List<ScanFocusSelection> copies = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[
          complete,
          shifted(complete, .40, '/local/second-physical-copy.jpg'),
        ]),
        _photo(<ScanCrop>[damaged]),
      ],
    );
    expect(copies, hasLength(2));
    expect(
      copies.map((ScanFocusSelection selection) => selection.observations),
      containsAll(<int>[2, 1]),
    );
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[complete]),
        _photo(<ScanCrop>[
          shifted(damaged, .08, '/local/different-projection.jpg'),
        ]),
      ]),
      hasLength(2),
    );
    final ScanCrop different = ScanCrop(
      imagePath: '/local/full-different-title.jpg',
      width: complete.width,
      height: complete.height,
      rectified: complete.rectified,
      sourceCorners: complete.sourceCorners,
      warnings: const <String>['orientation_ensemble'],
      lines: complete.lines
          .map(
            (ScanTextLine line) => line.text == 'Circle of Protection: Blue'
                ? ScanTextLine(
                    text: 'Rune of Protection: Blue',
                    confidence: line.confidence,
                    bounds: line.bounds,
                    glyphHeight: line.glyphHeight,
                  )
                : line,
          )
          .toList(),
    );
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[complete]),
        _photo(<ScanCrop>[different]),
      ]),
      hasLength(2),
    );
    final ScanCrop misspelled = ScanCrop(
      imagePath: '/local/independent-title-misspelling.jpg',
      width: complete.width,
      height: complete.height,
      rectified: complete.rectified,
      sourceCorners: complete.sourceCorners,
      warnings: complete.warnings,
      lines: complete.lines
          .map(
            (ScanTextLine line) => line.text == 'Circle of Protection: Blue'
                ? ScanTextLine(
                    text: 'Strele of Protection: Blue',
                    confidence: line.confidence,
                    bounds: line.bounds,
                    glyphHeight: line.glyphHeight,
                  )
                : line,
          )
          .toList(),
    );
    expect(
      mergeScanFocusStack(<ScanRecognition>[
        _photo(<ScanCrop>[complete]),
        _photo(<ScanCrop>[misspelled]),
      ]),
      hasLength(1),
    );
    ScanCrop printing(String number, String set) => ScanCrop(
      imagePath: '/local/printing-$set-$number.jpg',
      width: complete.width,
      height: complete.height,
      rectified: true,
      sourceCorners: complete.sourceCorners,
      lines: <ScanTextLine>[
        ...complete.lines,
        ScanTextLine(
          text: number,
          confidence: 1,
          bounds: const ScanBounds(.05, .88, .2, .025),
        ),
        ScanTextLine(
          text: '$set EN',
          confidence: 1,
          bounds: const ScanBounds(.05, .92, .3, .025),
        ),
      ],
    );
    for (final ScanCrop conflicting in <ScanCrop>[
      printing('2', 'MOM'),
      printing('1', 'ONE'),
    ]) {
      expect(
        mergeScanFocusStack(<ScanRecognition>[
          _photo(<ScanCrop>[printing('1', 'MOM')]),
          _photo(<ScanCrop>[conflicting]),
        ]),
        hasLength(2),
      );
    }
  });

  test('automatic mounted focus passes merge observed title alternatives without inventing unreadable Bats', () async {
    final List<Object?> recorded = jsonDecode(
      await File('test/fixtures/focus_stack_automatic_duplicate_scene.json')
          .readAsString(),
    ) as List<Object?>;
    final List<ScanRecognition> photos = recorded
        .map(
          (Object? value) =>
              ScanRecognition.fromMap(value as Map<Object?, Object?>),
        )
        .toList();
    final List<ScanFocusSelection> selected = mergeScanFocusStack(photos);
    expect(selected, hasLength(2));
    final ScanFocusSelection circle = selected.singleWhere(
      (ScanFocusSelection selection) =>
          ScanHints.fromCrop(selection.crop).names
              .any((String name) => name.contains('Protection')),
    );
    expect(circle.crop, same(photos[2].crops[0]));
    expect(circle.observations, 3);
    expect(
      ScanHints.fromCrop(circle.crop).names.first,
      'Circle of Protection: Blue',
    );
    expect(
      selected.any(
        (ScanFocusSelection selection) =>
            ScanHints.fromCrop(selection.crop).names.contains('Mirkwood Bats'),
      ),
      isFalse,
    );
  });

  test('observed-alternative focus merge rejects adjacent cards and conflicting evidence', () async {
    final List<Object?> recorded = jsonDecode(
      await File('test/fixtures/focus_stack_automatic_duplicate_scene.json')
          .readAsString(),
    ) as List<Object?>;
    final List<ScanRecognition> photos = recorded
        .map(
          (Object? value) =>
              ScanRecognition.fromMap(value as Map<Object?, Object?>),
        )
        .toList();
    final ScanCrop typo = photos[1].crops[0];
    final ScanCrop complete = photos[2].crops[0];
    expect(ScanHints.fromCrop(typo).typeLine, isNull);
    expect(ScanHints.fromCrop(complete).typeLine, 'enchantment');
    ScanCrop changed(
      ScanCrop source, {
      double dx = 0,
      List<ScanTextLine>? lines,
    }) => ScanCrop(
      imagePath: source.imagePath,
      width: source.width,
      height: source.height,
      rectified: source.rectified,
      warnings: source.warnings,
      sharpness: source.sharpness,
      sourceCorners: source.sourceCorners
          .map((ScanPoint point) => ScanPoint(point.x + dx, point.y))
          .toList(),
      lines: lines ?? source.lines,
    );
    ScanTextLine text(
      ScanTextLine source,
      String value, {
      bool alternatives = true,
    }) => ScanTextLine(
      text: value,
      confidence: source.confidence,
      bounds: source.bounds,
      glyphHeight: source.glyphHeight,
      alternatives: alternatives ? source.alternatives : const <String>[],
    );
    ScanCrop footer(
      ScanCrop source, {
      String number = '001',
      String language = 'EN',
      String set = 'MOM',
    }) => changed(
      source,
      lines: <ScanTextLine>[
        ...source.lines,
        ScanTextLine(
          text: number,
          confidence: 1,
          bounds: const ScanBounds(.05, .88, .2, .025),
        ),
        ScanTextLine(
          text: '$set $language',
          confidence: 1,
          bounds: const ScanBounds(.05, .92, .3, .025),
        ),
      ],
    );
    final ScanCrop weakPrimary = changed(
      typo,
      lines: <ScanTextLine>[
        ...typo.lines.map(
          (ScanTextLine line) => line.bounds.y < .13
              ? ScanTextLine(
                  text: line.text,
                  confidence: .8,
                  bounds: line.bounds,
                  glyphHeight: line.glyphHeight,
                  alternatives: line.alternatives,
                )
              : line,
        ),
        const ScanTextLine(
          text: '4',
          confidence: 1,
          bounds: ScanBounds(.8, .04, .025, .025),
        ),
      ],
    );
    expect(
      ScanHints.fromCrop(weakPrimary).names.first,
      'Cirele of Protection: Blue',
    );
    final Map<String, (ScanCrop, ScanCrop)> cases =
        <String, (ScanCrop, ScanCrop)>{
          'weak title with mana noise': (weakPrimary, complete),
          'adjacent shift minus .08': (changed(typo, dx: -.08), complete),
          'missing observed title alternative': (
            typo,
            changed(
              complete,
              lines: complete.lines
                  .map(
                    (ScanTextLine line) =>
                        text(line, line.text, alternatives: false),
                  )
                  .toList(),
            ),
          ),
          'conflicting color': (
            typo,
            changed(
              complete,
              lines: complete.lines
                  .map(
                    (ScanTextLine line) => text(
                      line,
                      line.bounds.y >= .5
                          ? line.text.replaceAll('blue', 'white')
                          : line.text,
                    ),
                  )
                  .toList(),
            ),
          ),
          'conflicting rule number': (
            typo,
            changed(
              complete,
              lines: complete.lines
                  .map(
                    (ScanTextLine line) => text(
                      line,
                      line.text.startsWith('; Prevent')
                          ? '2${line.text}'
                          : line.text,
                    ),
                  )
                  .toList(),
            ),
          ),
          'one body agreement': (
            typo,
            changed(
              complete,
              lines: complete.lines
                  .where(
                    (ScanTextLine line) =>
                        line.bounds.y < .13 ||
                        line.text == 'Enchantment' ||
                        line.text.startsWith('; Prevent'),
                  )
                  .toList(),
            ),
          ),
          'conflicting type': (
            changed(
              typo,
              lines: <ScanTextLine>[
                ...typo.lines,
                const ScanTextLine(
                  text: 'Creature',
                  confidence: 1,
                  bounds: ScanBounds(.05, .51, .5, .025),
                ),
              ],
            ),
            complete,
          ),
          'conflicting collector number': (
            footer(typo),
            footer(complete, number: '002'),
          ),
          'conflicting language': (
            footer(typo),
            footer(complete, language: 'FR'),
          ),
          'conflicting set': (footer(typo), footer(complete, set: 'ONE')),
        };
    final Map<String, int> counts = <String, int>{
      for (final MapEntry<String, (ScanCrop, ScanCrop)> entry in cases.entries)
        entry.key: mergeScanFocusStack(<ScanRecognition>[
          _photo(<ScanCrop>[entry.value.$1]),
          _photo(<ScanCrop>[entry.value.$2]),
        ]).length,
    };
    expect(counts, <String, int>{
      for (final String label in cases.keys) label: 2,
    });
  });

  test('similar titles require strong overlap and independent rules rather than fuzzy identity alone', () {
    final List<ScanFocusSelection>
    moving = mergeScanFocusStack(<ScanRecognition>[
      _photo(<ScanCrop>[_corroborated('Circle of Protection: Blue', .10, .30)]),
      _photo(<ScanCrop>[_corroborated('Cirele of Protection: Blue', .16, .30)]),
    ]);
    expect(moving, hasLength(2));
    final List<ScanFocusSelection> noRules = mergeScanFocusStack(
      <ScanRecognition>[
        _photo(<ScanCrop>[_crop('Circle of Protection: Blue', .10, .30)]),
        _photo(<ScanCrop>[_crop('Circle of Protection: White', .10, .30)]),
      ],
    );
    // Uncorroborated OCR remains one spatial proposal; it does not prove either name.
    expect(noRules, hasLength(1));
  });

  group('durable focus stacks', () {
    late Directory directory;
    late List<File> originals;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'collector-focus-stack-',
      );
      Hive.init(directory.path);
      originals = <File>[];
      for (int index = 0; index < 3; index++) {
        originals.add(
          await File('${directory.path}/camera-$index.jpg')
              .writeAsBytes(<int>[index, 255, 42], flush: true),
        );
      }
    });
    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    test('lost durable acknowledgement retries the same capture without another scene or quantity', () async {
      final List<String> paths = originals
          .map((File file) => file.path)
          .toList();
      final ScanDraftStore failing = ScanDraftStore(
        userId: 'ack',
        openBox: (String name) async =>
            _LostGroupAcknowledgementBox(await Hive.openBox<String>(name)),
      );
      await expectLater(
        failing.importFocusStack(paths, ownedCameraSource: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await Future.wait(originals.map((File file) => file.exists())),
        everyElement(isTrue),
      );
      await Hive.close();
      final ScanDraftStore restored = ScanDraftStore(userId: 'ack');
      final List<ScanDraftPhoto> pending = await restored.readPhotos();
      expect(pending, hasLength(1));
      final List<ScanDraftPhoto> retry = await restored.importFocusStack(paths);
      expect(retry.first.id, pending.single.id);
      expect(await restored.readPhotos(), hasLength(1));
      final _SceneRecognizer recognizer = _SceneRecognizer(<List<ScanCrop>>[
        <ScanCrop>[_crop('Nevermore', .2, .2)],
        <ScanCrop>[_crop('Nevermore', .2, .2)],
        <ScanCrop>[_crop('Nevermore', .2, .2)],
      ]);
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: _ReviewResolver(),
        store: restored,
      );
      await session.load();
      expect(await session.addFocusStack(paths), isTrue);
      await _settled(session);
      expect(session.items, hasLength(1));
      expect(recognizer.sourceIndexes.take(3), <int>[0, 1, 2]);
      expect(
        recognizer.calls,
        4,
        reason: 'Three depth reads plus one bounded recovery for the unresolved merged card.',
      );
      final List<int> readsPerSource = <int>[
        for (int index = 0; index < 3; index++)
          recognizer.sourceIndexes
              .where((int source) => source == index)
              .length,
      ]..sort();
      expect(readsPerSource, <int>[1, 1, 2]);
      expect(await session.addFocusStack(paths), isTrue);
      await _settled(session);
      expect(session.items, hasLength(1));
      expect(
        recognizer.calls,
        4,
        reason: 'Replaying the accepted stack starts neither depth reads nor another recovery.',
      );
      session.dispose();
    });

    test('reopening a pending group reads each depth with bounded unresolved recovery and retains every source until removal', () async {
      final ScanDraftStore initial = ScanDraftStore(userId: 'focus');
      final List<ScanDraftPhoto> admitted = await initial.importFocusStack(
        originals.map((File file) => file.path).toList(),
        ownedCameraSource: true,
      );
      expect(await initial.readPhotos(), hasLength(1));
      expect(await initial.readFocusStack(admitted.first.id), hasLength(3));
      expect(
        await Future.wait(originals.map((File file) => file.exists())),
        everyElement(isFalse),
      );
      await Hive.close();
      final ScanDraftStore restored = ScanDraftStore(userId: 'focus');
      final _SceneRecognizer recognizer = _SceneRecognizer(<List<ScanCrop>>[
        <ScanCrop>[
          _crop('Nevermore', .60, .55),
          _crop('', .20, .55),
          _crop('', .60, .15),
        ],
        <ScanCrop>[
          _crop('', .60, .55),
          _crop('Circle of Protection: Blue', .20, .55),
          _crop('', .60, .15),
        ],
        <ScanCrop>[
          _crop('', .60, .55),
          _crop('', .20, .55),
          _crop('Mirkwood Bats', .60, .15),
        ],
      ]);
      final _ReviewResolver resolver = _ReviewResolver();
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: resolver,
        store: restored,
      );
      await session.load();
      await _settled(session);
      expect(recognizer.sourceIndexes.take(3), <int>[0, 1, 2]);
      expect(
        recognizer.calls,
        6,
        reason:
            'Three depth reads plus one recovery per unresolved saved source.',
      );
      for (int index = 0; index < 3; index++) {
        expect(
          recognizer.sourceIndexes.where((int source) => source == index),
          hasLength(2),
        );
      }
      expect(session.items, hasLength(3));
      expect(resolver.batches.first, hasLength(3));
      expect(await restored.readPhotos(), isEmpty);
      for (int index = 0; index < admitted.length; index++) {
        expect(
          await File((await restored.readSource(admitted[index].id))!.imagePath)
              .readAsBytes(),
          <int>[index, 255, 42],
        );
      }
      session.dispose();
      await Hive.close();
      final ScanDraftStore reopened = ScanDraftStore(userId: 'focus');
      final List<ScanDraftItem> items = await reopened.readItems();
      expect(items, hasLength(3));
      expect(
        items.map((ScanDraftItem item) => item.photoId).toSet(),
        admitted.map((ScanDraftPhoto photo) => photo.id).toSet(),
      );
      await reopened.removeItems(<String>[items.first.id]);
      expect(
        await Future.wait(
          admitted.map(
            (ScanDraftPhoto photo) => File(photo.imagePath).exists(),
          ),
        ),
        everyElement(isTrue),
      );
      await reopened.removeItems(
        items.skip(1).map((ScanDraftItem item) => item.id).toList(),
      );
      expect(
        await Future.wait(
          admitted.map(
            (ScanDraftPhoto photo) => File(photo.imagePath).exists(),
          ),
        ),
        everyElement(isFalse),
      );
    });

    test('interrupted completion reopens one group and replays stable IDs without tripling cards', () async {
      final ScanDraftStore normal = ScanDraftStore(userId: 'interrupted');
      final List<ScanDraftPhoto> photos = await normal.importFocusStack(
        originals.map((File file) => file.path).toList(),
      );
      final List<ScanDraftItem> items = <ScanDraftItem>[
        ScanDraftItem(
          id: '${photos.first.id}_0',
          photoId: photos.last.id,
          crop: _crop('Nevermore', .2, .2),
        ),
      ];
      final ScanDraftStore interrupted = ScanDraftStore(
        userId: 'interrupted',
        openBox: (String name) async =>
            _InterruptedGroupBox(await Hive.openBox<String>(name)),
      );
      await expectLater(
        interrupted.completeFocusStack(photos, items),
        throwsA(isA<FileSystemException>()),
      );
      await Hive.close();
      final ScanDraftStore reopened = ScanDraftStore(userId: 'interrupted');
      expect(await reopened.readPhotos(), hasLength(1));
      expect(await reopened.readFocusStack(photos.first.id), hasLength(3));
      await reopened.completeFocusStack(
        await reopened.readFocusStack(photos.first.id),
        items,
      );
      expect(await reopened.readPhotos(), isEmpty);
      expect(await reopened.readItems(), hasLength(1));
    });

    test('discarding a pending group removes only its owned copies and retains gallery originals', () async {
      final ScanDraftStore store = ScanDraftStore(userId: 'discard');
      final List<ScanDraftPhoto> photos = await store.importFocusStack(
        originals.map((File file) => file.path).toList(),
      );
      await store.removePhotos(<String>[photos.first.id]);
      expect(await store.readPhotos(), isEmpty);
      expect(
        await Future.wait(
          photos.map((ScanDraftPhoto photo) => File(photo.imagePath).exists()),
        ),
        everyElement(isFalse),
      );
      expect(
        await Future.wait(originals.map((File file) => file.exists())),
        everyElement(isTrue),
      );
    });

    test('closing during recognition retains the complete pending group for a new session', () async {
      final Completer<void> started = Completer<void>();
      final Completer<void> release = Completer<void>();
      final _SceneRecognizer recognizer = _SceneRecognizer(
        <List<ScanCrop>>[
          <ScanCrop>[_crop('Nevermore', .2, .2)],
          <ScanCrop>[_crop('Nevermore', .2, .2)],
          <ScanCrop>[_crop('Nevermore', .2, .2)],
        ],
        firstStarted: started,
        firstRelease: release,
      );
      final ScanDraftStore store = ScanDraftStore(userId: 'closing');
      final ScanSession session = ScanSession(
        recognizer: recognizer,
        resolver: _ReviewResolver(),
        store: store,
      );
      await session.load();
      expect(
        await session.addFocusStack(
          originals.map((File file) => file.path).toList(),
        ),
        isTrue,
      );
      await started.future;
      session.dispose();
      release.complete();
      await _settled(session);
      expect(recognizer.calls, 1);
      final List<ScanDraftPhoto> pending = await store.readPhotos();
      expect(pending, hasLength(1));
      expect(await store.readFocusStack(pending.single.id), hasLength(3));
      expect(await store.readItems(), isEmpty);
    });
  });
}
