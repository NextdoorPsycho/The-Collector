import 'dart:math' as math;

import 'package:arcane/arcane.dart';
import 'package:collector_models/card/card_prices.dart';
import 'package:the_collector/utils/valuation.dart';

typedef PriceHistoryPoint = ({DateTime date, double total});

class PriceHistoryPlot extends StatelessWidget {
  const PriceHistoryPlot({
    super.key,
    required this.points,
    required this.currency,
  });

  final List<PriceHistoryPoint> points;
  final CardCurrency currency;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) return const SizedBox.shrink();
    final List<PriceHistoryPoint> ordered = List<PriceHistoryPoint>.of(points)
      ..sort(
        (PriceHistoryPoint a, PriceHistoryPoint b) => a.date.compareTo(b.date),
      );
    final double low = ordered
        .map((PriceHistoryPoint p) => p.total)
        .reduce(math.min);
    final double high = ordered
        .map((PriceHistoryPoint p) => p.total)
        .reduce(math.max);
    final Color ink = Theme.of(context).colorScheme.foreground;
    final Color muted = Theme.of(context).colorScheme.mutedForeground;
    return Semantics(
      label:
          'Recorded collection value, ${ordered.length} observations. '
          'From ${formatValue(ordered.first.total, currency)} '
          'to ${formatValue(ordered.last.total, currency)}. '
          'Range ${formatValue(low, currency)} to ${formatValue(high, currency)}.',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Recorded collection value',
              style: TextStyle(fontSize: 12, color: muted),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 84,
              child: CustomPaint(
                painter: _HistoryPainter(
                  points: ordered,
                  ink: ink,
                  rule: Theme.of(context).colorScheme.border,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  _date(ordered.first.date),
                  style: TextStyle(fontSize: 11, color: muted),
                ),
                Text(
                  _date(ordered.last.date),
                  style: TextStyle(fontSize: 11, color: muted),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Includes cards added or removed.',
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ],
        ),
      ),
    );
  }

  static String _date(DateTime date) =>
      date.toLocal().toIso8601String().split('T').first;
}

class _HistoryPainter extends CustomPainter {
  const _HistoryPainter({
    required this.points,
    required this.ink,
    required this.rule,
  });

  final List<PriceHistoryPoint> points;
  final Color ink;
  final Color rule;

  @override
  void paint(Canvas canvas, Size size) {
    final double low = points
        .map((PriceHistoryPoint p) => p.total)
        .reduce(math.min);
    final double high = points
        .map((PriceHistoryPoint p) => p.total)
        .reduce(math.max);
    final int start = points.first.date.millisecondsSinceEpoch;
    final int span = points.last.date.millisecondsSinceEpoch - start;
    final Paint grid = Paint()
      ..color = rule
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 4),
      Offset(size.width, size.height - 4),
      grid,
    );
    final Path path = Path();
    final List<Offset> positions = <Offset>[];
    for (int index = 0; index < points.length; index++) {
      final PriceHistoryPoint point = points[index];
      final double x = span == 0
          ? index / (points.length - 1)
          : (point.date.millisecondsSinceEpoch - start) / span;
      final double y = high == low ? .5 : (point.total - low) / (high - low);
      final Offset position = Offset(
        4 + x * (size.width - 8),
        4 + (1 - y) * (size.height - 8),
      );
      positions.add(position);
      if (index == 0) {
        path.moveTo(position.dx, position.dy);
      } else {
        path.lineTo(position.dx, position.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = ink
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
    final Paint pointPaint = Paint()..color = ink;
    for (final Offset position in positions) {
      canvas.drawCircle(position, 2.5, pointPaint);
    }
  }

  @override
  bool shouldRepaint(_HistoryPainter oldDelegate) =>
      oldDelegate.ink != ink ||
      oldDelegate.rule != rule ||
      oldDelegate.points != points;
}
