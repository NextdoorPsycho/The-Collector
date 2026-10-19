import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class ScanPoint {
  final double x;
  final double y;

  const ScanPoint(this.x, this.y);

  factory ScanPoint.fromMap(Map<Object?, Object?> value) =>
      ScanPoint((value['x'] as num).toDouble(), (value['y'] as num).toDouble());
}

/// Coordinates use the upright image's top-left origin, normalized to 0..1.
@immutable
class ScanBounds {
  final double x;
  final double y;
  final double width;
  final double height;

  const ScanBounds(this.x, this.y, this.width, this.height);

  factory ScanBounds.fromMap(Map<Object?, Object?> value) => ScanBounds(
    (value['x'] as num).toDouble(),
    (value['y'] as num).toDouble(),
    (value['width'] as num).toDouble(),
    (value['height'] as num).toDouble(),
  );
}

@immutable
class ScanTextLine {
  final String text;
  final double confidence;
  final ScanBounds bounds;
  final double? glyphHeight;
  final List<String> alternatives;
  final bool sceneFooterGuide;

  const ScanTextLine({
    required this.text,
    required this.confidence,
    required this.bounds,
    this.glyphHeight,
    this.alternatives = const <String>[],
    this.sceneFooterGuide = false,
  });

  factory ScanTextLine.fromMap(Map<Object?, Object?> value) => ScanTextLine(
    text: value['text'] as String,
    confidence: (value['confidence'] as num).toDouble(),
    bounds: ScanBounds.fromMap(value['bounds'] as Map<Object?, Object?>),
    glyphHeight: (value['glyphHeight'] as num?)?.toDouble(),
    alternatives: List<String>.unmodifiable(
      (value['alternatives'] as List<Object?>? ?? const <Object?>[])
          .cast<String>(),
    ),
    sceneFooterGuide: value['sceneFooterGuide'] == true,
  );

  double get textHeight {
    final double? measured = glyphHeight;
    return measured != null &&
            measured.isFinite &&
            measured > 0 &&
            measured <= 1
        ? measured
        : bounds.height;
  }
}

@immutable
class ScanCrop {
  final String imagePath;
  final int width;
  final int height;
  final bool rectified;
  final List<ScanPoint> sourceCorners;
  final List<ScanTextLine> lines;
  final List<String> warnings;
  final double? sharpness;

  const ScanCrop({
    required this.imagePath,
    required this.width,
    required this.height,
    required this.rectified,
    required this.sourceCorners,
    required this.lines,
    this.warnings = const <String>[],
    this.sharpness,
  });

  factory ScanCrop.fromMap(Map<Object?, Object?> value) => ScanCrop(
    imagePath: value['imagePath'] as String,
    width: (value['width'] as num).toInt(),
    height: (value['height'] as num).toInt(),
    rectified: value['rectified'] as bool,
    sourceCorners: List<ScanPoint>.unmodifiable(
      (value['sourceCorners'] as List<Object?>).map(
        (Object? point) => ScanPoint.fromMap(point as Map<Object?, Object?>),
      ),
    ),
    lines: List<ScanTextLine>.unmodifiable(
      (value['lines'] as List<Object?>).map(
        (Object? line) => ScanTextLine.fromMap(line as Map<Object?, Object?>),
      ),
    ),
    warnings: List<String>.unmodifiable(
      (value['warnings'] as List<Object?>? ?? const <Object?>[]).cast<String>(),
    ),
    sharpness: (value['sharpness'] as num?)?.toDouble(),
  );
}

