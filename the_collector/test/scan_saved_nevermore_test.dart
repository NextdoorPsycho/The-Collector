import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';
import 'package:the_collector/utils/scanning/scan_resolver.dart';

// Public catalog reference: https://api.scryfall.com/cards/67b610fe-36ee-4d58-8ed4-04e7a12587b2
const String _catalogJson =
    r'''{"object": "card", "id": "67b610fe-36ee-4d58-8ed4-04e7a12587b2", "oracle_id": "0a1f4892-c9fa-4c60-a41e-7986cdd59096", "multiverse_ids": [226878], "mtgo_id": 42448, "mtgo_foil_id": 42449, "tcgplayer_id": 55976, "cardmarket_id": 250644, "name": "Nevermore", "lang": "en", "released_at": "2011-09-30", "uri": "https://api.scryfall.com/cards/67b610fe-36ee-4d58-8ed4-04e7a12587b2", "scryfall_uri": "https://scryfall.com/card/isd/25/nevermore?utm_source=api", "layout": "normal", "highres_image": true, "image_status": "highres_scan", "image_updated_at": "2026-07-13T11:09:49Z", "image_uris": {"small": "https://cards.scryfall.io/small/front/6/7/67b610fe-36ee-4d58-8ed4-04e7a12587b2.jpg?1783940989", "normal": "https://cards.scryfall.io/normal/front/6/7/67b610fe-36ee-4d58-8ed4-04e7a12587b2.jpg?1783940989", "large": "https://cards.scryfall.io/large/front/6/7/67b610fe-36ee-4d58-8ed4-04e7a12587b2.jpg?1783940989", "png": "https://cards.scryfall.io/png/front/6/7/67b610fe-36ee-4d58-8ed4-04e7a12587b2.png?1783940989", "art_crop": "https://cards.scryfall.io/art_crop/front/6/7/67b610fe-36ee-4d58-8ed4-04e7a12587b2.jpg?1783940989", "border_crop": "https://cards.scryfall.io/border_crop/front/6/7/67b610fe-36ee-4d58-8ed4-04e7a12587b2.jpg?1783940989", "thumb": "https://cards.scryfall.io/thumb/front/6/7/67b610fe-36ee-4d58-8ed4-04e7a12587b2.webp?1783940989", "grid": "https://cards.scryfall.io/grid/front/6/7/67b610fe-36ee-4d58-8ed4-04e7a12587b2.webp?1783940989", "display": "https://cards.scryfall.io/display/front/6/7/67b610fe-36ee-4d58-8ed4-04e7a12587b2.webp?1783940989", "art": "https://cards.scryfall.io/art/front/6/7/67b610fe-36ee-4d58-8ed4-04e7a12587b2.webp?1783940989", "crop": "https://cards.scryfall.io/crop/front/6/7/67b610fe-36ee-4d58-8ed4-04e7a12587b2.webp?1783940989"}, "mana_cost": "{1}{W}{W}", "cmc": 3.0, "type_line": "Enchantment", "oracle_text": "As this enchantment enters, choose a nonland card name.\nSpells with the chosen name can't be cast.", "colors": ["W"], "color_identity": ["W"], "keywords": [], "legalities": {"standard": "not_legal", "future": "not_legal", "historic": "not_legal", "timeless": "not_legal", "gladiator": "not_legal", "pioneer": "not_legal", "modern": "legal", "legacy": "legal", "pauper": "not_legal", "vintage": "legal", "penny": "legal", "commander": "legal", "oathbreaker": "legal", "standardbrawl": "not_legal", "brawl": "not_legal", "competitivebrawl": "not_legal", "alchemy": "not_legal", "paupercommander": "not_legal", "duel": "legal", "oldschool": "not_legal", "premodern": "not_legal", "predh": "not_legal", "tlr": "legal"}, "games": ["paper", "mtgo"], "reserved": false, "game_changer": false, "foil": true, "nonfoil": true, "finishes": ["nonfoil", "foil"], "oversized": false, "promo": false, "reprint": false, "variation": false, "set_id": "d1026945-2969-42b9-be53-f941405a58cb", "set": "isd", "set_name": "Innistrad", "set_type": "expansion", "set_uri": "https://api.scryfall.com/sets/d1026945-2969-42b9-be53-f941405a58cb", "set_search_uri": "https://api.scryfall.com/cards/search?order=set&q=e%3Aisd&unique=prints", "scryfall_set_uri": "https://scryfall.com/sets/isd?utm_source=api", "rulings_uri": "https://api.scryfall.com/cards/67b610fe-36ee-4d58-8ed4-04e7a12587b2/rulings", "prints_search_uri": "https://api.scryfall.com/cards/search?order=released&q=oracleid%3A0a1f4892-c9fa-4c60-a41e-7986cdd59096&unique=prints", "collector_number": "25", "digital": false, "rarity": "rare", "flavor_text": "\"By the law of Avacyn, the following thoughts, words, and deeds are henceforth disallowed.\"", "card_back_id": "0aeebaf5-8c7d-4636-9e82-8c27447861f7", "artist": "Jason A. Engle", "artist_ids": ["02e2b5de-4341-464c-8fdb-a1adbf873bc0"], "illustration_id": "c4008d2f-9e82-4dfb-a45f-577e981542b2", "border_color": "black", "frame": "2003", "full_art": false, "textless": false, "booster": true, "story_spotlight": false, "edhrec_rank": 14737, "penny_rank": 1464, "prices": {"usd": "1.99", "usd_foil": "6.77", "usd_etched": null, "eur": "0.49", "eur_foil": "2.82", "tix": "0.02"}, "related_uris": {"gatherer": "https://gatherer.wizards.com/Pages/Card/Details.aspx?multiverseid=226878&printed=false", "tcgplayer_infinite_articles": "https://partner.tcgplayer.com/c/4931599/1830156/21018?subId1=api&trafcat=tcgplayer.com%2Fsearch%2Farticles&u=https%3A%2F%2Fwww.tcgplayer.com%2Fsearch%2Farticles%3FproductLineName%3Dmagic%26q%3DNevermore", "tcgplayer_infinite_decks": "https://partner.tcgplayer.com/c/4931599/1830156/21018?subId1=api&trafcat=tcgplayer.com%2Fsearch%2Fdecks&u=https%3A%2F%2Fwww.tcgplayer.com%2Fsearch%2Fdecks%3FproductLineName%3Dmagic%26q%3DNevermore", "edhrec": "https://edhrec.com/route/?cc=Nevermore"}, "purchase_uris": {"tcgplayer": "https://partner.tcgplayer.com/c/4931599/1830156/21018?subId1=api&u=https%3A%2F%2Fwww.tcgplayer.com%2Fproduct%2F55976%3Fpage%3D1", "cardmarket": "https://www.cardmarket.com/en/Magic/Products?idProduct=250644&referrer=scryfall&utm_campaign=card_prices&utm_medium=text&utm_source=scryfall", "cardhoarder": "https://www.cardhoarder.com/cards/42448?affiliate_id=scryfall&ref=card-profile&utm_campaign=affiliate&utm_medium=card&utm_source=scryfall"}}''';

