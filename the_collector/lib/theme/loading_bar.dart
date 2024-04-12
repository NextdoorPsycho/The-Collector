import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

class CupertinoProgressBar extends StatefulWidget {
  const CupertinoProgressBar({
    Key? key,
    this.value = 0.0,
    this.trackColor = CupertinoColors.systemFill,
    this.valueColor,
    this.semanticsLabel,
    this.semanticsValue,
    this.width, // Add this parameter
  })  : assert(value >= 0.0 && value <= 1.0),
        super(key: key);

  /// The value of this progress bar.
  ///
  /// A value of 0.0 means no progress and 1.0 means that progress is complete.
  final double value;

  /// The progress bar's background color.
  ///
  /// The [CupertinoColors.systemFill] color by default.
  final Color? trackColor;

  /// The progress bar's value color.
  ///
  /// The current theme's [CupertinoThemeData.primaryColor] by default.
  final Color? valueColor;

  /// {@macro flutter.material.progressIndicator.semanticsLabel}
  final String? semanticsLabel;

  /// {@macro flutter.material.progressIndicator.semanticsValue}
  final String? semanticsValue;

  final double? width; // Add this property

  @override
  _CupertinoProgressBarState createState() => _CupertinoProgressBarState();
}

class _CupertinoProgressBarState extends State<CupertinoProgressBar> {
  @override
  Widget build(BuildContext context) {
    String? expandedSemanticsValue = widget.semanticsValue;
    expandedSemanticsValue ??= '${(widget.value * 100).round()}%';
    return Semantics(
      label: widget.semanticsLabel,
      value: expandedSemanticsValue,
      child: _CupertinoProgressBarRenderObjectWidget(
        value: widget.value,
        valueColor: CupertinoDynamicColor.resolve(
          widget.valueColor ?? CupertinoTheme.of(context).primaryColor,
          context,
        ),
        trackColor: CupertinoDynamicColor.resolve(
          widget.trackColor ?? Color(0x00000000),
          context,
        ),
        width: widget.width, // Pass the width
      ),
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(PercentProperty('value', widget.value, showName: false));
  }
}

class _CupertinoProgressBarRenderObjectWidget extends LeafRenderObjectWidget {
  const _CupertinoProgressBarRenderObjectWidget({
    Key? key,
    required this.value,
    this.valueColor,
    this.trackColor,
    this.width,
  }) : super(key: key);

  final double value;
  final Color? valueColor;
  final Color? trackColor;
  final double? width;

  @override
  _RenderCupertinoProgressBar createRenderObject(BuildContext context) {
    return _RenderCupertinoProgressBar(
      value: value,
      valueColor: valueColor,
      trackColor: trackColor,
      textDirection: Directionality.of(context),
      width: width,
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, _RenderCupertinoProgressBar renderObject) {
    renderObject
      ..value = value
      ..valueColor = valueColor
      ..trackColor = trackColor
      ..textDirection = Directionality.of(context)
      ..width = width;
  }
}

const double _kPadding = 0.0;
const double _kBarHeight = 2.0;
// const double _kBarWidth = 176.0;

class _RenderCupertinoProgressBar extends RenderBox {
  _RenderCupertinoProgressBar({
    required double value,
    Color? valueColor,
    Color? trackColor,
    required TextDirection textDirection,
    double? width,
  })  : assert(value >= 0.0 && value <= 1.0),
        _value = value,
        _valueColor = valueColor,
        _trackColor = trackColor,
        _textDirection = textDirection,
        _width = width;

  double? _width;

  set width(double? value) {
    if (value == _width) return;
    _width = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final double constrainedWidth = constraints.maxWidth;
    final double desiredWidth = _width ?? constrainedWidth;
    final double progressBarWidth = min(desiredWidth, constrainedWidth);
    size = Size(progressBarWidth, _kBarHeight);
  }

  double get value => _value;
  double _value;

  set value(double newValue) {
    assert(newValue >= 0.0 && newValue <= 1.0);
    if (newValue == _value) return;
    _value = newValue;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  Color? get valueColor => _valueColor;
  Color? _valueColor;

  set valueColor(Color? value) {
    if (value == _valueColor) return;
    _valueColor = value;
    markNeedsPaint();
  }

  Color? get trackColor => _trackColor;
  Color? _trackColor;

  set trackColor(Color? value) {
    if (value == _trackColor) return;
    _trackColor = value;
    markNeedsPaint();
  }

  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;

  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsPaint();
  }

  double get _trackLeft => _kPadding;

  double get _trackRight => size.width - _kPadding;

  double? get _thumbCenter {
    double? visualPosition;
    switch (textDirection) {
      case TextDirection.rtl:
        visualPosition = 1.0 - _value;
        break;
      case TextDirection.ltr:
        visualPosition = _value;
        break;
    }
    return lerpDouble(_trackLeft, _trackRight, visualPosition);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    double? visualPosition;
    Color? leftColor;
    Color? rightColor;
    switch (textDirection) {
      case TextDirection.rtl:
        visualPosition = 1.0 - _value;
        leftColor = _valueColor;
        rightColor = trackColor;
        break;
      case TextDirection.ltr:
        visualPosition = _value;
        leftColor = trackColor;
        rightColor = _valueColor;
        break;
    }

    final double trackCenter = offset.dy + size.height / 2.0;
    final double trackLeft = offset.dx + _trackLeft;
    final double trackTop = max(0, trackCenter - 1.0);
    final double trackBottom = min(offset.dy + size.height, trackCenter + 1.0);
    final double trackRight = offset.dx + _trackRight;
    final double trackActive = offset.dx + _thumbCenter!;

    final Canvas canvas = context.canvas;

    if (visualPosition > 0.0 && rightColor != null) {
      final Paint paint = Paint()..color = rightColor;
      canvas.drawRRect(
          RRect.fromLTRBXY(
              trackLeft, trackTop, trackActive, trackBottom, 1.0, 1.0),
          paint);
    }

    if (visualPosition < 1.0 && leftColor != null) {
      final Paint paint = Paint()..color = leftColor;
      canvas.drawRRect(
          RRect.fromLTRBXY(
              trackActive, trackTop, trackRight, trackBottom, 1.0, 1.0),
          paint);
    }
  }
}
