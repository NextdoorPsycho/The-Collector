import 'package:arcane/arcane.dart';

class Selector<T> extends StatelessWidget {
  final bool canUnselect;
  final T? value;
  final ValueChanged<T?>? onChanged;
  final List<T> values;
  final String Function(T) labelBuilder;

  const Selector({
    super.key,
    this.canUnselect = false,
    this.value,
    this.onChanged,
    required this.values,
    required this.labelBuilder,
  });

  @override
  Widget build(BuildContext context) => Select<T>(
    itemBuilder: (BuildContext context, T item) => Text(labelBuilder(item)),
    value: value,
    onChanged: onChanged,
    placeholder: const Text('Any'),
    popupWidthConstraint: PopoverConstraint.anchorFixedSize,
    canUnselect: canUnselect,
    // SelectPopup installs the handle used by the option buttons.
    popup: SelectPopup<T>(
      items: SelectItemList(children: <Widget>[
        for (final T option in values) SelectItemButton<T>(value: option, child: Text(labelBuilder(option))),
      ]),
    ),
  );
}
