import 'dart:math' as math;

import 'live_scan_detector.dart';
import 'scan_recognition.dart';
import 'scan_resolver.dart';

class ScanFocusTargetMemory {
  final DateTime Function() _clock;
  final List<_FocusTarget> _targets = <_FocusTarget>[];

  ScanFocusTargetMemory({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  List<List<ScanPoint>> get targets {
    _expire(_clock());
    return List<List<ScanPoint>>.unmodifiable(
      _targets.map((_FocusTarget target) => target.corners),
    );
  }

  void update(Iterable<List<ScanPoint>> corners) {
    final DateTime now = _clock();
    _expire(now);
    for (final List<ScanPoint> points in corners) {
      final ScanPoint? center = _center(points);
      if (center == null) continue;
      _FocusTarget? matching;
      double nearest = double.infinity;
      for (final _FocusTarget target in _targets) {
        final double distance = _distance(center, _center(target.corners)!);
        if ((_overlap(points, target.corners) >= .45 || distance < .08) &&
            distance < nearest) {
          matching = target;
          nearest = distance;
        }
      }
      final List<ScanPoint> snapshot = List<ScanPoint>.unmodifiable(points);
      if (matching == null) {
        if (_targets.length == 8) _targets.removeAt(0);
        _targets.add(_FocusTarget(snapshot, now));
      } else {
        _targets.remove(matching);
        _targets.add(_FocusTarget(snapshot, now));
      }
    }
  }

  void clear() => _targets.clear();

  void _expire(DateTime now) => _targets.removeWhere(
    (_FocusTarget target) =>
        now.difference(target.observed) >= const Duration(seconds: 30),
  );
}

class _FocusTarget {
  final List<ScanPoint> corners;
  final DateTime observed;

  const _FocusTarget(this.corners, this.observed);
}

class ScanFocusDiscoveryBudget {
  final DateTime Function() _clock;
  final List<_DiscoveryTarget> _targets = <_DiscoveryTarget>[];

  ScanFocusDiscoveryBudget({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  void observe(Iterable<List<ScanPoint>> regions) {
    final DateTime now = _clock();
    _targets.removeWhere(
      (_DiscoveryTarget target) =>
          now.difference(target.lastSeen) >= const Duration(seconds: 12),
    );
    final Set<_DiscoveryTarget> observed = <_DiscoveryTarget>{};
    for (final List<ScanPoint> corners in regions) {
      final ScanPoint? point = _center(corners);
      if (point == null) continue;
      _DiscoveryTarget? target = _matching(point);
      if (target == null) {
        if (_targets.length >= 16) continue;
        target = _DiscoveryTarget(point, now);
        _targets.add(target);
      }
      if (!observed.add(target)) continue;
      target.lastSeen = now;
      target.observations++;
    }
  }

  bool allows(ScanPoint point) {
    final _DiscoveryTarget? target = _matching(point);
    final DateTime now = _clock();
    return target != null &&
        (target.attempts < 2 || target.recoveryRemaining > 0) &&
        target.observations >= 2 &&
        now.difference(target.firstSeen) >= const Duration(milliseconds: 400) &&
        now.difference(target.lastSeen) < const Duration(seconds: 12);
  }

  bool allowsInitial(ScanPoint point) =>
      _matching(point)?.attempts == 0 && allows(point);

  bool allowsImmediate(ScanPoint point) =>
      allowsInitial(point) ||
      ((_matching(point)?.recoveryRemaining ?? 0) > 0 && allows(point));

  bool grantUnreadRecovery(ScanPoint point) {
    final _DiscoveryTarget? target = _matching(point);
    if (target == null ||
        target.recoveryGranted ||
        target.observations < 2 ||
        _clock().difference(target.firstSeen) <
            const Duration(milliseconds: 400) ||
        _clock().difference(target.lastSeen) >= const Duration(seconds: 12)) {
      return false;
    }
    target.recoveryGranted = true;
    target.recoveryRemaining = 2;
    return true;
  }

  void record(ScanPoint point) {
    final _DiscoveryTarget? target = _matching(point);
    if (target == null) {
      return;
    }
    if (target.attempts < 2) {
      target.attempts++;
    } else if (target.recoveryRemaining > 0) {
      target.recoveryRemaining--;
    }
  }

  void clear() => _targets.clear();

  _DiscoveryTarget? _matching(ScanPoint point) => _targets
      .where((_DiscoveryTarget target) => _distance(target.point, point) < .08)
      .firstOrNull;
}

class _DiscoveryTarget {
  final ScanPoint point;
  final DateTime firstSeen;
  DateTime lastSeen;
  int observations = 0;
  int attempts = 0;
  bool recoveryGranted = false;
  int recoveryRemaining = 0;

  _DiscoveryTarget(this.point, this.firstSeen) : lastSeen = firstSeen;
}

List<ScanPoint> planDetectedScanFocusPoints({
  required Iterable<List<ScanPoint>> regions,
  int maximumPoints = 5,
}) {
  if (maximumPoints < 1 || maximumPoints > 5) {
    throw ArgumentError.value(maximumPoints, 'maximumPoints');
  }
  final List<List<ScanPoint>> admitted = <List<ScanPoint>>[];
  final List<ScanPoint> points = <ScanPoint>[];
  for (final List<ScanPoint> corners in regions) {
    final ScanPoint? center = _center(corners);
    if (center == null) continue;
    if (admitted.any(
      (List<ScanPoint> previous) =>
          _overlap(corners, previous) >= .45 ||
          _distance(center, _center(previous)!) < .06,
    )) {
      continue;
    }
    admitted.add(corners);
    points.add(center);
    if (points.length == maximumPoints) break;
  }
  return List<ScanPoint>.unmodifiable(points);
}

List<ScanPoint> planScanFocusPoints({
  required Iterable<LiveCardDetection> candidates,
  Iterable<List<ScanPoint>> trackedCorners = const <List<ScanPoint>>[],
  int maximumPoints = 5,
}) {
  if (maximumPoints < 1 || maximumPoints > 5) {
    throw ArgumentError.value(maximumPoints, 'maximumPoints');
  }
  final List<ScanPoint> points = <ScanPoint>[const ScanPoint(.5, .5)];
  void admit(ScanPoint? point) {
    if (point == null || points.length >= maximumPoints) return;
    if (points.every(
      (ScanPoint existing) => _distance(existing, point) >= .15,
    )) {
      points.add(point);
    }
  }

  for (final List<ScanPoint> proposals in <List<ScanPoint>>[
    trackedCorners.map(_center).whereType<ScanPoint>().toList(),
    candidates
        .map((LiveCardDetection detection) => _center(detection.corners))
        .whereType<ScanPoint>()
        .toList(),
  ]) {
    while (proposals.isNotEmpty && points.length < maximumPoints) {
      proposals.sort(
        (ScanPoint a, ScanPoint b) =>
            _nearest(b, points).compareTo(_nearest(a, points)),
      );
      admit(proposals.removeAt(0));
    }
  }
  final List<ScanPoint> coverage = <ScanPoint>[
    const ScanPoint(.25, .30),
    const ScanPoint(.75, .30),
    const ScanPoint(.25, .75),
    const ScanPoint(.75, .75),
  ];
  while (coverage.isNotEmpty && points.length < maximumPoints) {
    coverage.sort(
      (ScanPoint a, ScanPoint b) =>
          _nearest(b, points).compareTo(_nearest(a, points)),
    );
    admit(coverage.removeAt(0));
  }
  return List<ScanPoint>.unmodifiable(points);
}

double _distance(ScanPoint a, ScanPoint b) =>
    math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
double _nearest(ScanPoint point, List<ScanPoint> others) =>
    others.map((ScanPoint other) => _distance(point, other)).reduce(math.min);

ScanPoint? _center(List<ScanPoint> corners) {
  if (corners.length != 4 ||
      corners.any(
        (ScanPoint point) =>
            !point.x.isFinite ||
            !point.y.isFinite ||
            point.x < 0 ||
            point.x > 1 ||
            point.y < 0 ||
            point.y > 1,
      )) {
    return null;
  }
  return ScanPoint(
    corners.fold<double>(0, (double sum, ScanPoint point) => sum + point.x) / 4,
    corners.fold<double>(0, (double sum, ScanPoint point) => sum + point.y) / 4,
  );
}

class ScanFocusSelection {
  final int photoIndex;
  final ScanCrop crop;
  final int observations;

  const ScanFocusSelection({
    required this.photoIndex,
    required this.crop,
    required this.observations,
  });
}

class _Observation {
  final int photoIndex;
  final ScanCrop crop;
  final ScanHints hints;

  _Observation(this.photoIndex, this.crop) : hints = ScanHints.fromCrop(crop);

  bool get reliableName =>
      hints.names.isNotEmpty &&
      crop.lines.any(
        (ScanTextLine line) => line.bounds.y < .13 && line.confidence >= .85,
      ) &&
      (hints.typeLine != null ||
          ScanResolver.rulesSearchPhrase(hints.rulesText) != null ||
          (hints.setCode != null && hints.collectorNumber != null));

  double get quality {
    final double confidence = crop.lines.isEmpty
        ? 0
        : crop.lines
                  .map((ScanTextLine line) => line.confidence)
                  .reduce((double a, double b) => a + b) /
              crop.lines.length;
    final double sharpness = crop.sharpness?.isFinite == true
        ? crop.sharpness!.clamp(0, 1).toDouble()
        : 0;
    return (reliableName ? 100 : (hints.names.isNotEmpty ? 20 : 0)) +
        (hints.names.isNotEmpty &&
                RegExp(r'\s+[A-Za-z]$').hasMatch(hints.names.first.trim())
            ? -35
            : 0) +
        (hints.typeLine != null ? 25 : 0) +
        math.min(hints.rulesText.length, 6) * 5 +
        (hints.setCode != null && hints.collectorNumber != null ? 35 : 0) +
        (crop.rectified ? 10 : 0) +
        (crop.warnings.contains('geometry_adjusted') ? -3 : 0) +
        confidence +
        sharpness * 4;
  }
}

class _PhysicalCard {
  final _Observation anchor;
  _Observation best;
  final Set<int> photos;
  final List<_Observation> observations;

  _PhysicalCard(this.anchor)
    : best = anchor,
      photos = <int>{anchor.photoIndex},
      observations = <_Observation>[anchor];
}

List<ScanFocusSelection> mergeScanFocusStack(
  List<ScanRecognition> photos, {
  bool retainUnreadableContours = false,
}) {
  if (photos.isEmpty ||
      photos.length > 5 ||
      photos.any((ScanRecognition photo) => photo.crops.length > 8)) {
    throw ArgumentError.value(photos.length, 'photos');
  }
  final List<_PhysicalCard> cards = <_PhysicalCard>[];
  for (int photoIndex = 0; photoIndex < photos.length; photoIndex++) {
    final List<_Observation> observations =
        photos[photoIndex].crops
            .map((ScanCrop crop) => _Observation(photoIndex, crop))
            .toList()
          ..sort(
            (_Observation a, _Observation b) => b.quality.compareTo(a.quality),
          );
    for (final _Observation observation in observations) {
      _PhysicalCard? matching;
      double overlap = .45;
      for (final _PhysicalCard card in cards) {
        if (card.photos.contains(photoIndex)) continue;
        final double candidate = _overlap(
          card.anchor.crop.sourceCorners,
          observation.crop.sourceCorners,
        );
        if (!_compatible(card.best, observation, candidate)) continue;
        if (candidate >= overlap) {
          overlap = candidate;
          matching = card;
        }
      }
      if (matching == null) {
        cards.add(_PhysicalCard(observation));
      } else {
        matching.photos.add(photoIndex);
        matching.observations.add(observation);
        if (observation.quality > matching.best.quality) {
          matching.best = observation;
        }
      }
    }
  }
  for (final _PhysicalCard card in cards) {
    bool completeTitle(_Observation complete, _Observation truncated) {
      if (truncated.hints.names.isEmpty ||
          ScanResolver.rulesSearchPhrase(complete.hints.rulesText) == null) {
        return false;
      }
      final String prefix = _normalizedName(truncated.hints.names.first);
      return complete.crop.lines.any((ScanTextLine line) {
        final String name = _normalizedName(line.text);
        return line.bounds.y < .13 &&
            line.bounds.x < .6 &&
            line.bounds.width >= .1 &&
            line.bounds.height < .20 &&
            line.textHeight > 0 &&
            line.textHeight < .07 &&
            line.confidence >= .85 &&
            name.startsWith(prefix) &&
            name.length >= prefix.length + 2 &&
            name.length <= prefix.length + 20;
      });
    }

    double quality(_Observation observation) {
      if (observation.hints.names.isEmpty) {
        final bool completeObservedTitle = card.observations.any(
          (_Observation other) => completeTitle(observation, other),
        );
        return observation.quality + (completeObservedTitle ? 150 : 0);
      }
      final String name = _normalizedName(observation.hints.names.first);
      final bool missingPrefix = card.observations.any((_Observation other) {
        if (other.hints.names.isEmpty) return false;
        final String complete = _normalizedName(other.hints.names.first);
        final int missing = complete.length - name.length;
        return missing >= 2 && missing <= 5 && complete.endsWith(name);
      });
      final bool missingSuffix = card.observations.any(
        (_Observation other) => completeTitle(other, observation),
      );
      final bool missingGlyph = card.observations.any(
        (_Observation other) =>
            other.hints.names.isNotEmpty &&
            _normalizedName(other.hints.names.first).length ==
                name.length + 1 &&
            _singleMissingGlyphMerge(
              observation,
              other,
              _overlap(
                observation.crop.sourceCorners,
                other.crop.sourceCorners,
              ),
            ),
      );
      return observation.quality -
          (missingPrefix ? 20 : 0) -
          (missingSuffix || missingGlyph ? 35 : 0);
    }

    card.best = card.observations.reduce(
      (_Observation a, _Observation b) => quality(b) > quality(a) ? b : a,
    );
  }
  cards.sort((_PhysicalCard a, _PhysicalCard b) {
    final ScanPoint? first = _center(a.anchor.crop.sourceCorners);
    final ScanPoint? second = _center(b.anchor.crop.sourceCorners);
    if (first == null || second == null) return 0;
    final int row = first.y.compareTo(second.y);
    return row != 0 ? row : first.x.compareTo(second.x);
  });
  return cards
      .where(
        (_PhysicalCard card) =>
            card.best.hints.names.isNotEmpty ||
            (card.best.hints.typeLine != null &&
                card.best.hints.rulesText.isNotEmpty) ||
            ScanResolver.rulesSearchPhrase(card.best.hints.rulesText) != null ||
            (card.best.hints.setCode != null &&
                card.best.hints.collectorNumber != null) ||
            (retainUnreadableContours && _hasSavedCardContour(card.best.crop)),
      )
      .map((_PhysicalCard card) {
        final ScanCrop crop = card.best.crop;
        return ScanFocusSelection(
          photoIndex: card.best.photoIndex,
          observations: card.photos.length,
          crop: crop,
        );
      })
      .toList();
}

bool _hasSavedCardContour(ScanCrop crop) {
  if (crop.imagePath.trim().isEmpty ||
      !crop.rectified ||
      crop.width < 64 ||
      crop.height < 64 ||
      crop.width / crop.height < .58 ||
      crop.width / crop.height > .84 ||
      _center(crop.sourceCorners) == null ||
      crop.warnings.any(
        (String warning) => !const <String>{
          'no_text',
          'incomplete_card',
          'small_image',
          'low_text_confidence',
          'orientation_ensemble',
          'geometry_adjusted',
        }.contains(warning),
      )) {
    return false;
  }
  double? direction;
  double twiceArea = 0;
  for (int index = 0; index < 4; index++) {
    final ScanPoint point = crop.sourceCorners[index];
    final ScanPoint next = crop.sourceCorners[(index + 1) % 4];
    final ScanPoint after = crop.sourceCorners[(index + 2) % 4];
    final double cross =
        (next.x - point.x) * (after.y - next.y) -
        (next.y - point.y) * (after.x - next.x);
    if (!cross.isFinite ||
        cross.abs() < .000001 ||
        (direction != null && cross * direction <= 0)) {
      return false;
    }
    direction = cross;
    twiceArea += point.x * next.y - next.x * point.y;
  }
  return twiceArea.abs() >= .0002;
}

bool _compatible(_Observation a, _Observation b, double overlap) {
  if (a.hints.setCode != null &&
      b.hints.setCode != null &&
      a.hints.setCode != b.hints.setCode) {
    return false;
  }
  if (a.hints.collectorNumber != null &&
      b.hints.collectorNumber != null &&
      a.hints.collectorNumber != b.hints.collectorNumber) {
    return false;
  }
  if (a.hints.language != null &&
      b.hints.language != null &&
      a.hints.language != b.hints.language) {
    return false;
  }
  if (!a.reliableName || !b.reliableName) return true;
  final Set<String> names = a.hints.names.map(_normalizedName).toSet();
  if (b.hints.names.any(
    (String name) => names.contains(_normalizedName(name)),
  )) {
    return true;
  }
  if (_singleMissingGlyphMerge(a, b, overlap) ||
      _observedNameplateAlternativeMerge(a, b, overlap) ||
      _damagedNameplateMerge(a, b, overlap)) {
    return true;
  }
  if (overlap < .60 ||
      a.hints.typeLine == null ||
      a.hints.typeLine != b.hints.typeLine ||
      !_sameRules(a.hints, b.hints)) {
    return false;
  }
  for (final String title in a.hints.names) {
    final String first = _normalizedName(title);
    for (final String name in b.hints.names) {
      final String second = _normalizedName(name);
      final int longer = math.max(first.length, second.length);
      if (math.min(first.length, second.length) < 12) continue;
      final String firstWord = _tokens(title).first;
      final String secondWord = _tokens(name).first;
      final int wordLimit = math.max(
        2,
        math.max(firstWord.length, secondWord.length) ~/ 2,
      );
      if (_editDistance(firstWord, secondWord) > wordLimit) continue;
      final int limit = math.min(5, (longer * .25).floor());
      if (_editDistance(first, second) <= limit) return true;
    }
  }
  bool clippedRepair(_Observation observation) =>
      (observation.crop.warnings.contains('geometry_adjusted') &&
          _tokens(observation.hints.names.first).first.length <= 3) ||
      (observation.crop.warnings.contains('orientation_ensemble') &&
          RegExp(r'\s+[A-Za-z]$')
              .hasMatch(observation.hints.names.first.trim()));
  if (overlap < .90 ||
      (!clippedRepair(a) && !clippedRepair(b)) ||
      a.hints.typeLine == null ||
      a.hints.typeLine != b.hints.typeLine ||
      !_sameRules(a.hints, b.hints, requireLineAgreement: true)) {
    return false;
  }
  Set<String> anchors(String name) => _tokens(name)
      .where((String word) => word.length >= 8)
      .map(
        (String word) =>
            word.endsWith('s') ? word.substring(0, word.length - 1) : word,
      )
      .toSet();
  final String first = a.hints.names.first;
  final String second = b.hints.names.first;
  if (anchors(first).intersection(anchors(second)).isEmpty) return false;
  final String normalizedFirst = _normalizedName(first);
  final String normalizedSecond = _normalizedName(second);
  return _editDistance(normalizedFirst, normalizedSecond) <=
      math.min(
        9,
        (math.max(normalizedFirst.length, normalizedSecond.length) * .45)
            .floor(),
      );
}

bool _singleMissingGlyphMerge(_Observation a, _Observation b, double overlap) {
  if (overlap < .90 ||
      !a.crop.rectified ||
      !b.crop.rectified ||
      a.hints.names.isEmpty ||
      b.hints.names.isEmpty ||
      a.hints.typeLine == null ||
      a.hints.typeLine != b.hints.typeLine ||
      _distance(
            _center(a.crop.sourceCorners)!,
            _center(b.crop.sourceCorners)!,
          ) >
          .02) {
    return false;
  }
  final String first = _normalizedName(a.hints.names.first);
  final String second = _normalizedName(b.hints.names.first);
  bool observedNameplate(_Observation observation, String name) =>
      observation.crop.lines.any(
        (ScanTextLine line) =>
            line.confidence >= .85 &&
            line.bounds.y < .13 &&
            line.bounds.x < .6 &&
            line.bounds.width >= .1 &&
            line.bounds.height > 0 &&
            line.bounds.height < .08 &&
            line.textHeight > 0 &&
            line.textHeight < .07 &&
            _normalizedName(line.text) == name,
      );
  if (math.min(first.length, second.length) < 8 ||
      (first.length - second.length).abs() != 1 ||
      _tokens(a.hints.names.first).length != 1 ||
      _tokens(b.hints.names.first).length != 1 ||
      _editDistance(first, second) != 1 ||
      !observedNameplate(a, first) ||
      !observedNameplate(b, second)) {
    return false;
  }
  List<ScanTextLine> body(_Observation observation) {
    final List<ScanTextLine> types = observation.crop.lines
        .where(
          (ScanTextLine line) =>
              line.confidence >= .85 &&
              line.bounds.y >= .45 &&
              line.bounds.y < .65 &&
              _tokens(line.text).contains(observation.hints.typeLine),
        )
        .toList();
    if (types.isEmpty) return <ScanTextLine>[];
    final double typeY = types
        .map((ScanTextLine line) => line.bounds.y)
        .reduce(math.min);
    final double quoteY = observation.crop.lines
        .where(
          (ScanTextLine line) =>
              line.confidence >= .80 &&
              line.bounds.y > typeY &&
              RegExp(r'^["“«]').hasMatch(line.text.trim()),
        )
        .map((ScanTextLine line) => line.bounds.y)
        .fold<double>(.86, math.min);
    final List<ScanTextLine> rows =
        observation.crop.lines
            .where(
              (ScanTextLine line) =>
                  line.confidence >= .85 &&
                  line.bounds.y > typeY + .025 &&
                  line.bounds.y < quoteY &&
                  line.bounds.x < .75 &&
                  line.bounds.width >= .20 &&
                  line.bounds.height > 0 &&
                  line.bounds.height < .08 &&
                  line.textHeight > 0 &&
                  line.textHeight < .07 &&
                  _tokens(line.text).length >= 4 &&
                  _normalizedName(line.text).length >= 16 &&
                  !RegExp(
                    r'©|copyright|wizards',
                    caseSensitive: false,
                  ).hasMatch(line.text),
            )
            .toList()
          ..sort(
            (ScanTextLine x, ScanTextLine y) =>
                x.bounds.y.compareTo(y.bounds.y),
          );
    final List<ScanTextLine> independent = <ScanTextLine>[];
    for (final ScanTextLine row in rows) {
      if (independent.every(
        (ScanTextLine previous) =>
            (previous.bounds.y - row.bounds.y).abs() >= .018,
      )) {
        independent.add(row);
      }
    }
    return independent;
  }

  final List<ScanTextLine> firstBody = body(a);
  final List<ScanTextLine> secondBody = body(b);
  final String complete = first.length > second.length ? first : second;
  if (!firstBody.any(
        (ScanTextLine line) => _tokens(line.text).contains(complete),
      ) ||
      !secondBody.any(
        (ScanTextLine line) => _tokens(line.text).contains(complete),
      )) {
    return false;
  }
  Set<String> markers(_Observation observation, List<ScanTextLine> lines) =>
      _tokens(
            <String>[
              ...observation.hints.names,
              ...lines.map((ScanTextLine line) => line.text),
            ].join(' '),
          )
          .where(
            (String word) =>
                const <String>{
                  'white',
                  'blue',
                  'black',
                  'red',
                  'green',
                  'colorless',
                }.contains(word) ||
                RegExp(r'^\d+$').hasMatch(word) ||
                word.startsWith('non'),
          )
          .toSet();
  if (markers(a, firstBody).difference(markers(b, secondBody)).isNotEmpty ||
      markers(b, secondBody).difference(markers(a, firstBody)).isNotEmpty) {
    return false;
  }
  final Set<String> firstRules = firstBody
      .map((ScanTextLine line) => _normalizedName(line.text))
      .toSet();
  final Set<String> secondRules = secondBody
      .map((ScanTextLine line) => _normalizedName(line.text))
      .toSet();
  return firstRules.intersection(secondRules).length >= 2;
}

List<String> _nameplateBody(_Observation observation) {
  final double quoteY = observation.crop.lines
      .where((ScanTextLine line) {
        final double? glyphHeight = line.glyphHeight;
        final bool bodyHeight = line.bounds.height < .08 ||
            (glyphHeight != null &&
                glyphHeight.isFinite &&
                glyphHeight > 0 &&
                glyphHeight < .08 &&
                glyphHeight <= line.bounds.height &&
                line.bounds.height < .14 &&
                line.bounds.x >= 0 &&
                line.bounds.x + line.bounds.width <= 1.02 &&
                line.bounds.y + line.bounds.height <= .96);
        return line.confidence >= .80 &&
            line.bounds.y >= .50 &&
            line.bounds.y < .86 &&
            line.bounds.x < .75 &&
            line.bounds.width >= .20 &&
            bodyHeight &&
            line.text.trim().length <= 240 &&
            RegExp(r'^["“«]').hasMatch(line.text.trim());
      })
      .map((ScanTextLine line) => line.bounds.y)
      .fold<double>(.86, math.min);
  return observation.crop.lines
      .where(
        (ScanTextLine line) =>
            line.confidence >= .85 &&
            line.bounds.y >= .50 &&
            line.bounds.y < quoteY &&
            line.bounds.x < .75 &&
            line.bounds.width >= .20 &&
            line.bounds.height <= .12 &&
            line.textHeight > 0 &&
            line.textHeight < .07 &&
            !RegExp(
              r'^["“«]|©|copyright|wizards',
              caseSensitive: false,
            ).hasMatch(line.text.trim()) &&
            line.text.toLowerCase().trim() != observation.hints.typeLine,
      )
      .map((ScanTextLine line) => line.text)
      .toList();
}

bool _observedNameplateAlternativeMerge(
  _Observation a,
  _Observation b,
  double overlap,
) {
  if (overlap < .70 ||
      _overlap(a.crop.sourceCorners, b.crop.sourceCorners) < .70 ||
      !a.crop.rectified ||
      !b.crop.rectified ||
      a.hints.names.isEmpty ||
      b.hints.names.isEmpty ||
      a.hints.typeLine == null && b.hints.typeLine == null ||
      a.hints.typeLine != null &&
          b.hints.typeLine != null &&
          a.hints.typeLine != b.hints.typeLine ||
      _distance(
            _center(a.crop.sourceCorners)!,
            _center(b.crop.sourceCorners)!,
          ) >
          .035) {
    return false;
  }
  bool readableNameplate(ScanTextLine line) =>
      line.confidence >= .85 &&
      line.bounds.y < .13 &&
      line.bounds.x < .6 &&
      line.bounds.width >= .1 &&
      line.bounds.height > 0 &&
      line.bounds.height < .20 &&
      line.textHeight > 0 &&
      line.textHeight < .07;
  bool observedAlternative(_Observation observation, _Observation other) =>
      observation.crop.lines.any((ScanTextLine line) {
        final String primary = _normalizedName(line.text);
        if (!readableNameplate(line) ||
            !observation.hints.names.any(
              (String name) => _normalizedName(name) == primary,
            )) {
          return false;
        }
        return other.hints.names.any((String name) {
          final String target = _normalizedName(name);
          return math.min(primary.length, target.length) >= 12 &&
              other.crop.lines.any(
                (ScanTextLine observed) =>
                    readableNameplate(observed) &&
                    _normalizedName(observed.text) == target,
              ) &&
              _tokens(line.text).length == _tokens(name).length &&
              _editDistance(primary, target) == 1 &&
              line.alternatives
                  .take(3)
                  .any(
                    (String alternative) =>
                        _normalizedName(alternative) == target,
                  );
        });
      });
  if (!observedAlternative(a, b) && !observedAlternative(b, a)) return false;
  final List<String> firstBody = _nameplateBody(a);
  final List<String> secondBody = _nameplateBody(b);
  Set<String> markers(_Observation observation, List<String> lines) =>
      _tokens(<String>[...observation.hints.names, ...lines].join(' '))
          .where(
            (String word) =>
                const <String>{
                  'white',
                  'blue',
                  'black',
                  'red',
                  'green',
                  'colorless',
                }.contains(word) ||
                RegExp(r'^\d+$').hasMatch(word) ||
                word.startsWith('non'),
          )
          .toSet();
  final Set<String> firstMarkers = markers(a, firstBody);
  final Set<String> secondMarkers = markers(b, secondBody);
  for (final bool Function(String) category in <bool Function(String)>[
    (String word) => RegExp(r'^\d+$').hasMatch(word),
    (String word) => word.startsWith('non'),
    (String word) =>
        !RegExp(r'^\d+$').hasMatch(word) && !word.startsWith('non'),
  ]) {
    final Set<String> firstKnown = firstMarkers.where(category).toSet();
    final Set<String> secondKnown = secondMarkers.where(category).toSet();
    if (firstKnown.isNotEmpty &&
        secondKnown.isNotEmpty &&
        (firstKnown.difference(secondKnown).isNotEmpty ||
            secondKnown.difference(firstKnown).isNotEmpty)) {
      return false;
    }
  }
  final Set<int> matched = <int>{};
  final Set<String> phrases = <String>{};
  for (final String first in firstBody) {
    for (int index = 0; index < secondBody.length; index++) {
      if (matched.contains(index)) continue;
      final String? phrase = _sharedRulesFragment(first, secondBody[index]);
      if (phrase == null || !phrases.add(phrase)) continue;
      matched.add(index);
      if (matched.length == 2) return true;
      break;
    }
  }
  return false;
}

bool _damagedNameplateMerge(_Observation a, _Observation b, double overlap) {
  bool sameObservedType(bool firstSplit, bool secondSplit) {
    final String? first = a.hints.typeLine;
    final String? second = b.hints.typeLine;
    if (first != null && second != null) return first == second;
    if (first == null && second == null) return false;
    final _Observation damagedType = first == null ? a : b;
    final String reference = (first ?? second)!;
    if (!RegExp(r'^[a-z]{6,}$').hasMatch(reference)) return false;
    final List<ScanTextLine> candidates = damagedType.crop.lines.where((
      ScanTextLine line,
    ) {
      final String text = line.text.trim().toLowerCase();
      return line.bounds.y >= .45 &&
          line.bounds.y < .65 &&
          line.bounds.x < .2 &&
          line.bounds.width >= .15 &&
          (RegExp(r'^[a-z]{6,}$').hasMatch(text) ||
              ScanHints.observedCardType(text) != null);
    }).toList();
    if (candidates.isEmpty) return first == null ? firstSplit : secondSplit;
    return candidates.any((ScanTextLine line) {
      final String text = line.text.trim().toLowerCase();
      return line.confidence >= .85 &&
          line.bounds.height <= .12 &&
          line.textHeight > 0 &&
          line.textHeight < .07 &&
          RegExp(r'^[a-z]{6,}$').hasMatch(text) &&
          text.startsWith(reference.substring(0, 3)) &&
          _editDistance(text, reference) == 1;
    });
  }

  if (overlap < .70 ||
      !a.crop.rectified ||
      !b.crop.rectified ||
      _distance(
            _center(a.crop.sourceCorners)!,
            _center(b.crop.sourceCorners)!,
          ) >
          .035) {
    return false;
  }
  bool damaged(_Observation observation) {
    final String title = observation.hints.names.first;
    final List<String> words = RegExp(r'[a-z]+')
        .allMatches(title.toLowerCase())
        .map((RegExpMatch match) => match.group(0)!)
        .toList();
    return words.length >= 3 &&
        words.first.length <= 3 &&
        words.last.length <= 2 &&
        observation.crop.lines.any(
          (ScanTextLine line) =>
              line.bounds.y < .13 &&
              line.bounds.x >= .15 &&
              line.bounds.width <= .55 &&
              line.confidence >= .85 &&
              line.text.trim() == title,
        );
  }

  bool truncatedSuffix(_Observation observation, _Observation reference) {
    final List<String> shortened = RegExp(r'[a-z]+')
        .allMatches(observation.hints.names.first.toLowerCase())
        .map((RegExpMatch match) => match.group(0)!)
        .toList();
    final List<String> complete = RegExp(r'[a-z]+')
        .allMatches(reference.hints.names.first.toLowerCase())
        .map((RegExpMatch match) => match.group(0)!)
        .toList();
    final int missing = complete.length - shortened.length;
    if (shortened.length < 3 ||
        missing < 1 ||
        missing > 2 ||
        _editDistance(shortened.first, complete.first) > 2) {
      return false;
    }
    final String stem = complete.take(shortened.length).join();
    if (_editDistance(shortened.join(), stem) >
        math.min(4, (stem.length * .20).ceil())) {
      return false;
    }
    return observation.crop.lines.any(
      (ScanTextLine line) =>
          line.bounds.y < .13 &&
          line.bounds.x >= .10 &&
          line.bounds.width <= .65 &&
          line.confidence >= .85 &&
          line.text.trim() == observation.hints.names.first,
    );
  }

  bool splitNameplate(_Observation observation, _Observation reference) {
    final List<ScanTextLine> fragments =
        observation.crop.lines
            .where(
              (ScanTextLine line) =>
                  line.bounds.y < .13 &&
                  line.bounds.x < .6 &&
                  line.bounds.width >= .10 &&
                  line.bounds.height <= .13 &&
                  line.textHeight > 0 &&
                  line.textHeight < .07 &&
                  line.confidence >= .5 &&
                  RegExp(r'[A-Za-z]{3}').hasMatch(line.text),
            )
            .toList()
          ..sort(
            (ScanTextLine a, ScanTextLine b) =>
                a.bounds.x.compareTo(b.bounds.x),
          );
    if (fragments.length < 2 ||
        fragments.length > 3 ||
        !fragments.any((ScanTextLine line) => line.confidence >= .85) ||
        fragments.any(
          (ScanTextLine line) =>
              (line.bounds.y - fragments.first.bounds.y).abs() > .06,
        )) {
      return false;
    }
    final String assembled = _normalizedName(
      fragments.map((ScanTextLine line) => line.text).join(' '),
    );
    final String inferred = _normalizedName(observation.hints.names.first);
    if (assembled != inferred) return false;
    final ScanTextLine lastFragment = fragments.last;
    final List<ScanTextLine> suffixes = observation.crop.lines.where((
      ScanTextLine line,
    ) {
      final double gap =
          line.bounds.x - lastFragment.bounds.x - lastFragment.bounds.width;
      return line.confidence >= .5 &&
          line.bounds.x >= .6 &&
          line.bounds.x + line.bounds.width <= .85 &&
          gap >= -.02 &&
          gap <= .06 &&
          (line.bounds.y - lastFragment.bounds.y).abs() <= .035 &&
          line.bounds.width >= .04 &&
          line.bounds.width < .10 &&
          line.bounds.height > 0 &&
          line.bounds.height <= .13 &&
          line.textHeight > 0 &&
          line.textHeight < .07 &&
          RegExp(r'^[A-Za-z]{2,4}$').hasMatch(line.text.trim());
    }).toList();
    bool matchesTitle(String name) {
      final String referenceName = _normalizedName(name);
      if (suffixes.isEmpty) {
        return _editDistance(assembled, referenceName) <= 2;
      }
      if (suffixes.length != 1) return false;
      final String observedSuffix = _normalizedName(suffixes.single.text);
      final String incompleteWord = _tokens(lastFragment.text).last;
      return incompleteWord.length <= 2 &&
          '$incompleteWord$observedSuffix' == _tokens(name).last &&
          _editDistance('$assembled$observedSuffix', referenceName) <= 2;
    }

    return reference.hints.names.any(
      (String name) =>
          math.min(assembled.length, _normalizedName(name).length) >= 12 &&
          matchesTitle(name) &&
          _editDistance(
                _tokens(observation.hints.names.first).first,
                _tokens(name).first,
              ) <=
              2,
    );
  }

  final bool firstSplit = splitNameplate(a, b);
  final bool secondSplit = splitNameplate(b, a);
  if (!sameObservedType(firstSplit, secondSplit)) return false;
  final bool firstDamaged = damaged(a) || truncatedSuffix(a, b) || firstSplit;
  final bool secondDamaged = damaged(b) || truncatedSuffix(b, a) || secondSplit;
  if (firstDamaged == secondDamaged) return false;
  final List<String> firstBody = _nameplateBody(a);
  final List<String> secondBody = _nameplateBody(b);
  Set<String> markers(List<String> lines, List<String> names) =>
      _tokens(<String>[...lines, ...names].join(' '))
          .where(
            (String word) =>
                const <String>{
                  'white',
                  'blue',
                  'black',
                  'red',
                  'green',
                  'colorless',
                }.contains(word) ||
                RegExp(r'^\d+$').hasMatch(word) ||
                word.startsWith('non'),
          )
          .toSet();
  final Set<String> firstMarkers = markers(firstBody, a.hints.names);
  final Set<String> secondMarkers = markers(secondBody, b.hints.names);
  for (final bool Function(String) category in <bool Function(String)>[
    (String word) => RegExp(r'^\d+$').hasMatch(word),
    (String word) => word.startsWith('non'),
    (String word) =>
        !RegExp(r'^\d+$').hasMatch(word) && !word.startsWith('non'),
  ]) {
    final Set<String> firstKnown = firstMarkers.where(category).toSet();
    final Set<String> secondKnown = secondMarkers.where(category).toSet();
    if (firstKnown.isNotEmpty &&
        secondKnown.isNotEmpty &&
        (firstKnown.difference(secondKnown).isNotEmpty ||
            secondKnown.difference(firstKnown).isNotEmpty)) {
      return false;
    }
  }
  final Set<int> matched = <int>{};
  final Set<String> phrases = <String>{};
  for (final String first in firstBody) {
    for (int index = 0; index < secondBody.length; index++) {
      if (matched.contains(index)) continue;
      final String? phrase = _sharedRulesFragment(first, secondBody[index]);
      if (phrase == null || !phrases.add(phrase)) continue;
      matched.add(index);
      if (matched.length == 2) return true;
      break;
    }
  }
  return false;
}

String? _sharedRulesFragment(String first, String second) {
  List<String> words(String text) =>
      RegExp(r'[a-z0-9]+')
          .allMatches(text.toLowerCase())
          .map((RegExpMatch match) => match.group(0)!)
          .toList();
  final List<String> a = words(first);
  final List<String> b = words(second);
  const Set<String> effects = <String>{
    'prevent',
    'damage',
    'destroy',
    'exile',
    'sacrifice',
    'discard',
    'counter',
    'create',
    'draw',
    'return',
    'search',
  };
  for (int startA = 0; startA < a.length; startA++) {
    for (int startB = 0; startB < b.length; startB++) {
      final List<String> common = <String>[];
      for (
        int offset = 0;
        startA + offset < a.length && startB + offset < b.length;
        offset++
      ) {
        final String x = a[startA + offset];
        final String y = b[startB + offset];
        if (x == y) {
          common.add(x);
        } else if ((startA + offset == a.length - 1 &&
                x.length >= 2 &&
                y.startsWith(x)) ||
            (startB + offset == b.length - 1 &&
                y.length >= 2 &&
                x.startsWith(y))) {
          common.add(x.length < y.length ? x : y);
          break;
        } else {
          break;
        }
      }
      if (common.length >= 4 &&
          common.join().length >= 12 &&
          common.any(effects.contains)) {
        return common.join(' ');
      }
    }
  }
  return null;
}

String _normalizedName(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

Set<String> _tokens(String text) => RegExp(r'[\p{L}\p{N}]+', unicode: true)
    .allMatches(text.toLowerCase())
    .map((RegExpMatch match) => match.group(0)!)
    .toSet();

bool _sameRules(ScanHints a, ScanHints b, {bool requireLineAgreement = false}) {
  if (a.typeLine != null && b.typeLine != null && a.typeLine != b.typeLine) {
    return false;
  }
  if (ScanResolver.rulesSearchPhrase(a.rulesText) == null ||
      ScanResolver.rulesSearchPhrase(b.rulesText) == null) {
    return false;
  }
  final Set<String> first = _tokens(a.rulesText.join(' '));
  final Set<String> second = _tokens(b.rulesText.join(' '));
  Set<String> markers(ScanHints hints, Set<String> body) =>
      <String>{...body, ..._tokens(hints.names.join(' '))}
          .where(
            (String word) =>
                const <String>{
                  'white',
                  'blue',
                  'black',
                  'red',
                  'green',
                  'colorless',
                }.contains(word) ||
                RegExp(r'^\d+$').hasMatch(word) ||
                word.startsWith('non'),
          )
          .toSet();
  final Set<String> firstMarkers = markers(a, first);
  final Set<String> secondMarkers = markers(b, second);
  for (final bool Function(String) category in <bool Function(String)>[
    (String word) => RegExp(r'^\d+$').hasMatch(word),
    (String word) => word.startsWith('non'),
    (String word) =>
        !RegExp(r'^\d+$').hasMatch(word) && !word.startsWith('non'),
  ]) {
    final Set<String> firstKnown = firstMarkers.where(category).toSet();
    final Set<String> secondKnown = secondMarkers.where(category).toSet();
    if (firstKnown.isNotEmpty &&
        secondKnown.isNotEmpty &&
        (firstKnown.difference(secondKnown).isNotEmpty ||
            secondKnown.difference(firstKnown).isNotEmpty)) {
      return false;
    }
  }
  const Set<String> generic = <String>{
    'a',
    'an',
    'the',
    'you',
    'your',
    'to',
    'of',
    'from',
    'one',
    'all',
    'each',
    'if',
    'or',
    'and',
    'in',
    'is',
    'it',
    'this',
    'that',
    'may',
    'more',
    'than',
    'any',
    'at',
    'on',
    'as',
  };
  final Set<String> firstWords = first.difference(generic);
  final Set<String> secondWords = second.difference(generic);
  final int shared = firstWords.intersection(secondWords).length;
  if (!requireLineAgreement &&
      shared >= 4 &&
      shared / math.min(firstWords.length, secondWords.length) >= .80) {
    return true;
  }
  final Set<String> matchingWords = <String>{};
  final Set<String> matchedPhrases = <String>{};
  final Set<int> matchingSecondLines = <int>{};
  int matchingLines = 0;
  for (final String firstLine in a.rulesText) {
    if (_normalizedName(firstLine).length < 24) continue;
    final Set<String> firstLineWords = _tokens(firstLine).difference(generic);
    if (firstLineWords.length < 2) continue;
    for (int index = 0; index < b.rulesText.length; index++) {
      if (matchingSecondLines.contains(index)) continue;
      final String secondLine = b.rulesText[index];
      if (_normalizedName(secondLine).length < 24) continue;
      final Set<String> secondLineWords = _tokens(secondLine)
          .difference(generic);
      final Set<String> common = firstLineWords.intersection(secondLineWords);
      if (common.length < 2 ||
          common.length /
                  math.max(firstLineWords.length, secondLineWords.length) <
              .80) {
        continue;
      }
      final List<String> phraseWords = common.toList()..sort();
      if (!matchedPhrases.add(phraseWords.join(' '))) continue;
      matchingSecondLines.add(index);
      matchingWords.addAll(common);
      matchingLines++;
      break;
    }
  }
  return matchingLines >= 2 && matchingWords.length >= 5;
}

int _editDistance(String a, String b) {
  List<int> previous = List<int>.generate(b.length + 1, (int index) => index);
  for (int row = 0; row < a.length; row++) {
    final List<int> current = <int>[row + 1];
    for (int column = 0; column < b.length; column++) {
      current.add(
        math.min(
          math.min(current[column] + 1, previous[column + 1] + 1),
          previous[column] +
              (a.codeUnitAt(row) == b.codeUnitAt(column) ? 0 : 1),
        ),
      );
    }
    previous = current;
  }
  return previous.last;
}

double _overlap(List<ScanPoint> a, List<ScanPoint> b) {
  if (_center(a) == null || _center(b) == null) return 0;
  final double ax = a.map((ScanPoint p) => p.x).reduce(math.min);
  final double ay = a.map((ScanPoint p) => p.y).reduce(math.min);
  final double ar = a.map((ScanPoint p) => p.x).reduce(math.max);
  final double ab = a.map((ScanPoint p) => p.y).reduce(math.max);
  final double bx = b.map((ScanPoint p) => p.x).reduce(math.min);
  final double by = b.map((ScanPoint p) => p.y).reduce(math.min);
  final double br = b.map((ScanPoint p) => p.x).reduce(math.max);
  final double bb = b.map((ScanPoint p) => p.y).reduce(math.max);
  final double intersection =
      math.max(0, math.min(ar, br) - math.max(ax, bx)) *
      math.max(0, math.min(ab, bb) - math.max(ay, by));
  final double union =
      (ar - ax) * (ab - ay) + (br - bx) * (bb - by) - intersection;
  return union > 0 ? intersection / union : 0;
}
