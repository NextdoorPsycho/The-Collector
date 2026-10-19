import 'dart:async';
import 'dart:collection';

class ScanVisualWorkScheduler {
  static final _VisualWorkPool _references = _VisualWorkPool(4);
  static final _VisualWorkPool _comparisons = _VisualWorkPool(2);

  static Future<T> reference<T>(Future<T> Function() operation) =>
      _references.run(operation);

  static Future<T> compare<T>(Future<T> Function() operation) =>
      _comparisons.run(operation);
}

class _VisualWorkPool {
  _VisualWorkPool(this.limit);

  final int limit;
  final Queue<Future<void> Function()> _waiting =
      Queue<Future<void> Function()>();
  int _active = 0;

  Future<T> run<T>(Future<T> Function() operation) {
    final Completer<T> result = Completer<T>();
    _waiting.add(() async {
      try {
        result.complete(await Future<T>.sync(operation));
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        _active--;
        _admit();
      }
    });
    _admit();
    return result.future;
  }

  void _admit() {
    while (_active < limit && _waiting.isNotEmpty) {
      _active++;
      unawaited(_waiting.removeFirst()());
    }
  }
}
