import 'dart:math' as math;

import 'package:arcane/arcane.dart';
import 'package:flutter/semantics.dart' show SemanticsProperties;

import '../../utils/scanning/live_scan_tracker.dart';
import '../../utils/scanning/scan_recognition.dart';
import '../../utils/scanning/scan_resolver.dart';
import 'capture_preview_transform.dart';

class LiveCaptureOverlay extends StatefulWidget {
  const LiveCaptureOverlay({
    super.key,
    required this.tracks,
    required this.transform,
    this.retainedPhotoRegions = const <List<ScanPoint>>[],
    this.observedPhotoRegions = const <List<ScanPoint>>[],
    this.safeToMoveTrackIds = const <String>{},
    this.savingTrackIds = const <String>{},
    this.safeToMovePhotoRegions = const <List<ScanPoint>>[],
  });

  final List<LiveScanTrack> tracks;
  final CapturePreviewTransform transform;
  final List<List<ScanPoint>> retainedPhotoRegions;
  final List<List<ScanPoint>> observedPhotoRegions;
  final Set<String> safeToMoveTrackIds;
  final Set<String> savingTrackIds;
  final List<List<ScanPoint>> safeToMovePhotoRegions;

  @override
  State<LiveCaptureOverlay> createState() => _LiveCaptureOverlayState();
}

