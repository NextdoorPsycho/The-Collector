import 'dart:async';
import 'dart:convert';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:scryfall_api/scryfall_api.dart';

import 'scan_recognition.dart';
import 'scan_artwork_matcher.dart';
import 'scan_symbol_matcher.dart';
import 'scryfall_request_scheduler.dart';
import 'scan_name_index.dart';
import 'scan_local_catalog.dart';
import 'scan_visual_index.dart';

enum ScanResolutionStatus { exactPrinting, needsReview, noMatch }

bool _hasNonLatinName(String name) => RegExp(
  r'[\u0370-\u052f\u0590-\u06ff\u0900-\u097f\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af\uff65-\uff9f]',
).hasMatch(name);

String? _copyrightFooterCollectorNumber(ScanTextLine line) {
  if (!ScanResolver._printingFooterLine(line) ||
      line.bounds.y < .88 ||
      line.bounds.height > .045) {
    return null;
  }
  final RegExpMatch? match = RegExp(
    r'^(?:©|copyright)\s*(19\d{2}|20\d{2})(?:\s*[-–−]\s*((?:19|20)(?:\d{2}|\d[OQIl]|[OQIl]\d)))?\s*\.?\s*Wizards\s+of\s+the\s+Coast,?\s*(?:Inc\.?)?\s+(\d{1,3})\s*/\s*(\d{3})$',
    caseSensitive: false,
  ).firstMatch(line.text.trim());
  if (match == null) return null;
  final int firstYear = int.parse(match.group(1)!);
  final int? lastYear = int.tryParse(match.group(2) ?? match.group(1)!);
  final int number = int.parse(match.group(3)!);
  final int total = int.parse(match.group(4)!);
  return (lastYear == null || lastYear >= firstYear) &&
          number > 0 &&
          total >= 100 &&
          number <= total
      ? match.group(3)
      : null;
}

bool hasConflictingScanTitle(ScanCrop crop) =>
    crop.warnings.contains('lighting_title_conflict');

bool _hasReviewableBasicArtwork(ScanCrop crop) {
  if (hasVerifiedSavedBasicLandCapturePresence(crop)) return true;
  if (!crop.warnings.contains('capture_ownership_uncertain')) return false;
  return hasVerifiedSavedBasicLandCapturePresence(
    ScanCrop(
      imagePath: crop.imagePath,
      width: crop.width,
      height: crop.height,
      rectified: crop.rectified,
      sourceCorners: crop.sourceCorners,
      lines: crop.lines,
      sharpness: crop.sharpness,
      warnings: crop.warnings
          .where((String warning) => warning != 'capture_ownership_uncertain')
          .toList(),
    ),
  );
}

enum ScanEvidence {
  footerMatch,
  nameMatch,
  nameMismatch,
  fuzzyName,
  rulesTextMatch,
  rulesKeywordMatch,
  rulesTextMismatch,
  collectorNumberMatch,
  collectorNumberSimilar,
  printingMismatch,
  languageMatch,
  languageMismatch,
  typeLineMatch,
  artworkCompared,
  symbolCompared,
  illustratorMatch,
  copyrightYearMatch,
  cloudSuggestion,
}

double _boundsIntersectionArea(ScanBounds a, ScanBounds b) {
  final double left = a.x > b.x ? a.x : b.x;
  final double top = a.y > b.y ? a.y : b.y;
  final double right = a.x + a.width < b.x + b.width
      ? a.x + a.width
      : b.x + b.width;
  final double bottom = a.y + a.height < b.y + b.height
      ? a.y + a.height
      : b.y + b.height;
  return right > left && bottom > top ? (right - left) * (bottom - top) : 0;
}

@immutable
class ScanHints {
  final List<String> names;
  final String? setCode;
  final String? collectorNumber;
  final String? language;
  final List<String> rulesText;
  final List<String> postQuoteText;
  final String? typeLine;
  final bool hasConflictingFooter;

  const ScanHints({
    required this.names,
    this.setCode,
    this.collectorNumber,
    this.language,
    this.rulesText = const <String>[],
    this.postQuoteText = const <String>[],
    this.typeLine,
    this.hasConflictingFooter = false,
  });

  factory ScanHints.fromCrop(
    ScanCrop crop, {
    double minimumFooterConfidence = .75,
    double minimumConfidence = 0,
  }) {
    final List<ScanTextLine> lines = minimumConfidence == 0
        ? crop.lines
        : crop.lines
              .where(
                (ScanTextLine line) => line.confidence >= minimumConfidence,
              )
              .toList();
    final bool partial =
        !crop.rectified && crop.warnings.contains('partial_card');
    bool titleGeometry(ScanTextLine line) =>
        (!crop.warnings.contains('incomplete_card') || partial) &&
        line.bounds.y < 0.13 &&
        line.bounds.x < 0.6 &&
        line.bounds.width >= 0.1 &&
        line.bounds.height < .20 &&
        line.textHeight > 0 &&
        line.textHeight < 0.07 &&
        !line.text.startsWith('"') &&
        !line.text.startsWith('“') &&
        line.text.trim().length >= 3;
    final List<ScanTextLine> titles =
        lines
            .where(
              (ScanTextLine line) =>
                  titleGeometry(line) &&
                  line.confidence >= (partial ? .85 : .35),
            )
            .toList()
          ..sort(
            (ScanTextLine a, ScanTextLine b) =>
                a.bounds.y.compareTo(b.bounds.y),
          );
    final List<String> nameCandidates = <String>[];
    if (titles.isNotEmpty) {
      final List<ScanTextLine> firstRow =
          lines
              .where(
                (ScanTextLine line) =>
                    titleGeometry(line) &&
                    line.confidence >= (partial ? .85 : .30) &&
                    (line.bounds.y - titles.first.bounds.y).abs() < .035,
              )
              .toList()
            ..sort(
              (ScanTextLine a, ScanTextLine b) =>
                  a.bounds.x.compareTo(b.bounds.x),
            );
      bool adjacent = firstRow.length > 1;
      for (int index = 1; index < firstRow.length; index++) {
        final double gap =
            firstRow[index].bounds.x -
            firstRow[index - 1].bounds.x -
            firstRow[index - 1].bounds.width;
        adjacent = adjacent && gap >= -.02 && gap <= .06;
      }
      final bool weakFragment = firstRow.any(
        (ScanTextLine line) => line.confidence < .35,
      );
      if (adjacent &&
          (!weakFragment ||
              firstRow.any((ScanTextLine line) => line.confidence >= .85))) {
        nameCandidates.add(
          firstRow.map((ScanTextLine line) => line.text.trim()).join(' '),
        );
      }
    }
    nameCandidates.addAll(titles.map((ScanTextLine line) => line.text.trim()));
    final List<String> names = nameCandidates.toSet().take(3).toList();
    String? setCode;
    String? language;
    String? collectorNumber;
    final RegExp setAndLanguage = RegExp(
      r'\b([A-Z0-9]{3,5})(?:\s*[•·∙]\s*|\s+)('
      r'EN|ES|FR|DE|IT|PT|JA|KO|RU|ZHS|ZHT|HE|LA|GRC|AR|SA|PH|QYA)\b',
      caseSensitive: false,
    );
    final RegExp number = RegExp(
      r'^(?:[CMRULST]\s+)?((?:[A-Za-z]{1,3}-?)?\d{1,5}[a-z★†]*)(?:\s*/\s*\d{1,5})?(?:\s+[CMRULST])?$',
      caseSensitive: false,
    );
    final List<(ScanTextLine, String)> numberObservations =
        <(ScanTextLine, String)>[];
    final List<ScanTextLine> setObservations = <ScanTextLine>[];
    final Set<(String, String)> setLanguages = <(String, String)>{};
    bool footerObservation(ScanTextLine line) =>
        line.confidence >= (partial ? .85 : minimumFooterConfidence) &&
        line.confidence <= 1 &&
        (!partial ||
            (line.bounds.y >= .80 &&
                line.bounds.x >= 0 &&
                line.bounds.x + line.bounds.width <= 1.02 &&
                line.bounds.width > 0 &&
                line.bounds.width <= .80 &&
                line.bounds.height > 0 &&
                line.bounds.height <= .06 &&
                line.bounds.y + line.bounds.height <= 1.02));
    RegExpMatch? footerSet(String text) {
      final RegExpMatch? match = setAndLanguage.firstMatch(text);
      if (!partial || match == null) {
        return match;
      }
      final String prefix = text.substring(0, match.start).trim();
      final String suffix = text.substring(match.end).trim();
      return (prefix.isEmpty && (suffix.isEmpty || number.hasMatch(suffix))) ||
              (suffix.isEmpty && number.hasMatch(prefix))
          ? match
          : null;
    }

    for (final ScanTextLine line in lines) {
      if (line.bounds.y < 0.70 || !footerObservation(line)) {
        continue;
      }
      final String text = line.text.trim();
      if (RegExp(r'©|copyright|wizards', caseSensitive: false).hasMatch(text)) {
        final String? footerNumber = _copyrightFooterCollectorNumber(line);
        if (footerNumber != null) numberObservations.add((line, footerNumber));
        continue;
      }
      final RegExpMatch? setMatch = footerSet(text);
      if (setMatch != null) {
        for (final RegExpMatch observed
            in partial
                ? <RegExpMatch>[setMatch]
                : setAndLanguage.allMatches(text)) {
          setLanguages.add((
            observed.group(1)!.toLowerCase(),
            observed.group(2)!.toLowerCase(),
          ));
        }
        setCode ??= setMatch.group(1)!.toLowerCase();
        language ??= setMatch.group(2)!.toLowerCase();
        setObservations.add(line);
      }
      final String numberText = setMatch == null
          ? text
          : text.substring(0, setMatch.start).trim().isNotEmpty
          ? text.substring(0, setMatch.start).trim()
          : text.substring(setMatch.end).trim();
      final RegExpMatch? numberMatch = number.firstMatch(numberText);
      if (numberMatch != null) {
        numberObservations.add((line, numberMatch.group(1)!));
      }
    }
    {
      final List<ScanTextLine> footer =
          lines
              .where(
                (ScanTextLine line) =>
                    line.bounds.y > .70 &&
                    footerObservation(line) &&
                    !RegExp(
                      r'©|copyright|wizards',
                      caseSensitive: false,
                    ).hasMatch(line.text),
              )
              .toList()
            ..sort(
              (ScanTextLine a, ScanTextLine b) =>
                  a.bounds.y.compareTo(b.bounds.y),
            );
      for (int index = 0; index + 1 < footer.length; index++) {
        final ScanTextLine a = footer[index];
        final ScanTextLine b = footer[index + 1];
        if ((a.bounds.y - b.bounds.y).abs() > .06 ||
            (a.bounds.x - b.bounds.x).abs() > .2 ||
            !RegExp(
              r'^[A-Z0-9]{3,5}$',
              caseSensitive: false,
            ).hasMatch(a.text.trim()) ||
            !RegExp(r'[A-Z]', caseSensitive: false).hasMatch(a.text)) {
          continue;
        }
        final RegExpMatch? joined = footerSet(
          '${a.text.trim()} ${b.text.trim()}',
        );
        if (joined != null) {
          setLanguages.add((
            joined.group(1)!.toLowerCase(),
            joined.group(2)!.toLowerCase(),
          ));
          setCode ??= joined.group(1)!.toLowerCase();
          language ??= joined.group(2)!.toLowerCase();
          setObservations.addAll(<ScanTextLine>[a, b]);
        }
      }
    }
    if (setLanguages.length > 1) {
      setCode = null;
      language = null;
    }
    bool besideSet(ScanTextLine line) => setObservations.any(
      (ScanTextLine setLine) =>
          (line.bounds.y - setLine.bounds.y).abs() <= .08 &&
          ((line.bounds.x - setLine.bounds.x).abs() <= .20 ||
              (line.bounds.y - setLine.bounds.y).abs() <= .035),
    );
    bool historicalFraction(ScanTextLine line) {
      final RegExpMatch? fraction = RegExp(r'^(\d{1,3})\s*/\s*(\d{3})$')
          .firstMatch(line.text.trim());
      if (fraction == null) return false;
      final int identifier = int.parse(fraction.group(1)!);
      final int total = int.parse(fraction.group(2)!);
      return identifier > 0 && total >= 100 && identifier <= total;
    }

    bool rightFooter(ScanTextLine line, String identifier) =>
        line.confidence >= .85 &&
        line.bounds.y >= .88 &&
        line.bounds.y + line.bounds.height <= 1.02 &&
        line.bounds.x + line.bounds.width <= 1.02 &&
        line.bounds.width > 0 &&
        line.bounds.width <= .35 &&
        line.bounds.height > 0 &&
        line.bounds.height <= .045 &&
        (historicalFraction(line) ||
            _copyrightFooterCollectorNumber(line) != null ||
            (besideSet(line) &&
                // Short slash pairs at the lower right are power/toughness.
                (!line.text.contains('/') ||
                    RegExp(r'\d{3,5}').hasMatch(identifier))));
    final List<(ScanTextLine, String)> eligibleNumbers = numberObservations
        .where(
          ((ScanTextLine, String) observation) =>
              !setLanguages.any(
                ((String, String) pair) =>
                    observation.$1.text.trim().toLowerCase() == pair.$1,
              ) &&
              observation.$1.bounds.y >= .80 &&
              observation.$1.bounds.y + observation.$1.bounds.height <= 1.02 &&
              observation.$1.bounds.height > 0 &&
              observation.$1.bounds.height <= .06 &&
              (observation.$2.length > 1 ||
                  besideSet(observation.$1) ||
                  RegExp(
                    r'\b[CMRULST]\b',
                    caseSensitive: false,
                  ).hasMatch(observation.$1.text)) &&
              (observation.$1.bounds.x < .65 ||
                  rightFooter(observation.$1, observation.$2)),
        )
        .toList();
    double numberPriority(ScanTextLine line) =>
        (besideSet(line) ? 2 : 0) +
        (line.bounds.y >= .80 ? 1 : 0) +
        line.confidence * .1;
    eligibleNumbers.sort(
      ((ScanTextLine, String) a, (ScanTextLine, String) b) =>
          numberPriority(b.$1).compareTo(numberPriority(a.$1)),
    );
    final Set<String> conflictingNumbers = eligibleNumbers
        .where(
          ((ScanTextLine, String) observation) =>
              observation.$1.confidence >=
                  (partial ? .85 : minimumFooterConfidence) &&
              observation.$1.bounds.y >= .80,
        )
        .map(
          ((ScanTextLine, String) observation) =>
              ScanResolver._number(observation.$2),
        )
        .toSet();
    collectorNumber = conflictingNumbers.length > 1
        ? null
        : eligibleNumbers.firstOrNull?.$2;
    final RegExp openingQuote = RegExp(r'^["“«]');
    bool earlyType(ScanTextLine line) =>
        line.confidence >= .85 &&
        line.text.trim().split(RegExp(r'\s+')).length <= 8 &&
        observedCardType(line.text) != null;
    final List<ScanTextLine> body =
        crop.lines
            .where(
              (ScanTextLine line) =>
                  (line.confidence >= minimumConfidence ||
                      _isQuoteBoundary(line, partial: partial)) &&
                  line.bounds.y >=
                      (partial ? .28 : (earlyType(line) ? .45 : .50)) &&
                  line.bounds.y < (earlyType(line) ? .90 : .86) &&
                  line.bounds.x < .75 &&
                  line.bounds.width >= (earlyType(line) ? .08 : .20) &&
                  _bodyHeight(line, partial: partial) &&
                  line.confidence >= .80 &&
                  !RegExp(
                    r'©|copyright|wizards',
                    caseSensitive: false,
                  ).hasMatch(line.text.trim()) &&
                  ScanResolver._illustratorCredit(line) == null,
            )
            .take(24)
            .toList()
          ..sort(
            (ScanTextLine a, ScanTextLine b) =>
                a.bounds.y.compareTo(b.bounds.y),
          );
    String? typeLine;
    final List<String> rulesText = <String>[];
    final List<String> postQuoteText = <String>[];
    bool afterQuote = false;
    bool typeObservation(ScanTextLine line) =>
        (line.bounds.y < .65 ||
            (line.bounds.y < .90 &&
                observedCardType(line.text) == 'land' &&
                RegExp(
                  r'^(?:basic|snow)\b',
                  caseSensitive: false,
                ).hasMatch(line.text.trim()))) &&
        line.text.trim().split(RegExp(r'\s+')).length <= 8 &&
        observedCardType(line.text) != null;
    final List<ScanTextLine> recognizedTypes = body
        .where(
          (ScanTextLine line) =>
              line.confidence >= .85 && typeObservation(line),
        )
        .toList();
    for (final ScanTextLine line in body) {
      final String text = line.text.trim();
      if (text.length > 240) {
        continue;
      }
      if (openingQuote.hasMatch(text)) {
        if (partial && typeLine != null) break;
        afterQuote = true;
        continue;
      }
      if (afterQuote) {
        if (text.length >= 4) postQuoteText.add(text);
        continue;
      }
      final String? type = observedCardType(text);
      if (type != null && typeObservation(line)) {
        typeLine ??= type;
      } else if (text.length >= 4 && (!partial || typeLine != null)) {
        final bool duplicateType = recognizedTypes.any((ScanTextLine type) {
          final double area = line.bounds.width * line.bounds.height;
          final double typeArea = type.bounds.width * type.bounds.height;
          final double largerArea = area > typeArea ? area : typeArea;
          return largerArea > 0 &&
              _boundsIntersectionArea(line.bounds, type.bounds) / largerArea >=
                  .80;
        });
        if (duplicateType) {
          continue;
        }
        rulesText.add(text);
      }
    }
    return ScanHints(
      names: partial && (typeLine == null || rulesText.isEmpty)
          ? const <String>[]
          : List<String>.unmodifiable(names),
      setCode: setCode,
      collectorNumber: collectorNumber,
      language: language,
      rulesText: List<String>.unmodifiable(rulesText.take(12)),
      postQuoteText: List<String>.unmodifiable(postQuoteText.take(12)),
      typeLine: typeLine,
      hasConflictingFooter:
          setLanguages.length > 1 || conflictingNumbers.length > 1,
    );
  }

  static String? observedBodySelfReference(ScanCrop crop) =>
      _observedBodySelfReference(crop, titleless: false);

  static bool _bodyHeight(ScanTextLine line, {required bool partial}) {
    if (line.bounds.height <
        (partial ? (observedCardType(line.text) != null ? .11 : .20) : .08)) {
      return true;
    }
    final double? glyphHeight = line.glyphHeight;
    return !partial &&
        glyphHeight != null &&
        glyphHeight.isFinite &&
        glyphHeight > 0 &&
        glyphHeight < .08 &&
        glyphHeight <= line.bounds.height &&
        line.bounds.height < .14 &&
        line.bounds.x >= 0 &&
        line.bounds.x + line.bounds.width <= 1.02 &&
        line.bounds.y + line.bounds.height <= .96;
  }

  static bool _isQuoteBoundary(
    ScanTextLine line, {
    bool partial = false,
  }) =>
      line.confidence >= .80 &&
      line.bounds.y >= (partial ? .28 : .50) &&
      line.bounds.y < .86 &&
      line.bounds.x < .75 &&
      line.bounds.width >= .20 &&
      _bodyHeight(line, partial: partial) &&
      line.text.trim().length <= 240 &&
      RegExp(r'^["“«]').hasMatch(line.text.trim());

  static String? observedSavedBodySelfReference(ScanCrop crop) =>
      _observedBodySelfReference(crop, titleless: true);

