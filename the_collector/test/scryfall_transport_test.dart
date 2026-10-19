import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:the_collector/utils/scanning/scryfall_request_scheduler.dart';

typedef _Handler = Future<http.StreamedResponse> Function(http.BaseRequest);

class _Transport extends http.BaseClient {
  _Transport(this.handler);

  final _Handler handler;
  int calls = 0;
  int closes = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls++;
    return handler(request);
  }

  @override
  void close() {
    closes++;
  }
}

class _ClosingTransport extends _Transport {
  _ClosingTransport(super.handler, this.onClosed);

  final void Function() onClosed;

  @override
  void close() {
    super.close();
    onClosed();
  }
}

http.StreamedResponse _response({String body = '{}'}) =>
    http.StreamedResponse(Stream<List<int>>.value(body.codeUnits), 200);

Uri _uri(String name) => Uri.https('api.scryfall.com', '/cards/$name');

void main() {
  test(
    'real sockets recover from missing headers and a stalled response body',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final List<Socket> detached = <Socket>[];
      final Map<String, List<int>> ports = <String, List<int>>{};
      final Map<String, Completer<void>> disconnected =
          <String, Completer<void>>{
            '/headers': Completer<void>(),
            '/body': Completer<void>(),
          };
      final StreamSubscription<HttpRequest> requests = server.listen((
        HttpRequest request,
      ) async {
        final String path = request.uri.path;
        (ports[path] ??= <int>[]).add(request.connectionInfo!.remotePort);
        if (path == '/headers' || path == '/body') {
          final Socket socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          detached.add(socket);
          if (path == '/body') {
            socket.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{');
            await socket.flush();
          }
          socket.listen(
            (List<int> _) {},
            onError: (Object _) {},
            onDone: () {
              disconnected[path]!.complete();
            },
          );
          return;
        }
        request.response.write('{}');
        await request.response.close();
      });
      final ScryfallHttpClient client = ScryfallHttpClient(
        headerTimeout: const Duration(milliseconds: 100),
        bodyTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(() async {
        client.close();
        for (final Socket socket in detached) {
          socket.destroy();
        }
        await requests.cancel();
        await server.close(force: true);
      });
      Uri local(String path) => Uri.http('127.0.0.1:${server.port}', path);
      await expectLater(
        client.get(local('/headers')),
        throwsA(isA<TimeoutException>()),
      );
      await disconnected['/headers']!.future.timeout(
        const Duration(seconds: 1),
      );
      expect((await client.get(local('/healthy'))).body, '{}');
      expect((await client.get(local('/healthy'))).body, '{}');
      expect(ports['/healthy']![0], ports['/healthy']![1]);
      expect(ports['/healthy']![0], isNot(ports['/headers']!.single));
      await expectLater(
        client.get(local('/body')),
        throwsA(isA<TimeoutException>()),
      );
      await disconnected['/body']!.future.timeout(const Duration(seconds: 1));
      expect(ports['/body']!.single, ports['/healthy']![1]);
      expect((await client.get(local('/healthy'))).body, '{}');
      expect((await client.get(local('/healthy'))).body, '{}');
      expect(ports['/healthy']![2], ports['/healthy']![3]);
      expect(ports['/healthy']![2], isNot(ports['/body']!.single));
    },
  );

  test(
    'a burst of stalled requests closes each pool before admitting another',
    () async {
      final List<Completer<http.StreamedResponse>> pending =
          <Completer<http.StreamedResponse>>[];
      final List<DateTime> admitted = <DateTime>[];
      final List<_Transport> transports = <_Transport>[];
      int live = 0;
      int maximumLive = 0;
      final ScryfallHttpClient client = ScryfallHttpClient(
        headerTimeout: const Duration(milliseconds: 20),
        clientFactory: () {
          live++;
          if (live > maximumLive) maximumLive = live;
          final Completer<http.StreamedResponse> response =
              Completer<http.StreamedResponse>();
          pending.add(response);
          final _Transport transport = _ClosingTransport((http.BaseRequest _) {
            admitted.add(DateTime.now());
            return response.future;
          }, () => live--);
          transports.add(transport);
          return transport;
        },
      );
      addTearDown(client.close);
      await Future.wait<void>(
        List<Future<void>>.generate(
          8,
          (int index) => expectLater(
            client.get(_uri('stall-$index')),
            throwsA(isA<TimeoutException>()),
          ),
        ),
      );
      expect(maximumLive, 1);
      expect(live, 0);
      expect(
        transports.every((_Transport transport) => transport.closes == 1),
        isTrue,
      );
      for (int index = 1; index < admitted.length; index++) {
        expect(
          admitted[index].difference(admitted[index - 1]).inMilliseconds,
          greaterThanOrEqualTo(90),
        );
      }
      for (final Completer<http.StreamedResponse> response in pending) {
        response.completeError(StateError('late closed transport'));
      }
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'healthy requests reuse the owned transport and preserve request bytes',
    () async {
      int created = 0;
      final _Transport transport = _Transport((http.BaseRequest request) async {
        expect(request, isA<http.Abortable>());
        expect(request.headers['User-Agent'], contains('TheCollector/'));
        expect(request.headers['Accept'], 'application/json');
        expect(request.headers['content-type'], 'application/json');
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 2);
        expect(request.contentLength, 2);
        expect(await request.finalize().bytesToString(), '{}');
        return _response();
      });
      final ScryfallHttpClient client = ScryfallHttpClient(
        clientFactory: () {
          created++;
          return transport;
        },
      );
      addTearDown(client.close);
      for (int index = 0; index < 2; index++) {
        final http.Request request = http.Request('POST', _uri('$index'))
          ..headers['content-type'] = 'application/json'
          ..body = '{}'
          ..followRedirects = false
          ..maxRedirects = 2;
        final http.Response response = await http.Response.fromStream(
          await client.send(request),
        );
        expect(response.body, '{}');
        expect(request.finalized, isTrue);
      }
      expect(created, 1);
      expect(transport.calls, 2);
      expect(transport.closes, 0);
      client.close();
      client.close();
      expect(transport.closes, 1);
    },
  );

  test(
    'never arriving headers close the transport and release the global queue',
    () async {
      final Completer<http.StreamedResponse> pending =
          Completer<http.StreamedResponse>();
      final Completer<void> admitted = Completer<void>();
      final Completer<void> aborted = Completer<void>();
      final _Transport stalled = _Transport((http.BaseRequest request) {
        unawaited(
          (request as http.Abortable).abortTrigger!.then<void>(
            (_) => aborted.complete(),
          ),
        );
        admitted.complete();
        return pending.future;
      });
      final _Transport recovered = _Transport(
        (http.BaseRequest _) async => _response(),
      );
      int created = 0;
      final ScryfallHttpClient client = ScryfallHttpClient(
        headerTimeout: const Duration(milliseconds: 40),
        clientFactory: () => ++created == 1 ? stalled : recovered,
      );
      addTearDown(client.close);
      final Future<void> failed = expectLater(
        client.get(_uri('stalled')),
        throwsA(isA<TimeoutException>()),
      );
      await admitted.future;
      final ScryfallHttpClient other = ScryfallHttpClient(
        clientFactory: () =>
            _Transport((http.BaseRequest _) async => _response()),
      );
      addTearDown(other.close);
      final Future<http.Response> unrelated = other.get(_uri('unrelated'));
      await failed;
      await aborted.future;
      expect(stalled.closes, 1);
      expect(
        (await unrelated.timeout(const Duration(seconds: 1))).statusCode,
        200,
      );
      expect((await client.get(_uri('retry'))).statusCode, 200);
      expect(created, 2);
      // The abandoned send still reports a late error; the timeout has consumed its completion.
      pending.completeError(StateError('late transport error'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('late response after a header deadline is cancelled without consuming its body', () async {
    final Completer<http.StreamedResponse> pending =
        Completer<http.StreamedResponse>();
    final Completer<void> admitted = Completer<void>();
    final _Transport transport = _Transport((http.BaseRequest _) {
      admitted.complete();
      return pending.future;
    });
    final ScryfallHttpClient client = ScryfallHttpClient(
      headerTimeout: const Duration(milliseconds: 30),
      clientFactory: () => transport,
    );
    addTearDown(client.close);
    final Future<void> failed = expectLater(
      client.get(_uri('late')),
      throwsA(isA<TimeoutException>()),
    );
    await admitted.future;
    await failed;
    final Completer<void> cancelled = Completer<void>();
    final StreamController<List<int>> body = StreamController<List<int>>(
      onCancel: cancelled.complete,
    );
    pending.complete(http.StreamedResponse(body.stream, 200));
    await cancelled.future.timeout(const Duration(seconds: 1));
    body.addError(StateError('late body error'));
    await body.close();
    expect(transport.closes, 1);
  });

  test('never ending body holds the slot, then cancels and permits the next request', () async {
    final Completer<void> admitted = Completer<void>();
    final StreamController<List<int>> body = StreamController<List<int>>();
    final _Transport stalled = _Transport((http.BaseRequest _) async {
      admitted.complete();
      return http.StreamedResponse(body.stream, 200);
    });
    final _Transport recovered = _Transport(
      (http.BaseRequest _) async => _response(),
    );
    int created = 0;
    final ScryfallHttpClient client = ScryfallHttpClient(
      bodyTimeout: const Duration(milliseconds: 40),
      clientFactory: () => ++created == 1 ? stalled : recovered,
    );
    addTearDown(client.close);
    addTearDown(body.close);
    final Future<void> failed = expectLater(
      client.get(_uri('body')),
      throwsA(isA<TimeoutException>()),
    );
    await admitted.future;
    final Future<http.Response> next = client.get(_uri('next'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(created, 1);
    await failed;
    expect(body.hasListener, isFalse);
    expect(stalled.closes, 1);
    expect((await next.timeout(const Duration(seconds: 1))).statusCode, 200);
    expect(created, 2);
  });

  test('continuous trickle cannot reset the absolute body deadline', () async {
    final StreamController<List<int>> body = StreamController<List<int>>();
    Timer? trickle;
    final _Transport transport = _Transport((http.BaseRequest _) async {
      trickle = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => body.add(<int>[1]),
      );
      return http.StreamedResponse(body.stream, 200);
    });
    final ScryfallHttpClient client = ScryfallHttpClient(
      bodyTimeout: const Duration(milliseconds: 40),
      clientFactory: () => transport,
    );
    addTearDown(() async {
      trickle?.cancel();
      client.close();
      await body.close();
    });
    await expectLater(
      client.get(_uri('trickle')).timeout(const Duration(seconds: 1)),
      throwsA(
        isA<TimeoutException>().having(
          (TimeoutException error) => error.duration,
          'body deadline',
          const Duration(milliseconds: 40),
        ),
      ),
    );
    expect(body.hasListener, isFalse);
    expect(transport.closes, 1);
  });

  test('declared and streamed oversized responses cancel before allocating beyond the cap', () async {
    final List<_Transport> transports = <_Transport>[];
    final List<StreamController<List<int>>> bodies =
        <StreamController<List<int>>>[];
    final ScryfallHttpClient client = ScryfallHttpClient(
      maximumResponseBytes: 4,
      clientFactory: () {
        final StreamController<List<int>> body = StreamController<List<int>>();
        bodies.add(body);
        final int index = transports.length;
        final _Transport transport = _Transport((http.BaseRequest _) async {
          body.add(<int>[1, 2, 3]);
          body.add(<int>[4, 5]);
          return http.StreamedResponse(
            body.stream,
            200,
            contentLength: index == 0 ? 5 : null,
          );
        });
        transports.add(transport);
        return transport;
      },
    );
    addTearDown(() async {
      client.close();
      for (final StreamController<List<int>> body in bodies) {
        await body.close();
      }
    });
    for (int index = 0; index < 2; index++) {
      await expectLater(
        client.get(_uri('large-$index')),
        throwsA(
          isA<http.ClientException>().having(
            (http.ClientException error) => error.message,
            'message',
            contains('too large'),
          ),
        ),
      );
      expect(bodies[index].hasListener, isFalse);
      expect(transports[index].closes, 1);
    }
  });

  test(
    'closing an active client cancels promptly and another client still works',
    () async {
      final Completer<void> admitted = Completer<void>();
      final Completer<http.StreamedResponse> pending =
          Completer<http.StreamedResponse>();
      final _Transport stalled = _Transport((http.BaseRequest _) {
        admitted.complete();
        return pending.future;
      });
      final ScryfallHttpClient client = ScryfallHttpClient(
        clientFactory: () => stalled,
      );
      final Future<void> cancelled = expectLater(
        client.get(_uri('close')).timeout(const Duration(seconds: 1)),
        throwsA(isA<http.RequestAbortedException>()),
      );
      await admitted.future;
      client.close();
      await cancelled;
      expect(stalled.closes, 1);
      pending.completeError(StateError('closed late'));
      final ScryfallHttpClient other = ScryfallHttpClient(
        clientFactory: () =>
            _Transport((http.BaseRequest _) async => _response()),
      );
      addTearDown(other.close);
      expect((await other.get(_uri('other'))).statusCode, 200);
    },
  );

  test(
    'closing a queued client never creates or starts its transport',
    () async {
      final Completer<void> admitted = Completer<void>();
      final Completer<void> release = Completer<void>();
      final Future<void> first = ScryfallRequestScheduler.run<void>(() {
        admitted.complete();
        return release.future;
      }, minimumInterval: Duration.zero);
      await admitted.future;
      int created = 0;
      final ScryfallHttpClient client = ScryfallHttpClient(
        clientFactory: () {
          created++;
          return _Transport((http.BaseRequest _) async => _response());
        },
      );
      final Future<void> queued = expectLater(
        client.get(_uri('queued')),
        throwsA(isA<http.ClientException>()),
      );
      client.close();
      release.complete();
      await first;
      await queued;
      expect(created, 0);
    },
  );

  test(
    'caller cancellation aborts an admitted body and does not poison a retry',
    () async {
      final Completer<void> callerAbort = Completer<void>();
      final Completer<void> admitted = Completer<void>();
      final StreamController<List<int>> body = StreamController<List<int>>();
      final _Transport stalled = _Transport((http.BaseRequest _) async {
        admitted.complete();
        return http.StreamedResponse(body.stream, 200);
      });
      final _Transport recovered = _Transport(
        (http.BaseRequest _) async => _response(),
      );
      int created = 0;
      final ScryfallHttpClient client = ScryfallHttpClient(
        clientFactory: () => ++created == 1 ? stalled : recovered,
      );
      addTearDown(client.close);
      addTearDown(body.close);
      final http.AbortableRequest request = http.AbortableRequest(
        'GET',
        _uri('abort'),
        abortTrigger: callerAbort.future,
      );
      final Future<void> failed = expectLater(
        client.send(request),
        throwsA(isA<http.RequestAbortedException>()),
      );
      await admitted.future;
      await Future<void>.delayed(Duration.zero);
      callerAbort.complete();
      await failed;
      expect(body.hasListener, isFalse);
      expect(stalled.closes, 1);
      expect((await client.get(_uri('retry'))).statusCode, 200);
    },
  );
}
