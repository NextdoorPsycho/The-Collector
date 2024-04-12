import 'dart:math';

import 'package:flutter/material.dart';

class SpinningTriangle extends StatefulWidget {
  final Color iconColor;
  final double size;

  const SpinningTriangle({
    super.key,
    required this.iconColor,
    this.size = 200,
  });

  @override
  _SpinningTriangleState createState() => _SpinningTriangleState();
}

class _SpinningTriangleState extends State<SpinningTriangle>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _animation = Tween<double>(begin: 0, end: 2 * pi).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.linear,
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Transform(
          alignment: const Alignment(0, 0.25),
          transform: Matrix4.rotationZ(_animation.value + pi),
          child: Icon(
            Icons.change_history_sharp,
            size: widget.size,
            color: widget.iconColor,
          ),
        );
      },
    );
  }
}
