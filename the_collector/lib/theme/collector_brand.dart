import 'dart:math';

import 'package:arcane/arcane.dart';
import 'package:flutter_svg/flutter_svg.dart';

class CollectorLoading extends StatelessWidget {
  const CollectorLoading({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: label,
    child: ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CollectorBrandMark(size: 48),
          const SizedBox(height: 16),
          if (!MediaQuery.disableAnimationsOf(context)) ...<Widget>[
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(),
            ),
            const SizedBox(height: 12),
          ],
          Text(label, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class CollectorBrandMark extends StatefulWidget {
  const CollectorBrandMark({
    super.key,
    this.size = 200,
    this.color,
    this.onActivated,
    this.semanticLabel = 'The Collector',
  });

  final double size;
  final Color? color;
  final VoidCallback? onActivated;
  final String semanticLabel;

  @override
  State<CollectorBrandMark> createState() => _CollectorBrandMarkState();
}

class _CollectorBrandMarkState extends State<CollectorBrandMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    if (_spin.isAnimating) return;
    if (!MediaQuery.disableAnimationsOf(context)) {
      await _spin.forward(from: 0).orCancel.catchError((Object _) {});
    }
    if (mounted) widget.onActivated?.call();
  }

  @override
  Widget build(BuildContext context) {
    final Color color =
        widget.color ?? Theme.of(context).colorScheme.foreground;
    // The SVG viewport contains the full circular sweep; size keeps the artwork's width.
    final double canvasSize = widget.size * 648 / 578;
    final Widget mark = AnimatedBuilder(
      animation: _spin,
      child: SvgPicture.asset(
        'assets/images/Icon.svg',
        width: canvasSize,
        height: canvasSize,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        excludeFromSemantics: true,
      ),
      builder: (BuildContext context, Widget? child) =>
          Transform.rotate(angle: _spin.value * 2 * pi, child: child),
    );
    if (widget.onActivated == null) {
      return Semantics(label: widget.semanticLabel, image: true, child: mark);
    }
    return Semantics(
      label: widget.semanticLabel,
      button: true,
      child: IconButton(
        icon: mark,
        onPressed: _activate,
        variance: ButtonVariance.ghost,
      ),
    );
  }
}

class CollectorTypewriter extends StatefulWidget {
  const CollectorTypewriter(
    this.text, {
    super.key,
    this.characterDuration = const Duration(milliseconds: 50),
    this.style,
  });

  final String text;
  final Duration characterDuration;
  final TextStyle? style;

  @override
  State<CollectorTypewriter> createState() => _CollectorTypewriterState();
}

class _CollectorTypewriterState extends State<CollectorTypewriter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _typing = AnimationController(vsync: this);
  bool? _reduceMotion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion == reduceMotion) return;
    _reduceMotion = reduceMotion;
    _typing.duration = widget.characterDuration * widget.text.runes.length;
    if (reduceMotion || widget.text.isEmpty) {
      _typing.value = 1;
    } else {
      _typing.forward();
    }
  }

  @override
  void didUpdateWidget(CollectorTypewriter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _typing.duration = widget.characterDuration * widget.text.runes.length;
      if (_reduceMotion == true || widget.text.isEmpty) {
        _typing.value = 1;
      } else {
        _typing.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _typing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.text,
    child: ExcludeSemantics(
      child: GestureDetector(
        onTap: () => _typing.value = 1,
        child: AnimatedBuilder(
          animation: _typing,
          builder: (BuildContext context, Widget? child) {
            final List<int> characters = widget.text.runes.toList();
            final int visible = (_typing.value * characters.length).floor();
            final String shown = String.fromCharCodes(characters.take(visible));
            return Text(
              _typing.value == 1 ? widget.text : '$shown|',
              style: widget.style,
              textAlign: TextAlign.center,
            );
          },
        ),
      ),
    ),
  );
}
