import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ScryfallRequestScheduler {
  static Future<void> _tail = Future<void>.value();
  static DateTime _nextRequest = DateTime.fromMillisecondsSinceEpoch(0);

  static const Map<String, String> headers = <String, String>{
    'User-Agent': 'TheCollector/1.0 (card collection app)',
    'Accept': 'application/json',
  };

  /// Shared across scanner, catalog, pricing and rulings; failed calls release it.
  static Future<T> run<T>(
    Future<T> Function() request, {
    Duration minimumInterval = const Duration(milliseconds: 500),
  }) {
    final Completer<T> result = Completer<T>();
    _tail = _tail.then((_) async {
      final Duration wait = _nextRequest.difference(DateTime.now());
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
      _nextRequest = DateTime.now().add(minimumInterval);
      try {
        result.complete(await request());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  static void backOff(Duration duration) {
    final DateTime until = DateTime.now().add(duration);
    if (until.isAfter(_nextRequest)) {
      _nextRequest = until;
    }
  }
}

class ScryfallHttpClient extends http.BaseClient {
  final http.Client Function() _clientFactory;
  final Duration headerTimeout;
  final Duration bodyTimeout;
  final int maximumResponseBytes;
  final Set<_ScryfallRequest> _active = <_ScryfallRequest>{};
  http.Client? _client;
  bool _closed = false;

  /// The factory creates owned transports; cancelled pools are closed and replaced.
  ScryfallHttpClient({
    http.Client Function()? clientFactory,
    this.headerTimeout = const Duration(seconds: 20),
    this.bodyTimeout = const Duration(seconds: 20),
    this.maximumResponseBytes = 16777216,
  }) : _clientFactory = clientFactory ?? http.Client.new {
    if (headerTimeout <= Duration.zero || bodyTimeout <= Duration.zero) {
      throw ArgumentError('Scryfall request deadlines must be positive.');
    }
    if (maximumResponseBytes <= 0) {
      throw ArgumentError('Scryfall response limit must be positive.');
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_closed) {
      return Future<http.StreamedResponse>.error(
        http.ClientException('Scryfall client is closed.', request.url),
      );
    }
    request.headers.addAll(ScryfallRequestScheduler.headers);
    return ScryfallRequestScheduler.run<http.StreamedResponse>(() async {
      if (_closed) {
        throw http.ClientException('Scryfall client is closed.', request.url);
      }
      final _ScryfallRequest operation = _ScryfallRequest(
        _client ??= _clientFactory(),
        request.url,
        () {
          final http.Client? client = _client;
          _client = null;
          client?.close();
        },
      );
      _active.add(operation);
      try {
        final _AbortableScryfallRequest forwarded = _AbortableScryfallRequest(
          request,
          operation.cancelled.future,
        );
        if (request case http.Abortable(:final abortTrigger?)) {
          unawaited(
            abortTrigger.then<void>(
              (_) => operation.cancel(),
              onError: (Object _, StackTrace _) => operation.cancel(),
            ),
          );
        }
        final Future<http.StreamedResponse> pending = operation.client
            .send(forwarded)
            .then((http.StreamedResponse response) {
              if (operation.isCancelled) {
                unawaited(
                  response.stream
                      .listen((List<int> _) {}, onError: (Object _) {})
                      .cancel()
                      .catchError((Object _) {}),
                );
                throw http.RequestAbortedException(request.url);
              }
              return response;
            });
        final http.StreamedResponse response =
            await Future.any<http.StreamedResponse>(
              <Future<http.StreamedResponse>>[
                pending,
                operation.cancelled.future.then<http.StreamedResponse>(
                  (_) => throw http.RequestAbortedException(request.url),
                ),
              ],
            ).timeout(
              headerTimeout,
              onTimeout: () {
                operation.cancel();
                throw TimeoutException(
                  'Scryfall response headers timed out.',
                  headerTimeout,
                );
              },
            );
        if (response.statusCode == 429) {
          final int seconds =
              int.tryParse(response.headers['retry-after'] ?? '') ?? 30;
          ScryfallRequestScheduler.backOff(
            Duration(seconds: seconds < 30 ? 30 : seconds),
          );
        }
        if ((response.contentLength ?? 0) > maximumResponseBytes) {
          operation.cancel();
          unawaited(
            response.stream
                .listen((List<int> _) {}, onError: (Object _) {})
                .cancel()
                .catchError((Object _) {}),
          );
          throw http.ClientException(
            'Scryfall response is too large.',
            request.url,
          );
        }
        // Keep the global slot until the body finishes; a stalled download must not admit another transport.
        final Uint8List bytes = await _readBody(response.stream, operation);
        return http.StreamedResponse(
          Stream<List<int>>.value(bytes),
          response.statusCode,
          contentLength: bytes.length,
          request: request,
          headers: response.headers,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
          reasonPhrase: response.reasonPhrase,
        );
      } finally {
        _active.remove(operation);
        operation.finish();
      }
    }, minimumInterval: requestInterval(request.url));
  }

  Future<Uint8List> _readBody(
    Stream<List<int>> stream,
    _ScryfallRequest operation,
  ) {
    final Completer<Uint8List> result = Completer<Uint8List>();
    final BytesBuilder bytes = BytesBuilder(copy: false);
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    void fail(Object error, [StackTrace? stack]) {
      if (result.isCompleted) return;
      timer?.cancel();
      // Force-closing IOClient can synchronously emit a second stream error.
      result.completeError(error, stack);
      operation.cancel();
      unawaited(subscription?.cancel().catchError((Object _) {}));
    }

    timer = Timer(bodyTimeout, () {
      fail(TimeoutException('Scryfall response body timed out.', bodyTimeout));
    });
    unawaited(
      operation.cancelled.future.then<void>((_) {
        fail(http.RequestAbortedException(operation.uri));
      }),
    );
    subscription = stream.listen(
      (List<int> chunk) {
        if (result.isCompleted) return;
        if (bytes.length + chunk.length > maximumResponseBytes) {
          fail(
            http.ClientException(
              'Scryfall response is too large.',
              operation.uri,
            ),
          );
          return;
        }
        bytes.add(chunk);
      },
      onError: fail,
      onDone: () {
        if (result.isCompleted) return;
        timer?.cancel();
        result.complete(bytes.takeBytes());
      },
    );
    return result.future;
  }

  static Duration requestInterval(Uri uri) {
    if (uri.path == '/cards/manifest') return const Duration(seconds: 6);
    if (<String>{
      '/cards/search',
      '/cards/named',
      '/cards/random',
      '/cards/collection',
    }.contains(uri.path)) {
      return const Duration(milliseconds: 500);
    }
    return const Duration(milliseconds: 100);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final _ScryfallRequest operation in _active.toList()) {
      operation.cancel();
    }
    _client?.close();
    _client = null;
    super.close();
  }
}

class _ScryfallRequest {
  _ScryfallRequest(this.client, this.uri, this._closeClient);

  final http.Client client;
  final Uri uri;
  final void Function() _closeClient;
  final Completer<void> cancelled = Completer<void>();
  bool _finished = false;

  bool get isCancelled => cancelled.isCompleted;

  void cancel() {
    if (_finished || isCancelled) return;
    cancelled.complete();
    _closeClient();
  }

  void finish() {
    if (_finished) return;
    _finished = true;
  }
}

class _AbortableScryfallRequest extends http.BaseRequest with http.Abortable {
  _AbortableScryfallRequest(this.original, this.abortTrigger)
    : super(original.method, original.url) {
    headers.addAll(original.headers);
    contentLength = original.contentLength;
    followRedirects = original.followRedirects;
    maxRedirects = original.maxRedirects;
    persistentConnection = original.persistentConnection;
  }

  final http.BaseRequest original;
  @override
  final Future<void> abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return original.finalize();
  }
}