  static String? observedLiveBodySelfReference(ScanCrop crop) =>
      _observedBodySelfReference(crop, titleless: true, live: true);

  static String? _observedBodySelfReference(
    ScanCrop crop, {
    required bool titleless,
    bool live = false,
  }) {
    if (hasConflictingScanTitle(crop) ||
        !crop.rectified ||
        crop.sourceCorners.length != 4 ||
        crop.width <= 0 ||
        crop.height / crop.width < 1.2 ||
        crop.height / crop.width > 1.8 ||
        crop.warnings.contains('partial_card') ||
        (!titleless && crop.warnings.contains('incomplete_card')) ||
        (titleless &&
            (live
                ? !hasVerifiedLiveBodyLayout(crop)
                : !_canonicalSavedSelfReferenceLayout(crop)))) {
      return null;
    }
    final List<ScanTextLine> titles = crop.lines
        .where(
          (ScanTextLine line) =>
              line.confidence >= .90 &&
              line.bounds.y >= 0 &&
              line.bounds.y < .13 &&
              line.bounds.x >= 0 &&
              line.bounds.x < .6 &&
              line.bounds.width >= .10 &&
              line.bounds.height > 0 &&
              line.bounds.height <= .08 &&
              line.textHeight > 0 &&
              line.textHeight <= .05 &&
              !RegExp(r'^["“«]').hasMatch(line.text.trim()),
        )
        .toList();
    if (titleless ? titles.isNotEmpty : titles.isEmpty) return null;
    final RegExp type = RegExp(
      r'^(?:(?:legendary|basic|snow|world)\s+)*(?:creature|instant|sorcery|enchantment|artifact|land|planeswalker|battle|kindred|tribal)(?:\s+(?:creature|enchantment|artifact|land|kindred|tribal))*(?:\s*[—–-]\s*.+)?$',
      caseSensitive: false,
    );
    bool row(ScanTextLine line) =>
        line.confidence >= .90 &&
        line.bounds.x >= 0 &&
        line.bounds.x < .75 &&
        line.bounds.width >= .20 &&
        line.bounds.x + line.bounds.width <= 1.02 &&
        line.bounds.height > 0 &&
        line.bounds.height <= (titleless ? .08 : .06) &&
        (!titleless || line.glyphHeight != null) &&
        line.textHeight > 0 &&
        line.textHeight <= .05;
    final List<ScanTextLine> types = crop.lines
        .where(
          (ScanTextLine line) =>
              row(line) &&
              line.bounds.y >= .45 &&
              line.bounds.y < .65 &&
              type.hasMatch(line.text.trim()),
        )
        .toList();
    final List<ScanTextLine> independentTypes = <ScanTextLine>[];
    for (final ScanTextLine line in types) {
      if (live &&
          independentTypes.any((ScanTextLine previous) {
            final double area = line.bounds.width * line.bounds.height;
            final double priorArea =
                previous.bounds.width * previous.bounds.height;
            final double largerArea = area > priorArea ? area : priorArea;
            return line.text.trim().toLowerCase() ==
                    previous.text.trim().toLowerCase() &&
                largerArea > 0 &&
                _boundsIntersectionArea(line.bounds, previous.bounds) /
                        largerArea >=
                    .80;
          })) {
        continue;
      }
      independentTypes.add(line);
    }
    if (independentTypes.length != 1) return null;
    final ScanTextLine typeRow = independentTypes.single;
    final List<String> rules = ScanHints.fromCrop(crop).rulesText;
    final List<ScanTextLine> body =
        crop.lines
            .where(
              (ScanTextLine line) =>
                  ((row(line) &&
                          rules.contains(line.text.trim()) &&
                          line.text.trim().split(RegExp(r'\s+')).length >= 3) ||
                      _isQuoteBoundary(line)) &&
                  line.bounds.y >= .50 &&
                  line.bounds.y < .86 &&
                  line.bounds.y >=
                      typeRow.bounds.y + typeRow.bounds.height + .005 &&
                  !RegExp(
                    r'©|copyright|wizards',
                    caseSensitive: false,
                  ).hasMatch(line.text),
            )
            .toList()
          ..sort(
            (ScanTextLine a, ScanTextLine b) =>
                a.bounds.y.compareTo(b.bounds.y),
          );
    final List<ScanTextLine> independent = <ScanTextLine>[];
    for (final ScanTextLine line in body) {
      if (RegExp(r'^["“«]').hasMatch(line.text.trim())) break;
      if (independent.isEmpty ||
          line.bounds.y - independent.last.bounds.y >= .025) {
        independent.add(line);
      }
    }
    if (independent.length < 3) return null;
    final RegExpMatch? self = RegExp(
      r'^As ([\p{L}][\p{L}\s,\x27’—-]{2,95}?) enters(?: the battlefield)?[,.:]?$',
      unicode: true,
    ).firstMatch(independent.first.text.trim());
    final String? name = self?.group(1)?.trim();
    if (name == null ||
        name.split(RegExp(r'\s+')).length > 8 ||
        RegExp(
          r'^(?:this|that|a|an|the)(?:\s|$)',
          caseSensitive: false,
        ).hasMatch(name)) {
      return null;
    }
    String normalized(String text) => text.toLowerCase().replaceAll(
      RegExp(r'[^\p{L}\p{N}]', unicode: true),
      '',
    );
    final String full = normalized(name);
    if (!titles.every((ScanTextLine line) {
      final String prefix = normalized(line.text);
      return prefix.length >= 4 &&
          prefix.length >= full.length * .4 &&
          full.startsWith(prefix);
    })) {
      return null;
    }
    return name;
  }

  static bool _canonicalSavedSelfReferenceLayout(ScanCrop crop) {
    const Set<String> repairs = <String>{
      'geometry_adjusted',
      'orientation_ensemble',
      'incomplete_card',
    };
    if (crop.imagePath.isEmpty ||
        crop.width < 400 ||
        crop.height < 400 ||
        !crop.warnings.contains('geometry_adjusted') ||
        crop.warnings.any((String warning) => !repairs.contains(warning)) ||
        crop.sourceCorners.any(
          (ScanPoint point) =>
              !point.x.isFinite ||
              !point.y.isFinite ||
              point.x < 0 ||
              point.x > 1 ||
              point.y < 0 ||
              point.y > 1,
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
    return twiceArea >= .0002;
  }
}

@immutable
class ScanCandidate {
  final MtgCard card;
  final Set<ScanEvidence> evidence;
  final double? artworkDistance;
  final double? symbolDistance;

  const ScanCandidate(
    this.card,
    this.evidence, {
    this.artworkDistance,
    this.symbolDistance,
  });

  int get score =>
      (evidence.contains(ScanEvidence.footerMatch) ? 60 : 0) +
      (evidence.contains(ScanEvidence.nameMatch) ? 30 : 0) +
      (evidence.contains(ScanEvidence.fuzzyName) ? 5 : 0) +
      (evidence.contains(ScanEvidence.rulesTextMatch) ? 25 : 0) +
      (evidence.contains(ScanEvidence.rulesKeywordMatch) ? 15 : 0) +
      (evidence.contains(ScanEvidence.collectorNumberMatch) ? 10 : 0) +
      (evidence.contains(ScanEvidence.languageMatch) ? 5 : 0) +
      (evidence.contains(ScanEvidence.typeLineMatch) ? 5 : 0) +
      (evidence.contains(ScanEvidence.illustratorMatch) ? 12 : 0) +
      (evidence.contains(ScanEvidence.copyrightYearMatch) ? 3 : 0) -
      (evidence.contains(ScanEvidence.nameMismatch) ? 80 : 0) -
      (evidence.contains(ScanEvidence.rulesTextMismatch) ? 80 : 0) -
      (evidence.contains(ScanEvidence.printingMismatch) ? 100 : 0) -
      (evidence.contains(ScanEvidence.languageMismatch) ? 40 : 0);

  bool get hasContradiction => evidence.any(
    (ScanEvidence item) => <ScanEvidence>{
      ScanEvidence.nameMismatch,
      ScanEvidence.rulesTextMismatch,
      ScanEvidence.printingMismatch,
      ScanEvidence.languageMismatch,
    }.contains(item),
  );
}

@immutable
class HistoricalBodyIdentityProof {
  final String name;
  final String bodySignature;

  const HistoricalBodyIdentityProof({
    required this.name,
    required this.bodySignature,
  });
}

@immutable
class ScanResolution {
  final List<ScanCandidate> candidates;
  final ScanHints hints;
  final ScanResolutionStatus status;
  final bool hasMore;
  final int page;
  final HistoricalBodyIdentityProof? historicalBodyIdentityProof;

  const ScanResolution({
    required this.candidates,
    required this.hints,
    required this.status,
    this.hasMore = false,
    this.page = 1,
    this.historicalBodyIdentityProof,
  });
}

@immutable
class ScanResolveOutcome {
  final ScanResolution? resolution;
  final Object? error;
  final StackTrace? stackTrace;

  const ScanResolveOutcome.success(ScanResolution value)
    : resolution = value,
      error = null,
      stackTrace = null;

  const ScanResolveOutcome.failure(Object failure, StackTrace stack)
    : resolution = null,
      error = failure,
      stackTrace = stack;

  bool get succeeded => resolution != null;
}

final Object _batchOutcomeZoneKey = Object();

typedef ScanOutcomeListener = Future<void> Function(
  int index,
  ScanResolveOutcome outcome,
);

class _BatchOutcomeCapture {
  final List<ScanCrop> crops;
  final ScanOutcomeListener? onOutcome;
  final Set<int> _published = <int>{};
  final List<Future<void>> _publications = <Future<void>>[];
  Object? _publicationFailure;
  StackTrace? _publicationFailureStack;
  List<ScanResolveOutcome>? outcomes;
  _BatchOutcomeCapture(this.crops, this.onOutcome);

  void publish(int index, ScanResolveOutcome outcome) {
    if (onOutcome == null || !_published.add(index)) return;
    _publications.add(_deliver(index, outcome));
  }

  Future<void> _deliver(int index, ScanResolveOutcome outcome) async {
    try {
      await onOutcome!(index, outcome);
    } catch (error, stack) {
      _publicationFailure ??= error;
      _publicationFailureStack ??= stack;
    }
  }

  Future<void> finish() async {
    await Future.wait<void>(_publications);
    if (_publicationFailure != null) {
      Error.throwWithStackTrace(
        _publicationFailure!,
        _publicationFailureStack!,
      );
    }
  }
}

String? verifiedSavedSelfReferenceIdentity(
  ScanCrop crop,
  ScanResolution resolution,
) {
  if (hasConflictingScanTitle(crop)) return null;
  final String? observed = ScanHints.observedSavedBodySelfReference(crop);
  final ScanHints raw = ScanHints.fromCrop(crop);
  if (observed == null ||
      resolution.status != ScanResolutionStatus.needsReview ||
      !resolution.hints.names.contains(observed) ||
      resolution.hints.typeLine != raw.typeLine ||
      !listEquals(resolution.hints.rulesText, raw.rulesText) ||
      !listEquals(resolution.hints.postQuoteText, raw.postQuoteText)) {
    return null;
  }
  final List<ScanCandidate> supported = resolution.candidates
      .where(
        (ScanCandidate candidate) =>
            !candidate.hasContradiction &&
            candidate.evidence.containsAll(const <ScanEvidence>{
              ScanEvidence.nameMatch,
              ScanEvidence.typeLineMatch,
              ScanEvidence.rulesTextMatch,
              ScanEvidence.illustratorMatch,
              ScanEvidence.copyrightYearMatch,
            }) &&
            ScanResolver._savedSelfReferenceFooterMatches(crop, candidate.card),
      )
      .toList();
  final Set<String> identities = supported
      .map(
        (ScanCandidate candidate) =>
            ScanResolver._normalizeName(candidate.card.name),
      )
      .toSet();
  return identities.length == 1 &&
          identities.single == ScanResolver._normalizeName(observed)
      ? observed
      : null;
}

String? verifiedHistoricalBodyIdentity(
  ScanCrop crop,
  ScanResolution resolution,
) {
  if (hasConflictingScanTitle(crop) ||
      crop.imagePath.isEmpty ||
      !hasVerifiedSavedBodyLayout(crop) ||
      (resolution.hasMore && resolution.historicalBodyIdentityProof == null) ||
      resolution.status == ScanResolutionStatus.noMatch) {
    return null;
  }
  final ScanHints hints = ScanHints.fromCrop(crop);
  if (hints.typeLine == null ||
      ScanResolver.rulesSearchKeywords(hints.rulesText).length < 4) {
    return null;
  }
  final List<ScanCandidate> supported = resolution.candidates
      .where(
        (ScanCandidate candidate) =>
            !candidate.hasContradiction &&
            candidate.evidence.containsAll(const <ScanEvidence>{
              ScanEvidence.rulesKeywordMatch,
              ScanEvidence.typeLineMatch,
              ScanEvidence.illustratorMatch,
              ScanEvidence.copyrightYearMatch,
            }),
      )
      .toList();
  final Set<String> identities = supported
      .map(
        (ScanCandidate candidate) =>
            ScanResolver._normalizeName(candidate.card.name),
      )
      .toSet();
  if (identities.length != 1 || identities.single.isEmpty) {
    return null;
  }
  final HistoricalBodyIdentityProof? proof =
      resolution.historicalBodyIdentityProof;
  if (proof != null &&
      (ScanResolver._normalizeName(proof.name) != identities.single ||
          proof.bodySignature != ScanResolver._historicalBodySignature(crop))) {
    return null;
  }
  return supported.first.card.name;
}

String? verifiedLiveHistoricalBodyIdentity(
  ScanCrop crop,
  ScanResolution resolution,
) {
  return _liveHistoricalBodyIdentity(crop, resolution, requireProof: true);
}

String? _liveHistoricalBodyIdentity(
  ScanCrop crop,
  ScanResolution resolution, {
  required bool requireProof,
}) {
  if (hasConflictingScanTitle(crop) ||
      !hasVerifiedLiveBodyLayout(crop) ||
      resolution.status != ScanResolutionStatus.needsReview ||
      (requireProof && resolution.historicalBodyIdentityProof == null) ||
      (resolution.hasMore && resolution.historicalBodyIdentityProof == null)) {
    return null;
  }
  final ScanHints hints = ScanHints.fromCrop(crop);
  final String? literalSelf = ScanHints.observedLiveBodySelfReference(crop);
  if (hints.typeLine == null ||
      (literalSelf == null &&
          ScanResolver.rulesSearchKeywords(hints.rulesText).length < 4)) {
    return null;
  }
  final List<ScanCandidate> supported = resolution.candidates
      .where(
        (ScanCandidate candidate) =>
            !candidate.hasContradiction &&
            candidate.evidence.containsAll(<ScanEvidence>{
              if (literalSelf == null) ScanEvidence.rulesKeywordMatch,
              if (literalSelf != null) ScanEvidence.rulesTextMatch,
              ScanEvidence.typeLineMatch,
              ScanEvidence.illustratorMatch,
              ScanEvidence.copyrightYearMatch,
            }) &&
            (literalSelf == null
                ? ScanResolver._liveHistoricalMetadataMatches(
                    crop,
                    candidate.card,
                  )
                : ScanResolver._savedSelfReferenceFooterMatches(
                    crop,
                    candidate.card,
                  )),
      )
      .toList();
  final Set<String> names = supported
      .map(
        (ScanCandidate candidate) =>
            ScanResolver._normalizeName(candidate.card.name),
      )
      .toSet();
  if (names.length != 1 ||
      names.single.isEmpty ||
      (literalSelf != null &&
          names.single != ScanResolver._normalizeName(literalSelf))) {
    return null;
  }
  final HistoricalBodyIdentityProof? proof =
      resolution.historicalBodyIdentityProof;
  if (proof != null &&
      (ScanResolver._normalizeName(proof.name) != names.single ||
          proof.bodySignature != ScanResolver._historicalBodySignature(crop))) {
    return null;
  }
  final List<ScanTextLine> titles = crop.lines
      .where(
        (ScanTextLine line) =>
            line.confidence >= .90 &&
            line.bounds.y < .13 &&
            line.bounds.x < .6 &&
            line.bounds.width >= .1 &&
            line.glyphHeight != null &&
            line.textHeight <= .05,
      )
      .toList();
  if (titles.any(
    (ScanTextLine line) =>
        ScanResolver._normalizeName(line.text) != names.single,
  )) {
    return null;
  }
  return supported.first.card.name;
}

bool hasExactPrintingEvidence(ScanCrop crop, ScanResolution? resolution) {
  if (resolution == null ||
      resolution.status != ScanResolutionStatus.exactPrinting ||
      resolution.candidates.length != 1 ||
      !crop.rectified ||
      crop.warnings.isNotEmpty) {
    return false;
  }
  final ScanCandidate candidate = resolution.candidates.single;
  if (!candidate.evidence.contains(ScanEvidence.nameMatch) ||
      candidate.hasContradiction ||
      candidate.evidence.contains(ScanEvidence.collectorNumberSimilar) ||
      candidate.evidence.contains(ScanEvidence.fuzzyName)) {
    return false;
  }
  ScanHints reliableHints(double confidence, bool title) => ScanHints.fromCrop(
    ScanCrop(
      imagePath: '',
      width: crop.width,
      height: crop.height,
      rectified: true,
      sourceCorners: const <ScanPoint>[],
      lines: crop.lines
          .where(
            (ScanTextLine line) =>
                line.confidence >= confidence &&
                (title ? line.bounds.y < .13 : line.bounds.y > .70),
          )
          .toList(),
    ),
  );
  final ScanHints title = reliableHints(.85, true);
  final ScanHints footer = reliableHints(.75, false);
  return title.names.any(
        (String name) => ScanResolver._matchesName(candidate.card, name),
      ) &&
      footer.setCode != null &&
      footer.setCode == candidate.card.set.toLowerCase() &&
      footer.collectorNumber != null &&
      ScanResolver._number(footer.collectorNumber!) ==
          ScanResolver._number(candidate.card.collectorNumber) &&
      footer.language != null &&
      footer.language == candidate.card.lang.json;
}

abstract interface class ScanCatalog {
  Future<MtgCard?> exactPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  });

  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  });

  Future<MtgCard?> fuzzyName(String name);

  Future<PaginableList<MtgCard>> rulesTextPrintings(
    String phrase, {
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
    int page = 1,
  });

  Future<PaginableList<MtgCard>> rulesKeywordCards(
    List<String> keywords, {
    String? phrase,
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
  });
}

abstract interface class ScanMetadataCatalog {
  Future<PaginableList<MtgCard>> metadataPrintings({
    required String collectorNumber,
    required String illustrator,
    String? language,
  });
}

typedef _PrintingSearchKey = ({
  String name,
  String? setCode,
  String? language,
  int page,
});

typedef _CachedPrintingSearch = ({
  DateTime expiresAt,
  PaginableList<MtgCard> result,
});

typedef _SoftFooterRead = ({String? setCode, Set<String> numbers});

class ScryfallScanCatalog implements ScanCatalog, ScanMetadataCatalog {
  final ScryfallApiClient _api;
  final DateTime Function() _clock;
  final LocalScanCatalog? localCatalog;
  final Map<String, Future<MtgCard?>> _requests = <String, Future<MtgCard?>>{};
  final LinkedHashMap<String, MtgCard> _recent =
      LinkedHashMap<String, MtgCard>();
  Future<Box<String>>? _cache;
  final Map<_PrintingSearchKey, Future<PaginableList<MtgCard>>>
  _printingRequests = <_PrintingSearchKey, Future<PaginableList<MtgCard>>>{};
  final LinkedHashMap<_PrintingSearchKey, _CachedPrintingSearch>
  _printingSearches =
      LinkedHashMap<_PrintingSearchKey, _CachedPrintingSearch>();
  int _printingSearchCards = 0;
  bool _closed = false;

