import 'dart:js_interop';

@JS('location.reload')
external void _reload();

void restartAfterDeletion() => _reload();