class _SavedCatalog extends Fake implements ScanCatalog {
  final MtgCard card = MtgCard.fromJson(
    jsonDecode(_catalogJson) as Map<String, Object?>,
  );

  @override
  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) async => PaginableList<MtgCard>(data: <MtgCard>[card], hasMore: false);

  @override
  Future<PaginableList<MtgCard>> rulesTextPrintings(
    String phrase, {
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
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
  Future<MtgCard?> exactPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  }) async => null;

  @override
  Future<MtgCard?> fuzzyName(String name) async => null;
}

const ScanCrop _saved = ScanCrop(
  imagePath: '',
  width: 1575,
  height: 2205,
  rectified: false,
  warnings: <String>['no_card_rectangle', 'partial_card', 'incomplete_card'],
  sourceCorners: <ScanPoint>[
    ScanPoint(0.6204449371747903, 0.5636116236059224),
    ScanPoint(0.8806433455695102, 0.5636116236059224),
    ScanPoint(0.8806433455695102, 0.836929279482729),
    ScanPoint(0.6204449371747903, 0.836929279482729),
  ],
  lines: <ScanTextLine>[
    ScanTextLine(
      text: "Enchantment",
      confidence: 1.0,
      alternatives: <String>["Enchantmen", "Enchantmet"],
      glyphHeight: 0.03120472184644001,
      bounds: ScanBounds(
        0.044533981778498356,
        0.45759324999757767,
        0.39918432865046,
        0.07247933105026061,
      ),
    ),
    ScanTextLine(
      text: "As Nevermore enters the ba",
      confidence: 1.0,
      alternatives: <String>[
        "As Nevermore enter the ba",
        "As Nevermor enters the ba",
      ],
      glyphHeight: 0.04432352132913851,
      bounds: ScanBounds(
        0.04320120740983964,
        0.5274713502466429,
        0.9567987925901603,
        0.12814242517742802,
      ),
    ),
    ScanTextLine(
      text: "name a nonland card.",
      confidence: 1.0,
      alternatives: <String>["name a noland card.", "name a nonland card"],
      glyphHeight: 0.04501536020064712,
      bounds: ScanBounds(
        0.040186120154500724,
        0.5608720960842639,
        0.765847298094464,
        0.12188953112604817,
      ),
    ),
    ScanTextLine(
      text: "The named card can't be c",
      confidence: 1.0,
      alternatives: <String>[
        "The named card can't bec",
        "The named card can't be",
      ],
      glyphHeight: 0.0499861071923048,
      bounds: ScanBounds(
        0.032192075683304636,
        0.6181891772656253,
        0.9678079243166954,
        0.13828471262457143,
      ),
    ),
    ScanTextLine(
      text: "van t oe c",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.03715872789058182,
      bounds: ScanBounds(
        0.63881276012503,
        0.7,
        0.35270551497561076,
        0.04538601504197254,
      ),
    ),
    ScanTextLine(
      text: "By the law of Avacyn, the f",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.04992265556608251,
      bounds: ScanBounds(
        0.07864655434338504,
        0.7,
        0.9092702333092083,
        0.12221732519803377,
      ),
    ),
    ScanTextLine(
      text: "thoughts",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.04459742822520603,
      bounds: ScanBounds(
        0.03355136918066465,
        0.7320761475237211,
        0.3004299299365978,
        0.07287132977719032,
      ),
    ),
    ScanTextLine(
      text: ", words, and",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.047595387596957736,
      bounds: ScanBounds(
        0.3139717419400775,
        0.7591151671566191,
        0.4319993614545329,
        0.0842223268261129,
      ),
    ),
    ScanTextLine(
      text: "deeds",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.04078116490820628,
      bounds: ScanBounds(
        0.7275847510481303,
        0.7951380066543785,
        0.1924506250371788,
        0.054173104784639915,
      ),
    ),
    ScanTextLine(
      text: "a",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.024913494631735044,
      bounds: ScanBounds(
        0.9331395342169948,
        0.8235294121004307,
        0.04360465228860155,
        0.024913493960285447,
      ),
    ),
    ScanTextLine(
      text: "-Jason A. Engle",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.033103649735445426,
      bounds: ScanBounds(
        0.08320559379829003,
        0.8695488411299525,
        0.4015069177308059,
        0.07355851464401202,
      ),
    ),
    ScanTextLine(
      text: "&e C 1995-2051 Wouede of due €",
      confidence: 0.5,
      alternatives: <String>[],
      glyphHeight: 0.02839926315192356,
      bounds: ScanBounds(
        0.050344065959867526,
        0.902204377467925,
        0.5738781769263563,
        0.08492516001905917,
      ),
    ),
    ScanTextLine(
      text: "rugnis, woras, an",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.05071862927018316,
      bounds: ScanBounds(
        0.08149575096333216,
        0.76,
        0.5659362107515336,
        0.08013852655231563,
      ),
    ),
    ScanTextLine(
      text: "henceforth",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.0428694144435797,
      bounds: ScanBounds(
        0.038540066104093315,
        0.7778159527142807,
        0.3478398621082306,
        0.07502960780881485,
      ),
    ),
    ScanTextLine(
      text: "disall",
      confidence: 1.0,
      alternatives: <String>[],
      glyphHeight: 0.0320968982282215,
      bounds: ScanBounds(
        0.40335807101529103,
        0.8214624371298809,
        0.19148043692111968,
        0.04282171515698705,
      ),
    ),
    ScanTextLine(
      text: "Nevermore",
      confidence: 1.0,
      alternatives: <String>["Nevermor", "Nevemore"],
      glyphHeight: 0.024609230460538492,
      bounds: ScanBounds(
        0.03917639721382605,
        0.0356092797984896,
        0.3195037841796875,
        0.05119564992076947,
      ),
    ),
  ],
);