  Future<Box<String>> _box() =>
      _cache ??= Hive.openBox<String>('scanner_printings_v1');

  static String _key(String set, String number, String? language) =>
      '$set/$number/${language ?? 'en'}';

  Future<MtgCard?> _read(String key) async {
    final MtgCard? recent = _recent.remove(key);
    if (recent != null) {
      if (!recent.games.contains(Game.paper)) {
        return null;
      }
      _recent[key] = recent;
      return recent;
    }
    try {
      final String? value = (await _box()).get(key);
      if (value == null) {
        return null;
      }
      final Map<String, Object?> record = Map<String, Object?>.from(
        jsonDecode(value) as Map<Object?, Object?>,
      );
      if (DateTime.now().difference(DateTime.parse(record['at'] as String)) >
          const Duration(days: 1)) {
        return null;
      }
      final MtgCard card = MtgCard.fromJson(
        Map<String, Object?>.from(record['card'] as Map<Object?, Object?>),
      );
      return card.games.contains(Game.paper) ? card : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _remember(MtgCard card, {String? alias}) async {
    if (!card.games.contains(Game.paper)) {
      return;
    }
    final String key =
        alias ?? _key(card.set, card.collectorNumber, card.lang.json);
    _recent.remove(key);
    _recent[key] = card;
    if (_recent.length > 256) {
      _recent.remove(_recent.keys.first);
    }
    try {
      final Box<String> box = await _box();
      await box.put(
        key,
        jsonEncode(<String, Object?>{
          'at': DateTime.now().toUtc().toIso8601String(),
          'card': card.toJson(),
        }),
      );
      if (box.length > 4096) {
        await box.deleteAll(box.keys.take(box.length - 4096).toList());
      }
    } catch (_) {
      /* An unavailable cache must not prevent card lookup. */
    }
  }

  ScryfallScanCatalog({
    ScryfallApiClient? api,
    DateTime Function()? clock,
    LocalScanCatalog? localCatalog,
  }) : _api = api ?? ScryfallApiClient(httpClient: ScryfallHttpClient()),
       _clock = clock ?? DateTime.now,
       localCatalog =
           localCatalog ?? (api == null ? LocalScanCatalog.shared : null);

  @override
  Future<MtgCard?> exactPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  }) {
    final String key = _key(setCode, collectorNumber, language);
    final Future<MtgCard?>? pending = _requests[key];
    if (pending != null) {
      return pending;
    }
    late final Future<MtgCard?> request;
    request =
        (() async {
          final MtgCard? local = await localCatalog
              ?.exactReady(setCode, collectorNumber, language: language)
              .catchError((Object _) => null);
          if (local != null) return local;
          final MtgCard? cached = await _read(key);
          if (cached != null) {
            return cached;
          }
          final MtgCard? card = await _fetchPrinting(
            setCode,
            collectorNumber,
            language: language,
          );
          if (card != null) {
            await _remember(card, alias: key);
          }
          return card;
        })().whenComplete(() {
          if (identical(_requests[key], request)) {
            _requests.remove(key);
          }
        });
    _requests[key] = request;
    return request;
  }

  Future<MtgCard?> _fetchPrinting(
    String setCode,
    String collectorNumber, {
    String? language,
  }) async {
    final Language? requestedLanguage = language == null
        ? null
        : Language.values
              .where((Language item) => item.json == language)
              .firstOrNull;
    if (language != null && requestedLanguage == null) {
      throw ArgumentError.value(
        language,
        'language',
        'Unsupported card language',
      );
    }
    try {
      final MtgCard card = await _api.getCardBySetCodeAndCollectorNumber(
        setCode,
        collectorNumber,
        language: requestedLanguage,
      );
      return card.games.contains(Game.paper) ? card : null;
    } on ScryfallException catch (error) {
      if (error.status == 404) {
        // Printed footer numbers can be zero-padded; Scryfall keeps the suffix.
        final String unpadded = collectorNumber.replaceFirst(
          RegExp(r'^0+(?=\d)'),
          '',
        );
        if (unpadded == collectorNumber) {
          return null;
        }
        try {
          final MtgCard card = await _api.getCardBySetCodeAndCollectorNumber(
            setCode,
            unpadded,
            language: requestedLanguage,
          );
          return card.games.contains(Game.paper) ? card : null;
        } on ScryfallException catch (fallback) {
          if (fallback.status == 404) {
            return null;
          }
          rethrow;
        }
      }
      rethrow;
    }
  }

  Future<Map<String, MtgCard>> exactPrintings(List<ScanHints> hints) async {
    final Map<String, MtgCard> result = <String, MtgCard>{};
    final Map<String, ScanHints> missing = <String, ScanHints>{};
    for (final ScanHints hint in hints) {
      if (hint.setCode == null ||
          hint.collectorNumber == null ||
          hint.language != 'en') {
        continue;
      }
      final String key = _key(hint.setCode!, hint.collectorNumber!, 'en');
      if (result.containsKey(key) || missing.containsKey(key)) {
        continue;
      }
      final MtgCard? local = await localCatalog
          ?.exactReady(hint.setCode!, hint.collectorNumber!, language: 'en')
          .catchError((Object _) => null);
      final MtgCard? cached =
          local ??
          (_requests.containsKey(key)
              ? await _requests[key]!
              : await _read(key));
      if (cached != null) {
        result[key] = cached;
      } else {
        missing[key] = hint;
      }
    }
    final List<ScanHints> needed = missing.values.toList();
    for (int offset = 0; offset < needed.length; offset += 75) {
      final List<ScanHints> chunk = needed.skip(offset).take(75).toList();
      final CardList cards = await _api.getCardsByIdentifiers(
        chunk
            .map(
              (ScanHints hint) => CardIdentifierSetCollectorNumber(
                hint.setCode!,
                hint.collectorNumber!,
              ),
            )
            .toList(),
      );
      for (final MtgCard card in cards.data) {
        if (card.lang != Language.english || !card.games.contains(Game.paper)) {
          continue;
        }
        result[_key(card.set, card.collectorNumber, 'en')] = card;
        await _remember(card);
      }
    }
    // Literal identifiers are tried first; only unmatched zero-padded footer numbers use the normalized form.
    final List<MapEntry<String, ScanHints>> retries = missing.entries
        .where(
          (MapEntry<String, ScanHints> entry) =>
              !result.containsKey(entry.key) &&
              entry.value.collectorNumber !=
                  entry.value.collectorNumber!.replaceFirst(
                    RegExp(r'^0+(?=\d)'),
                    '',
                  ),
        )
        .toList();
    for (int offset = 0; offset < retries.length; offset += 75) {
      final List<MapEntry<String, ScanHints>> chunk = retries
          .skip(offset)
          .take(75)
          .toList();
      final CardList cards = await _api.getCardsByIdentifiers(
        chunk
            .map(
              (MapEntry<String, ScanHints> entry) =>
                  CardIdentifierSetCollectorNumber(
                    entry.value.setCode!,
                    entry.value.collectorNumber!.replaceFirst(
                      RegExp(r'^0+(?=\d)'),
                      '',
                    ),
                  ),
            )
            .toList(),
      );
      for (final MtgCard card in cards.data) {
        if (card.lang != Language.english || !card.games.contains(Game.paper)) {
          continue;
        }
        await _remember(card);
        for (final MapEntry<String, ScanHints> entry in chunk) {
          if (card.set == entry.value.setCode &&
              card.collectorNumber ==
                  entry.value.collectorNumber!.replaceFirst(
                    RegExp(r'^0+(?=\d)'),
                    '',
                  )) {
            result[entry.key] = card;
            await _remember(card, alias: entry.key);
          }
        }
      }
    }
    return result;
  }

  @override
  Future<PaginableList<MtgCard>> printings(
    String name, {
    String? setCode,
    String? language,
    int page = 1,
  }) {
    if (_closed) {
      return Future<PaginableList<MtgCard>>.error(
        StateError('Scryfall catalog is closed.'),
      );
    }
    final _PrintingSearchKey key = (
      name: name,
      setCode: setCode,
      language: language,
      page: page,
    );
    final _CachedPrintingSearch? cached = _printingSearches.remove(key);
    if (cached != null) {
      if (cached.expiresAt.isAfter(_clock())) {
        _printingSearches[key] = cached;
        return Future<PaginableList<MtgCard>>.value(cached.result);
      }
      _printingSearchCards -= cached.result.data.length;
    }
    final Future<PaginableList<MtgCard>>? pending = _printingRequests[key];
    if (pending != null) return pending;
    late final Future<PaginableList<MtgCard>> request;
    request =
        (() async {
          final PaginableList<MtgCard> found = await _fetchPrintings(
            name,
            setCode: setCode,
            language: language,
            page: page,
          );
          final PaginableList<MtgCard> result = PaginableList<MtgCard>(
            data: List<MtgCard>.unmodifiable(found.data),
            hasMore: found.hasMore,
            nextPage: found.nextPage,
            totalCards: found.totalCards,
            warnings: found.warnings == null
                ? null
                : List<String>.unmodifiable(found.warnings!),
          );
          if (!_closed && result.data.length <= 2048) {
            _printingSearches[key] = (
              expiresAt: _clock().add(const Duration(minutes: 15)),
              result: result,
            );
            _printingSearchCards += result.data.length;
            while (_printingSearches.length > 64 ||
                _printingSearchCards > 2048) {
              final _CachedPrintingSearch oldest = _printingSearches.remove(
                _printingSearches.keys.first,
              )!;
              _printingSearchCards -= oldest.result.data.length;
            }
          }
          return result;
        })().whenComplete(() {
          if (identical(_printingRequests[key], request)) {
            _printingRequests.remove(key);
          }
        });
    _printingRequests[key] = request;
    return request;
  }

  Future<PaginableList<MtgCard>> _fetchPrintings(
    String name, {
    String? setCode,
    String? language,
    required int page,
  }) async {
    final LocalCatalogPage? local = await localCatalog
        ?.printingsReady(name, setCode: setCode, language: language, page: page)
        .catchError((Object _) => null);
    if (local != null && local.cards.isNotEmpty) {
      return PaginableList<MtgCard>(
        data: local.cards,
        hasMore: local.hasMore,
        totalCards: local.total,
      );
    }
    final String quotedName = name
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"');
    final String query = <String>[
      '!"$quotedName"',
      'game:paper',
      if (setCode != null) 'set:$setCode',
      if (language != null) 'lang:$language',
    ].join(' ');
    try {
      return _paperPage(
        await _api.searchCards(
          query,
          rollupMode: RollupMode.prints,
          includeMultilingual: language != null || _hasNonLatinName(name),
          includeVariations: true,
          includeExtras: true,
          page: page,
        ),
      );
    } on ScryfallException catch (error) {
      if (error.status != 404) {
        rethrow;
      }
      return PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);
    }
  }

  @override
  Future<MtgCard?> fuzzyName(String name) async {
    try {
      final MtgCard card = await _api.getCardByName(
        name,
        searchType: SearchType.fuzzy,
      );
      if (card.games.contains(Game.paper)) {
        return card;
      }
      final PaginableList<MtgCard> paper = await printings(card.name);
      return paper.data.firstOrNull;
    } on ScryfallException catch (error) {
      if (error.status == 404) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<PaginableList<MtgCard>> metadataPrintings({
    required String collectorNumber,
    required String illustrator,
    String? language,
  }) async {
    String quoted(String value) =>
        '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
    final String query = <String>[
      'cn:${quoted(collectorNumber.replaceFirst(RegExp(r'^0+(?=\d)'), ''))}',
      'artist:${quoted(illustrator)}',
      'game:paper',
      if (language != null) 'lang:${quoted(language)}',
    ].join(' ');
    try {
      final PaginableList<MtgCard> found = _paperPage(
        await _api.searchCards(
          query,
          rollupMode: RollupMode.prints,
          includeMultilingual: true,
          includeVariations: true,
          includeExtras: false,
        ),
      );
      return found.hasMore || found.data.length > 32
          ? PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false)
          : found;
    } on ScryfallException catch (error) {
      if (error.status != 404) rethrow;
      return PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);
    }
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
    String quoted(String value) =>
        '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
    final String query = <String>[
      'oracle:${quoted(phrase)}',
      'game:paper',
      if (setCode != null) 'set:${quoted(setCode)}',
      if (collectorNumber != null)
        'cn:${quoted(collectorNumber.replaceFirst(RegExp(r'^0+(?=\d)'), ''))}',
      if (language != null) 'lang:${quoted(language)}',
      if (typeLine != null) 'type:${quoted(typeLine)}',
    ].join(' ');
    try {
      return _paperPage(
        await _api.searchCards(
          query,
          rollupMode: RollupMode.prints,
          includeMultilingual: language != null,
          includeVariations: true,
          includeExtras: false,
          page: page,
        ),
      );
    } on ScryfallException catch (error) {
      if (error.status != 404) {
        rethrow;
      }
      return PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);
    }
  }

  @override
  Future<PaginableList<MtgCard>> rulesKeywordCards(
    List<String> keywords, {
    String? phrase,
    String? setCode,
    String? collectorNumber,
    String? language,
    String? typeLine,
  }) async {
    if ((phrase == null
            ? keywords.length != 4
            : keywords.length < 2 ||
                  keywords.length > 4 ||
                  typeLine == null ||
                  typeLine.trim().isEmpty ||
                  !RegExp(r'^[a-z]{2,24}(?: [a-z]{2,24}){2,3}$')
                      .hasMatch(phrase)) ||
        keywords.toSet().length != keywords.length ||
        keywords.any(
          (String word) =>
              word != 'red' && !RegExp(r'^[a-z]{4,24}$').hasMatch(word),
        )) {
      throw ArgumentError.value(keywords, 'keywords');
    }
    String quoted(String value) =>
        '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
    final String query = <String>[
      ...keywords.map((String word) => 'oracle:$word'),
      'game:paper',
      if (phrase != null) 'oracle:${quoted(phrase)}',
      if (setCode != null) 'set:${quoted(setCode)}',
      if (collectorNumber != null)
        'cn:${quoted(collectorNumber.replaceFirst(RegExp(r'^0+(?=\d)'), ''))}',
      if (language != null) 'lang:${quoted(language)}',
      if (typeLine != null) 'type:${quoted(typeLine)}',
    ].join(' ');
    try {
      final PaginableList<MtgCard> found = _paperPage(
        await _api.searchCards(
          query,
          rollupMode: RollupMode.cards,
          includeMultilingual: language != null,
          includeExtras: false,
        ),
      );
      return found.hasMore || found.data.length > 32
          ? PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false)
          : found;
    } on ScryfallException catch (error) {
      if (error.status != 404) {
        rethrow;
      }
      return PaginableList<MtgCard>(data: <MtgCard>[], hasMore: false);
    }
  }

  static PaginableList<MtgCard> _paperPage(PaginableList<MtgCard> result) {
    final List<MtgCard> cards = result.data
        .where((MtgCard card) => card.games.contains(Game.paper))
        .toList();
    return PaginableList<MtgCard>(
      data: cards,
      hasMore: result.hasMore,
      nextPage: result.nextPage,
      totalCards: result.hasMore ? result.totalCards : cards.length,
      warnings: result.warnings,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _printingRequests.clear();
    _printingSearches.clear();
    _printingSearchCards = 0;
    _api.close();
  }
}

class ScanResolver {
  static final ScryfallScanNameIndex _sharedNameIndex = ScryfallScanNameIndex();
  final ScanCatalog catalog;
  final ScanArtworkMatcher artwork;
  final ScanSymbolMatcher symbols;
  final ScanNameIndex? nameIndex;
  final ScanVisualRetriever? visualIndex;

  ScanResolver({
    ScanCatalog? catalog,
    ScanArtworkMatcher? artwork,
    ScanSymbolMatcher? symbols,
    ScanNameIndex? nameIndex,
    ScanVisualRetriever? visualIndex,
  }) : catalog = catalog ?? ScryfallScanCatalog(),
       artwork = artwork ?? CachedScanArtworkMatcher.shared,
       symbols = symbols ?? CachedScanSymbolMatcher.shared,
       nameIndex = nameIndex ?? (catalog == null ? _sharedNameIndex : null),
       visualIndex =
           visualIndex ??
           (catalog == null ? IndexedScanVisualRetriever() : null);

  Future<void> warmNames() async {
    final ScanCatalog source = catalog;
    if (source is ScryfallScanCatalog && source.localCatalog != null) {
      unawaited(source.localCatalog!.warm().catchError((Object _) {}));
    }
    if (!identical(nameIndex, _sharedNameIndex)) {
      return;
    }
    try {
      await _sharedNameIndex.warm();
    } catch (_) {}
  }

  Future<List<ScanResolveOutcome>> resolveBatchOutcomes(
    List<ScanCrop> crops, {
    ScanOutcomeListener? onOutcome,
  }) async {
    final List<ScanCrop> frozen = List<ScanCrop>.unmodifiable(crops);
    final _BatchOutcomeCapture capture = _BatchOutcomeCapture(
      frozen,
      onOutcome,
    );
    late final List<ScanResolveOutcome> completed;
    try {
      final List<ScanResolution> results = await runZoned(
        () => resolveBatch(frozen),
        zoneValues: <Object, Object>{_batchOutcomeZoneKey: capture},
      );
      if (results.length != frozen.length) {
        throw StateError('The resolver returned an incomplete batch.');
      }
      completed =
          capture.outcomes ??
          List<ScanResolveOutcome>.unmodifiable(
            results.map(ScanResolveOutcome.success),
          );
    } catch (_) {
      final List<ScanResolveOutcome>? captured = capture.outcomes;
      if (captured != null) {
        completed = captured;
      } else {
        final List<ScanResolveOutcome?> outcomes =
            List<ScanResolveOutcome?>.filled(frozen.length, null);
        int next = 0;
        Future<void> worker() async {
          while (next < frozen.length) {
            final int index = next++;
            try {
              outcomes[index] = ScanResolveOutcome.success(
                await resolve(frozen[index]),
              );
            } catch (error, stack) {
              outcomes[index] = ScanResolveOutcome.failure(error, stack);
            }
            capture.publish(index, outcomes[index]!);
          }
        }

        await Future.wait<void>(<Future<void>>[
          for (int index = 0; index < frozen.length && index < 4; index++)
            worker(),
        ]);
        completed = List<ScanResolveOutcome>.unmodifiable(
          outcomes.cast<ScanResolveOutcome>(),
        );
      }
    }
    for (int index = 0; index < completed.length; index++) {
      capture.publish(index, completed[index]);
    }
    await capture.finish();
    return completed;
  }

