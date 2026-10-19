import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:sensors_plus/sensors_plus.dart';

class CardEffects extends StatefulWidget {
  const CardEffects({
    super.key,
    required this.child,
    this.foil = false,
    this.parallax = false,
  });

  final Widget child;
  final bool foil;
  final bool parallax;

  @override
  State<CardEffects> createState() => _CardEffectsState();
}

class _CardEffectsState extends State<CardEffects> {
  StreamSubscription<AccelerometerEvent>? _sensorSubscription;
  Offset _motion = Offset.zero;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      _sensorSubscription =
          accelerometerEventStream(
            samplingPeriod: SensorInterval.uiInterval,
          ).listen(
            (AccelerometerEvent event) => _setMotion(
              Offset(
                (-event.x / 9.81).clamp(-1.0, 1.0),
                (event.y / 9.81).clamp(-1.0, 1.0),
              ),
            ),
            onError: (Object error, StackTrace stackTrace) {},
            cancelOnError: true,
          );
    }
  }

  void _setMotion(Offset motion) {
    if (mounted && motion != _motion) {
      setState(() => _motion = motion);
    }
  }

  void _movePointer(Offset position, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _setMotion(
      Offset(
        (position.dx / size.width * 2 - 1).clamp(-1.0, 1.0),
        (position.dy / size.height * 2 - 1).clamp(-1.0, 1.0),
      ),
    );
  }

  @override
  void dispose() {
    _sensorSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.foil && !widget.parallax) return widget.child;
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          MouseRegion(
            onExit: (_) => _setMotion(Offset.zero),
            child: Listener(
              onPointerHover: (PointerHoverEvent event) =>
                  _movePointer(event.localPosition, context.size ?? Size.zero),
              onPointerMove: (PointerMoveEvent event) =>
                  _movePointer(event.localPosition, context.size ?? Size.zero),
              onPointerUp: (_) => _setMotion(Offset.zero),
              onPointerCancel: (_) => _setMotion(Offset.zero),
              child: TweenAnimationBuilder<Offset>(
                tween: Tween<Offset>(begin: Offset.zero, end: _motion),
                duration: const Duration(milliseconds: 150),
                child: widget.child,
                builder: (BuildContext context, Offset motion, Widget? child) {
                  Widget result = child!;
                  if (widget.foil) {
                    result = ShaderMask(
                      blendMode: BlendMode.srcATop,
                      shaderCallback: (Rect bounds) => LinearGradient(
                        begin: Alignment(
                          -1 + motion.dx * 0.55,
                          -1 + motion.dy * 0.55,
                        ),
                        end: Alignment(
                          1 + motion.dx * 0.55,
                          1 + motion.dy * 0.55,
                        ),
                        tileMode: TileMode.repeated,
                        colors: const <Color>[
                          Color(0x66f44336),
                          Color(0x66ff9800),
                          Color(0x66ffeb3b),
                          Color(0x664caf50),
                          Color(0x662196f3),
                          Color(0x663f51b5),
                          Color(0x669c27b0),
                          Color(0x66e91e63),
                          Color(0x66f44336),
                        ],
                      ).createShader(bounds),
                      child: result,
                    );
                  }
                  if (widget.parallax) {
                    result = Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.002)
                        ..rotateX(-motion.dy * 0.3)
                        ..rotateY(motion.dx * 0.18)
                        ..rotateZ(motion.dx * 0.15),
                      child: result,
                    );
                  }
                  return result;
                },
              ),
            ),
          ),
    );
  }
}
