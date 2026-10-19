import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:magic_card/src/card/card_effects.dart';

Widget _surface({bool disableAnimations = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: disableAnimations),
  child: const Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(
        width: 200,
        height: 300,
        child: CardEffects(
          foil: true,
          parallax: true,
          child: ColoredBox(color: Color(0xffffffff)),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('pointer movement tilts the card and exit resets it', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_surface());
    final Transform initial = tester.widget<Transform>(find.byType(Transform));
    final List<double> initialMatrix = initial.transform.storage.toList();
    final TestGesture pointer = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await pointer.addPointer(location: Offset.zero);
    await pointer.moveTo(
      tester.getTopRight(find.byType(CardEffects)) - const Offset(10, -10),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final Transform tilted = tester.widget<Transform>(find.byType(Transform));
    expect(tilted.transform.storage.toList(), isNot(initialMatrix));
    expect(find.byType(ShaderMask), findsOneWidget);

    await pointer.moveTo(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final Transform reset = tester.widget<Transform>(find.byType(Transform));
    expect(reset.transform.storage.toList(), initialMatrix);
    await pointer.removePointer();
  });

  testWidgets('reduced motion bypasses the card effects', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_surface(disableAnimations: true));
    expect(find.byType(ShaderMask), findsNothing);
    expect(find.byType(Transform), findsNothing);
    expect(find.byType(ColoredBox), findsOneWidget);
  });
}
