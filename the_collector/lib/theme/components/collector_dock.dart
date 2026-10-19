import 'package:arcane/arcane.dart';

class CollectorDockItem {
  const CollectorDockItem({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
}

class CollectorDock extends StatelessWidget {
  const CollectorDock({
    super.key,
    required this.items,
    required this.selectedIndex,
  });

  final List<CollectorDockItem> items;
  final int selectedIndex;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    minimum: const EdgeInsets.all(4),
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final ColorScheme colors = Theme.of(context).colorScheme;
        final double width = constraints.maxWidth / items.length;
        return Row(
          children: <Widget>[
            for (int index = 0; index < items.length; index++)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: selectedIndex == index,
                  label: items[index].label,
                  child: Tooltip(
                    tooltip: (BuildContext context) =>
                        TooltipContainer(child: Text(items[index].label)),
                    child: Button(
                      key: ValueKey<String>('dock-${items[index].label}'),
                      style: ButtonStyle.ghost(
                        density: ButtonDensity(
                          (EdgeInsets _) => EdgeInsets.zero,
                        ),
                      ),
                      onPressed: items[index].onPressed,
                      child: ExcludeSemantics(
                        child: Container(
                          height: 48,
                          width: width,
                          color: selectedIndex == index
                              ? colors.foreground
                              : colors.background,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Icon(
                                items[index].icon,
                                size: 19,
                                color: selectedIndex == index
                                    ? colors.background
                                    : colors.mutedForeground,
                              ),
                              if (MediaQuery.textScalerOf(context).scale(10) <=
                                      16 &&
                                  MediaQuery.textScalerOf(context).scale(10) *
                                          items[index].label.length *
                                          .55 <
                                      width - 4) ...<Widget>[
                                const SizedBox(height: 3),
                                Text(
                                  items[index].label,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: selectedIndex == index
                                        ? colors.background
                                        : colors.mutedForeground,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}
