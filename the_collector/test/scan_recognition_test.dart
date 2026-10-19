import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/scanning/scan_recognition.dart';

ScanCrop _bodyLayout({
  required bool live,
  required bool quoteBeforeRules,
  double quoteConfidence = .80,
  double ruleConfidence = 1,
  double typeConfidence = 1,
}) => ScanCrop(
  imagePath: live ? '' : 'saved-layout.jpg',
  width: 1000,
  height: 1400,
  rectified: !live,
  sourceCorners: const <ScanPoint>[
    ScanPoint(.1, .1),
    ScanPoint(.3, .1),
    ScanPoint(.3, .4),
    ScanPoint(.1, .4),
  ],
  warnings: live
      ? const <String>['partial_card', 'incomplete_card']
      : const <String>['orientation_ensemble', 'geometry_adjusted'],
  lines: <ScanTextLine>[
    ScanTextLine(
      text: 'Enchantment',
      confidence: typeConfidence,
      bounds: const ScanBounds(.05, .50, .3, .03),
      glyphHeight: .03,
    ),
    ScanTextLine(
      text: '"Remember the ancient forest',
      confidence: quoteConfidence,
      bounds: ScanBounds(.05, quoteBeforeRules ? .55 : .80, .8, .03),
      glyphHeight: .03,
    ),
    for (final (int index, String text) in <String>[
      '1: Prevent all damage against you',
      'from one blue source. If a source',
      'deals damage to you more than once',
    ].indexed)
      ScanTextLine(
        text: text,
        confidence: ruleConfidence,
        bounds: ScanBounds(.05, .60 + index * .06, .8, .03),
        glyphHeight: .03,
      ),
  ],
);

void main() {
  test('saved and live layout proofs reject three strong rows after an .80 quote delimiter', () {
    for (final bool live in <bool>[false, true]) {
      for (final double quoteConfidence in <double>[.80, 1]) {
        final ScanCrop crop = _bodyLayout(
          live: live,
          quoteBeforeRules: true,
          quoteConfidence: quoteConfidence,
        );
        expect(
          live
              ? hasVerifiedLiveBodyLayout(crop)
              : hasVerifiedSavedBodyLayout(crop),
          isFalse,
          reason: 'live=$live, quote confidence=$quoteConfidence',
        );
        if (!live) expect(hasVerifiedSavedVisualLayout(crop), isFalse);
      }
    }
  });

  test('layout quote delimiters preserve saved and live positive evidence thresholds', () {
    for (final bool live in <bool>[false, true]) {
      for (final bool varyType in <bool>[false, true]) {
        for (final double confidence in <double>[.84, .85, .89, .90, 1]) {
          final ScanCrop crop = _bodyLayout(
            live: live,
            quoteBeforeRules: false,
            typeConfidence: varyType ? confidence : 1,
            ruleConfidence: varyType ? 1 : confidence,
          );
          expect(
            live
                ? hasVerifiedLiveBodyLayout(crop)
                : hasVerifiedSavedBodyLayout(crop),
            confidence >= (live ? .90 : .85),
            reason: 'live=$live, vary type=$varyType, confidence=$confidence',
          );
        }
      }
    }
  });
}