ScanCrop _withLines(List<ScanTextLine> lines) => ScanCrop(
  imagePath: '',
  width: _saved.width,
  height: _saved.height,
  rectified: _saved.rectified,
  warnings: _saved.warnings,
  sourceCorners: _saved.sourceCorners,
  lines: lines,
);

void main() {
  test('saved partial split-flavor observations corroborate the authoritative Nevermore rules without inventing printing proof', () async {
    final ScanResolution result = await ScanResolver(catalog: _SavedCatalog())
        .resolve(_saved);
    expect(result.hints.names, <String>['Nevermore']);
    expect(result.hints.typeLine, 'enchantment');
    expect(result.hints.rulesText, contains('rugnis, woras, an'));
    expect(result.candidates.single.card.name, 'Nevermore');
    expect(
      result.candidates.single.evidence,
      containsAll(<ScanEvidence>[
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
        ScanEvidence.rulesTextMatch,
      ]),
    );
    expect(result.candidates.single.hasContradiction, isFalse);
    expect(result.status, ScanResolutionStatus.needsReview);
    expect(hasExactPrintingEvidence(_saved, result), isFalse);
    expect(_saved.lines[12].text, 'rugnis, woras, an');
  });

  test('genuine contradictory rules remain contradictory next to split flavor observations', () async {
    final List<ScanTextLine> changed = List<ScanTextLine>.of(_saved.lines);
    final ScanTextLine original = changed[2];
    changed[2] = ScanTextLine(
      text: 'Destroy target nonartifact creature.',
      confidence: original.confidence,
      bounds: original.bounds,
      glyphHeight: original.glyphHeight,
    );
    final ScanResolution result = await ScanResolver(catalog: _SavedCatalog())
        .resolve(_withLines(changed));
    expect(
      result.candidates.single.evidence,
      contains(ScanEvidence.rulesTextMismatch),
    );
    expect(result.candidates.single.hasContradiction, isTrue);
  });
  test(
    'split-flavor grouping keeps color and numeric contradictions visible',
    () async {
      for (final String text in <String>[
        'Sacrifice three blue creatures.',
        'Destroy target nonartifact creature.',
      ]) {
        final List<ScanTextLine> changed = List<ScanTextLine>.of(_saved.lines);
        final ScanTextLine original = changed[12];
        changed[12] = ScanTextLine(
          text: text,
          confidence: original.confidence,
          bounds: original.bounds,
          glyphHeight: original.glyphHeight,
        );
        final ScanResolution result = await ScanResolver(
          catalog: _SavedCatalog(),
        ).resolve(_withLines(changed));
        expect(result.hints.rulesText, contains(text));
        expect(
          result.candidates.single.evidence,
          contains(ScanEvidence.rulesTextMismatch),
          reason: text,
        );
      }
    },
  );

  test('split flavor alone never supplies rules-text evidence', () async {
    final ScanCrop flavor = _withLines(<ScanTextLine>[
      _saved.lines.first,
      ..._saved.lines.skip(4),
    ]);
    final ScanResolution result = await ScanResolver(catalog: _SavedCatalog())
        .resolve(flavor);
    expect(
      result.candidates.single.evidence,
      isNot(contains(ScanEvidence.rulesTextMatch)),
    );
    expect(hasExactPrintingEvidence(flavor, result), isFalse);
  });
}
