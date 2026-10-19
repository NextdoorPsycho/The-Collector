import 'dart:math' as math;

import 'package:arcane/arcane.dart';

class TabletopResult extends StatelessWidget {
  const TabletopResult({
    super.key,
    required this.value,
    required this.valueKey,
    required this.label,
    required this.semanticLabel,
    required this.motion,
    required this.animating,
    this.details = const <String>[],
  });

  final String value;
  final String valueKey;
  final String label;
  final String semanticLabel;
  final Animation<double> motion;
  final bool animating;
  final List<String> details;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    excludeSemantics: true,
    label: semanticLabel,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: motion,
            builder: (BuildContext context, Widget? child) => Opacity(
              key: ValueKey<String>('$valueKey-motion'),
              opacity: animating ? .65 + .35 * motion.value : 1,
              child: child,
            ),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double fontSize = value == 'Ready' ? 36 : 72;
                final TextStyle style = Theme.of(context).typography.h1
                    .copyWith(
                      fontSize: fontSize,
                      height: 1.1,
                      fontWeight: FontWeight.w900,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    );
                final TextPainter measure = TextPainter(
                  text: TextSpan(text: value, style: style),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout();
                final double fit = math.min(
                  1,
                  constraints.maxWidth / measure.width,
                );
                measure.dispose();
                return Text(
                  value,
                  key: ValueKey<String>(valueKey),
                  textAlign: TextAlign.center,
                  style: style.copyWith(fontSize: fontSize * fit),
                );
              },
            ),
          ),
          if (details.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 16,
              runSpacing: 8,
              children: <Widget>[
                for (final String detail in details)
                  Text(
                    detail,
                    style: const TextStyle(
                      fontSize: 16,
                      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}