class _LiveCaptureOverlayState extends State<LiveCaptureOverlay>
    with SingleTickerProviderStateMixin {
  List<LiveScanTrack> get _visibleTracks => widget.tracks
      .where((LiveScanTrack track) => track.hasCardEvidence)
      .toList();
  final Map<String, _ContourColors> _colors = <String, _ContourColors>{};
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncColors();
  }

  @override
  void didUpdateWidget(LiveCaptureOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncColors();
  }

  void _syncColors() {
    final List<LiveScanTrack> tracks = _visibleTracks;
    final Set<String> ids = tracks
        .map((LiveScanTrack track) => track.photoFeedbackId)
        .toSet();
    _colors.removeWhere((String id, _ContourColors _) => !ids.contains(id));
    final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
    final bool changed = tracks.any((LiveScanTrack track) {
      final _ContourColors? previous = _colors[track.photoFeedbackId];
      return previous != null && previous.end != _contourColor(track);
    });
    final double progress = Curves.easeInOut.transform(_fade.value);
    for (final LiveScanTrack track in tracks) {
      final Color target = _contourColor(track);
      final _ContourColors? previous = _colors[track.photoFeedbackId];
      if (reducedMotion ||
          previous == null ||
          (previous.end == _green && !_safeTrack(track))) {
        _colors[track.photoFeedbackId] = _ContourColors(target, target);
      } else if (changed) {
        _colors[track.photoFeedbackId] = _ContourColors(
          previous.at(progress),
          target,
        );
      }
    }
    if (reducedMotion) {
      _fade.stop();
      _fade.value = 1;
    } else if (changed) {
      _fade.forward(from: 0);
    }
  }

  bool _safeTrack(LiveScanTrack track) =>
      widget.safeToMoveTrackIds.contains(track.photoFeedbackId) ||
      _safePhoto(track.corners);

  Color _contourColor(LiveScanTrack track) => _safeTrack(track)
      ? _green
      : widget.savingTrackIds.contains(track.photoFeedbackId) ||
            track.captured ||
            track.hasRetainedCapture ||
            track.capturedIdentified
      ? _yellow
      : _white;

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  String _status(LiveScanTrack track) {
    final ScanResolution? resolution = track.resolution;
    final ScanCandidate? candidate = resolution?.candidates.firstOrNull;
    if (_safeTrack(track)) {
      return track.capturedIdentified
          ? 'Saved. Ready. Printing review required.'
          : 'Saved. Ready. Identifying.';
    }
    if (widget.savingTrackIds.contains(track.photoFeedbackId)) {
      return 'Saving. Wait.';
    }
    if (track.captured || track.hasRetainedCapture) {
      return track.capturedIdentified
          ? 'Identified. Printing review required. Wait.'
          : 'Wait.';
    }
    if (track.confidence > 0 &&
        hasExactPrintingEvidence(track.crop, resolution)) {
      return '${candidate!.card.set.toUpperCase()} #${candidate.card.collectorNumber} · Printing matched';
    }
    if (candidate != null) {
      return candidate.evidence.contains(ScanEvidence.nameMatch)
          ? 'Name matched · Review printing'
          : 'Possible match · Review printing';
    }
    if (track.resolving) return 'Reading…';
    if (track.error != null) return 'Lookup unavailable';
    return 'Reading…';
  }

  bool _safePhoto(List<ScanPoint> corners) => widget.safeToMovePhotoRegions.any(
    (List<ScanPoint> safe) => _sameRegion(corners, safe),
  );

  String? _name(LiveScanTrack track) =>
      track.captured && !track.capturedIdentified
      ? null
      : track.resolution?.candidates.firstOrNull?.card.name;

  @override
  Widget build(BuildContext context) {
    final List<LiveScanTrack> tracks = _visibleTracks;
    return RepaintBoundary(
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _LiveCardPainter(
                  <_Contour>[
                    for (
                      int index = 0;
                      index < widget.observedPhotoRegions.length;
                      index++
                    )
                      _Contour(
                        'raw_observed_$index',
                        widget.observedPhotoRegions[index],
                        _ContourColors(
                          _safePhoto(widget.observedPhotoRegions[index])
                              ? _green
                              : _white,
                          _safePhoto(widget.observedPhotoRegions[index])
                              ? _green
                              : _white,
                        ),
                        _safePhoto(widget.observedPhotoRegions[index])
                            ? _savedStatus
                            : 'Detected.',
                      ),
                    for (
                      int index = 0;
                      index < widget.retainedPhotoRegions.length;
                      index++
                    )
                      _Contour(
                        'raw_photo_$index',
                        widget.retainedPhotoRegions[index],
                        _ContourColors(
                          _safePhoto(widget.retainedPhotoRegions[index])
                              ? _green
                              : _yellow,
                          _safePhoto(widget.retainedPhotoRegions[index])
                              ? _green
                              : _yellow,
                        ),
                        _safePhoto(widget.retainedPhotoRegions[index])
                            ? _savedStatus
                            : 'Wait.',
                      ),
                    for (final LiveScanTrack track in tracks)
                      _Contour(
                        track.id,
                        List<ScanPoint>.unmodifiable(track.corners),
                        _colors[track.photoFeedbackId]!,
                        '${_name(track) ?? 'Card'}. ${_status(track)}',
                      ),
                    for (
                      int index = 0;
                      index < widget.safeToMovePhotoRegions.length;
                      index++
                    )
                      if (!<List<ScanPoint>>[
                        ...widget.observedPhotoRegions,
                        ...widget.retainedPhotoRegions,
                        ...tracks.map((LiveScanTrack track) => track.corners),
                      ].any(
                        (List<ScanPoint> corners) => _sameRegion(
                          corners,
                          widget.safeToMovePhotoRegions[index],
                        ),
                      ))
                        _Contour(
                          'saved_photo_$index',
                          widget.safeToMovePhotoRegions[index],
                          const _ContourColors(_green, _green),
                          _savedStatus,
                        ),
                  ],
                  <List<ScanPoint>>[
                    for (final LiveScanTrack track in tracks)
                      if (widget.safeToMoveTrackIds.contains(
                        track.photoFeedbackId,
                      ))
                        List<ScanPoint>.unmodifiable(track.corners),
                    for (final List<ScanPoint> corners
                        in widget.safeToMovePhotoRegions)
                      if (!tracks.any(
                        (LiveScanTrack track) =>
                            widget.safeToMoveTrackIds.contains(
                              track.photoFeedbackId,
                            ) &&
                            _sameRegion(track.corners, corners),
                      ))
                        List<ScanPoint>.unmodifiable(corners),
                  ],
                  widget.transform,
                  _fade,
                  Directionality.of(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const String _savedStatus = 'Saved. Ready. Identifying.';

const Color _white = Color(0x42ffffff);
const Color _yellow = Color(0x70ffd65c);
const Color _green = Color(0x8575e09b);

bool _sameRegion(List<ScanPoint> first, List<ScanPoint> second) =>
    first.length == 4 &&
    second.length == 4 &&
    List<int>.generate(4, (int index) => index).every(
      (int index) =>
          (first[index].x - second[index].x).abs() <= .004 &&
          (first[index].y - second[index].y).abs() <= .004,
    );

class _ContourColors {
  const _ContourColors(this.begin, this.end);

  final Color begin;
  final Color end;

  Color at(double progress) => Color.lerp(begin, end, progress)!;
}

class _Contour {
  const _Contour(this.id, this.corners, this.colors, this.semanticLabel);

  final String id;
  final List<ScanPoint> corners;
  final _ContourColors colors;
  final String semanticLabel;
}

class _LiveCardPainter extends CustomPainter {
  _LiveCardPainter(
    this.contours,
    this.safeRegions,
    this.transform,
    this.phase,
    this.textDirection,
  ) : super(repaint: phase);

  final List<_Contour> contours;
  final List<List<ScanPoint>> safeRegions;
  final CapturePreviewTransform transform;
  final Animation<double> phase;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final double progress = Curves.easeInOut.transform(phase.value);
    for (final _Contour contour in contours) {
      if (contour.corners.length != 4) continue;
      final List<Offset> corners = contour.corners
          .map((ScanPoint point) => transform.project(Offset(point.x, point.y)))
          .toList();
      final Path path = Path()..addPolygon(corners, true);
      final Color color = contour.colors.at(progress);
      canvas.drawPath(path, Paint()..color = color);
    }
    for (final List<ScanPoint> region in safeRegions) {
      if (region.length != 4) continue;
      final List<Offset> corners = region
          .map((ScanPoint point) => transform.project(Offset(point.x, point.y)))
          .toList();
      final Offset center = corners.reduce((Offset a, Offset b) => a + b) / 4;
      final Offset horizontal =
          (corners[1] - corners[0] + corners[2] - corners[3]) / 2;
      final Offset vertical =
          (corners[3] - corners[0] + corners[2] - corners[1]) / 2;
      final double shortest = math.min(horizontal.distance, vertical.distance);
      if (shortest < 12) continue;
      final double extent = (shortest * .22).clamp(12, 36);
      final Offset x = horizontal / horizontal.distance * extent;
      final Offset y = vertical / vertical.distance * extent;
      final Path check = Path()
        ..moveTo((center - x * .5).dx, (center - x * .5).dy)
        ..lineTo(
          (center - x * .12 + y * .35).dx,
          (center - x * .12 + y * .35).dy,
        )
        ..lineTo(
          (center + x * .55 - y * .45).dx,
          (center + x * .55 - y * .45).dy,
        );
      for (final (Color color, double width) in <(Color, double)>[
        (Colors.black, 8),
        (Colors.white, 3.5),
      ]) {
        canvas.drawPath(
          check,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = width
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (Size size) {
    final Rect viewport = Offset.zero & size;
    final List<CustomPainterSemantics> semantics = <CustomPainterSemantics>[];
    for (final _Contour contour in contours) {
      if (contour.corners.length != 4) continue;
      final List<Offset> corners = contour.corners
          .map((ScanPoint point) => transform.project(Offset(point.x, point.y)))
          .toList();
      final Rect bounds = corners
          .skip(1)
          .fold<Rect>(
            Rect.fromPoints(corners.first, corners.first),
            (Rect bounds, Offset point) =>
                bounds.expandToInclude(Rect.fromPoints(point, point)),
          );
      if (!bounds.overlaps(viewport)) continue;
      semantics.add(
        CustomPainterSemantics(
          key: ValueKey<String>(contour.id),
          rect: bounds.intersect(viewport),
          properties: SemanticsProperties(
            label: contour.semanticLabel,
            textDirection: textDirection,
          ),
        ),
      );
    }
    for (int index = 0; index < safeRegions.length; index++) {
      final List<ScanPoint> region = safeRegions[index];
      if (region.length != 4 ||
          contours.any(
            (_Contour contour) => _sameRegion(contour.corners, region),
          )) {
        continue;
      }
      final List<Offset> corners = region
          .map((ScanPoint point) => transform.project(Offset(point.x, point.y)))
          .toList();
      final Rect bounds = corners
          .skip(1)
          .fold<Rect>(
            Rect.fromPoints(corners.first, corners.first),
            (Rect bounds, Offset point) =>
                bounds.expandToInclude(Rect.fromPoints(point, point)),
          );
      if (!bounds.overlaps(viewport)) continue;
      semantics.add(
        CustomPainterSemantics(
          key: ValueKey<String>('saved_photo_$index'),
          rect: bounds.intersect(viewport),
          properties: SemanticsProperties(
            label: _savedStatus,
            textDirection: textDirection,
          ),
        ),
      );
    }
    return semantics;
  };

  @override
  bool shouldRepaint(_LiveCardPainter oldDelegate) =>
      oldDelegate.contours != contours ||
      oldDelegate.safeRegions != safeRegions ||
      oldDelegate.transform != transform;

  @override
  bool shouldRebuildSemantics(_LiveCardPainter oldDelegate) =>
      oldDelegate.contours != contours ||
      oldDelegate.safeRegions != safeRegions ||
      oldDelegate.transform != transform ||
      oldDelegate.textDirection != textDirection;
}