String? observedCardType(String text) {
  final String value = text.trim();
  final RegExpMatch? modern = RegExp(
    r'^(?:(?:legendary|basic|snow|world|ongoing)\s+)*((?:creature|instant|sorcery|enchantment|artifact|land|planeswalker|battle|kindred|tribal)(?:\s+(?:creature|instant|sorcery|enchantment|artifact|land|planeswalker|battle|kindred|tribal))*)(?:\s*[—–-]\s*.+)?$',
    caseSensitive: false,
  ).firstMatch(value);
  if (modern != null) return modern.group(1)!.toLowerCase();
  const Map<String, String> japaneseTypes = <String, String>{
    'クリーチャー': 'creature',
    'インスタント': 'instant',
    'ソーサリー': 'sorcery',
    'エンチャント': 'enchantment',
    'アーティファクト': 'artifact',
    '土地': 'land',
    'プレインズウォーカー': 'planeswalker',
    'バトル': 'battle',
    '同族': 'kindred',
    '部族': 'tribal',
  };
  final String japaneseType = japaneseTypes.keys.join('|');
  final RegExpMatch? japanese = RegExp(
    '^(?:(?:伝説の|基本|氷雪|ワールド)\\s*)*'
    '((?:$japaneseType)(?:\\s*[・･]\\s*(?:$japaneseType))*)'
    '(?:\\s*[—–－ー-]\\s*.+|\\s+レジェンド)?\$',
  ).firstMatch(value);
  if (japanese != null) {
    return japanese
        .group(1)!
        .split(RegExp(r'\s*[・･]\s*'))
        .map((String type) => japaneseTypes[type]!)
        .join(' ');
  }
  if (RegExp(
    r'^enchant\s+(?:creature|artifact|land|enchantment|wall|permanent|world)(?:\s+(?:or|and)\s+(?:creature|artifact|land|enchantment|wall|permanent))*$',
    caseSensitive: false,
  ).hasMatch(value)) {
    return 'enchantment';
  }
  if (RegExp(
    r'^summon\s+[\p{L}][\p{L}\s—–-]{0,60}$',
    caseSensitive: false,
    unicode: true,
  ).hasMatch(value)) {
    return 'creature';
  }
  return null;
}

/// Checks repaired card layout without supplying title or printing evidence.
bool hasVerifiedSavedBodyLayout(ScanCrop crop) {
  return crop.warnings.contains('orientation_ensemble') &&
      crop.warnings.contains('geometry_adjusted') &&
      _hasVerifiedSavedRulesLayout(crop);
}

bool hasVerifiedLiveBodyLayout(ScanCrop crop) {
  if (crop.imagePath.isNotEmpty || crop.sourceCorners.length != 4) return false;
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
  return twiceArea.abs() >= .0002 &&
      _hasVerifiedSavedRulesLayout(crop, live: true);
}

/// Weak collector glyphs establish saved framing, never printing identity.
bool hasVerifiedSavedBasicLandCapturePresence(ScanCrop crop) {
  if (crop.imagePath.isEmpty ||
      !crop.rectified ||
      crop.width < 400 ||
      crop.height < 400 ||
      crop.width / crop.height < .58 ||
      crop.width / crop.height > .84 ||
      !crop.warnings.contains('basic_land_outline') ||
      !crop.warnings.contains('unread_footer') ||
      crop.warnings.any(
        (String warning) => !const <String>{
          'border_recovered',
          'geometry_adjusted',
          'orientation_ensemble',
          'partial_card',
          'basic_land_outline',
          'unread_footer',
          'details_pending',
        }.contains(warning),
      ) ||
      crop.sourceCorners.length != 4) {
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
    if (!point.x.isFinite ||
        !point.y.isFinite ||
        point.x < 0 ||
        point.x > 1 ||
        point.y < 0 ||
        point.y > 1 ||
        !cross.isFinite ||
        cross.abs() < .000001 ||
        (direction != null && cross * direction <= 0)) {
      return false;
    }
    direction = cross;
    twiceArea += point.x * next.y - next.x * point.y;
  }
  if (twiceArea.abs() < .0002) {
    return false;
  }
  bool readable(ScanTextLine line, double confidence) {
    final ScanBounds bounds = line.bounds;
    return line.confidence.isFinite &&
        line.confidence >= confidence &&
        line.confidence <= 1 &&
        bounds.x.isFinite &&
        bounds.y.isFinite &&
        bounds.width.isFinite &&
        bounds.height.isFinite &&
        bounds.x >= 0 &&
        bounds.y >= 0 &&
        bounds.width >= .08 &&
        bounds.height > 0 &&
        bounds.height < .08 &&
        bounds.x + bounds.width <= 1.02 &&
        bounds.y + bounds.height <= 1.02;
  }

  final bool title = crop.lines.any(
    (ScanTextLine line) =>
        readable(line, .90) &&
        line.bounds.y < .15 &&
        line.bounds.width >= .18 &&
        RegExp(r'[\p{L}]{3}', unicode: true).hasMatch(line.text) &&
        observedCardType(line.text) == null,
  );
  final RegExp basicType = RegExp(
    r'^basic(?:\s+snow)?\s+land(?:\s*[—–-]\s*[\p{L}\s]+)?$',
    caseSensitive: false,
    unicode: true,
  );
  final bool type = crop.lines.any(
    (ScanTextLine line) =>
        readable(line, .90) &&
        line.bounds.y >= .35 &&
        line.bounds.y + line.bounds.height <= .90 &&
        basicType.hasMatch(line.text.trim()),
  );
  final bool physicalFooter = crop.lines.any(
    (ScanTextLine line) =>
        readable(line, .30) &&
        line.bounds.y >= .88 &&
        line.bounds.y + line.bounds.height <= 1 &&
        line.bounds.height < .055 &&
        line.bounds.x < .65 &&
        RegExp(r'^\s*\d{2,5}\s*/+\s*\d{2,5}(?:\s+[A-Za-z0-9])?\s*$')
            .hasMatch(line.text),
  );
  return title && type && physicalFooter;
}

