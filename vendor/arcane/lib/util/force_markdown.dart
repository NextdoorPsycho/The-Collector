import 'package:arcane/arcane.dart';

class ForceMarkdown extends StatelessWidget {
  final String data;
  final TextStyle genericStyle;

  const ForceMarkdown(
    this.data, {
    super.key,
    this.genericStyle = const TextStyle(),
  });

  @override
  Widget build(BuildContext context) => Markdown(data, style: genericStyle);
}
