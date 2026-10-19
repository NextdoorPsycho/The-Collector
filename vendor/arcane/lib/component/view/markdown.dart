import 'package:arcane/arcane.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:tinycolor2/tinycolor2.dart';
import 'package:url_launcher/url_launcher.dart';

class TextSelect extends StatelessWidget {
  final Widget child;

  const TextSelect({super.key, required this.child});

  @override
  Widget build(BuildContext context) => SelectionArea(child: child);
}

class Markdown extends StatelessWidget {
  final String data;
  final TextStyle? style;

  const Markdown(this.data, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return GptMarkdown(
      data,
      style: style,
      styleSheet: GptMarkdownStyleSheet(
        link: LinkStyle(
          color: theme.colorScheme.primary.mix(
            theme.colorScheme.foreground,
            50,
          ),
          hoverColor: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
        table: TableStyle(
          borderColor: theme.colorScheme.border,
          borderWidth: 1,
          borderRadius: Radius.circular(theme.radiusMd),
          cellPadding: const EdgeInsets.all(8),
          headerBackground: theme.colorScheme.card,
        ),
      ),
      codeBuilder: codeBuilder,
      blockQuoteBuilder: (
        BuildContext context,
        Widget child,
        BlockQuoteStyle style,
      ) => SurfaceCard(padding: const EdgeInsets.all(12), child: child),
      onLinkTap: (String url, String title) => openLink(context, url, title),
    );
  }

  Future<void> openLink(BuildContext context, String url, String title) async {
    final Uri uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (context.mounted) {
      TextToast('Could not open link: $url').open(context);
    }
  }

  Widget codeBuilder(
    BuildContext context,
    String name,
    String code,
    bool closed,
  ) => SurfaceCard(
    padding: const EdgeInsets.all(12),
    child: SelectableText(code).mono().small(),
  );
}