  Future<List<ScanResolution>> resolveBatch(List<ScanCrop> crops) async {
    final List<ScanHints> hints = crops.map(ScanHints.fromCrop).toList();
    final ScanCatalog source = catalog;
    Map<String, MtgCard> exact = <String, MtgCard>{};
    if (source is ScryfallScanCatalog) {
      try {
        exact = await source.exactPrintings(hints);
      } catch (_) {
        // Individual lookups can still succeed when a bulk request fails.
      }
    }
    final List<ScanResolveOutcome?> outcomes = List<ScanResolveOutcome?>.filled(
      crops.length,
      null,
    );
    Future<ScanResolution> resolveIndex(int index) async {
      final ScanHints hint = hints[index];
      final MtgCard? card = hint.setCode == null || hint.collectorNumber == null
          ? null
          : exact[ScryfallScanCatalog._key(
              hint.setCode!,
              hint.collectorNumber!,
              hint.language,
            )];
      if (card == null) return resolve(crops[index]);
      final ScanResolution footer = await _candidates(
        crops[index],
        hint,
        <MtgCard>[card],
        footer: true,
      );
      return _footerIdentityConflict(footer)
          ? _recoverFooterIdentity(crops[index], hint, footer)
          : footer;
    }

    int next = 0;
    Object? firstFailure;
    StackTrace? firstFailureStack;
    final Object? context = Zone.current[_batchOutcomeZoneKey];
    final _BatchOutcomeCapture? capture =
        context is _BatchOutcomeCapture && identical(context.crops, crops)
        ? context
        : null;
    Future<void> worker() async {
      while (next < crops.length) {
        final int index = next++;
        try {
          outcomes[index] = ScanResolveOutcome.success(
            await resolveIndex(index),
          );
        } catch (error, stack) {
          outcomes[index] = ScanResolveOutcome.failure(error, stack);
          firstFailure ??= error;
          firstFailureStack ??= stack;
        }
        capture?.publish(index, outcomes[index]!);
      }
    }

    await Future.wait<void>(<Future<void>>[
      for (int index = 0; index < crops.length && index < 4; index++) worker(),
    ]);
    final List<ScanResolveOutcome> completed =
        List<ScanResolveOutcome>.unmodifiable(
          outcomes.cast<ScanResolveOutcome>(),
        );
    if (capture != null) capture.outcomes = completed;
    if (firstFailure != null) {
      Error.throwWithStackTrace(firstFailure!, firstFailureStack!);
    }
    return completed
        .map((ScanResolveOutcome outcome) => outcome.resolution!)
        .toList();
  }

  Future<ScanResolution> resolve(
    ScanCrop crop, {
    String? name,
    String? setCode,
    String? collectorNumber,
    String? language,
    int page = 1,
  }) async {
    final ScanHints detected = ScanHints.fromCrop(crop);
    final ScanHints hints = ScanHints(
      names: name == null ? detected.names : <String>[name.trim()],
      setCode: _nonEmpty(setCode ?? detected.setCode)?.toLowerCase(),
      collectorNumber: _nonEmpty(collectorNumber ?? detected.collectorNumber),
      language: _nonEmpty(language ?? detected.language)?.toLowerCase(),
      rulesText: detected.rulesText,
      postQuoteText: detected.postQuoteText,
      typeLine: detected.typeLine,
    );
    final bool automatic =
        name == null &&
        setCode == null &&
        collectorNumber == null &&
        language == null &&
        page == 1;
    if (hints.setCode != null && hints.collectorNumber != null && page == 1) {
      final MtgCard? exact = await catalog.exactPrinting(
        hints.setCode!,
        hints.collectorNumber!,
        language: hints.language,
      );
      if (exact != null) {
        final ScanResolution footer = await _candidates(crop, hints, <MtgCard>[
          exact,
        ], footer: true);
        final bool manual =
            name != null ||
            setCode != null ||
            collectorNumber != null ||
            language != null;
        return !manual && _footerIdentityConflict(footer)
            ? _recoverFooterIdentity(crop, hints, footer)
            : footer;
      }
    }
    if (automatic && hints.names.isEmpty && !detected.hasConflictingFooter) {
      final ScanResolution? metadata = await _metadataPrintings(crop, hints);
      if (metadata != null) return metadata;
    }
    if (automatic &&
        (hints.names.isEmpty ||
            (crop.warnings.isNotEmpty && _hasReviewableBasicArtwork(crop)))) {
      final ScanResolution? discovered = await _visualDiscovery(crop, hints);
      if (discovered != null) return discovered;
    }
    final String? selfReference =
        name == null &&
            page == 1 &&
            hints.setCode == null &&
            hints.collectorNumber == null
        ? ScanHints.observedBodySelfReference(crop)
        : null;
    ScanResolution? contradictedTitle;
    final List<String> titleQueries = <String>[
      ...hints.names,
      if (selfReference != null && !hints.names.contains(selfReference))
        selfReference,
    ];
    if (name == null && page == 1) {
      final ScanResolution? indexed = await _indexedTitles(
        crop,
        hints,
        allowSceneFooterSimilarity:
            setCode == null && collectorNumber == null && language == null,
      );
      if (indexed != null) return indexed;
    }
    for (final String title in titleQueries) {
      if (title.isEmpty) {
        continue;
      }
      final PaginableList<MtgCard> printings = await catalog.printings(
        title,
        setCode: hints.setCode,
        language: hints.language,
        page: page,
      );
      if (printings.data.isEmpty &&
          !printings.hasMore &&
          name == null &&
          setCode == null &&
          collectorNumber == null &&
          language == null &&
          page == 1) {
        final ScanResolution? recovered = await _failedBasicSetPrintings(
          crop,
          hints,
          title,
        );
        if (recovered != null) return recovered;
      }
      if (printings.data.isNotEmpty) {
        final ScanHints scoringHints =
            title == selfReference && !hints.names.contains(selfReference)
            ? ScanHints(
                names: List<String>.unmodifiable(<String>[
                  ...hints.names,
                  title,
                ]),
                setCode: hints.setCode,
                collectorNumber: hints.collectorNumber,
                language: hints.language,
                rulesText: hints.rulesText,
                postQuoteText: hints.postQuoteText,
                typeLine: hints.typeLine,
              )
            : hints;
        final ScanResolution resolved = await _candidates(
          crop,
          scoringHints,
          printings.data,
          hasMore: printings.hasMore,
          page: page,
          allowSceneFooterSimilarity:
              name == null &&
              setCode == null &&
              collectorNumber == null &&
              language == null,
        );
        if (selfReference != null &&
            title != selfReference &&
            resolved.candidates.every(
              (ScanCandidate candidate) => candidate.hasContradiction,
            )) {
          contradictedTitle ??= resolved;
          continue;
        }
        if (selfReference != null &&
            title == selfReference &&
            hints.names.first != selfReference) {
          final List<ScanCandidate> supported = resolved.candidates
              .where(
                (ScanCandidate candidate) =>
                    _normalizeName(candidate.card.name) ==
                        _normalizeName(selfReference) &&
                    !candidate.hasContradiction &&
                    candidate.evidence.contains(ScanEvidence.nameMatch) &&
                    candidate.evidence.contains(ScanEvidence.typeLineMatch) &&
                    candidate.evidence.contains(ScanEvidence.rulesTextMatch),
              )
              .toList();
          if (supported.isEmpty) return contradictedTitle ?? resolved;
          return ScanResolution(
            candidates: List<ScanCandidate>.unmodifiable(supported),
            hints: resolved.hints,
            status: ScanResolutionStatus.needsReview,
            hasMore: resolved.hasMore,
            page: page,
          );
        }
        return resolved;
      }
    }
    if (contradictedTitle != null) return contradictedTitle;
    if (automatic && hints.names.isNotEmpty && !detected.hasConflictingFooter) {
      final ScanResolution? metadata = await _metadataPrintings(crop, hints);
      if (metadata != null) return metadata;
    }
    if (name == null &&
        page == 1 &&
        hints.names.isEmpty &&
        hints.setCode == null &&
        hints.collectorNumber == null) {
      final String? liveSelf = ScanHints.observedLiveBodySelfReference(crop);
      if (liveSelf != null) {
        final PaginableList<MtgCard> found = await catalog.printings(
          liveSelf,
          language: hints.language,
        );
        if (!found.hasMore &&
            found.data.isNotEmpty &&
            found.data.length <= 96) {
          final ScanResolution resolved = await _candidates(
            crop,
            hints,
            found.data,
            savedSelfReferenceFooter: true,
            completeIdentitySearch: true,
          );
          if (verifiedLiveHistoricalBodyIdentity(crop, resolved) != null) {
            return resolved;
          }
        }
      }
      final String? savedSelf = ScanHints.observedSavedBodySelfReference(crop);
      if (savedSelf != null) {
        final PaginableList<MtgCard> found = await catalog.printings(
          savedSelf,
          language: hints.language,
        );
        if (found.data.isNotEmpty && found.data.length <= 96) {
          final ScanResolution resolved = await _candidates(
            crop,
            ScanHints(
              names: <String>[savedSelf],
              language: hints.language,
              rulesText: hints.rulesText,
              postQuoteText: hints.postQuoteText,
              typeLine: hints.typeLine,
            ),
            found.data,
            savedSelfReferenceFooter: true,
            hasMore: found.hasMore,
          );
          final String? verified = verifiedSavedSelfReferenceIdentity(
            crop,
            resolved,
          );
          if (verified != null) {
            return ScanResolution(
              candidates: List<ScanCandidate>.unmodifiable(
                resolved.candidates.where(
                  (ScanCandidate candidate) =>
                      !candidate.hasContradiction &&
                      _normalizeName(candidate.card.name) ==
                          _normalizeName(verified) &&
                      candidate.evidence.contains(ScanEvidence.typeLineMatch) &&
                      candidate.evidence.contains(
                        ScanEvidence.rulesTextMatch,
                      ) &&
                      _savedSelfReferenceFooterMatches(crop, candidate.card),
                ),
              ),
              hints: resolved.hints,
              status: ScanResolutionStatus.needsReview,
              hasMore: resolved.hasMore,
            );
          }
        }
      }
    }
    if (page == 1 && _nonEmpty(name) == null) {
      final (List<String>, String?) keywordHints = _corroboratedKeywordRules(
        crop,
      );
      final List<String> keywords = rulesSearchKeywords(keywordHints.$1);
      if (keywords.isNotEmpty) {
        for (final String alternative in _observedTitleAlternatives(crop)) {
          final PaginableList<MtgCard> found = await catalog.printings(
            alternative,
            setCode: hints.setCode,
            language: hints.language,
            page: page,
          );
          final List<MtgCard> matching = found.data
              .where((MtgCard card) => _matchesName(card, alternative))
              .toList();
          if (matching.isEmpty) {
            continue;
          }
          final ScanResolution verified = await _candidates(
            crop,
            ScanHints(
              names: List<String>.unmodifiable(<String>[
                ...hints.names,
                alternative,
              ]),
              setCode: hints.setCode,
              collectorNumber: hints.collectorNumber,
              language: hints.language,
              rulesText: hints.rulesText,
              postQuoteText: hints.postQuoteText,
              typeLine: hints.typeLine,
            ),
            matching,
            keywords: keywords,
            corroboratedColor: keywordHints.$2,
            hasMore: found.hasMore,
            page: page,
          );
          final List<ScanCandidate> supported = verified.candidates
              .where(
                (ScanCandidate candidate) =>
                    !candidate.hasContradiction &&
                    candidate.evidence.contains(ScanEvidence.nameMatch) &&
                    candidate.evidence.contains(ScanEvidence.typeLineMatch) &&
                    (candidate.evidence.contains(ScanEvidence.rulesTextMatch) ||
                        candidate.evidence.contains(
                          ScanEvidence.rulesKeywordMatch,
                        )),
              )
              .toList();
          if (supported.isNotEmpty) {
            return ScanResolution(
              candidates: List<ScanCandidate>.unmodifiable(supported),
              hints: verified.hints,
              status: ScanResolutionStatus.needsReview,
              hasMore: verified.hasMore,
              page: page,
            );
          }
        }
      }
    }
    final String? phrase = rulesSearchPhrase(hints.rulesText);
    if (phrase != null) {
      final PaginableList<MtgCard> found = await catalog.rulesTextPrintings(
        phrase,
        setCode: hints.setCode,
        collectorNumber: hints.collectorNumber,
        language: hints.language,
        typeLine: hints.typeLine,
        page: page,
      );
      if (found.data.isNotEmpty) {
        return _candidates(
          crop,
          hints,
          found.data,
          hasMore: found.hasMore,
          page: page,
        );
      }
    }
    final (List<String>, String?) keywordHints = _corroboratedKeywordRules(
      crop,
    );
    final List<String> keywords = rulesSearchKeywords(keywordHints.$1);
    if (page == 1 && keywords.isNotEmpty) {
      final PaginableList<MtgCard> found = await catalog.rulesKeywordCards(
        keywords,
        setCode: hints.setCode,
        collectorNumber: hints.collectorNumber,
        language: hints.language,
        typeLine: hints.typeLine,
      );
      if (!found.hasMore && found.data.isNotEmpty && found.data.length <= 32) {
        return _keywordPrintings(
          crop,
          hints,
          found.data,
          keywords: keywords,
          corroboratedColor: keywordHints.$2,
        );
      }
    }
    if (page == 1 && hints.names.isEmpty) {
      final (List<String>, String)? body = _bodyQuery(crop);
      if (body != null) {
        final PaginableList<MtgCard> found = await catalog.rulesKeywordCards(
          body.$1,
          phrase: body.$2,
          setCode: hints.setCode,
          collectorNumber: hints.collectorNumber,
          language: hints.language,
          typeLine: hints.typeLine,
        );
        if (!found.hasMore &&
            found.data.isNotEmpty &&
            found.data.length <= 32) {
          return _keywordPrintings(crop, hints, found.data, keywords: body.$1);
        }
      }
    }
    if (hints.names.isNotEmpty &&
        (!crop.warnings.contains('partial_card') || _nonEmpty(name) != null)) {
      final MtgCard? fuzzy = await catalog.fuzzyName(hints.names.first);
      if (fuzzy != null) {
        final String? printingLanguage =
            hints.language ??
            (_hasNonLatinName(hints.names.first) ? fuzzy.lang.json : null);
        final PaginableList<MtgCard> printings = await catalog.printings(
          fuzzy.name,
          language: printingLanguage,
          page: page,
        );
        final List<MtgCard> cards = printings.data.isEmpty
            ? <MtgCard>[fuzzy]
            : printings.data;
        return _candidates(
          crop,
          hints,
          cards,
          fuzzy: true,
          hasMore: printings.hasMore,
          page: page,
        );
      }
    }
    if (automatic) {
      final ScanResolution? discovered = await _visualDiscovery(crop, hints);
      if (discovered != null) return discovered;
    }
    return ScanResolution(
      candidates: const <ScanCandidate>[],
      hints: hints,
      status: ScanResolutionStatus.noMatch,
      page: page,
    );
  }

  Future<ScanResolution?> _metadataPrintings(
    ScanCrop crop,
    ScanHints hints,
  ) async {
    final ScanMetadataCatalog? source = switch (catalog) {
      final ScanMetadataCatalog metadata => metadata,
      _ => null,
    };
    final String? number = hints.collectorNumber;
    if (source == null ||
        number == null ||
        !RegExp(r'^\d{1,3}$').hasMatch(number) ||
        (!crop.rectified && !hasVerifiedLiveBodyLayout(crop))) {
      return null;
    }
    final List<String> artists = _observedIllustrators(crop);
    if (artists.length != 1) return null;
    final RegExp kana = RegExp(r'[\u3041-\u3096\u30a1-\u30fa]');
    final bool japaneseScript = crop.lines.any(
      (ScanTextLine line) =>
          line.confidence >= .85 &&
          line.bounds.y >= .40 &&
          line.bounds.y < .86 &&
          line.bounds.x >= 0 &&
          line.bounds.x + line.bounds.width <= 1.02 &&
          line.bounds.height > 0 &&
          line.bounds.height <= .08 &&
          kana.allMatches(line.text).length >= 4,
    );
    final String? queryLanguage =
        hints.language ?? (japaneseScript ? 'ja' : null);
    try {
      final PaginableList<MtgCard> found = await source.metadataPrintings(
        collectorNumber: number,
        illustrator: artists.single,
        language: queryLanguage,
      );
      if (found.hasMore || found.data.length > 32) return null;
      final List<MtgCard> matching = found.data.where((MtgCard card) {
        return _number(card.collectorNumber) == _number(number) &&
            (queryLanguage == null || card.lang.json == queryLanguage) &&
            <String>[
              if (card.artist != null) card.artist!,
              ...?card.cardFaces
                  ?.map((CardFace face) => face.artist)
                  .whereType<String>(),
            ].any(
              (String artist) =>
                  _normalizeName(artist) == _normalizeName(artists.single),
            );
      }).toList();
      if (matching.isEmpty) return null;
      final ScanResolution ranked = await _candidates(crop, hints, matching);
      if (ranked.candidates.isEmpty) return null;
      return ScanResolution(
        candidates: ranked.candidates,
        hints: hints,
        status: ScanResolutionStatus.needsReview,
      );
    } catch (_) {
      return null;
    }
  }

  Future<ScanResolution?> _visualDiscovery(
    ScanCrop crop,
    ScanHints hints,
  ) async {
    final ScanVisualRetriever? retriever = visualIndex;
    if (retriever == null || crop.imagePath.isEmpty || !crop.rectified) {
      return null;
    }
    try {
      final List<LocalVisualHit> hits = await retriever.discover(crop);
      final LinkedHashMap<String, MtgCard> cards =
          LinkedHashMap<String, MtgCard>();
      for (final LocalVisualHit hit in hits) {
        for (final MtgCard card in hit.cards) {
          if (cards.length < 160) cards.putIfAbsent(card.id, () => card);
        }
      }
      if (cards.isEmpty) return null;
      Map<String, double> distances = <String, double>{};
      try {
        final ScanArtworkMatcher matcher = artwork;
        if (matcher is CachedScanArtworkMatcher) {
          final Map<
            ({int rotation, double x, double y, double width, double height}),
            Map<String, MtgCard>
          >
          groups =
              <
                ({
                  int rotation,
                  double x,
                  double y,
                  double width,
                  double height,
                }),
                Map<String, MtgCard>
              >{};
          final Map<
            ({int rotation, double x, double y, double width, double height}),
            Map<String, String>
          >
          illustrationGroups =
              <
                ({
                  int rotation,
                  double x,
                  double y,
                  double width,
                  double height,
                }),
                Map<String, String>
              >{};
          final Map<String, Uint8List> referencePixels = <String, Uint8List>{
            for (final LocalVisualHit hit in hits)
              if (hit.referencePixels != null)
                hit.illustrationId: hit.referencePixels!,
          };
          for (final LocalVisualHit hit in hits) {
            final ScanBounds region =
                hit.queryRegion ?? IndexedScanVisualRetriever.standardArtwork;
            final ({
              int rotation,
              double x,
              double y,
              double width,
              double height,
            })
            key = (
              rotation: hit.rotationDegrees,
              x: region.x,
              y: region.y,
              width: region.width,
              height: region.height,
            );
            final Map<String, MtgCard> group = groups.putIfAbsent(
              key,
              () => <String, MtgCard>{},
            );
            final Map<String, String> artIds = illustrationGroups.putIfAbsent(
              key,
              () => <String, String>{},
            );
            for (final MtgCard card in hit.cards) {
              if (cards.containsKey(card.id)) {
                group.putIfAbsent(card.id, () => card);
                artIds.putIfAbsent(card.id, () => hit.illustrationId);
              }
            }
          }
          final List<Map<String, double>> compared =
              await Future.wait<Map<String, double>>(
                groups.entries.map(
                  (
                    MapEntry<
                      ({
                        int rotation,
                        double x,
                        double y,
                        double width,
                        double height,
                      }),
                      Map<String, MtgCard>
                    >
                    group,
                  ) => matcher.compareDiscovered(
                    crop,
                    group.value.values.toList(),
                    queryRegion: ScanBounds(
                      group.key.x,
                      group.key.y,
                      group.key.width,
                      group.key.height,
                    ),
                    rotationDegrees: group.key.rotation,
                    illustrationByCard: illustrationGroups[group.key],
                    referencePixelsByIllustration: referencePixels,
                  ),
                ),
              );
          for (final Map<String, double> group in compared) {
            for (final MapEntry<String, double> result in group.entries) {
              final double? previous = distances[result.key];
              if (previous == null || result.value < previous) {
                distances[result.key] = result.value;
              }
            }
          }
        } else if (hits.first.rotationDegrees == 0) {
          distances = await matcher.compare(crop, cards.values.toList());
        }
      } catch (_) {}
      if (distances.isEmpty) return null;
      final Map<String, MtgCard> supported = <String, MtgCard>{};
      for (final LocalVisualHit hit in hits) {
        if (hit.cards.any((MtgCard card) => distances.containsKey(card.id))) {
          for (final MtgCard card in hit.cards) {
            supported.putIfAbsent(card.id, () => card);
          }
        }
      }
      final ScanResolution ranked = await _candidates(
        crop,
        hints,
        supported.values.toList(),
        discoveredArtwork: distances,
      );
      List<ScanCandidate> candidates = ranked.candidates;
      final Set<String> literalTitles = <String>{
        if (!hasConflictingScanTitle(crop))
          for (final ScanTextLine line in crop.lines)
            if (line.confidence >= .90 &&
                line.bounds.y < .13 &&
                line.bounds.x < .6 &&
                line.bounds.width >= .1 &&
                line.bounds.height < .20 &&
                line.textHeight > 0 &&
                line.textHeight < .07 &&
                hints.names.any(
                  (String name) =>
                      _normalizeName(name) == _normalizeName(line.text),
                ))
              _normalizeName(line.text),
      };
      if (literalTitles.length == 1 &&
          candidates.any(
            (ScanCandidate candidate) =>
                _matchesName(candidate.card, literalTitles.single),
          )) {
        candidates = candidates
            .where(
              (ScanCandidate candidate) =>
                  _matchesName(candidate.card, literalTitles.single),
            )
            .toList();
      }
      final Set<String> identities = <String>{};
      candidates = candidates.where((ScanCandidate candidate) {
        final String identity = candidate.card.oracleId;
        if (identities.contains(identity)) return true;
        if (identities.length == 3) return false;
        identities.add(identity);
        return true;
      }).toList();
      return ScanResolution(
        candidates: candidates,
        hints: hints,
        status: ScanResolutionStatus.needsReview,
      );
    } catch (_) {
      return null;
    }
  }

