import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_collector/utils/rules_reference.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('official text link is discovered from HTML and escaped JSON', () {
    for (final String html in <String>[
      '<a href="https://media.wizards.com/2026/downloads/MagicCompRules.txt">Rules</a>',
      r'{"url":"https:\/\/media.wizards.com\/2026\/MagicCompRules.txt"}',
      r'{"url":"https:\u002F\u002Fmedia.wizards.com\u002F2026\u002FMagicCompRules.txt"}',
    ]) {
      final Uri uri = RulesReference.locateTextSource(html);
      expect(uri.scheme, 'https');
      expect(uri.host, 'media.wizards.com');
      expect(uri.path.endsWith('.txt'), isTrue);
    }
  });

  test('official download filename accepts a literal space in its href', () {
    final Uri uri = RulesReference.locateTextSource(
      '<a href="https://media.wizards.com/2026/downloads/MagicCompRules 20260925.txt">TXT</a>',
    );
    expect(
      uri.toString(),
      'https://media.wizards.com/2026/downloads/MagicCompRules%2020260925.txt',
    );
  });

  test(
    'official URL preserves escaped query parameters and rejects other files',
    () {
      final Uri uri = RulesReference.locateTextSource(
        '<a href="https://media.wizards.com/downloads/rules.txt?lang=en&amp;rev=2">Rules</a>',
      );
      expect(uri.queryParameters, <String, String>{'lang': 'en', 'rev': '2'});
      expect(
        () => RulesReference.locateTextSource(
          '<a href="https://media.wizards.com/rules.txt.exe">Wrong</a>',
        ),
        throwsFormatException,
      );
      expect(
        () => RulesReference.locateTextSource(
          '<a href="https://example.com/rules.txt">Wrong</a>',
        ),
        throwsFormatException,
      );
      expect(
        () => RulesReference.locateTextSource('<p>No download</p>'),
        throwsFormatException,
      );
    },
  );

  test('search trims queries, ignores case, and groups CRLF paragraphs', () {
    final RulesReference reference = RulesReference(
      'Comprehensive Rules\r\n\r\n100.1 Players play.\r\nThis continues.\r\n \r\n101.2 PLAYER choices.\r\n\r\n200. Other.',
      Uri.parse('https://media.wizards.com/rules.txt'),
      DateTime.utc(2026),
    );
    expect(reference.search(' PLAYER '), <String>[
      '100.1 Players play.\r\nThis continues.',
      '101.2 PLAYER choices.',
    ]);
    expect(reference.search('p'), isEmpty);
    expect(reference.search(' absent '), isEmpty);
    expect(reference.search('  '), isEmpty);
  });

  test('number search respects rule boundaries and preserves full official paragraphs', () {
    final RulesReference reference = RulesReference(
      'Comprehensive Rules\n\n1. Game Concepts\n\n100. General\n\n100.1 Players play.\nThis continues.\n\n100.1a Players choose.\n\n100.10 Another rule.\n\n2. Parts of a Card',
      Uri.parse('https://media.wizards.com/rules.txt'),
      DateTime.utc(2026),
    );
    expect(
      reference.sections.map((RuleParagraph value) => value.number),
      <String>['1.', '2.'],
    );
    expect(
      reference.find('100.1').map((RuleParagraph value) => value.number),
      <String>['100.1', '100.1a'],
    );
    expect(reference.find('100.').length, 4);
    expect(
      reference.find('100.1').first.body,
      'Players play.\nThis continues.',
    );
    expect(
      reference.search('players').first,
      '100.1 Players play.\nThis continues.',
    );
  });

  test('failed update keeps cached official rules available offline', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'comprehensiveRules.text': 'Comprehensive Rules\n\n100.1 Saved rule.',
      'comprehensiveRules.source': 'https://media.wizards.com/saved.txt',
      'comprehensiveRules.fetchedAt': '2026-10-01T00:00:00.000Z',
    });
    final RulesReference reference = await RulesReference.load(
      refresh: true,
      httpClient: MockClient(
        (http.Request request) async => throw StateError('offline'),
      ),
    );
    expect(reference.updateFailed, isTrue);
    expect(reference.fromCache, isTrue);
    expect(reference.find('100.1').single.body, 'Saved rule.');
    expect(reference.fetchedAt, DateTime.utc(2026, 10, 1));
  });

  test('corrupt cached timestamp downloads a valid exact UTF-8 reference instead of failing', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'comprehensiveRules.text': 'Comprehensive Rules',
      'comprehensiveRules.source': 'https://media.wizards.com/saved.txt',
      'comprehensiveRules.fetchedAt': 'broken',
    });
    final String document =
        'Comprehensive Rules\n\n100.1 “Official” wording.\n\n${List<String>.filled(1000, '100.2 Rules.').join('\n\n')}';
    final List<Uri> requests = <Uri>[];
    final RulesReference reference = await RulesReference.load(
      httpClient: MockClient((http.Request request) async {
        requests.add(request.url);
        return request.url == RulesReference.index
            ? http.Response(
                '<a href="https://media.wizards.com/rules.txt">TXT</a>',
                200,
              )
            : http.Response(
                document,
                200,
                headers: <String, String>{
                  'content-type': 'text/plain; charset=utf-8',
                },
              );
      }),
    );
    expect(requests, hasLength(2));
    expect(reference.text, document);
    expect(reference.updateFailed, isFalse);
    expect(reference.savedOffline, isTrue);
    final RulesReference cached = await RulesReference.load(
      httpClient: MockClient(
        (http.Request request) async =>
            throw StateError('network should not be used'),
      ),
    );
    expect(cached.text, document);
  });

  test('search omits the repeated table of contents and retains official section context', () {
    final String contents = <String>[
      '1. Game Concepts',
      for (int index = 100; index < 107; index++) '$index. Commander index',
    ].join('\n');
    final RulesReference reference = RulesReference(
      'Comprehensive Rules\n\n$contents\n\n9. Casual Variants\n\n903. Commander\n\n903.1 Commander uses a legendary creature.\n\nGlossary\n\nCommander\nA legendary creature.',
      Uri.parse('https://media.wizards.com/rules.txt'),
      DateTime.utc(2026),
    );
    final List<RuleParagraph> matches = reference.find('commander');
    expect(matches, hasLength(3));
    expect(matches[1].section, '903. Commander');
    expect(matches[2].section, isNull);
    expect(
      reference.sections.map((RuleParagraph paragraph) => paragraph.number),
      <String>['9.'],
    );
  });

  test('official main-rule terminal periods are indexed without losing displayed punctuation', () {
    final RulesReference reference = RulesReference(
      'Comprehensive Rules\n\n608. Resolving Spells and Abilities\n\n608.2. If the object that’s resolving is an instant spell.\n\n608.2a This subrule remains intact.',
      Uri.parse('https://media.wizards.com/rules.txt'),
      DateTime.utc(2026),
    );
    final List<RuleParagraph> matches = reference.find('608.2');
    expect(matches.map((RuleParagraph paragraph) => paragraph.number), <String>[
      '608.2',
      '608.2a',
    ]);
    expect(matches.first.label, '608.2.');
    expect(
      matches.first.text,
      '608.2. If the object that’s resolving is an instant spell.',
    );
  });

  test('cached reference loads without a network download', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'comprehensiveRules.text': 'Cached Comprehensive Rules',
      'comprehensiveRules.source': 'https://media.wizards.com/cached.txt',
      'comprehensiveRules.fetchedAt': '2026-10-01T00:00:00.000Z',
    });
    final RulesReference reference = await RulesReference.load();
    expect(reference.text, 'Cached Comprehensive Rules');
    expect(reference.source.path, '/cached.txt');
    expect(reference.fetchedAt, DateTime.utc(2026, 10, 1));
  });

  test('adjacent numbered rules retain distinct identifiers and examples', () {
    final RulesReference reference = RulesReference(
      'Comprehensive Rules\r\n\r\n100. General\r\n'
      '100.1. First rule.\r\n100.1a First subrule.\r\n'
      'Its continuation remains here.\r\nExample: Preserve this example.\r\n'
      '100.1b Second subrule.\r\n\r\n100.2. Next rule.',
      Uri.parse('https://media.wizards.com/rules.txt'),
      DateTime.utc(2026),
    );
    expect(
      reference.find('100.1').map((RuleParagraph value) => value.number),
      <String>['100.1', '100.1a', '100.1b'],
    );
    final RuleParagraph subrule = reference.find('100.1a').single;
    expect(subrule.section, '100. General');
    expect(
      subrule.text,
      '100.1a First subrule.\r\nIts continuation remains here.\r\n'
      'Example: Preserve this example.',
    );
    expect(reference.find('100.1b').single.body, 'Second subrule.');
    expect(reference.find('100.2').single.body, 'Next rule.');
  });

  test('pasted printed rule numbers accept a terminal period', () {
    final RulesReference reference = RulesReference(
      'Comprehensive Rules\n\n608. Resolution\n\n'
      '608.2. Parent.\n608.2a Child.\n608.20. Other.',
      Uri.parse('https://media.wizards.com/rules.txt'),
      DateTime.utc(2026),
    );
    expect(
      reference.find('608.2.').map((RuleParagraph value) => value.number),
      <String>['608.2', '608.2a'],
    );
    expect(reference.find('608.2a.').single.number, '608.2a');
    expect(reference.find('608.').length, 4);
  });

  test(
    'short contents and adjacent body headings are excluded from results',
    () {
      final RulesReference reference = RulesReference(
        'Comprehensive Rules\n\nContents\n\n'
        '1. Game Concepts\n100. General\n101. Other\n\n'
        '2. Parts of a Card\n200. General\n\nCredits\n'
        '1. Game Concepts\n\n100. General\n100.1. First rule.\n\n'
        '2. Parts of a Card\n\n200. General\n200.1. Second rule.',
        Uri.parse('https://media.wizards.com/rules.txt'),
        DateTime.utc(2026),
      );
      expect(reference.find('101'), isEmpty);
      expect(reference.find('general'), hasLength(2));
      expect(
        reference.sections.map((RuleParagraph value) => value.number),
        <String>['1.', '2.'],
      );
      expect(reference.find('100.1').single.section, '100. General');
      expect(reference.find('200.1').single.section, '200. General');
    },
  );
}
