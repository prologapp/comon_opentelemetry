part of '../comon_otel_test.dart';

void defineHttpTransportTests() {
  group('http transport', () {
    test('default transport sends request body and reads response', () async {
      final transport = DefaultOtlpHttpTransport(
        client: _FakeHttpClient(
          handler: (request) async {
            expect(request.method, 'POST');
            expect(
              request.url.toString(),
              'https://collector.example/v1/traces',
            );
            expect(request.headers['content-type'], 'application/json');
            expect(utf8.decode(request.bodyBytes), '{"ok":true}');
            return http.Response(
              '{"partialSuccess":{}}',
              200,
              headers: <String, String>{'retry-after': '3'},
            );
          },
        ),
      );

      final response = await transport.postJson(
        OtlpHttpRequest(
          uri: Uri.parse('https://collector.example/v1/traces'),
          body: '{"ok":true}',
          headers: <String, String>{'content-type': 'application/json'},
          timeout: Duration(seconds: 1),
        ),
      );

      expect(response.statusCode, 200);
      expect(response.body, '{"partialSuccess":{}}');
      expect(response.headers['retry-after'], '3');
      await transport.shutdown();
    });

    test('gzip request body is encoded without dart:io gzip', () {
      final request = OtlpHttpRequest(
        uri: Uri.parse('https://collector.example/v1/logs'),
        body: '{"compressed":true}',
        headers: <String, String>{},
        timeout: Duration(seconds: 1),
        compression: OtlpCompression.gzip,
      );

      final decoded = utf8.decode(gzip.decode(request.bodyBytes));
      expect(decoded, '{"compressed":true}');
    });
    for (final stallAfterHeaders in <bool>[false, true]) {
      final phase = stallAfterHeaders ? 'response body' : 'response headers';
      test(
        'timeout aborts the connection when the server stalls on the $phase',
        () async {
          final server = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final openSockets = <Socket>{};
          server.listen((socket) {
            openSockets.add(socket);
            var answered = false;
            socket.listen(
              (_) {
                if (stallAfterHeaders && !answered) {
                  answered = true;
                  // Promise 100 bytes and send 2, then go silent.
                  socket.add(
                    utf8.encode(
                      'HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n{}',
                    ),
                  );
                }
              },
              onDone: () => openSockets.remove(socket),
              onError: (Object _) => openSockets.remove(socket),
            );
          });
          final transport = DefaultOtlpHttpTransport();
          addTearDown(() async {
            await transport.shutdown();
            for (final socket in openSockets.toList()) {
              socket.destroy();
            }
            await server.close();
          });

          await expectLater(
            transport.postJson(
              OtlpHttpRequest(
                uri: Uri.parse('http://127.0.0.1:${server.port}/v1/traces'),
                body: '{}',
                headers: const <String, String>{},
                timeout: const Duration(milliseconds: 200),
              ),
            ),
            throwsA(isA<TimeoutException>()),
          );

          // The transport is still alive: only the timed-out request's
          // connection must have been closed.
          final deadline = DateTime.now().add(const Duration(seconds: 2));
          while (openSockets.isNotEmpty && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(openSockets, isEmpty);
        },
      );
    }
    test('one deadline covers headers and body together', () async {
      const timeout = Duration(milliseconds: 400);
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>{};
      server.listen((socket) {
        sockets.add(socket);
        var answered = false;
        socket.listen((_) async {
          if (answered) {
            return;
          }
          answered = true;
          // Headers arrive just before the deadline...
          await Future<void>.delayed(const Duration(milliseconds: 300));
          socket.add(
            utf8.encode('HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\n'),
          );
          // ...and the body well after it.
          await Future<void>.delayed(const Duration(milliseconds: 600));
          try {
            socket.add(utf8.encode('{}'));
          } catch (_) {
            // Connection already closed by the client.
          }
        }, onError: (Object _) {});
      });
      final transport = DefaultOtlpHttpTransport();
      addTearDown(() async {
        await transport.shutdown();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      });

      final stopwatch = Stopwatch()..start();
      await expectLater(
        transport.postJson(
          OtlpHttpRequest(
            uri: Uri.parse('http://127.0.0.1:${server.port}/v1/traces'),
            body: '{}',
            headers: const <String, String>{},
            timeout: timeout,
          ),
        ),
        throwsA(isA<TimeoutException>()),
      );
      stopwatch.stop();

      // A deadline restarted at the headers would end at ~700 ms.
      expect(
        stopwatch.elapsed,
        lessThan(timeout + const Duration(milliseconds: 150)),
      );
    });
  });
}

final class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient({required this.handler});

  final Future<http.Response> Function(http.Request request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final typedRequest = request as http.Request;
    final response = await handler(typedRequest);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      request: typedRequest,
    );
  }
}
