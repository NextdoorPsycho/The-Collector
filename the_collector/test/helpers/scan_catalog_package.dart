import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

Future<Directory> writeScanCatalogPackage(
  Directory directory,
  List<Map<String, Object?>> cards,
  Map<String, List<double>> descriptors, {
  String version = '0123456789abcdef01234567',
  Map<String, Uint8List>? referencePixels,
}) async {
  await directory.create(recursive: true);
  final BytesBuilder shard = BytesBuilder(copy: false);
  final List<List<Object?>> entries = <List<Object?>>[];
  final Set<String> illustrations = <String>{};
  for (int start = 0; start < cards.length; start += 100) {
    final int end = start + 100 < cards.length ? start + 100 : cards.length;
    final List<int> chunk = gzip.encode(
      utf8.encode(jsonEncode(cards.sublist(start, end))),
    );
    final int offset = shard.length;
    shard.add(chunk);
    for (int index = start; index < end; index++) {
      final Map<String, Object?> card = cards[index];
      final List<String> ids = <String>[
        if (card['illustration_id'] is String)
          card['illustration_id']! as String,
      ];
      illustrations.addAll(ids);
      entries.add(<Object?>[
        card['id'],
        card['name'],
        card['set'],
        card['collector_number'],
        card['lang'],
        card['oracle_id'] ?? card['id'],
        ids,
        0,
        offset,
        chunk.length,
        index - start,
        <String>[card['name']! as String],
      ]);
    }
  }
  await File('${directory.path}/cards.0000.bin')
      .writeAsBytes(shard.takeBytes());
  await File('${directory.path}/catalog.index.json.gz').writeAsBytes(
    gzip.encode(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'schema': 1,
          'entries': entries,
          'oracleRows': <String, Object?>{},
        }),
      ),
    ),
  );
  final List<String> ids = descriptors.keys.toList()..sort();
  await File('${directory.path}/visual.ids.json.gz')
      .writeAsBytes(gzip.encode(utf8.encode(jsonEncode(ids))));
  final Uint8List vectors = Uint8List(16 + ids.length * 256);
  vectors.setRange(0, 8, utf8.encode('SCVEC01\u0000'));
  final ByteData header = ByteData.sublistView(vectors);
  header.setUint32(8, 256, Endian.little);
  header.setUint32(12, ids.length, Endian.little);
  for (int index = 0; index < ids.length; index++) {
    final List<double> row = descriptors[ids[index]]!;
    if (row.length != 256) {
      throw ArgumentError('Descriptor must contain 256 values.');
    }
    vectors.setRange(
      16 + index * 256,
      16 + (index + 1) * 256,
      row.map((double value) => (value * 255).round()),
    );
  }
  await File('${directory.path}/visual.index.bin').writeAsBytes(vectors);
  final BytesBuilder gray = BytesBuilder(copy: false)
    ..add(utf8.encode('SCGRSH2\u0000'));
  final List<List<Object?>> grayRows = <List<Object?>>[];
  for (int index = 0; index < ids.length; index++) {
    final Uint8List pixels =
        referencePixels?[ids[index]] ??
        Uint8List.fromList(
          List<int>.generate(
            2304,
            (int position) => (position * 7 + index * 13) % 256,
          ),
        );
    if (pixels.length != 2304) {
      throw ArgumentError('Reference requires 2304 pixels.');
    }
    final List<int> compressed = gzip.encode(pixels);
    grayRows.add(<Object?>[
      0,
      gray.length,
      compressed.length,
      sha256.convert(pixels).toString(),
    ]);
    gray.add(compressed);
  }
  await File('${directory.path}/visual.gray.0000.bin')
      .writeAsBytes(gray.takeBytes());
  await File('${directory.path}/visual.gray.index.json.gz').writeAsBytes(
    gzip.encode(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'schema': 'gray48-bt601-cg-high-v1',
          'bytesPerReference': 2304,
          'rows': grayRows,
        }),
      ),
    ),
  );
  final List<Map<String, Object?>> files = <Map<String, Object?>>[];
  await for (final FileSystemEntity entity in directory.list()) {
    if (entity is! File || entity.path.endsWith('manifest.json')) continue;
    final List<int> bytes = await entity.readAsBytes();
    files.add(<String, Object?>{
      'name': entity.uri.pathSegments.last,
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
  }
  await File('${directory.path}/manifest.json').writeAsString(
    jsonEncode(<String, Object?>{
      'schema': 2,
      'descriptorSchema': 'rgb-gradient-8x8-v1',
      'referenceSchema': 'gray48-bt601-cg-high-v1',
      'version': version,
      'metadataComplete': true,
      'cardCount': cards.length,
      'visualCount': ids.length,
      'illustrationCount': illustrations.length,
      'visualComplete': ids.length == illustrations.length,
      'files': files,
    }),
  );
  return directory;
}
