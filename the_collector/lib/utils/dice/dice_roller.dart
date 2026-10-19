import 'dart:math';

class DiceRoll {
  DiceRoll._({required this.sides, required List<int> values})
    : values = List<int>.unmodifiable(values);

  final int sides;
  final List<int> values;
  int get total => values.fold<int>(0, (int sum, int value) => sum + value);
  String get notation => '${values.length}d$sides';
}

class DiceRoller {
  DiceRoller({Random? random}) : _random = random ?? Random.secure();

  static const List<int> supportedSides = <int>[4, 6, 8, 10, 12, 20, 100];
  static const int maximumDice = 10;
  static const int historyLimit = 12;
  final Random _random;
  final List<DiceRoll> _history = <DiceRoll>[];

  List<DiceRoll> get history => List<DiceRoll>.unmodifiable(_history);

  DiceRoll roll({required int sides, required int count}) {
    if (!supportedSides.contains(sides)) {
      throw ArgumentError.value(sides, 'sides', 'Unsupported die');
    }
    if (count < 1 || count > maximumDice) {
      throw RangeError.range(count, 1, maximumDice, 'count');
    }
    final DiceRoll result = DiceRoll._(
      sides: sides,
      values: List<int>.generate(count, (int _) => _random.nextInt(sides) + 1),
    );
    _history.insert(0, result);
    if (_history.length > historyLimit) _history.removeLast();
    return result;
  }

  void clear() => _history.clear();
}
