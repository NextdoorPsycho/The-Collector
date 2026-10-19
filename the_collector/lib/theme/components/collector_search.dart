import 'package:arcane/arcane.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, TextInputAction;

class CollectorSearch extends StatefulWidget {
  const CollectorSearch({
    super.key,
    required this.controller,
    required this.label,
    required this.onChanged,
    required this.builder,
    this.fieldKey,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;
  final ValueChanged<String> onChanged;
  final Widget Function(BuildContext, Widget, Widget?) builder;
  final Key? fieldKey;
  final bool enabled;

  @override
  State<CollectorSearch> createState() => _CollectorSearchState();
}

class _CollectorSearchState extends State<CollectorSearch> {
  final FocusNode _focus = FocusNode();
  final FocusNode _shortcutsFocus = FocusNode(skipTraversal: true);
  late bool _expanded = widget.controller.text.isNotEmpty;
  double _pull = 0;
  bool _dragging = false;
  bool _revealQueued = false;

  @override
  void dispose() {
    _focus.dispose();
    _shortcutsFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(CollectorSearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      _dragging = false;
      _pull = 0;
      if (widget.enabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.enabled) _shortcutsFocus.requestFocus();
        });
      }
    }
  }

  void _dismissKeyboard() {
    if (widget.enabled) {
      _shortcutsFocus.requestFocus();
    } else {
      _focus.unfocus();
    }
  }

  void _open() {
    if (!widget.enabled) return;
    setState(() => _expanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _expanded && widget.enabled) _focus.requestFocus();
    });
  }

  void _close() {
    _dismissKeyboard();
    setState(() => _expanded = false);
    if (widget.controller.text.isNotEmpty) {
      widget.controller.clear();
      widget.onChanged('');
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (!widget.enabled ||
        _expanded ||
        notification.depth != 0 ||
        notification.metrics.axisDirection != AxisDirection.down) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _dragging = notification.dragDetails != null;
      _pull = 0;
    } else if (_dragging &&
        notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      final double distance =
          notification.metrics.minScrollExtent - notification.metrics.pixels;
      if (distance > _pull) _pull = distance;
    } else if (_dragging &&
        notification is OverscrollNotification &&
        notification.dragDetails != null) {
      if (notification.overscroll < 0) _pull -= notification.overscroll;
    } else if (notification is ScrollEndNotification) {
      final bool reveal = _dragging && _pull >= 48;
      _dragging = false;
      _pull = 0;
      if (reveal && !_revealQueued) {
        _revealQueued = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _revealQueued = false;
          if (mounted && !_expanded) _open();
        });
      }
    }
    return false;
  }

  Widget _button(String label, IconData icon, VoidCallback? action) => Tooltip(
    tooltip: (BuildContext context) => TooltipContainer(child: Text(label)),
    child: SizedBox.square(
      dimension: 44,
      child: IconButton(
        icon: Icon(icon, size: 20, semanticLabel: label),
        variance: ButtonVariance.ghost,
        onPressed: action,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      if (_expanded) const SingleActivator(LogicalKeyboardKey.escape): _close,
      const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _open,
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): _open,
    },
    child: Focus(
      focusNode: _shortcutsFocus,
      autofocus: widget.enabled,
      canRequestFocus: widget.enabled,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.builder(
          context,
          _button(
            widget.label,
            Icons.magnifying_glass,
            widget.enabled ? _open : null,
          ),
          _expanded
              ? Row(
                  children: <Widget>[
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 44),
                        child: TextField(
                          key: widget.fieldKey,
                          controller: widget.controller,
                          focusNode: _focus,
                          semanticLabel: widget.label,
                          placeholder: ExcludeSemantics(
                            child: Text(widget.label),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          style: const TextStyle(fontSize: 14),
                          textInputAction: TextInputAction.search,
                          onChanged: widget.onChanged,
                          onSubmitted: (String _) => _dismissKeyboard(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _button('Close search', Icons.x, _close),
                  ],
                )
              : null,
        ),
      ),
    ),
  );
}
