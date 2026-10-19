import 'package:flutter_test/flutter_test.dart';
import 'package:the_collector/utils/dice/dice_roller.dart';

import 'helpers/dice_boundary_random.dart';

void main() {
  test('every supported die can reach one and its largest face', () {
    for (final int sides in DiceRoller.supportedSides) {
      for (final bool maximum in <bool>[false, true]) {
        final DiceRoller roller = DiceRoller(random: BoundaryRandom(maximum));
        final DiceRoll roll = roller.roll(sides: sides, count: 10);
        expect(roll.values, List<int>.filled(10, maximum ? sides : 1));
        expect(roll.total, maximum ? sides * 10 : 10);
        expect(roll.notation, '10d$sides');
      }
    }
  });

  test(
    'roll history is bounded, newest first and keeps original configuration',
    () {
      final DiceRoller roller = DiceRoller(random: BoundaryRandom(true));
      final DiceRoll original = roller.roll(sides: 4, count: 1);
      final List<DiceRoll> before = roller.history;
      for (int index = 0; index < 15; index++) {
        roller.roll(sides: 100, count: index % 10 + 1);
      }
      expect(roller.history.length, DiceRoller.historyLimit);
      expect(roller.history.first.notation, '5d100');
      expect(roller.history.first.total, 500);
      expect(roller.history, isNot(contains(original)));
      expect(before.single.notation, '1d4');
      expect(() => before.clear(), throwsUnsupportedError);
      expect(() => original.values.add(2), throwsUnsupportedError);
      roller.clear();
      expect(roller.history, isEmpty);
      expect(before.single, same(original));
    },
  );

  test('invalid count or die never changes existing history', () {
    final DiceRoller roller = DiceRoller(random: BoundaryRandom(false));
    final DiceRoll saved = roller.roll(sides: 6, count: 1);
    expect(() => roller.roll(sides: 6, count: 0), throwsRangeError);
    expect(() => roller.roll(sides: 6, count: 11), throwsRangeError);
    expect(() => roller.roll(sides: 2, count: 1), throwsArgumentError);
    expect(roller.history, <DiceRoll>[saved]);
  });
}