/// Validates saved framing without granting printing identity.
bool hasVerifiedSavedCardCapturePresence(ScanCrop crop) {
  const Set<String> allowed = <String>{
    'border_recovered',
    'geometry_adjusted',
    'orientation_ensemble',
    'basic_land_outline',
    'partial_card',
    'unread_footer',
    'details_pending',
    'incomplete_card',
  };
  if (crop.imagePath.isEmpty ||
      !crop.rectified ||
      crop.width < 400 ||
      crop.height < 400 ||
      crop.width / crop.height < .58 ||
      crop.width / crop.height > .84 ||
      crop.warnings.any((String warning) => !allowed.contains(warning)) ||
      (crop.warnings.contains('partial_card') &&
          !crop.warnings.contains('basic_land_outline')) ||
      crop.sourceCorners.length != 4) {
    return false;
  }
  double? direction;
  for (int index = 0; index < 4; index++) {
    final ScanPoint a = crop.sourceCorners[index];
    final ScanPoint b = crop.sourceCorners[(index + 1) % 4];
    final ScanPoint c = crop.sourceCorners[(index + 2) % 4];
    final double turn = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
    if (!a.x.isFinite ||
        !a.y.isFinite ||
        a.x < 0 ||
        a.x > 1 ||
        a.y < 0 ||
        a.y > 1 ||
        !turn.isFinite ||
        turn.abs() < 1e-10 ||
        (direction != null && turn * direction < 0)) {
      return false;
    }
    direction = turn;
  }
  if (crop.warnings.contains('incomplete_card')) {
    return _hasWeakSavedCardFraming(crop);
  }
  if (hasVerifiedSavedBasicLandCapturePresence(crop)) return true;
  final ScanCrop layout = ScanCrop(
    imagePath: crop.imagePath,
    width: crop.width,
    height: crop.height,
    rectified: crop.rectified,
    sourceCorners: crop.sourceCorners,
    lines: crop.lines,
    warnings: crop.warnings
        .where((String warning) => warning != 'details_pending')
        .toList(),
  );
  if (hasVerifiedSavedVisualLayout(layout)) return true;
  bool readable(ScanTextLine line) =>
      line.confidence.isFinite &&
      line.confidence >= .65 &&
      line.confidence <= 1 &&
      line.bounds.x.isFinite &&
      line.bounds.y.isFinite &&
      line.bounds.width.isFinite &&
      line.bounds.height.isFinite &&
      line.bounds.x >= 0 &&
      line.bounds.y >= 0 &&
      line.bounds.width >= .08 &&
      line.bounds.height > 0 &&
      line.bounds.height < .08 &&
      line.bounds.x + line.bounds.width <= 1.02 &&
      line.bounds.y + line.bounds.height <= 1.02;
  final bool title = crop.lines.any(
    (ScanTextLine line) =>
        readable(line) &&
        line.bounds.y < .15 &&
        line.bounds.width >= .18 &&
        RegExp(r'[\p{L}]{3}', unicode: true).hasMatch(line.text) &&
        observedCardType(line.text) == null,
  );
  final bool type = crop.lines.any(
    (ScanTextLine line) =>
        readable(line) &&
        observedCardType(line.text) != null &&
        ((line.bounds.y >= .35 && line.bounds.y < .65) ||
            (observedCardType(line.text) == 'land' &&
                line.bounds.y >= .70 &&
                line.bounds.y + line.bounds.height <= .90)),
  );
  final RegExp footer = RegExp(
    r'\b[A-Z0-9]{3,5}(?:\s*[•·∙]\s*|\s+)(?:EN|DE|ES|FR|IT|PT|JA|KO|RU|ZHS|ZHT)\b|(?:©|\(c\)|copyright)\s*(?:19|20)\d{2}\b.*wizards',
    caseSensitive: false,
  );
  return (title &&
          type &&
          crop.lines.any(
            (ScanTextLine line) =>
                readable(line) &&
                line.bounds.y >= .85 &&
                footer.hasMatch(line.text),
          )) ||
      _hasWeakSavedCardFraming(crop);
}

