import 'dart:math';

class BoundaryRandom implements Random {
  BoundaryRandom(this.maximum);
  final bool maximum;
  @override
  int nextInt(int max) => maximum ? max - 1 : 0;
  @override
  bool nextBool() => maximum;
  @override
  double nextDouble() => maximum ? .99 : 0;
}