  static bool _footerIdentityConflict(ScanResolution resolution) =>
      resolution.candidates.any(
        (ScanCandidate candidate) => candidate.evidence.any(
          (ScanEvidence evidence) => const <ScanEvidence>{
            ScanEvidence.nameMismatch,
            ScanEvidence.rulesTextMismatch,
          }.contains(evidence),
        ),
      );

  Future<ScanResolution?> _failedBasicSetPrintings(
    ScanCrop crop,
    ScanHints hints,
    String title,
  ) async {
    if (hints.setCode == null ||
        hints.collectorNumber != null ||
        ScanHints.fromCrop(crop).hasConflictingFooter ||
        !crop.warnings.contains('basic_land_outline') ||
        !crop.warnings.contains('partial_card') ||
        !hasVerifiedSavedVisualLayout(crop) ||
        !crop.lines.any(
          (ScanTextLine line) =>
              line.confidence >= .90 &&
              line.bounds.y < .13 &&
              _normalizeName(line.text) == _normalizeName(title),
        )) {
      return null;
    }
    final RegExp subtype = RegExp(
      r'^(?:plains|island|swamp|mountain|forest|wastes)$',
      caseSensitive: false,
    );
    final List<ScanTextLine> basicTypeRows = crop.lines
        .where(
          (ScanTextLine line) =>
              line.confidence >= .90 &&
              line.bounds.y >= .70 &&
              line.bounds.y < .90 &&
              RegExp(
                r'^basic(?:\s+snow)?\s+land\b',
                caseSensitive: false,
              ).hasMatch(line.text.trim()),
        )
        .toList();
    if (hints.rulesText.any(
      (String observed) =>
          !subtype.hasMatch(observed.trim()) ||
          !crop.lines.any(
            (ScanTextLine line) =>
                line.text.trim() == observed.trim() &&
                line.confidence.isFinite &&
                line.confidence >= .90 &&
                line.confidence <= 1 &&
                line.bounds.x >= 0 &&
                line.bounds.width > 0 &&
                line.bounds.x + line.bounds.width <= 1 &&
                line.bounds.y >= .70 &&
                line.bounds.height > 0 &&
                line.bounds.y + line.bounds.height <= .90 &&
                basicTypeRows.any(
                  (ScanTextLine type) =>
                      (line.bounds.y - type.bounds.y).abs() <= .035,
                ),
          ),
    )) {
      return null;
    }
    try {
      final PaginableList<MtgCard> found = await catalog.printings(
        title,
        language: hints.language,
      );
      final RegExp basicType = RegExp(
        r'^basic(?:\s+snow)?\s+land\b',
        caseSensitive: false,
      );
      if (found.hasMore ||
          found.data.isEmpty ||
          found.data.length > 96 ||
          found.data
                  .map((MtgCard card) => card.illustrationId ?? card.id)
                  .toSet()
                  .length >
              32 ||
          !found.data.every(
            (MtgCard card) =>
                _normalizeName(card.name) == _normalizeName(title) &&
                basicType.hasMatch(card.typeLine) &&
                card.set.toLowerCase() != hints.setCode &&
                (hints.language == null || card.lang.json == hints.language),
          )) {
        return null;
      }
      final List<MtgCard> paper = found.data
          .where((MtgCard card) => card.games.contains(Game.paper))
          .toList();
      if (paper.isEmpty) return null;
      final ScanResolution result = await _candidates(
        crop,
        hints,
        paper,
        reliableBodyFallback: true,
        allowFailedBasicSetVisual: true,
      );
      return result.candidates.any(_hasOnlyFailedSetContradiction)
          ? result
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<ScanResolution?> _indexedTitles(
    ScanCrop crop,
    ScanHints hints, {
    bool allowSceneFooterSimilarity = false,
  }) async {
    final ScanNameIndex? index = nameIndex;
    if (index == null) return null;
    try {
      final List<(String, ScanNameMatch)> matches = <(String, ScanNameMatch)>[];
      for (final String title in hints.names.take(3)) {
        final ScanNameMatch? match = index is ScryfallScanNameIndex
            ? index.matchReady(title)
            : await index.match(title);
        if (match != null && match.canonicalName.trim().isNotEmpty) {
          matches.add((title, match));
        }
      }
      if (matches.isEmpty ||
          matches
                  .map(
                    ((String, ScanNameMatch) value) =>
                        _normalizeName(value.$2.canonicalName),
                  )
                  .toSet()
                  .length !=
              1) {
        return null;
      }
      final (String, ScanNameMatch) selected = matches.firstWhere(
        ((String, ScanNameMatch) value) => value.$2.exact,
        orElse: () => matches.first,
      );
      final ScanNameMatch match = selected.$2;
      if (match.canonicalName == selected.$1) return null;
      final PaginableList<MtgCard> found = await catalog.printings(
        match.canonicalName,
        setCode: hints.setCode,
        language: hints.language,
      );
      if (found.hasMore ||
          found.data.isEmpty ||
          found.data.length > 175 ||
          found.data
                  .map((MtgCard card) => _normalizeName(card.name))
                  .toSet()
                  .length !=
              1 ||
          !found.data.every(
            (MtgCard card) => _matchesName(card, match.canonicalName),
          )) {
        return null;
      }
      final ScanResolution resolved = await _candidates(
        crop,
        hints,
        found.data,
        fuzzy: !match.exact,
        allowSceneFooterSimilarity: allowSceneFooterSimilarity,
      );
      return resolved.candidates.any(
            (ScanCandidate candidate) => !candidate.hasContradiction,
          )
          ? resolved
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<ScanResolution> _recoverFooterIdentity(
    ScanCrop crop,
    ScanHints hints,
    ScanResolution footer,
  ) async {
    Future<ScanResolution?> supported(
      PaginableList<MtgCard> found, {
      required ScanEvidence identity,
    }) async {
      if (found.data.isEmpty) return null;
      final ScanResolution scored = await _candidates(
        crop,
        hints,
        found.data,
        hasMore: found.hasMore,
      );
      final List<ScanCandidate> candidates = scored.candidates
          .where(
            (ScanCandidate candidate) =>
                candidate.evidence.contains(identity) &&
                !candidate.evidence.contains(ScanEvidence.nameMismatch) &&
                !candidate.evidence.contains(ScanEvidence.rulesTextMismatch),
          )
          .toList();
      if (candidates.isEmpty) return null;
      return ScanResolution(
        candidates: List<ScanCandidate>.unmodifiable(candidates),
        hints: hints,
        status: ScanResolutionStatus.needsReview,
        hasMore: found.hasMore,
      );
    }

    for (final String title in hints.names.take(3)) {
      if (title.isEmpty) continue;
      final ScanResolution? constrained = await supported(
        await catalog.printings(
          title,
          setCode: hints.setCode,
          language: hints.language,
        ),
        identity: ScanEvidence.nameMatch,
      );
      if (constrained != null) return constrained;
      if (hints.setCode != null) {
        final ScanResolution? unconstrained = await supported(
          await catalog.printings(title, language: hints.language),
          identity: ScanEvidence.nameMatch,
        );
        if (unconstrained != null) return unconstrained;
      }
    }
    final String? phrase = rulesSearchPhrase(hints.rulesText);
    if (phrase != null) {
      final ScanResolution? body = await supported(
        await catalog.rulesTextPrintings(
          phrase,
          language: hints.language,
          typeLine: hints.typeLine,
        ),
        identity: ScanEvidence.rulesTextMatch,
      );
      if (body != null) return body;
    }
    final List<ScanCandidate> corroborated =
        crop.rectified && !ScanHints.fromCrop(crop).hasConflictingFooter
        ? footer.candidates.where((ScanCandidate candidate) {
            return candidate.evidence.containsAll(const <ScanEvidence>{
                  ScanEvidence.footerMatch,
                  ScanEvidence.collectorNumberMatch,
                  ScanEvidence.languageMatch,
                  ScanEvidence.rulesTextMatch,
                  ScanEvidence.typeLineMatch,
                  ScanEvidence.nameMismatch,
                }) &&
                !candidate.evidence.any(
                  (ScanEvidence evidence) => const <ScanEvidence>{
                    ScanEvidence.printingMismatch,
                    ScanEvidence.languageMismatch,
                    ScanEvidence.rulesTextMismatch,
                  }.contains(evidence),
                ) &&
                _nameDistance(candidate.card, hints.names) <= .25;
          }).toList()
        : <ScanCandidate>[];
    return ScanResolution(
      candidates: List<ScanCandidate>.unmodifiable(corroborated),
      hints: hints,
      status: corroborated.isEmpty
          ? ScanResolutionStatus.noMatch
          : ScanResolutionStatus.needsReview,
    );
  }

  Future<ScanResolution> _keywordPrintings(
    ScanCrop crop,
    ScanHints hints,
    List<MtgCard> discovered, {
    required List<String> keywords,
    String? corroboratedColor,
  }) async {
    final ScanResolution textual = await _candidates(
      ScanCrop(
        imagePath: '',
        width: crop.width,
        height: crop.height,
        rectified: crop.rectified,
        sourceCorners: crop.sourceCorners,
        lines: crop.lines,
        warnings: crop.warnings,
      ),
      hints,
      discovered,
      keywords: keywords,
      corroboratedColor: corroboratedColor,
    );
    if (crop.imagePath.isEmpty && !hasVerifiedLiveBodyLayout(crop)) {
      return textual;
    }
    final Map<String, MtgCard> identities = <String, MtgCard>{};
    for (final ScanCandidate candidate in textual.candidates) {
      if (candidate.hasContradiction ||
          !(candidate.evidence.contains(ScanEvidence.rulesKeywordMatch) ||
              candidate.evidence.contains(ScanEvidence.rulesTextMatch)) ||
          !(candidate.evidence.contains(ScanEvidence.typeLineMatch) ||
              candidate.evidence.contains(ScanEvidence.nameMatch) ||
              (keywords.length == 4 &&
                  candidate.evidence.contains(ScanEvidence.fuzzyName) &&
                  _nameDistance(candidate.card, hints.names) <= .25))) {
        continue;
      }
      identities.putIfAbsent(
        _normalizeName(candidate.card.name),
        () => candidate.card,
      );
    }
    final Map<String, MtgCard> prints = <String, MtgCard>{
      for (final MtgCard card in discovered) card.id: card,
    };
    bool hasMore = identities.length > 3;
    for (final MtgCard identity in identities.values.take(3)) {
      try {
        final PaginableList<MtgCard> found = await catalog.printings(
          identity.name,
          setCode: hints.setCode,
          language: hints.language,
        );
        final List<MtgCard> matching = <String, MtgCard>{
          for (final MtgCard card in found.data)
            if (_matchesName(card, identity.name)) card.id: card,
        }.values.toList();
        hasMore = hasMore || found.hasMore || matching.length > 32;
        if (matching.isEmpty) continue;
        prints.removeWhere(
          (String id, MtgCard card) => _matchesName(card, identity.name),
        );
        for (final MtgCard card in matching.take(32)) {
          if (!prints.containsKey(card.id) && prints.length >= 96) {
            hasMore = true;
            break;
          }
          prints[card.id] = card;
        }
      } catch (_) {
        // Keep discovered textual matches available when optional printing expansion fails.
        hasMore = true;
      }
    }
    return _candidates(
      crop,
      hints,
      prints.values.toList(),
      keywords: keywords,
      corroboratedColor: corroboratedColor,
      reliableBodyFallback: hasVerifiedSavedVisualLayout(crop),
      hasMore: hasMore,
      completeIdentitySearch: !hasMore,
    );
  }

  Future<ScanResolution> _candidates(
    ScanCrop crop,
    ScanHints hints,
    List<MtgCard> incomingCards, {
    bool footer = false,
    bool reliableBodyFallback = false,
    bool fuzzy = false,
    List<String> keywords = const <String>[],
    String? corroboratedColor,
    bool hasMore = false,
    int page = 1,
    bool completeIdentitySearch = false,
    bool savedSelfReferenceFooter = false,
    bool allowFailedBasicSetVisual = false,
    bool allowSceneFooterSimilarity = false,
    Map<String, double>? discoveredArtwork,
  }) async {
    final List<MtgCard> cards = incomingCards
        .where((MtgCard card) => card.games.contains(Game.paper))
        .toList();
    if (cards.isEmpty) {
      return ScanResolution(
        candidates: const <ScanCandidate>[],
        hints: hints,
        status: ScanResolutionStatus.noMatch,
        hasMore: hasMore,
        page: page,
      );
    }
    final List<String> observedIllustrators = _observedIllustrators(crop);
    final Set<int> copyrightYears = _observedCopyrightYears(crop);
    final List<String> weakIllustrators = _observedIllustrators(
      crop,
      minimumConfidence: .5,
    );
    final Set<int> weakYears = _observedCopyrightYears(
      crop,
      minimumConfidence: .5,
    );
    final _SoftFooterRead softFooter = _softFooterHints(crop);
    final bool completeExactIdentity =
        page == 1 &&
        !hasMore &&
        cards.isNotEmpty &&
        hints.names.any((String name) => _matchesName(cards.first, name)) &&
        cards.every(
          (MtgCard card) =>
              _normalizeName(card.name) == _normalizeName(cards.first.name),
        );
    final Set<String> validSoftNumbers = completeExactIdentity
        ? softFooter.numbers.intersection(
            cards.map((MtgCard card) => _number(card.collectorNumber)).toSet(),
          )
        : const <String>{};
    final String? softNumber = validSoftNumbers.length == 1
        ? validSoftNumbers.single
        : null;
    String? similarNumber;
    final String? energyGlyph = _observedEnergyGlyph(crop, hints.rulesText);
    int metadataPriority(MtgCard card) =>
        (weakIllustrators.isNotEmpty &&
                <String>[
                  if (card.artist != null) card.artist!,
                  ...?card.cardFaces
                      ?.map((CardFace face) => face.artist)
                      .whereType<String>(),
                ].any(
                  (String artist) =>
                      _illustratorMatches(artist, weakIllustrators),
                )
            ? 12
            : 0) +
        (weakYears.length == 1 && weakYears.contains(card.releasedAt.year)
            ? 3
            : 0) +
        (softNumber != null && softNumber == _number(card.collectorNumber)
            ? 8
            : 0) +
        (similarNumber != null && similarNumber == _number(card.collectorNumber)
            ? 8
            : 0) +
        (completeExactIdentity &&
                softFooter.setCode != null &&
                softFooter.setCode == card.set.toLowerCase()
            ? 2
            : 0);
    final bool savedVisual =
        reliableBodyFallback || hasVerifiedSavedVisualLayout(crop);
    final String? literalSelfReference = ScanHints.observedBodySelfReference(
      crop,
    );
    final RegExp? literalSelfReferenceRow = literalSelfReference == null
        ? null
        : RegExp(
            '^As ${RegExp.escape(literalSelfReference)} enters(?: the battlefield)?[,.:]?\$',
          );
    final List<ScanCandidate> scored = cards.map((MtgCard card) {
      final Set<ScanEvidence> evidence = <ScanEvidence>{};
      if (footer) {
        evidence.add(ScanEvidence.footerMatch);
      }
      if (hints.names.isNotEmpty) {
        final Set<String> observedColors = hints.names
            .expand((String name) => _words(name, ''))
            .where(_colors.contains)
            .toSet();
        final Set<String> nameColors = _words(
          card.name,
          '',
        ).where(_colors.contains).toSet();
        if (observedColors.length == 1 &&
            nameColors.isNotEmpty &&
            !nameColors.contains(observedColors.single)) {
          evidence.add(ScanEvidence.nameMismatch);
        } else if (hints.names.any((String name) => _matchesName(card, name))) {
          evidence.add(ScanEvidence.nameMatch);
        } else {
          evidence.add(
            fuzzy ||
                    (keywords.isNotEmpty &&
                        _nameDistance(card, hints.names) <= .25)
                ? ScanEvidence.fuzzyName
                : ScanEvidence.nameMismatch,
          );
        }
      }
      if (hints.setCode != null && hints.setCode != card.set.toLowerCase()) {
        evidence.add(ScanEvidence.printingMismatch);
      }
      if (hints.collectorNumber != null) {
        evidence.add(
          _number(hints.collectorNumber!) == _number(card.collectorNumber)
              ? ScanEvidence.collectorNumberMatch
              : ScanEvidence.printingMismatch,
        );
      }
      if (hints.language != null) {
        evidence.add(
          hints.language == card.lang.json
              ? ScanEvidence.languageMatch
              : ScanEvidence.languageMismatch,
        );
      }
      final List<String> texts = <String>[
        if (card.oracleText != null) card.oracleText!,
        if (card.printedText != null) card.printedText!,
        ...?card.cardFaces?.expand(
          (CardFace face) => <String>[
            if (face.oracleText != null) face.oracleText!,
            if (face.printedText != null) face.printedText!,
          ],
        ),
      ];
      final List<String> types = <String>[
        card.typeLine,
        ...?card.cardFaces?.map((CardFace face) => face.typeLine ?? ''),
      ];
      if (corroboratedColor != null) {
        final Set<String> rulesColors = texts
            .expand((String text) => _words(text, ''))
            .where(_colors.contains)
            .toSet();
        if (rulesColors.isNotEmpty &&
            !rulesColors.contains(corroboratedColor)) {
          evidence.add(ScanEvidence.rulesTextMismatch);
        }
      }
      final List<String> flavor = <String>[
        if (card.flavorText != null) card.flavorText!,
        ...?card.cardFaces
            ?.map((CardFace face) => face.flavorText)
            .whereType<String>(),
      ];
      final Set<String> artists = <String>{
        if (card.artist != null) _normalizeName(card.artist!),
        ...?card.cardFaces
            ?.map((CardFace face) => face.artist)
            .whereType<String>()
            .map(_normalizeName),
      };
      if (observedIllustrators.isNotEmpty &&
          <String>[
            if (card.artist != null) card.artist!,
            ...?card.cardFaces
                ?.map((CardFace face) => face.artist)
                .whereType<String>(),
          ].any(
            (String artist) =>
                _illustratorMatches(artist, observedIllustrators),
          )) {
        evidence.add(ScanEvidence.illustratorMatch);
      }
      if (copyrightYears.length == 1 &&
          copyrightYears.contains(card.releasedAt.year)) {
        evidence.add(ScanEvidence.copyrightYearMatch);
      }
      if (savedSelfReferenceFooter &&
          _savedSelfReferenceFooterMatches(crop, card)) {
        evidence.addAll(const <ScanEvidence>{
          ScanEvidence.illustratorMatch,
          ScanEvidence.copyrightYearMatch,
        });
      }
      if (keywords.isNotEmpty &&
          texts.any(
            (String text) => _words(text, '').toSet().containsAll(keywords),
          )) {
        evidence.add(ScanEvidence.rulesKeywordMatch);
      }
      if (hints.typeLine != null &&
          types.any(
            (String type) => type.toLowerCase().contains(hints.typeLine!),
          )) {
        evidence.add(ScanEvidence.typeLineMatch);
      }
      if (texts.isNotEmpty) {
        bool matched = false;
        bool contradicted = false;
        for (final ({List<String> lines, bool mayMatch}) group
            in <({List<String> lines, bool mayMatch})>[
              (lines: hints.rulesText, mayMatch: true),
              (lines: hints.postQuoteText, mayMatch: false),
            ]) {
          if (group.lines.isEmpty) continue;
          for (final String observation in _observations(
            _rulesWithoutFlavorDuplicates(
              crop,
              group.lines
                  .where(
                    (String line) => !artists.contains(_normalizeName(line)),
                  )
                  .toList(),
              flavor,
              card.name,
            ),
          )) {
            final List<String> observed = _words(
              _energyComparison(observation, energyGlyph),
              card.name,
            );
            if (observed.length < 4) {
              continue;
            }
            if (_matchesFlavor(observed, flavor, card.name)) {
              continue;
            }
            double best = 0;
            bool compatible = false;
            bool semanticConflict = false;
            for (final String text in texts) {
              final List<String> reference = _words(text, card.name);
              final Set<String> words = reference.toSet();
              final double overlap =
                  observed.where(words.contains).length / observed.length;
              if (overlap > best) {
                best = overlap;
              }
              final Set<String> observedNumbers = observed
                  .where((String word) => RegExp(r'^\d+$').hasMatch(word))
                  .toSet();
              final Set<String> referenceNumbers = reference
                  .where((String word) => RegExp(r'^\d+$').hasMatch(word))
                  .toSet();
              final bool numbersConflict =
                  observedNumbers.isNotEmpty &&
                  referenceNumbers.isNotEmpty &&
                  !referenceNumbers.containsAll(observedNumbers);
              final Set<String> qualifiers = observed
                  .where(
                    (String word) => word.startsWith('non') && word.length > 5,
                  )
                  .toSet();
              final bool qualifiersConflict =
                  qualifiers.isNotEmpty && !words.containsAll(qualifiers);
              const Set<String> colors = <String>{
                'white',
                'blue',
                'black',
                'red',
                'green',
              };
              final Set<String> observedColors = observed
                  .where(colors.contains)
                  .toSet();
              final Set<String> referenceColors = words.intersection(colors);
              final bool colorsConflict =
                  observedColors.isNotEmpty &&
                  referenceColors.isNotEmpty &&
                  !referenceColors.containsAll(observedColors);
              if (overlap >= .60 &&
                  (numbersConflict || qualifiersConflict || colorsConflict)) {
                semanticConflict = true;
              }
              if (overlap >= .80 &&
                  !numbersConflict &&
                  !qualifiersConflict &&
                  !colorsConflict) {
                compatible = true;
              }
            }
            if (compatible) {
              if (group.mayMatch) matched = true;
            } else if (semanticConflict ||
                best >= .80 ||
                (best < .35 &&
                    (rulesSearchPhrase(<String>[observation]) != null ||
                        literalSelfReferenceRow?.hasMatch(observation.trim()) ==
                            true))) {
              contradicted = true;
            }
          }
        }
        if (matched) {
          evidence.add(ScanEvidence.rulesTextMatch);
        }
        if (contradicted) {
          evidence.add(ScanEvidence.rulesTextMismatch);
        }
      }
      return ScanCandidate(card, Set<ScanEvidence>.unmodifiable(evidence));
    }).toList();
    final ScanHints authoritativeFooter = ScanHints.fromCrop(crop);
    if (completeExactIdentity &&
        validSoftNumbers.isEmpty &&
        cards.first.illustrationId != null &&
        cards.map((MtgCard card) => card.illustrationId).toSet().length == 1 &&
        cards.map((MtgCard card) => card.set).toSet().length == 1 &&
        hints.collectorNumber == null &&
        authoritativeFooter.collectorNumber == null &&
        !authoritativeFooter.hasConflictingFooter &&
        hasVerifiedSavedVisualLayout(crop)) {
      final ScanHints reliable = ScanHints.fromCrop(
        crop,
        minimumConfidence: .85,
      );
      final String? sceneToken =
          allowSceneFooterSimilarity && softFooter.numbers.isEmpty
          ? _sceneCollectorToken(crop, cards)
          : null;
      final Set<String> near = <String>{
        for (final ScanCandidate candidate in scored)
          if (!candidate.hasContradiction &&
              candidate.evidence.containsAll(const <ScanEvidence>{
                ScanEvidence.nameMatch,
                ScanEvidence.typeLineMatch,
                ScanEvidence.rulesTextMatch,
              }) &&
              reliable.names.any(
                (String name) => _matchesName(candidate.card, name),
              ) &&
              reliable.typeLine != null &&
              candidate.card.typeLine.toLowerCase().contains(
                reliable.typeLine!,
              ) &&
              RegExp(r'^\d{3,5}$')
                  .hasMatch(_number(candidate.card.collectorNumber)) &&
              (softFooter.numbers.any(
                    (String observed) =>
                        RegExp(r'^\d{3,5}$').hasMatch(observed) &&
                        observed.length ==
                            _number(candidate.card.collectorNumber).length &&
                        _oneLetterDifference(
                          observed,
                          _number(candidate.card.collectorNumber),
                        ),
                  ) ||
                  (sceneToken != null &&
                      _sceneCollectorNear(sceneToken, candidate.card))))
            _number(candidate.card.collectorNumber),
      };
      if (near.length == 1 &&
          scored
                  .where(
                    (ScanCandidate candidate) =>
                        _number(candidate.card.collectorNumber) == near.single,
                  )
                  .length ==
              1) {
        similarNumber = near.single;
        for (int index = 0; index < scored.length; index++) {
          final ScanCandidate candidate = scored[index];
          if (_number(candidate.card.collectorNumber) == similarNumber &&
              !candidate.hasContradiction &&
              candidate.evidence.containsAll(const <ScanEvidence>{
                ScanEvidence.nameMatch,
                ScanEvidence.typeLineMatch,
                ScanEvidence.rulesTextMatch,
              })) {
            scored[index] = ScanCandidate(
              candidate.card,
              Set<ScanEvidence>.unmodifiable(<ScanEvidence>{
                ...candidate.evidence,
                ScanEvidence.collectorNumberSimilar,
              }),
            );
          }
        }
      }
    }
    final Map<String, int> order = <String, int>{
      for (int index = 0; index < cards.length; index++) cards[index].id: index,
    };
    final Map<String, int> metadataOrder = <String, int>{
      for (final MtgCard card in cards) card.id: metadataPriority(card),
    };
    scored.sort((ScanCandidate a, ScanCandidate b) {
      final int score = b.score.compareTo(a.score);
      if (score == 0) {
        final int metadata = metadataOrder[b.card.id]!.compareTo(
          metadataOrder[a.card.id]!,
        );
        if (metadata != 0) return metadata;
      }
      if (score == 0 && keywords.isNotEmpty && hints.names.isNotEmpty) {
        final int title = _nameDistance(
          a.card,
          hints.names,
        ).compareTo(_nameDistance(b.card, hints.names));
        if (title != 0) return title;
      }
      return score == 0
          ? order[a.card.id]!.compareTo(order[b.card.id]!)
          : score;
    });
    final bool sharedVisualReferences =
        completeExactIdentity &&
        !fuzzy &&
        savedVisual &&
        cards.first.illustrationId != null &&
        cards.first.illustrationId!.isNotEmpty &&
        cards.every(
          (MtgCard card) =>
              card.illustrationId == cards.first.illustrationId &&
              card.set.toLowerCase() == cards.first.set.toLowerCase(),
        );
    final bool needsVisual =
        !sharedVisualReferences &&
        (!footer ||
            scored.length != 1 ||
            !scored.first.evidence.contains(ScanEvidence.nameMatch) ||
            scored.first.hasContradiction);
    Future<Map<String, double>> artworkDistances() async {
      if (discoveredArtwork != null) return discoveredArtwork;
      if (!needsVisual || crop.imagePath.isEmpty) {
        return const <String, double>{};
      }
      try {
        final List<ScanCandidate> visual = savedVisual
            ? _visualPrintShortlist(
                scored,
                allowFailedBasicSetVisual: allowFailedBasicSetVisual,
              )
            : scored.take(12).toList();
        if (allowFailedBasicSetVisual && visual.isEmpty) {
          return const <String, double>{};
        }
        return await artwork.compare(
          crop,
          visual.map((ScanCandidate candidate) => candidate.card).toList(),
          reliableBodyFallback: savedVisual,
        );
      } catch (_) {
        // Optional visual ranking cannot prevent textual identification.
        return const <String, double>{};
      }
    }

    Future<Map<String, double>> setDistances() async {
      if (!needsVisual || crop.imagePath.isEmpty) {
        return const <String, double>{};
      }
      try {
        final List<ScanCandidate> visual = savedVisual
            ? _symbolPrintShortlist(
                scored,
                allowFailedBasicSetVisual: allowFailedBasicSetVisual,
              )
            : scored.take(12).toList();
        if (allowFailedBasicSetVisual && visual.isEmpty) {
          return const <String, double>{};
        }
        return await symbols.compare(
          crop,
          visual.map((ScanCandidate candidate) => candidate.card).toList(),
        );
      } catch (_) {
        // Optional visual evidence cannot prevent text recognition.
        return const <String, double>{};
      }
    }

    final List<Map<String, double>> visualDistances =
        await Future.wait<Map<String, double>>(<Future<Map<String, double>>>[
          artworkDistances(),
          setDistances(),
        ]);
    final Map<String, double> distances = visualDistances[0];
    final Map<String, double> symbolDistances = visualDistances[1];
    final List<ScanCandidate> ranked = scored.map((ScanCandidate candidate) {
      final double? distance = distances[candidate.card.id];
      final double? symbolDistance = symbolDistances[candidate.card.id];
      return ScanCandidate(
        candidate.card,
        <ScanEvidence>{
          ...candidate.evidence,
          if (distance != null) ScanEvidence.artworkCompared,
          if (symbolDistance != null) ScanEvidence.symbolCompared,
        },
        artworkDistance: distance,
        symbolDistance: symbolDistance,
      );
    }).toList();
    _rankVisual(
      ranked,
      (ScanCandidate candidate) => candidate.artworkDistance,
      (ScanCandidate candidate) => '${candidate.score}',
    );
    _rankVisual(
      ranked,
      (ScanCandidate candidate) => candidate.symbolDistance,
      (ScanCandidate candidate) =>
          '${candidate.score}/${candidate.artworkDistance}',
    );
    final bool exact =
        footer &&
        similarNumber == null &&
        ranked.length == 1 &&
        ranked.first.evidence.contains(ScanEvidence.nameMatch) &&
        !ranked.first.hasContradiction &&
        crop.rectified &&
        crop.warnings.isEmpty;
    final ScanResolution resolution = ScanResolution(
      candidates: List<ScanCandidate>.unmodifiable(ranked),
      hints: hints,
      status: exact
          ? ScanResolutionStatus.exactPrinting
          : ScanResolutionStatus.needsReview,
      hasMore: hasMore,
      page: page,
    );
    final String? historicalIdentity = completeIdentitySearch && !hasMore
        ? verifiedHistoricalBodyIdentity(crop, resolution) ??
              _liveHistoricalBodyIdentity(crop, resolution, requireProof: false)
        : null;
    if (historicalIdentity == null) return resolution;
    return ScanResolution(
      candidates: resolution.candidates,
      hints: resolution.hints,
      status: resolution.status,
      hasMore: resolution.hasMore,
      page: resolution.page,
      historicalBodyIdentityProof: HistoricalBodyIdentityProof(
        name: historicalIdentity,
        bodySignature: _historicalBodySignature(crop),
      ),
    );
  }

  static String _historicalBodySignature(ScanCrop crop) {
    final ScanHints hints = ScanHints.fromCrop(crop);
    final List<String> illustrators = _observedIllustrators(crop)..sort();
    final List<int> years = _observedCopyrightYears(crop).toList()..sort();
    return jsonEncode(<String, Object?>{
      'type': hints.typeLine,
      'rules': hints.rulesText,
      'postQuoteText': hints.postQuoteText,
      'illustrators': illustrators,
      'years': years,
    });
  }

  static List<ScanCandidate> _visualPrintShortlist(
    List<ScanCandidate> candidates, {
    bool allowFailedBasicSetVisual = false,
  }) {
    final Set<String> illustrations = <String>{};
    final List<ScanCandidate> selected = <ScanCandidate>[];
    for (final ScanCandidate candidate in candidates) {
      if (candidate.hasContradiction &&
          !(allowFailedBasicSetVisual &&
              _hasOnlyFailedSetContradiction(candidate))) {
        continue;
      }
      final String illustration =
          candidate.card.illustrationId ?? candidate.card.id;
      if (!illustrations.contains(illustration) && illustrations.length >= 32) {
        continue;
      }
      illustrations.add(illustration);
      selected.add(candidate);
      if (selected.length == 96) break;
    }
    return selected;
  }

  static List<ScanCandidate> _symbolPrintShortlist(
    List<ScanCandidate> candidates, {
    bool allowFailedBasicSetVisual = false,
  }) {
    final Set<String> sets = <String>{};
    final List<ScanCandidate> selected = <ScanCandidate>[];
    for (final ScanCandidate candidate in candidates) {
      if (candidate.hasContradiction &&
          !(allowFailedBasicSetVisual &&
              _hasOnlyFailedSetContradiction(candidate))) {
        continue;
      }
      if (!sets.contains(candidate.card.set) && sets.length >= 32) continue;
      sets.add(candidate.card.set);
      selected.add(candidate);
      if (selected.length == 96) break;
    }
    return selected;
  }

  static bool _hasOnlyFailedSetContradiction(ScanCandidate candidate) =>
      candidate.evidence.containsAll(const <ScanEvidence>{
        ScanEvidence.nameMatch,
        ScanEvidence.typeLineMatch,
        ScanEvidence.printingMismatch,
      }) &&
      !candidate.evidence.any(
        (ScanEvidence evidence) => const <ScanEvidence>{
          ScanEvidence.nameMismatch,
          ScanEvidence.rulesTextMismatch,
          ScanEvidence.languageMismatch,
        }.contains(evidence),
      );

  static String? _sceneCollectorToken(ScanCrop crop, List<MtgCard> cards) {
    if (!crop.warnings.contains('border_recovered')) return null;
    final List<ScanTextLine> guides = crop.lines
        .where((ScanTextLine line) => line.sceneFooterGuide)
        .toList();
    if (guides.isEmpty || guides.length > 8) return null;
    final RegExp token = RegExp(
      r'^([CMRULST])\s+(\d{1,3}[A-Z]\d{1,3})$',
      caseSensitive: false,
    );
    final Set<String> observed = <String>{};
    for (final ScanTextLine line in guides) {
      final ScanBounds bounds = line.bounds;
      final RegExpMatch? match = token.firstMatch(line.text.trim());
      if (match == null ||
          match.group(2)!.length > 5 ||
          !line.confidence.isFinite ||
          line.confidence < .85 ||
          line.confidence > 1 ||
          !bounds.x.isFinite ||
          !bounds.y.isFinite ||
          !bounds.width.isFinite ||
          !bounds.height.isFinite ||
          bounds.x < .01 ||
          bounds.x + bounds.width > .99 ||
          bounds.width <= .025 ||
          bounds.width > .8 ||
          bounds.y < .84 ||
          bounds.y + bounds.height > .995 ||
          bounds.height <= 0 ||
          bounds.height > .06 ||
          line.textHeight <= 0 ||
          line.textHeight > .05) {
        return null;
      }
      final String field = match.group(2)!;
      if (cards.any(
        (MtgCard card) => _number(card.collectorNumber) == _number(field),
      )) {
        return null;
      }
      observed.add('${match.group(1)!.toUpperCase()}${field.toUpperCase()}');
    }
    return observed.length == 1 ? observed.single : null;
  }

  static bool _sceneCollectorNear(String observed, MtgCard card) {
    final String? rarity = switch (card.rarity) {
      Rarity.common => 'C',
      Rarity.uncommon => 'U',
      Rarity.rare => 'R',
      Rarity.mythic => 'M',
      Rarity.special => 'S',
      _ => null,
    };
    final String number = _number(card.collectorNumber);
    final int width = observed.length - 1;
    if (rarity == null ||
        number.length > width ||
        !RegExp(r'^\d{3,5}$').hasMatch(number)) {
      return false;
    }
    return _oneLetterDifference(
      observed,
      '$rarity${number.padLeft(width, '0')}',
    );
  }

  static _SoftFooterRead _softFooterHints(ScanCrop crop) {
    final List<ScanTextLine> lines = crop.lines
        .where(
          (ScanTextLine line) =>
              line.confidence >= .3 &&
              line.confidence <= 1 &&
              line.bounds.y >= .84 &&
              line.bounds.y + line.bounds.height <= .995 &&
              line.bounds.x >= .01 &&
              line.bounds.x + line.bounds.width <= .99 &&
              line.bounds.width > .025 &&
              line.bounds.width <= .8 &&
              line.bounds.height > 0 &&
              line.bounds.height <= .06 &&
              line.textHeight > 0 &&
              line.textHeight <= .05,
        )
        .take(64)
        .toList();
    ScanCrop footerCrop(List<ScanTextLine> observations) => ScanCrop(
      imagePath: crop.imagePath,
      width: crop.width,
      height: crop.height,
      rectified: crop.rectified,
      sourceCorners: crop.sourceCorners,
      warnings: crop.warnings,
      lines: observations,
    );
    final ScanHints detected = ScanHints.fromCrop(
      footerCrop(lines),
      minimumFooterConfidence: .3,
    );
    final Set<String> numbers = lines
        .map(
          (ScanTextLine line) => ScanHints.fromCrop(
            footerCrop(<ScanTextLine>[line]),
            minimumFooterConfidence: .3,
          ).collectorNumber,
        )
        .whereType<String>()
        .map(_number)
        .toSet();
    final bool rarity = lines.any(
      (ScanTextLine line) => RegExp(
        r'^(?:[CMRULST]\s+\d{2,5}[a-z★†]*(?:\s*/\s*\d{1,5})?|\d{2,5}[a-z★†]*(?:\s*/\s*\d{1,5})?\s+[CMRULST])$',
        caseSensitive: false,
      ).hasMatch(line.text.trim()),
    );
    final bool structuredSet = lines.any(
      (ScanTextLine line) => RegExp(
        r'^[A-Z0-9]{3,5}(?:\s*[•·∙]\s*|\s+)(?:EN|ES|FR|DE|IT|PT|JA|KO|RU|ZHS|ZHT|HE|LA|GRC|AR|SA|PH|QYA)\b',
        caseSensitive: false,
      ).hasMatch(line.text.trim()),
    );
    final bool context =
        rarity ||
        (structuredSet &&
            detected.setCode != null &&
            detected.language != null);
    return (
      setCode: context ? detected.setCode : null,
      numbers: context
          ? Set<String>.unmodifiable(<String>{
              ...numbers,
              if (detected.collectorNumber != null)
                _number(detected.collectorNumber!),
            })
          : const <String>{},
    );
  }

  static bool _printingFooterLine(
    ScanTextLine line, {
    double minimumConfidence = .85,
  }) =>
      line.confidence >= minimumConfidence &&
      line.bounds.x >= 0 &&
      line.bounds.x < .75 &&
      line.bounds.y >= .82 &&
      line.bounds.y + line.bounds.height <= 1.02 &&
      line.bounds.width > 0 &&
      line.bounds.width <= .85 &&
      line.bounds.x + line.bounds.width <= 1.02 &&
      line.bounds.height > 0 &&
      line.bounds.height <= .06 &&
      line.textHeight > 0 &&
      line.textHeight <= .05;

  static List<String> _observedIllustrators(
    ScanCrop crop, {
    double minimumConfidence = .85,
  }) {
    if (!crop.rectified && !hasVerifiedLiveBodyLayout(crop)) return <String>[];
    final Set<String> artists = crop.lines
        .map(
          (ScanTextLine line) =>
              _illustratorCredit(line, minimumConfidence: minimumConfidence),
        )
        .whereType<String>()
        .toSet();
    final List<ScanTextLine> footer = crop.lines
        .where(
          (ScanTextLine line) =>
              _printingFooterLine(line, minimumConfidence: minimumConfidence),
        )
        .toList();
    final RegExp incompleteCredit = RegExp(
      r'^(?:illus(?:trated)?|illun|lllus|fllus|illvs)\.?\s+(?:by\s+)?[\p{L}][\p{L}\s.\x27’&-]+$',
      caseSensitive: false,
      unicode: true,
    );
    final RegExp continuation = RegExp(
      r'^[\p{L}][\p{L}\s.\x27’&-]+$',
      unicode: true,
    );
    for (final ScanTextLine first in footer) {
      if (_illustratorCredit(first, minimumConfidence: minimumConfidence) !=
              null ||
          !incompleteCredit.hasMatch(first.text.trim())) {
        continue;
      }
      for (final ScanTextLine second in footer) {
        final double gap =
            second.bounds.x - first.bounds.x - first.bounds.width;
        if (identical(first, second) ||
            (first.bounds.y - second.bounds.y).abs() > .018 ||
            gap < -.015 ||
            gap > .025 ||
            !continuation.hasMatch(second.text.trim()) ||
            _words(second.text, '').length > 3) {
          continue;
        }
        final double y = first.bounds.y < second.bounds.y
            ? first.bounds.y
            : second.bounds.y;
        final double bottom =
            first.bounds.y + first.bounds.height >
                second.bounds.y + second.bounds.height
            ? first.bounds.y + first.bounds.height
            : second.bounds.y + second.bounds.height;
        final String? artist = _illustratorCredit(
          ScanTextLine(
            text: '${first.text.trim()} ${second.text.trim()}',
            confidence: first.confidence < second.confidence
                ? first.confidence
                : second.confidence,
            glyphHeight: first.textHeight > second.textHeight
                ? first.textHeight
                : second.textHeight,
            bounds: ScanBounds(
              first.bounds.x,
              y,
              second.bounds.x + second.bounds.width - first.bounds.x,
              bottom - y,
            ),
          ),
          minimumConfidence: minimumConfidence,
        );
        if (artist != null) artists.add(artist);
      }
    }
    return artists.toList();
  }

  static bool _savedSelfReferenceFooterMatches(ScanCrop crop, MtgCard card) {
    if (!crop.rectified) return false;
    final RegExp copyright = RegExp(
      r'(?:©|copyright)\s*(19\d{2}|20\d{2})(?:\s*[-–]\s*(19\d{2}|20\d{2}))?\b',
      caseSensitive: false,
    );
    final List<(ScanTextLine, int)> years = <(ScanTextLine, int)>[];
    for (final ScanTextLine line in crop.lines) {
      if (!_printingFooterLine(line) ||
          line.confidence < .90 ||
          line.bounds.y < .90) {
        continue;
      }
      for (final RegExpMatch match in copyright.allMatches(line.text)) {
        final int start = int.parse(match.group(1)!);
        final int end = int.parse(match.group(2) ?? match.group(1)!);
        if (end >= start) years.add((line, end));
      }
    }
    final Set<int> endYears = years
        .map(((ScanTextLine, int) value) => value.$2)
        .toSet();
    if (endYears.length != 1 || endYears.single != card.releasedAt.year) {
      return false;
    }
    final Set<String> credits = <String>{};
    for (final ScanTextLine line in crop.lines) {
      if (!_printingFooterLine(line) ||
          line.confidence < .90 ||
          line.bounds.y < .88 ||
          line.bounds.width > .65 ||
          !years.any(
            ((ScanTextLine, int) value) =>
                value.$1.bounds.y - line.bounds.y >= .005 &&
                value.$1.bounds.y - line.bounds.y <= .08 &&
                (value.$1.bounds.x - line.bounds.x).abs() <= .15,
          )) {
        continue;
      }
      final String text =
          _illustratorCredit(line) ??
          line.text.trim().replaceFirst(RegExp(r'^[~—–-]\s*'), '');
      if (RegExp(
            r'^[\p{L}][\p{L}\s.\x27’&-]+$',
            unicode: true,
          ).hasMatch(text) &&
          _words(text, '').length >= 2 &&
          _words(text, '').length <= 6) {
        credits.add(_normalizeName(text));
      }
    }
    if (credits.length != 1) return false;
    return <String>[
      if (card.artist != null) card.artist!,
      ...?card.cardFaces
          ?.map((CardFace face) => face.artist)
          .whereType<String>(),
    ].any((String artist) => _normalizeName(artist) == credits.single);
  }

  static bool _liveHistoricalMetadataMatches(ScanCrop crop, MtgCard card) {
    if (!hasVerifiedLiveBodyLayout(crop)) return false;
    final Set<String> artists = crop.lines
        .where(
          (ScanTextLine line) =>
              line.confidence >= .90 &&
              line.glyphHeight != null &&
              line.glyphHeight!.isFinite &&
              line.glyphHeight! > 0 &&
              line.textHeight <= .05,
        )
        .map(_illustratorCredit)
        .whereType<String>()
        .map(_normalizeName)
        .toSet();
    final Set<String> expectedArtists = <String>{
      if (card.artist != null) _normalizeName(card.artist!),
      ...?card.cardFaces
          ?.map((CardFace face) => face.artist)
          .whereType<String>()
          .map(_normalizeName),
    };
    if (artists.intersection(expectedArtists).isEmpty) return false;
    final Set<int> years = <int>{};
    final RegExp copyright = RegExp(
      r'(?:©|copyright)\s*(19\d{2}|20\d{2})(?:\s*[-–]\s*(19\d{2}|20\d{2}))?\b',
      caseSensitive: false,
    );
    for (final ScanTextLine line in crop.lines) {
      if (!_printingFooterLine(line) ||
          line.confidence < .90 ||
          line.glyphHeight == null ||
          !line.glyphHeight!.isFinite ||
          line.glyphHeight! <= 0 ||
          line.textHeight > .05) {
        continue;
      }
      for (final RegExpMatch match in copyright.allMatches(line.text)) {
        final int start = int.parse(match.group(1)!);
        final int end = int.parse(match.group(2) ?? match.group(1)!);
        if (end < start) return false;
        years.add(end);
      }
    }
    return years.length == 1 && years.single == card.releasedAt.year;
  }

  static String? _illustratorCredit(
    ScanTextLine line, {
    double minimumConfidence = .85,
  }) {
    if (!_printingFooterLine(line, minimumConfidence: minimumConfidence)) {
      return null;
    }
    final RegExp label = RegExp(
      r'^(?:illus(?:trated)?|illun|lllus|fllus|illvs)\.?\s+(?:by\s+)?([\p{L}][\p{L}\s.\x27’&-]+)$',
      caseSensitive: false,
      unicode: true,
    );
    final RegExpMatch? match = label.firstMatch(line.text.trim());
    final String? artist = match
        ?.group(1)
        ?.trim()
        .replaceFirst(RegExp(r'\s+-\s*$'), '');
    return artist != null &&
            _words(artist, '').length >= 2 &&
            _words(artist, '').length <= 6
        ? artist.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')
        : null;
  }

  static bool _illustratorMatches(String artist, List<String> observations) {
    if (observations.any(
      (String observed) => _normalizeName(observed) == _normalizeName(artist),
    )) {
      return true;
    }
    final List<String> reference = _words(artist, '');
    if (reference.length != 2 ||
        reference.any((String word) => word.length < 4)) {
      return false;
    }
    final String normalized = _normalizeName(artist);
    final Set<int> complementaryErrors = <int>{};
    for (final String observation in observations) {
      final String observed = _normalizeName(observation);
      if (observed.length != normalized.length ||
          _words(observation, '').length != reference.length) {
        continue;
      }
      final List<int> different = <int>[
        for (int index = 0; index < normalized.length; index++)
          if (observed[index] != normalized[index]) index,
      ];
      if (different.length == 1) complementaryErrors.add(different.single);
    }
    if (complementaryErrors.length >= 2) return true;
    return observations
            .where((String observed) {
              final List<String> words = _words(observed, '');
              return words.length == reference.length &&
                  words.first == reference.first &&
                  words.last.length >= 6 &&
                  _oneLetterDifference(words.last, reference.last);
            })
            .toSet()
            .length >=
        2;
  }

  static Set<int> _observedCopyrightYears(
    ScanCrop crop, {
    double minimumConfidence = .85,
  }) {
    if (!crop.rectified && !hasVerifiedLiveBodyLayout(crop)) return <int>{};
    final RegExp copyright = RegExp(
      r'(?:©|copyright)\s*(19\d{2}|20\d{2})(?:\s*[-–−]\s*(19\d{2}|20\d{2}))?(?!\s*[-–−])(?=\s|Wizards\b|[.,]|$)',
      caseSensitive: false,
    );
    return crop.lines
        .where(
          (ScanTextLine line) =>
              _printingFooterLine(line, minimumConfidence: minimumConfidence),
        )
        .expand(
          (ScanTextLine line) => copyright
              .allMatches(line.text)
              .where(
                (RegExpMatch match) =>
                    int.parse(match.group(2) ?? match.group(1)!) >=
                    int.parse(match.group(1)!),
              )
              .map(
                (RegExpMatch match) =>
                    int.parse(match.group(2) ?? match.group(1)!),
              ),
        )
        .toSet();
  }

  static void _rankVisual(
    List<ScanCandidate> candidates,
    double? Function(ScanCandidate) distance,
    String Function(ScanCandidate) group,
  ) {
    final Map<String, List<int>> slots = <String, List<int>>{};
    for (int index = 0; index < candidates.length; index++) {
      if (distance(candidates[index]) == null) {
        continue;
      }
      (slots[group(candidates[index])] ??= <int>[]).add(index);
    }
    for (final List<int> indices in slots.values) {
      final List<(int, ScanCandidate)> compared =
          indices.map((int index) => (index, candidates[index])).toList()
            ..sort(((int, ScanCandidate) a, (int, ScanCandidate) b) {
              final int comparison = distance(a.$2)!.compareTo(distance(b.$2)!);
              return comparison == 0 ? a.$1.compareTo(b.$1) : comparison;
            });
      for (int index = 0; index < indices.length; index++) {
        candidates[indices[index]] = compared[index].$2;
      }
    }
  }

  static final RegExp _energyCounterNotation = RegExp(
    r'\bget\s+([0-9])((?:\s*\1){1,4})\s*\((one|two|three|four|five|[1-5])\s+energy\s+counters?\)',
    caseSensitive: false,
  );

  static bool _validEnergyCounterRun(RegExpMatch match) {
    const Map<String, int> quantities = <String, int>{
      'one': 1,
      'two': 2,
      'three': 3,
      'four': 4,
      'five': 5,
      '1': 1,
      '2': 2,
      '3': 3,
      '4': 4,
      '5': 5,
    };
    return quantities[match.group(3)!.toLowerCase()] ==
        1 + RegExp(r'[0-9]').allMatches(match.group(2)!).length;
  }

  static String? _observedEnergyGlyph(ScanCrop crop, List<String> rules) {
    final Set<String> glyphs = <String>{
      for (final ScanTextLine line in crop.lines)
        if (line.confidence >= .85 && rules.contains(line.text.trim()))
          for (final RegExpMatch match in _energyCounterNotation.allMatches(
            line.text,
          ))
            if (_validEnergyCounterRun(match)) match.group(1)!,
    };
    return glyphs.length == 1 ? glyphs.single : null;
  }

  static String _energyComparison(String text, String? glyph) {
    if (glyph == null) return text;
    final String counters = text.replaceAllMapped(_energyCounterNotation, (
      Match match,
    ) {
      final RegExpMatch observed = match as RegExpMatch;
      if (observed.group(1) != glyph || !_validEnergyCounterRun(observed)) {
        return observed.group(0)!;
      }
      return observed.group(0)!.replaceFirst('$glyph${observed.group(2)}', '');
    });
    return counters.replaceAllMapped(
      RegExp(
        r'(\bmay\s+pay\s+an\s+amount\s+of\s+)' +
            RegExp.escape(glyph) +
            r'(?=\s+equal\s+to\b)',
        caseSensitive: false,
      ),
      (Match match) => match.group(1)!,
    );
  }

  static List<String> _observations(List<String> lines) => <String>[
    ...lines.take(12),
    for (int index = 0; index + 1 < lines.length && index < 11; index++)
      if (_words(lines[index], '').length < 4)
        '${lines[index]} ${lines[index + 1]}',
  ];

  static List<String> _rulesWithoutFlavorDuplicates(
    ScanCrop crop,
    List<String> rules,
    List<String> flavor,
    String name,
  ) {
    final List<ScanTextLine> observations = crop.lines
        .where(
          (ScanTextLine line) =>
              line.confidence >= .80 && rules.contains(line.text.trim()),
        )
        .take(24)
        .toList();
    final List<({String text, ScanBounds bounds})> knownFlavor =
        <({String text, ScanBounds bounds})>[
          for (final ScanTextLine line in observations)
            if (_matchesFlavor(_words(line.text, name), flavor, name))
              (text: line.text, bounds: line.bounds),
        ];
    // Rectified hints omit opening quotes; trailing enhanced OCR still belongs to the catalog-backed paragraph.
    final List<ScanTextLine> quotedFlavor = crop.lines
        .where(
          (ScanTextLine line) =>
              line.confidence >= .80 &&
              line.bounds.y >= .65 &&
              line.bounds.y < .86 &&
              line.bounds.width >= .20 &&
              line.bounds.height < .20 &&
              RegExp(r'^["“«]').hasMatch(line.text.trim()) &&
              _matchesFlavor(_words(line.text, name), flavor, name),
        )
        .toList();
    knownFlavor.addAll(
      quotedFlavor.map(
        (ScanTextLine line) => (text: line.text, bounds: line.bounds),
      ),
    );
    final Set<ScanTextLine> splitFlavor = <ScanTextLine>{};
    for (int first = 0; first < observations.length; first++) {
      final ScanTextLine a = observations[first];
      if (a.bounds.y < .65) {
        continue;
      }
      for (int second = first + 1; second < observations.length; second++) {
        final ScanTextLine b = observations[second];
        if (b.bounds.y < .65 || (a.bounds.y - b.bounds.y).abs() > .10) {
          continue;
        }
        final double left = a.bounds.x > b.bounds.x ? a.bounds.x : b.bounds.x;
        final double aRight = a.bounds.x + a.bounds.width;
        final double bRight = b.bounds.x + b.bounds.width;
        final double right = aRight < bRight ? aRight : bRight;
        final double smallerWidth = a.bounds.width < b.bounds.width
            ? a.bounds.width
            : b.bounds.width;
        if (smallerWidth <= 0 || (right - left) / smallerWidth < .50) {
          continue;
        }
        final String text = '${a.text.trim()} ${b.text.trim()}';
        if (!_matchesFlavor(_words(text, name), flavor, name)) {
          continue;
        }
        final double x = a.bounds.x < b.bounds.x ? a.bounds.x : b.bounds.x;
        final double y = a.bounds.y < b.bounds.y ? a.bounds.y : b.bounds.y;
        final double aBottom = a.bounds.y + a.bounds.height;
        final double bBottom = b.bounds.y + b.bounds.height;
        final double bottom = aBottom > bBottom ? aBottom : bBottom;
        if (bottom - y > .20) {
          continue;
        }
        knownFlavor.add((
          text: text,
          bounds: ScanBounds(
            x,
            y,
            (aRight > bRight ? aRight : bRight) - x,
            bottom - y,
          ),
        ));
        splitFlavor.add(a);
        splitFlavor.add(b);
      }
    }
    if (knownFlavor.isEmpty) {
      return rules;
    }
    const Set<String> colors = <String>{
      'white',
      'blue',
      'black',
      'red',
      'green',
    };
    bool duplicate(ScanTextLine line) {
      if (splitFlavor.contains(line)) {
        return true;
      }
      final List<String> words = _words(line.text, name);
      if (words.isNotEmpty &&
          quotedFlavor.any((ScanTextLine anchor) {
            final double smallerWidth = line.bounds.width < anchor.bounds.width
                ? line.bounds.width
                : anchor.bounds.width;
            final double left = line.bounds.x > anchor.bounds.x
                ? line.bounds.x
                : anchor.bounds.x;
            final double lineRight = line.bounds.x + line.bounds.width;
            final double anchorRight = anchor.bounds.x + anchor.bounds.width;
            final double right = lineRight < anchorRight
                ? lineRight
                : anchorRight;
            if (line.bounds.y < anchor.bounds.y ||
                line.bounds.y - anchor.bounds.y > .12 ||
                line.bounds.height >= .20 ||
                smallerWidth <= 0 ||
                (right - left) / smallerWidth < .50) {
              return false;
            }
            return flavor.any((String text) {
              final Set<String> reference = _words(text, name).toSet();
              bool compatible(String word) {
                if (reference.contains(word)) return true;
                final RegExpMatch? suffix = RegExp(
                  r'^([a-z]{6,})([^\x00-\x7F][\p{L}]*)$',
                  unicode: true,
                ).firstMatch(word);
                if (suffix == null) {
                  return false;
                }
                final String prefix = suffix.group(1)!;
                final String noise = suffix.group(2)!;
                if (!RegExp(r'^[\p{L}]+$', unicode: true).hasMatch(noise) ||
                    RegExp(r'[a-z]').allMatches(noise).length > 1) {
                  return false;
                }
                return reference.any(
                  (String value) =>
                      value.length >= 6 &&
                      noise.length <= value.length &&
                      (prefix == value || _oneLetterDifference(prefix, value)),
                );
              }

              return words.every(compatible) &&
                  words.any(
                    (String word) =>
                        word.length >= 4 && reference.contains(word),
                  );
            });
          })) {
        return true;
      }
      final double area = line.bounds.width * line.bounds.height;
      if (words.isEmpty || words.length >= 4 || area <= 0) {
        return false;
      }
      return knownFlavor.any((({String text, ScanBounds bounds}) full) {
        if (full.text.trim().length <= line.text.trim().length ||
            full.bounds.width * full.bounds.height < area * 1.5 ||
            _boundsIntersectionArea(line.bounds, full.bounds) / area < .90) {
          return false;
        }
        final Set<String> reference = _words(full.text, name).toSet();
        if (words.any(
          (String word) =>
              (colors.contains(word) ||
                  RegExp(r'^\d+$').hasMatch(word) ||
                  (word.startsWith('non') && word.length > 5)) &&
              !reference.contains(word),
        )) {
          return false;
        }
        return words.any(
          (String word) =>
              word.length >= 4 &&
              (reference.contains(word) ||
                  reference.any(
                    (String value) =>
                        value.length >= 4 && _oneLetterDifference(word, value),
                  )),
        );
      });
    }

    return rules.where((String text) {
      final List<ScanTextLine> observations = crop.lines
          .where((ScanTextLine line) => line.text.trim() == text)
          .toList();
      return observations.isEmpty || !observations.every(duplicate);
    }).toList();
  }

  static bool _matchesFlavor(
    List<String> observed,
    List<String> flavor,
    String name,
  ) {
    const Set<String> common = <String>{
      'a',
      'an',
      'the',
      'as',
      'at',
      'is',
      'of',
      'to',
      'and',
      'or',
      'on',
      'in',
      'it',
      'its',
      'that',
      'this',
      'you',
      'your',
      'any',
      'all',
      'each',
      'for',
      'from',
      'with',
      'then',
      'are',
      'was',
      'were',
      'has',
      'have',
    };
    const Set<String> colors = <String>{
      'white',
      'blue',
      'black',
      'red',
      'green',
    };
    final Set<String> distinctive = observed
        .where(
          (String word) =>
              word.length >= 4 &&
              !common.contains(word) &&
              !RegExp(r'^\d+$').hasMatch(word),
        )
        .toSet();
    if (distinctive.length < 2) {
      return false;
    }
    for (final String text in flavor) {
      final Set<String> reference = _words(text, name).toSet();
      final double exact =
          observed.where(reference.contains).length / observed.length;
      final double compatible =
          observed
              .where(
                (String word) =>
                    reference.contains(word) ||
                    (word.length >= 6 &&
                        reference.any(
                          (String value) =>
                              value.length >= 6 &&
                              _oneLetterDifference(word, value),
                        )),
              )
              .length /
          observed.length;
      if (exact < .6 ||
          compatible < .8 ||
          distinctive.intersection(reference).length < 2) {
        continue;
      }
      final Set<String> numbers = observed
          .where((String word) => RegExp(r'^\d+$').hasMatch(word))
          .toSet();
      final Set<String> qualifiers = observed
          .where((String word) => word.startsWith('non') && word.length > 5)
          .toSet();
      final Set<String> observedColors = observed
          .where(colors.contains)
          .toSet();
      if (!reference.containsAll(numbers) ||
          !reference.containsAll(qualifiers) ||
          !reference.containsAll(observedColors)) {
        continue;
      }
      return true;
    }
    return false;
  }

  static bool _oneLetterDifference(String a, String b) {
    if ((a.length - b.length).abs() > 1) return false;
    int left = 0;
    int right = 0;
    int edits = 0;
    while (left < a.length && right < b.length) {
      if (a[left] == b[right]) {
        left++;
        right++;
        continue;
      }
      if (++edits > 1) return false;
      if (a.length <= b.length) right++;
      if (a.length >= b.length) left++;
    }
    return edits + (a.length - left) + (b.length - right) <= 1;
  }

  static String _number(String text) =>
      text.toLowerCase().replaceFirst(RegExp(r'^0+(?=\d)'), '');

  static List<String> _words(String text, String name) {
    const Map<String, String> numbers = <String, String>{
      'zero': '0',
      'one': '1',
      'two': '2',
      'three': '3',
      'four': '4',
      'five': '5',
      'six': '6',
      'seven': '7',
      'eight': '8',
      'nine': '9',
      'ten': '10',
    };
    final String normalized = name.isEmpty
        ? text.toLowerCase()
        : text.toLowerCase().replaceAll(name.toLowerCase(), '~');
    return RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(normalized)
        .map((RegExpMatch match) => numbers[match.group(0)!] ?? match.group(0)!)
        .toList();
  }

  static String? rulesSearchPhrase(List<String> lines) {
    const Set<String> generic = <String>{
      'a',
      'an',
      'the',
      'as',
      'at',
      'is',
      'of',
      'to',
      'and',
      'or',
      'on',
      'in',
      'it',
      'its',
      'that',
      'this',
      'you',
      'your',
      'any',
      'all',
      'each',
      'for',
      'from',
      'with',
      'then',
      'target',
      'creature',
      'creatures',
      'card',
      'cards',
      'draw',
      'damage',
      'deals',
      'deal',
      'gain',
      'gains',
      'until',
      'end',
      'turn',
      'three',
      'two',
      'one',
      'may',
    };
    for (final String line in _observations(lines)) {
      final String phrase = line.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (RegExp(
        r'^as .+ enters (?:the battlefield|play)\b',
        caseSensitive: false,
      ).hasMatch(phrase)) {
        continue;
      }
      final List<String> words = _words(phrase, '');
      final Set<String> distinctive = words
          .where(
            (String word) =>
                word.length >= 4 &&
                !generic.contains(word) &&
                !RegExp(r'^\d+$').hasMatch(word),
          )
          .toSet();
      if (phrase.length >= 24 &&
          phrase.length <= 160 &&
          words.length >= 4 &&
          words.length <= 20 &&
          distinctive.length >= 2 &&
          distinctive.any((String word) => word.length >= 7)) {
        return phrase;
      }
    }
    return null;
  }

  static const Set<String> _colors = <String>{
    'white',
    'blue',
    'black',
    'red',
    'green',
  };

  static List<String> _observedTitleAlternatives(ScanCrop crop) {
    final ScanHints reliable = ScanHints.fromCrop(
      crop,
      minimumConfidence: .85,
    );
    if (reliable.typeLine == null ||
        rulesSearchPhrase(reliable.rulesText) == null ||
        reliable.names
                .expand((String name) => _words(name, ''))
                .where(_colors.contains)
                .toSet()
                .length >
            1) {
      return const <String>[];
    }
    final Set<String> result = <String>{};
    for (final ScanTextLine line in crop.lines) {
      if (line.confidence < .85 || !reliable.names.contains(line.text.trim())) {
        continue;
      }
      final String primary = _normalizeName(line.text);
      final List<String> primaryWords = _words(line.text, '');
      if (primary.length < 8 || primary.length > 96) {
        continue;
      }
      final Set<String> primaryColors = primaryWords
          .where(_colors.contains)
          .toSet();
      for (final String raw in line.alternatives.take(3)) {
        final String alternative = raw.trim();
        final String normalized = _normalizeName(alternative);
        final List<String> alternativeWords = _words(alternative, '');
        if (normalized == primary ||
            reliable.names.any(
              (String name) => _normalizeName(name) == normalized,
            ) ||
            normalized.length < 8 ||
            normalized.length > 96 ||
            alternativeWords.length != primaryWords.length ||
            !setEquals(
              primaryColors,
              alternativeWords.where(_colors.contains).toSet(),
            ) ||
            RegExp(r'^["“«]').hasMatch(alternative)) {
          continue;
        }
        bool sameNomenclature = true;
        for (int index = 0; index < primaryWords.length; index++) {
          if ((primaryWords[index].length < 4 ||
                  alternativeWords[index].length < 4 ||
                  RegExp(r'\d').hasMatch(primaryWords[index]) ||
                  RegExp(r'\d').hasMatch(alternativeWords[index])) &&
              primaryWords[index] != alternativeWords[index]) {
            sameNomenclature = false;
            break;
          }
        }
        if (!sameNomenclature ||
            (primary.length - normalized.length).abs() > 2) {
          continue;
        }
        List<int> previous = List<int>.generate(
          normalized.length + 1,
          (int index) => index,
        );
        for (int row = 0; row < primary.length; row++) {
          final List<int> current = <int>[row + 1];
          for (int column = 0; column < normalized.length; column++) {
            current.add(current[column] + 1);
            final int deletion = previous[column + 1] + 1;
            final int substitution =
                previous[column] +
                (primary.codeUnitAt(row) == normalized.codeUnitAt(column)
                    ? 0
                    : 1);
            if (deletion < current.last) {
              current[current.length - 1] = deletion;
            }
            if (substitution < current.last) {
              current[current.length - 1] = substitution;
            }
          }
          previous = current;
        }
        if (previous.last <= 2) {
          result.add(alternative);
        }
        if (result.length == 2) {
          return List<String>.unmodifiable(result);
        }
      }
    }
    return List<String>.unmodifiable(result);
  }

  static (List<String>, String?) _corroboratedKeywordRules(ScanCrop crop) {
    final ScanHints hints = ScanHints.fromCrop(crop);
    final ScanHints reliable = ScanHints.fromCrop(
      crop,
      minimumConfidence: .85,
    );
    final Set<String> titleColors = reliable.names
        .expand((String name) => _words(name, ''))
        .where(_colors.contains)
        .toSet();
    if (reliable.typeLine == null || titleColors.length != 1) {
      return (hints.rulesText, null);
    }
    final String color = titleColors.single;
    final List<List<String>> observations = hints.rulesText
        .map((String line) => _words(line, ''))
        .toList();
    if (observations
        .expand((List<String> words) => words)
        .any((String word) => _colors.contains(word) && word != color)) {
      return (hints.rulesText, null);
    }
    const Set<String> subjects = <String>{
      'source',
      'sources',
      'creature',
      'creatures',
      'spell',
      'spells',
      'token',
      'tokens',
      'permanent',
      'permanents',
      'artifact',
      'artifacts',
      'enchantment',
      'enchantments',
    };
    final Set<String> misspellings = <String>{
      for (final List<String> words in reliable.rulesText.map(
        (String line) => _words(line, ''),
      ))
        if (words.any(subjects.contains))
          for (final String word in words)
            if (word.length >= 4 &&
                !_colors.contains(word) &&
                _oneLetterDifference(word, color) &&
                _colors
                        .where(
                          (String value) => _oneLetterDifference(word, value),
                        )
                        .length ==
                    1)
              word,
    };
    if (misspellings.length != 1) {
      return (hints.rulesText, null);
    }
    final String misspelling = misspellings.single;
    return (
      observations
          .map(
            (List<String> words) => words.any(subjects.contains)
                ? words
                      .map((String word) => word == misspelling ? color : word)
                      .join(' ')
                : words.join(' '),
          )
          .toList(),
      color,
    );
  }

  static const Set<String> _rulesActions = <String>{
    'prevent',
    'destroy',
    'exile',
    'sacrifice',
    'discard',
    'counter',
    'return',
    'create',
    'search',
    'shuffle',
    'reveal',
    'attach',
    'untap',
  };

  static const Set<String> _rulesSubjects = <String>{
    'damage',
    'source',
    'creature',
    'creatures',
    'artifact',
    'artifacts',
    'enchantment',
    'enchantments',
    'land',
    'lands',
    'spell',
    'spells',
    'token',
    'tokens',
    'graveyard',
    'library',
    'battlefield',
    'permanent',
    'permanents',
    'equipment',
    'nonland',
    'nonartifact',
    'noncreature',
  };

  static (List<String>, String)? _bodyQuery(ScanCrop crop) {
    final ScanHints reliable = ScanHints.fromCrop(
      crop,
      minimumConfidence: .85,
    );
    final String? type = reliable.typeLine;
    if (type == null) {
      return null;
    }
    final List<ScanTextLine> types = crop.lines
        .where(
          (ScanTextLine line) =>
              line.confidence >= .85 &&
              line.bounds.y < .65 &&
              observedCardType(line.text) == type,
        )
        .toList();
    if (types.isEmpty) {
      return null;
    }
    types.sort(
      (ScanTextLine a, ScanTextLine b) => a.bounds.y.compareTo(b.bounds.y),
    );
    final double firstQuote = crop.lines
        .where(
          (ScanTextLine line) => ScanHints._isQuoteBoundary(
            line,
            partial: !crop.rectified && crop.warnings.contains('partial_card'),
          ),
        )
        .map((ScanTextLine line) => line.bounds.y)
        .fold<double>(
          double.infinity,
          (double first, double next) => first < next ? first : next,
        );
    final List<ScanTextLine> rows =
        crop.lines
            .where(
              (ScanTextLine line) =>
                  line.confidence >= .85 &&
                  line.bounds.y > types.first.bounds.y + .025 &&
                  line.bounds.y < firstQuote &&
                  reliable.rulesText.contains(line.text.trim()) &&
                  !RegExp(r'^["“«]').hasMatch(line.text.trim()),
            )
            .toList()
          ..sort(
            (ScanTextLine a, ScanTextLine b) =>
                a.bounds.y.compareTo(b.bounds.y),
          );
    final List<ScanTextLine> independent = <ScanTextLine>[];
    for (final ScanTextLine line in rows) {
      final int duplicate = independent.indexWhere(
        (ScanTextLine previous) =>
            (previous.bounds.y - line.bounds.y).abs() < .018,
      );
      if (duplicate < 0) {
        independent.add(line);
      } else {
        final ScanTextLine previous = independent[duplicate];
        final int words = _words(line.text, '').length;
        final int previousWords = _words(previous.text, '').length;
        if (words > previousWords ||
            (words == previousWords &&
                line.bounds.width > previous.bounds.width)) {
          independent[duplicate] = line;
        }
      }
    }
    independent.sort(
      (ScanTextLine a, ScanTextLine b) => a.bounds.y.compareTo(b.bounds.y),
    );
    if (independent.length < 3) {
      return null;
    }
    final Set<String> words = independent
        .expand((ScanTextLine line) => _words(line.text, ''))
        .toSet();
    final String? action = words.where(_rulesActions.contains).firstOrNull;
    if (action == null) {
      return null;
    }
    for (final ScanTextLine line in independent) {
      final List<String> row = _words(line.text, '');
      if (row.any(_rulesActions.contains)) {
        continue;
      }
      for (int index = 0; index + 2 < row.length; index++) {
        if (!_rulesSubjects.contains(row[index])) {
          continue;
        }
        final String phrase = row.sublist(index, index + 3).join(' ');
        if (!RegExp(r'^[a-z]{2,24}(?: [a-z]{2,24}){2}$').hasMatch(phrase)) {
          continue;
        }
        return (<String>[action, row[index]], phrase);
      }
    }
    return null;
  }

  static List<String> rulesSearchKeywords(List<String> lines) {
    const Set<String> actions = _rulesActions;
    const Set<String> subjects = _rulesSubjects;
    const Set<String> colors = <String>{
      'white',
      'blue',
      'black',
      'red',
      'green',
    };
    const Set<String> ignored = <String>{
      'a',
      'an',
      'the',
      'as',
      'at',
      'is',
      'of',
      'to',
      'and',
      'or',
      'on',
      'in',
      'it',
      'its',
      'that',
      'this',
      'you',
      'your',
      'any',
      'all',
      'each',
      'for',
      'from',
      'with',
      'then',
      'target',
      'card',
      'cards',
      'draw',
      'deal',
      'deals',
      'gain',
      'gains',
      'until',
      'end',
      'turn',
      'may',
      'against',
      'once',
      'more',
      'than',
      'would',
      'when',
      'whenever',
      'next',
      'time',
    };
    final List<Set<String>> observations = lines
        .take(12)
        .where(
          (String line) => !RegExp(
            r'^["“«]|©|copyright|wizards',
            caseSensitive: false,
          ).hasMatch(line.trim()),
        )
        .map(
          (String line) => _words(line, '')
              .where(
                (String word) =>
                    (word == 'red' ||
                        RegExp(r'^[a-z]{4,24}$').hasMatch(word)) &&
                    !ignored.contains(word),
              )
              .toSet(),
        )
        .where((Set<String> words) => words.isNotEmpty)
        .toList();
    if (observations.length < 2) {
      return const <String>[];
    }
    final List<String> words = observations
        .expand((Set<String> words) => words)
        .toSet()
        .toList();
    if (words.length < 4 ||
        !words.any(actions.contains) ||
        !words.any(subjects.contains)) {
      return const <String>[];
    }
    int priority(String word) => colors.contains(word)
        ? 0
        : actions.contains(word)
        ? 1
        : subjects.contains(word)
        ? 2
        : 3;
    final Map<String, int> order = <String, int>{
      for (int index = 0; index < words.length; index++) words[index]: index,
    };
    words.sort((String a, String b) {
      final int category = priority(a).compareTo(priority(b));
      return category == 0 ? order[a]!.compareTo(order[b]!) : category;
    });
    final List<String> selected = words.take(4).toList();
    if (!selected.any(actions.contains) ||
        !selected.any(subjects.contains) ||
        observations
                .where(
                  (Set<String> words) =>
                      words.intersection(selected.toSet()).isNotEmpty,
                )
                .length <
            2) {
      return const <String>[];
    }
    return List<String>.unmodifiable(selected);
  }

  static double _nameDistance(MtgCard card, List<String> names) {
    double best = 1;
    for (final String observed in names) {
      final String a = _normalizeName(observed);
      if (a.length < 6 || a.length > 96) continue;
      for (final String name in <String>[
        card.name,
        if (card.printedName != null) card.printedName!,
      ]) {
        final String b = _normalizeName(name);
        if (b.isEmpty || b.length > 96) continue;
        List<int> previous = List<int>.generate(
          b.length + 1,
          (int index) => index,
        );
        for (int row = 1; row <= a.length; row++) {
          final List<int> current = <int>[row];
          for (int column = 1; column <= b.length; column++) {
            final int insert = current[column - 1] + 1;
            final int remove = previous[column] + 1;
            final int replace =
                previous[column - 1] + (a[row - 1] == b[column - 1] ? 0 : 1);
            current.add(
              <int>[
                insert,
                remove,
                replace,
              ].reduce((int x, int y) => x < y ? x : y),
            );
          }
          previous = current;
        }
        final double distance =
            previous.last / (a.length > b.length ? a.length : b.length);
        if (distance < best) best = distance;
      }
    }
    return best;
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  static bool _matchesName(MtgCard card, String name) {
    final String target = _normalizeName(name);
    return <String>[
      card.name,
      if (card.printedName != null) card.printedName!,
      ...?card.cardFaces?.expand(
        (CardFace face) => <String>[
          face.name,
          if (face.printedName != null) face.printedName!,
        ],
      ),
    ].any((String candidate) => _normalizeName(candidate) == target);
  }

  static String _normalizeName(String name) => name.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );
}
