import 'dart:io';

import 'package:flutter/foundation.dart';

import 'scan_local_catalog.dart';
import 'scan_recognition.dart';
import 'scan_visual_work_scheduler.dart';

typedef ScanArtworkDescriptor = Future<List<double>?> Function(
  String imagePath,
  int rotationDegrees,
  ScanBounds queryRegion,
);

abstract interface class ScanVisualRetriever {
  Future<List<LocalVisualHit>> discover(ScanCrop crop);
}

class IndexedScanVisualRetriever implements ScanVisualRetriever {
  static const ScanBounds standardArtwork = ScanBounds(.07, .075, .86, .44);
  static const ScanBounds extendedArtwork = ScanBounds(.07, .10, .86, .65);
  final LocalScanCatalog catalog;
  final ScanArtworkDescriptor _descriptor;
  final double maximumDistance;

  IndexedScanVisualRetriever({
    LocalScanCatalog? catalog,
    ScanArtworkDescriptor? descriptor,
    this.maximumDistance = .35,
  }) : catalog = catalog ?? LocalScanCatalog.shared,
       _descriptor = descriptor ?? nativeDescriptor;

  static Future<List<double>?> nativeDescriptor(
    String path,
    int rotation,
    ScanBounds region,
  ) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
    final Object? response = await NativeCardRecognizer.channel
        .invokeMethod<Object?>('artworkDescriptor', <String, Object>{
          'imagePath': path,
          'referenceArtwork': false,
          'rotationDegrees': rotation,
          'queryRegion': <String, double>{
            'x': region.x,
            'y': region.y,
            'width': region.width,
            'height': region.height,
          },
        });
    return parseDescriptor(response);
  }

  static List<double>? parseDescriptor(Object? response) {
    if (response is! Map<Object?, Object?> ||
        response['schema'] != ScanCatalogPackage.descriptorSchema ||
        response['vector'] is! List<Object?>) {
      return null;
    }
    final List<Object?> values = response['vector']! as List<Object?>;
    if (values.length != 256 ||
        values.any(
          (Object? value) =>
              value is! num ||
              !value.toDouble().isFinite ||
              value < 0 ||
              value > 1,
        )) {
      return null;
    }
    return List<double>.unmodifiable(
      values.map((Object? value) => (value! as num).toDouble()),
    );
  }

  @override
  Future<List<LocalVisualHit>> discover(ScanCrop crop) async {
    if (crop.imagePath.isEmpty ||
        !crop.rectified ||
        crop.width < 32 ||
        crop.height < 32 ||
        !_hasCardFrame(crop) ||
        !await File(crop.imagePath).exists()) {
      return const <LocalVisualHit>[];
    }
    final List<List<double>> vectors = <List<double>>[];
    final List<int> rotations = <int>[];
    final List<ScanBounds> regions = <ScanBounds>[];
    final bool basicLand = crop.lines.any(
      (ScanTextLine line) =>
          line.confidence >= .75 &&
          line.bounds.y >= .45 &&
          RegExp(
            r'^basic(?:\s+snow)?\s+land\b',
            caseSensitive: false,
          ).hasMatch(line.text.trim()),
    );
    final List<ScanBounds> profiles = basicLand
        ? <ScanBounds>[extendedArtwork, standardArtwork]
        : <ScanBounds>[standardArtwork, extendedArtwork];
    for (final ScanBounds region in profiles) {
      for (final int rotation in <int>[0, 180]) {
        try {
          final List<double>? vector = await ScanVisualWorkScheduler.compare(
            () => _descriptor(crop.imagePath, rotation, region),
          );
          if (vector != null &&
              vector.length == 256 &&
              vector.every(
                (double value) => value.isFinite && value >= 0 && value <= 1,
              )) {
            vectors.add(vector);
            rotations.add(rotation);
            regions.add(region);
          }
        } catch (_) {
          // An unsupported optional descriptor leaves the original crop available for retry.
        }
      }
    }
    if (vectors.isEmpty) return const <LocalVisualHit>[];
    return catalog.visualSearch(
      vectors,
      maximumDistance: maximumDistance,
      queryRotations: rotations,
      queryRegions: regions,
    );
  }

  static bool _hasCardFrame(ScanCrop crop) {
    final double aspect = crop.width / crop.height;
    if (!aspect.isFinite ||
        aspect < .58 ||
        aspect > .84 ||
        crop.sourceCorners.length != 4 ||
        (crop.warnings.contains('incomplete_card') &&
            crop.warnings.contains('no_text'))) {
      return false;
    }
    double? direction;
    double area = 0;
    for (int index = 0; index < 4; index++) {
      final ScanPoint point = crop.sourceCorners[index];
      final ScanPoint next = crop.sourceCorners[(index + 1) % 4];
      final ScanPoint after = crop.sourceCorners[(index + 2) % 4];
      if (!point.x.isFinite ||
          !point.y.isFinite ||
          point.x < 0 ||
          point.x > 1 ||
          point.y < 0 ||
          point.y > 1) {
        return false;
      }
      final double cross =
          (next.x - point.x) * (after.y - next.y) -
          (next.y - point.y) * (after.x - next.x);
      if (!cross.isFinite ||
          cross.abs() < .000001 ||
          (direction != null && direction * cross <= 0)) {
        return false;
      }
      direction = cross;
      area += point.x * next.y - next.x * point.y;
    }
    return area.abs() >= .0002;
  }
}
