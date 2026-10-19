import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class RulesReference {
  RulesReference(
    this.text,
    this.source,
    this.fetchedAt, {
    this.fromCache = false,
    this.updateFailed = false,
    this.savedOffline = true,
  });

  final bool fromCache;
  final bool updateFailed;
  final bool savedOffline;
  late final List<RuleParagraph> paragraphs = _paragraphs(text);

  static List<RuleParagraph> _paragraphs(String text) {
    final List<RuleParagraph> result = <RuleParagraph>[];
    String? section;
    final RegExp numberedLine = RegExp(
      r'^\d{1,3}\.(?:\d+[a-z]?)?\.?[ \t]+',
      caseSensitive: false,
      multiLine: true,
    );
    for (final String block in _withoutContents(
      text,
    ).split(RegExp(r'\r?\n\s*\r?\n'))) {
      if (block.trim().isEmpty) {
        continue;
      }
      final List<int> starts = <int>[0];
      if (!RuleParagraph(block).isContents) {
        for (final RegExpMatch match in numberedLine.allMatches(block)) {
          if (match.start > 0) starts.add(match.start);
        }
      }
      for (int index = 0; index < starts.length; index++) {
        final String entry = block
            .substring(
              starts[index],
              index + 1 < starts.length ? starts[index + 1] : block.length,
            )
            .trim();
        if (entry.isEmpty) continue;
        final RuleParagraph paragraph = RuleParagraph(entry);
        if (paragraph.body.trim() == 'Glossary' ||
            paragraph.body.trim() == 'Credits' ||
            (paragraph.number != null &&
                RegExp(r'^\d\.$').hasMatch(paragraph.number!))) {
          section = null;
        }
        if (paragraph.isHeading &&
            paragraph.number!.length == 4 &&
            !paragraph.body.contains('\n')) {
          section = '${paragraph.number} ${paragraph.body}';
        }
        result.add(RuleParagraph(entry, section: section));
      }
    }
    return List<RuleParagraph>.unmodifiable(result);
  }

  static String _withoutContents(String text) {
    final RegExpMatch? contents = RegExp(
      r'^Contents[ \t]*\r?$',
      multiLine: true,
    ).firstMatch(text);
    if (contents == null) return text;
    final RegExp heading = RegExp(r'^\d\. [^\r\n]+', multiLine: true);
    final Iterable<RegExpMatch> headings = heading.allMatches(
      text,
      contents.end,
    );
    if (headings.isEmpty) return text;
    final String firstHeading = headings.first.group(0)!;
    for (final RegExpMatch match in headings.skip(1)) {
      if (match.group(0) == firstHeading) {
        return '${text.substring(0, contents.start)}\n\n${text.substring(match.start)}';
      }
    }
    return text;
  }

  late final List<RuleParagraph> sections = _sections();

  List<RuleParagraph> _sections() {
    final Map<String, RuleParagraph> headings = <String, RuleParagraph>{};
    for (final RuleParagraph paragraph in paragraphs) {
      if (paragraph.number != null &&
          RegExp(r'^\d\.$').hasMatch(paragraph.number!) &&
          !paragraph.body.contains('\n')) {
        headings[paragraph.number!] = paragraph;
      }
    }
    return List<RuleParagraph>.unmodifiable(headings.values);
  }

  final String text;
  final Uri source;
  final DateTime fetchedAt;
  static final Uri index = Uri.parse('https://magic.wizards.com/en/rules');

  static Future<RulesReference> load({
    bool refresh = false,
    http.Client? httpClient,
  }) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? cached = preferences.getString('comprehensiveRules.text');
    final String? source = preferences.getString('comprehensiveRules.source');
    final String? fetched = preferences.getString(
      'comprehensiveRules.fetchedAt',
    );
    RulesReference? previous;
    if (cached != null && source != null && fetched != null) {
      final Uri? uri = Uri.tryParse(source);
      final DateTime? at = DateTime.tryParse(fetched);
      if (uri != null &&
          _official(uri) &&
          at != null &&
          cached.contains('Comprehensive Rules')) {
        previous = RulesReference(cached, uri, at, fromCache: true);
      }
    }
    if (!refresh && previous != null) {
      return previous;
    }
    final http.Client client = httpClient ?? http.Client();
    try {
      final http.Response listing = await client
          .get(index)
          .timeout(const Duration(seconds: 20));
      if (listing.statusCode != 200) {
        throw StateError('Rules index unavailable.');
      }
      final Uri uri = locateTextSource(listing.body);
      final http.Response rules = await client
          .get(uri)
          .timeout(const Duration(seconds: 30));
      if (rules.statusCode != 200) {
        throw StateError('Rules unavailable.');
      }
      final String text = utf8.decode(rules.bodyBytes);
      if (!text.contains('Comprehensive Rules') || text.length < 10000) {
        throw const FormatException('Not a comprehensive rules document.');
      }
      final DateTime now = DateTime.now().toUtc();
      bool saved = false;
      try {
        final List<bool> stored = await Future.wait<bool>(<Future<bool>>[
          preferences.setString('comprehensiveRules.text', text),
          preferences.setString('comprehensiveRules.source', uri.toString()),
          preferences.setString(
            'comprehensiveRules.fetchedAt',
            now.toIso8601String(),
          ),
        ]);
        saved = stored.every((bool value) => value);
      } catch (_) {
        // The downloaded reference remains readable when device storage is full.
      }
      return RulesReference(text, uri, now, savedOffline: saved);
    } catch (_) {
      if (previous != null) {
        return RulesReference(
          previous.text,
          previous.source,
          previous.fetchedAt,
          fromCache: true,
          updateFailed: true,
        );
      }
      rethrow;
    } finally {
      if (httpClient == null) {
        client.close();
      }
    }
  }

  static bool _official(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host.toLowerCase() == 'media.wizards.com' &&
      uri.userInfo.isEmpty &&
      uri.path.toLowerCase().endsWith('.txt');

  static Uri locateTextSource(String html) {
    final String decoded = html
        .replaceAllMapped(RegExp(r'\\u002[fF]'), (_) => '/')
        .replaceAll(r'\/', '/')
        .replaceAll('&amp;', '&');
    final Iterable<RegExpMatch> matches = RegExp(
      r'''https://[^"'\r\n<>\\]+''',
      caseSensitive: false,
    ).allMatches(decoded);
    for (final RegExpMatch match in matches) {
      final Uri? uri = Uri.tryParse(match.group(0)!);
      if (uri != null && _official(uri)) {
        return uri;
      }
    }
    throw const FormatException('Rules download not found.');
  }

  List<RuleParagraph> find(String query) {
    String lower = query.trim().toLowerCase();
    if (RegExp(r'^\d{1,3}\.\d+[a-z]?\.$').hasMatch(lower)) {
      lower = lower.substring(0, lower.length - 1);
    }
    if (lower.length < 2) {
      return <RuleParagraph>[];
    }
    final bool number = RegExp(r'^\d{1,3}(?:\.\d+[a-z]?)?\.?$').hasMatch(lower);
    return paragraphs.where((RuleParagraph paragraph) {
      if (paragraph.isContents) {
        return false;
      }
      if (!number) {
        return paragraph.searchText.contains(lower);
      }
      final String? identifier = paragraph.number?.toLowerCase();
      if (identifier == null) {
        return false;
      }
      if (lower.length == 2 && lower.endsWith('.')) {
        return identifier == lower ||
            (identifier.length >= 4 && identifier.startsWith(lower[0]));
      }
      if (lower.endsWith('.')) {
        return identifier.startsWith(lower);
      }
      if (!lower.contains('.')) {
        return identifier == '$lower.' || identifier.startsWith('$lower.');
      }
      return identifier == lower ||
          RegExp('^${RegExp.escape(lower)}[a-z]\\b').hasMatch(identifier);
    }).toList();
  }

  List<String> search(String query) =>
      find(query).map((RuleParagraph paragraph) => paragraph.text).toList();
}

class RuleParagraph {
  RuleParagraph(this.text, {this.section}) {
    final RegExpMatch? prefix = RegExp(
      r'^(\d{1,3}\.(?:\d+[a-z]?)?)\.?\s+',
      caseSensitive: false,
    ).firstMatch(text.trim());
    number = prefix?.group(1);
    label = prefix?.group(0)?.trim();
    body = prefix == null ? text.trim() : text.trim().substring(prefix.end);
  }
  final String text;
  final String? section;
  late final String? number;
  late final String? label;
  late final String body;
  late final String searchText = text.toLowerCase();
  bool get isHeading => number?.endsWith('.') ?? false;
  late final bool isContents =
      RegExp(r'^\d\.\s').hasMatch(text.trim()) &&
      RegExp(r'^\d{3}\.\s', multiLine: true).allMatches(text).length > 5;
}