bool _hasWeakSavedCardFraming(ScanCrop crop) {
  if (crop.warnings.contains('partial_card')) return false;
  double twiceArea = 0;
  for (int index = 0; index < 4; index++) {
    final ScanPoint a = crop.sourceCorners[index];
    final ScanPoint b = crop.sourceCorners[(index + 1) % 4];
    twiceArea += a.x * b.y - b.x * a.y;
  }
  if (twiceArea.abs() < .0002) return false;
  bool observed(ScanTextLine line, double confidence) {
    final ScanBounds bounds = line.bounds;
    return !line.sceneFooterGuide &&
        line.confidence.isFinite &&
        line.confidence >= confidence &&
        line.confidence <= 1 &&
        bounds.x.isFinite &&
        bounds.y.isFinite &&
        bounds.width.isFinite &&
        bounds.height.isFinite &&
        bounds.x >= .015 &&
        bounds.x < .70 &&
        bounds.y >= .01 &&
        bounds.width >= .12 &&
        bounds.height >= .008 &&
        bounds.height < .07 &&
        bounds.x + bounds.width <= 1 &&
        bounds.y + bounds.height <= 1 &&
        line.textHeight.isFinite &&
        line.textHeight > 0 &&
        line.textHeight < .07;
  }

  bool letters(ScanTextLine line) =>
      RegExp(r'[\p{L}]{3}', unicode: true).hasMatch(line.text) &&
      line.text.length <= 100;
  final List<ScanTextLine> headers = crop.lines
      .where(
        (ScanTextLine line) =>
            observed(line, .30) &&
            letters(line) &&
            line.bounds.y < .15 &&
            line.bounds.x < .60 &&
            line.bounds.width >= .18 &&
            line.bounds.y + line.bounds.height <= .18 &&
            !RegExp(
              r'^["“«]|(?:©|\(c\)|copyright|illus\.)',
              caseSensitive: false,
            ).hasMatch(line.text.trim()) &&
            observedCardType(line.text) == null,
      )
      .toList();
  final List<ScanTextLine> types = crop.lines
      .where(
        (ScanTextLine line) =>
            observed(line, .30) &&
            letters(line) &&
            line.bounds.y >= .35 &&
            line.bounds.y + line.bounds.height <= .64 &&
            line.text.trim().split(RegExp(r'\s+')).length <= 8 &&
            !RegExp(
              r'^["“«]|(?:©|\(c\)|copyright|illus\.)',
              caseSensitive: false,
            ).hasMatch(line.text.trim()),
      )
      .toList();
  final RegExp artist = RegExp(
    r'^\s*(?:illus\.?|illustrated\s+by|illustration|artist)\s+[\p{L}].*[\p{L}]',
    caseSensitive: false,
    unicode: true,
  );
  final RegExp copyright = RegExp(
    r'(?:©|\(c\)|copyright)\s*(?:19|20)\d{2}\b.{0,32}\bwizards\b.{0,32}\bcoast\b',
    caseSensitive: false,
  );
  final List<ScanTextLine> artists = crop.lines
      .where(
        (ScanTextLine line) =>
            observed(line, .30) &&
            line.bounds.y >= .80 &&
            line.bounds.y + line.bounds.height <= .97 &&
            artist.hasMatch(line.text),
      )
      .toList();
  final List<ScanTextLine> copyrights = crop.lines
      .where(
        (ScanTextLine line) =>
            observed(line, .30) &&
            line.bounds.y >= .85 &&
            line.bounds.height < .055 &&
            copyright.hasMatch(line.text),
      )
      .toList();
  if (headers.isEmpty ||
      types.isEmpty ||
      artists.isEmpty ||
      copyrights.isEmpty) {
    return false;
  }
  final RegExp gameplay = RegExp(
    r'^(?:\d+\s*[:;,.]\s*)?(?:target\s+(?:creature|artifact|land|player|spell|permanent)\b.*\b(?:gains?|gets?|loses?|becomes?|deals?|has|can|is)\b|(?:prevent|deal|deals)\b.*\bdamage\b|(?:draw|discard)\b.*\bcards?\b|(?:return|exile|destroy|sacrifice)\b.*\b(?:cards?|creatures?|artifacts?|permanents?)\b|(?:choose|create|put)\b.*\b(?:target|token|card)\b)',
    caseSensitive: false,
  );
  for (final ScanTextLine type in types) {
    for (final ScanTextLine footer in artists) {
      if (!copyrights.any(
        (ScanTextLine line) => line.bounds.y >= footer.bounds.y + .008,
      )) {
        continue;
      }
      if (crop.lines.any(
        (ScanTextLine line) =>
            observed(line, .85) &&
            line.bounds.y >= .56 &&
            line.bounds.y >= type.bounds.y + type.bounds.height + .01 &&
            line.bounds.y + line.bounds.height <= footer.bounds.y - .01 &&
            line.bounds.width >= .20 &&
            gameplay.hasMatch(line.text.trim()),
      )) {
        return true;
      }
    }
  }
  return false;
}

