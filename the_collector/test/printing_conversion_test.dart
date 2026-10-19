import 'dart:convert';
import 'dart:io';

import 'package:collector_models/card/mtg_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scryfall_api/scryfall_api.dart' as sf;
import 'package:the_collector/utils/collection_ingestion.dart';

Map<String, dynamic> _fixture() => jsonDecode(
  File('test/fixtures/scryfall_split_card.json').readAsStringSync(),
) as Map<String, dynamic>;

void main() {
  test('Scryfall split printing retains identity, language, nullable mana, prices and timestamp', () {
    final sf.MtgCard source = sf.MtgCard.fromJson(_fixture());
    final MTGCard card = cardFromScryfall(source, finish: sf.Finish.nonfoil);
    final MTGCard decoded = MTGCardMapper.fromJson(card.toJson());
    expect(decoded.scryfallId, source.id);
    expect(decoded.oracleId, source.oracleId);
    expect(decoded.language, 'en');
    expect(decoded.setCode, source.set);
    expect(decoded.collectorNumber, source.collectorNumber);
    expect(decoded.finish, sf.Finish.nonfoil);
    expect(decoded.pricesUpdatedAt, card.pricesUpdatedAt);
    expect(decoded.oracleText, contains('Destroy all creatures'));
    expect(decoded.imageUrl, source.imageUris!.normal.toString());
    expect(
      () => cardFromScryfall(source, finish: sf.Finish.foil),
      throwsArgumentError,
    );
  });

  test('two-faced cards without top-level images retain both faces and aggregate colors', () {
    final Map<String, dynamic> json = _fixture()
      ..remove('image_uris')
      ..remove('colors');
    final List<Map<String, dynamic>> faces =
        (json['card_faces'] as List<Object?>).cast<Map<String, dynamic>>();
    final Map<String, dynamic> images = <String, dynamic>{
      for (final String key in <String>[
        'small',
        'normal',
        'large',
        'png',
        'art_crop',
        'border_crop',
      ])
        key: 'https://cards.example/front.png',
    };
    faces.first['image_uris'] = images;
    faces.first['colors'] = <String>['W'];
    faces.last['colors'] = <String>['W'];
    faces.last['image_uris'] = <String, dynamic>{
      for (final String key in images.keys)
        key: 'https://cards.example/back.png',
    };
    final MTGCard card = cardFromScryfall(
      sf.MtgCard.fromJson(json),
      finish: sf.Finish.nonfoil,
    );
    expect(card.imageUrl, 'https://cards.example/front.png');
    expect(card.backImageUrl, 'https://cards.example/back.png');
    expect(card.colors, contains(sf.Color.white));
  });
}
