import 'package:url_launcher/url_launcher.dart';

Future<void> openCollectorLink(Uri uri) async {
  if (uri.scheme != 'https' && uri.scheme != 'http') {
    throw ArgumentError.value(uri, 'uri', 'Expected a web link.');
  }
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    throw StateError('Could not open the link.');
  }
}

Uri shopSearchUri(String location) =>
    Uri.https('www.google.com', '/maps/search/', <String, String>{
      'api': '1',
      'query': location.trim().isEmpty
          ? 'trading card game stores near me'
          : 'trading card game stores ${location.trim()}',
    });