/// Allows saved-photo visual comparison without changing identity evidence.
bool hasVerifiedSavedVisualLayout(ScanCrop crop) {
  if (_hasVerifiedSavedBasicLandVisualLayout(crop)) return true;
  if (crop.imagePath.isEmpty ||
      (crop.warnings.isNotEmpty &&
          !crop.warnings.contains('geometry_adjusted') &&
          !crop.warnings.contains('border_recovered')) ||
      crop.sourceCorners.length != 4) {
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
  return twiceArea.abs() >= .0002 && _hasVerifiedSavedRulesLayout(crop);
}

bool _hasVerifiedSavedBasicLandVisualLayout(ScanCrop crop) {
  if (crop.imagePath.isEmpty ||
      !crop.rectified ||
      crop.width < 400 ||
      crop.height < 400 ||
      crop.width / crop.height < .58 ||
      crop.width / crop.height > .84 ||
      crop.sourceCorners.length != 4 ||
      crop.sourceCorners.any(
        (ScanPoint point) =>
            !point.x.isFinite ||
            !point.y.isFinite ||
            point.x < 0 ||
            point.x > 1 ||
            point.y < 0 ||
            point.y > 1,
      ) ||
      crop.warnings.any(
        (String warning) => !const <String>{
          'partial_card',
          'basic_land_outline',
        }.contains(warning),
      ) ||
      (crop.warnings.contains('partial_card') &&
          !crop.warnings.contains('basic_land_outline'))) {
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
  if (twiceArea.abs() < .0002) return false;

  bool readable(ScanTextLine line) {
    final ScanBounds bounds = line.bounds;
    return line.confidence.isFinite &&
        line.confidence >= .90 &&
        line.confidence <= 1 &&
        bounds.x.isFinite &&
        bounds.y.isFinite &&
        bounds.width.isFinite &&
        bounds.height.isFinite &&
        bounds.x >= 0 &&
        bounds.y >= 0 &&
        bounds.width >= .08 &&
        bounds.height > 0 &&
        bounds.height < .08 &&
        bounds.x + bounds.width <= 1 &&
        bounds.y + bounds.height <= 1 &&
        line.textHeight > 0 &&
        line.textHeight < .07;
  }

  final RegExp basicType = RegExp(
    r'^basic(?:\s+snow)?\s+land(?:\s*[—–-]\s*[\p{L}\s]+)?$',
    caseSensitive: false,
    unicode: true,
  );
  final RegExp footer = RegExp(
    r'^[a-z0-9]{2,6}\s*(?:[•·]\s*|\s+)(?:en|de|es|fr|it|pt|ja|ko|ru|zhs|zht)\b',
    caseSensitive: false,
  );
  final RegExp copyright = RegExp(
    r'(?:©|\(c\)|copyright)\s*(?:19|20)\d{2}\b.*\bwizards\s+of\s+the\s+coast\b',
    caseSensitive: false,
  );
  final bool title = crop.lines.any(
    (ScanTextLine line) =>
        readable(line) &&
        line.bounds.y < .15 &&
        line.bounds.width >= .18 &&
        line.text.trim().length >= 4 &&
        line.text.trim().length <= 80 &&
        RegExp(r'[\p{L}]{3}', unicode: true).hasMatch(line.text) &&
        observedCardType(line.text) == null,
  );
  final bool type = crop.lines.any(
    (ScanTextLine line) =>
        readable(line) &&
        line.bounds.y >= .70 &&
        line.bounds.y + line.bounds.height <= .90 &&
        basicType.hasMatch(line.text.trim()),
  );
  final bool physicalFooter = crop.lines.any(
    (ScanTextLine line) =>
        readable(line) &&
        line.bounds.y >= .88 &&
        (footer.hasMatch(line.text.trim()) || copyright.hasMatch(line.text)),
  );
  return title && type && physicalFooter;
}

bool _hasVerifiedSavedRulesLayout(ScanCrop crop, {bool live = false}) {
  const Set<String> repairWarnings = <String>{
    'incomplete_card',
    'orientation_ensemble',
    'geometry_adjusted',
    'border_recovered',
  };
  if ((!live && !crop.rectified) ||
      crop.width < 400 ||
      crop.height < 400 ||
      crop.width / crop.height < .58 ||
      crop.width / crop.height > .84 ||
      crop.sourceCorners.length != 4 ||
      crop.sourceCorners.any(
        (ScanPoint point) =>
            !point.x.isFinite ||
            !point.y.isFinite ||
            point.x < 0 ||
            point.x > 1 ||
            point.y < 0 ||
            point.y > 1,
      ) ||
      crop.warnings.any(
        (String warning) => !(live
            ? const <String>{
                'partial_card',
                'incomplete_card',
                'orientation_ensemble',
                'geometry_adjusted',
              }.contains(warning)
            : repairWarnings.contains(warning)),
      )) {
    return false;
  }
  final List<ScanTextLine> types = crop.lines
      .where(
        (ScanTextLine line) =>
            line.confidence >= (live ? .90 : .85) &&
            line.confidence <= 1 &&
            line.bounds.y >= .35 &&
            line.bounds.y < .65 &&
            line.bounds.x >= 0 &&
            line.bounds.x < .75 &&
            line.bounds.width >= .08 &&
            line.bounds.width <= 1 &&
            line.bounds.height > 0 &&
            line.bounds.height < .08 &&
            (!live ||
                (line.glyphHeight != null &&
                    line.glyphHeight!.isFinite &&
                    line.glyphHeight! > 0)) &&
            line.textHeight > 0 &&
            line.textHeight < (live ? .05 : .07) &&
            line.text.trim().split(RegExp(r'\s+')).length <= 8 &&
            observedCardType(line.text) != null,
      )
      .toList();
  if (types.isEmpty) {
    return false;
  }
  types.sort(
    (ScanTextLine a, ScanTextLine b) => a.bounds.y.compareTo(b.bounds.y),
  );
  final List<double> quoteRows =
      crop.lines
          .where(
            (ScanTextLine line) =>
                line.confidence >= .80 &&
                line.bounds.y > types.first.bounds.y &&
                RegExp(r'^["“«]').hasMatch(line.text.trim()),
          )
          .map((ScanTextLine line) => line.bounds.y)
          .toList()
        ..sort();
  final List<ScanTextLine> rows =
      crop.lines
          .where(
            (ScanTextLine line) =>
                line.confidence >= (live ? .90 : .85) &&
                line.confidence <= 1 &&
                line.bounds.y > types.first.bounds.y + .025 &&
                line.bounds.y < (live ? .82 : .86) &&
                line.bounds.x >= 0 &&
                line.bounds.x < .75 &&
                line.bounds.width >= .20 &&
                line.bounds.width <= 1 &&
                line.bounds.height > 0 &&
                line.bounds.height < (live ? .08 : .14) &&
                (line.bounds.height < .08 ||
                    (line.glyphHeight != null &&
                        line.glyphHeight!.isFinite &&
                        line.glyphHeight! > 0 &&
                        line.glyphHeight! < .07)) &&
                (!live ||
                    (line.glyphHeight != null &&
                        line.glyphHeight!.isFinite &&
                        line.glyphHeight! > 0)) &&
                line.textHeight > 0 &&
                line.textHeight < (live ? .05 : .07) &&
                (quoteRows.isEmpty || line.bounds.y < quoteRows.first) &&
                line.text.trim().split(RegExp(r'\s+')).length >= 4 &&
                !RegExp(
                  r'^["“«]|©|copyright|wizards',
                  caseSensitive: false,
                ).hasMatch(line.text.trim()),
          )
          .toList()
        ..sort(
          (ScanTextLine a, ScanTextLine b) => a.bounds.y.compareTo(b.bounds.y),
        );
  final List<ScanTextLine> independent = <ScanTextLine>[];
  for (final ScanTextLine line in rows) {
    if (independent.every(
      (ScanTextLine previous) =>
          (previous.bounds.y - line.bounds.y).abs() >= .018,
    )) {
      independent.add(line);
    }
  }
  if (independent.length < 3) {
    return false;
  }
  final Set<String> words = independent
      .expand(
        (ScanTextLine line) =>
            RegExp(r'[a-z]+')
                .allMatches(line.text.toLowerCase())
                .map((RegExpMatch word) => word.group(0)!),
      )
      .toSet();
  return words.any(
        const <String>{
          'prevent',
          'name',
          'cast',
          'destroy',
          'exile',
          'sacrifice',
          'sacrifices',
          'discard',
          'counter',
          'return',
          'create',
          'search',
          'shuffle',
          'reveal',
          'attach',
          'untap',
        }.contains,
      ) &&
      words.any(
        const <String>{
          'damage',
          'source',
          'creature',
          'creatures',
          'artifact',
          'artifacts',
          'enchantment',
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
          'equipment',
          'nonland',
          'nonartifact',
          'noncreature',
        }.contains,
      );
}

@immutable
class SavedTargetAppearance {
  final List<ScanPoint> corners;
  final List<double> values;
  final bool present;

  const SavedTargetAppearance({
    required this.corners,
    required this.values,
    required this.present,
  });

  bool get isValid =>
      present &&
      corners.length == 4 &&
      corners.every(
        (ScanPoint point) =>
            point.x.isFinite &&
            point.y.isFinite &&
            point.x >= 0 &&
            point.x <= 1 &&
            point.y >= 0 &&
            point.y <= 1,
      ) &&
      values.length == 288 &&
      values.every(
        (double value) => value.isFinite && value >= 0 && value <= 1,
      );

  factory SavedTargetAppearance.fromMap(Map<Object?, Object?> value) =>
      SavedTargetAppearance(
        corners: List<ScanPoint>.unmodifiable(
          (value['corners'] as List<Object?>).map(
            (Object? point) =>
                ScanPoint.fromMap(point as Map<Object?, Object?>),
          ),
        ),
        values: List<double>.unmodifiable(
          (value['values'] as List<Object?>).map(
            (Object? component) => (component as num).toDouble(),
          ),
        ),
        present: value['present'] == true,
      );
}

@immutable
class ScanRecognition {
  final String imagePath;
  final int width;
  final int height;
  final List<ScanCrop> crops;
  final List<SavedTargetAppearance> targetAppearances;

  const ScanRecognition({
    required this.imagePath,
    required this.width,
    required this.height,
    required this.crops,
    this.targetAppearances = const <SavedTargetAppearance>[],
  });

  factory ScanRecognition.fromMap(
    Map<Object?, Object?> value,
  ) => ScanRecognition(
    imagePath: value['imagePath'] as String,
    width: (value['width'] as num).toInt(),
    height: (value['height'] as num).toInt(),
    crops: List<ScanCrop>.unmodifiable(
      (value['crops'] as List<Object?>).map(
        (Object? crop) => ScanCrop.fromMap(crop as Map<Object?, Object?>),
      ),
    ),
    targetAppearances: List<SavedTargetAppearance>.unmodifiable(
      (value['targetAppearances'] as List<Object?>? ?? const <Object?>[]).map(
        (Object? appearance) =>
            SavedTargetAppearance.fromMap(appearance as Map<Object?, Object?>),
      ),
    ),
  );
}

abstract interface class CardRecognizer {
  Future<ScanRecognition> recognize(
    String imagePath, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  });
}

abstract interface class CapturePresenceRecognizer {
  bool get supportsCapturePresence;
  Future<ScanRecognition> recognizePresence(
    String imagePath, {
    bool multipleCards = true,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  });
}

class NativeCardRecognizer
    implements CardRecognizer, CapturePresenceRecognizer {
  static const MethodChannel channel = MethodChannel(
    'art.arcane.the_collector/scanner',
  );

  bool _busy = false;

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  static Future<double?> compareArtwork({
    required String queryImagePath,
    required String referenceImagePath,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
    final num? distance = await channel.invokeMethod<num>(
      'compareArtwork',
      <String, String>{
        'queryImagePath': queryImagePath,
        'referenceImagePath': referenceImagePath,
      },
    );
    return distance?.toDouble();
  }

  static Future<double?> compareSetSymbol({
    required String queryImagePath,
    required String referenceImagePath,
    required ScanBounds queryRegion,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
    if (!queryRegion.x.isFinite ||
        !queryRegion.y.isFinite ||
        !queryRegion.width.isFinite ||
        !queryRegion.height.isFinite ||
        queryRegion.x < 0 ||
        queryRegion.y < 0 ||
        queryRegion.width <= 0 ||
        queryRegion.height <= 0 ||
        queryRegion.x + queryRegion.width > 1 ||
        queryRegion.y + queryRegion.height > 1) {
      throw const FormatException(
        'Set symbol region is outside the card image.',
      );
    }
    final num? distance = await channel.invokeMethod<num>(
      'compareSetSymbol',
      <String, Object>{
        'queryImagePath': queryImagePath,
        'referenceImagePath': referenceImagePath,
        'queryRegion': <String, double>{
          'x': queryRegion.x,
          'y': queryRegion.y,
          'width': queryRegion.width,
          'height': queryRegion.height,
        },
      },
    );
    return distance?.toDouble();
  }

  @override
  Future<ScanRecognition> recognize(
    String imagePath, {
    bool multipleCards = false,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    if (!supported) {
      throw UnsupportedError('Local card recognition requires iOS or Android.');
    }
    if (_busy) {
      throw StateError('An image is already being recognized.');
    }
    _busy = true;
    try {
      final Map<Object?, Object?>? response = await channel
          .invokeMethod<Map<Object?, Object?>>('recognize', <String, Object>{
            'path': imagePath,
            'multipleCards': multipleCards,
            if (targetRegions.isNotEmpty)
              'targetRegions': _targetRegionMaps(targetRegions),
          });
      if (response == null) {
        throw const FormatException('Recognition returned no result.');
      }
      return ScanRecognition.fromMap(response);
    } finally {
      _busy = false;
    }
  }

  bool _presenceBusy = false;
  @override
  bool get supportsCapturePresence =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<ScanRecognition> recognizePresence(
    String imagePath, {
    bool multipleCards = true,
    List<List<ScanPoint>> targetRegions = const <List<ScanPoint>>[],
  }) async {
    if (!supportsCapturePresence) {
      throw UnsupportedError('Saved capture presence requires iOS.');
    }
    if (_presenceBusy) {
      throw StateError('A saved capture is already being verified.');
    }
    _presenceBusy = true;
    try {
      final Map<Object?, Object?>? response = await channel
          .invokeMethod<Map<Object?, Object?>>(
            'recognizePresence',
            <String, Object>{
              'path': imagePath,
              'multipleCards': multipleCards,
              if (targetRegions.isNotEmpty)
                'targetRegions': _targetRegionMaps(targetRegions),
            },
          );
      if (response == null) {
        throw const FormatException('Capture verification returned no result.');
      }
      return ScanRecognition.fromMap(response);
    } finally {
      _presenceBusy = false;
    }
  }

  static List<List<Map<String, double>>> _targetRegionMaps(
    List<List<ScanPoint>> regions,
  ) => regions
      .map(
        (List<ScanPoint> region) => region
            .map(
              (ScanPoint point) => <String, double>{'x': point.x, 'y': point.y},
            )
            .toList(),
      )
      .toList();
}
