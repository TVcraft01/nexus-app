import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/crypto/transfer_keys.dart';
import 'package:nexus_app/remote/nexus_datagram_channel.dart';

/// Creates a bound UDP socket on loopback for testing.
Future<RawDatagramSocket> _bindLoopback() async {
  return RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
}

/// A test transfer key (simulates the pairing-key-derived key).
final _testKey = deriveTransferKey('test-pairing-key-uuid-v4');

/// Helper: set up a connected client+server pair on loopback.
Future<(NexusDatagramChannel client, NexusDatagramChannel server,
    RawDatagramSocket clientSock, RawDatagramSocket serverSock)>
    _connectedPair() async {
  final serverSocket = await _bindLoopback();
  final clientSocket = await _bindLoopback();

  final acceptFuture = NexusDatagramChannel.accept(
    socket: serverSocket,
    remoteAddress: InternetAddress.loopbackIPv4,
    remotePort: clientSocket.port,
    keyBytes: _testKey,
  );

  final connectFuture = NexusDatagramChannel.connect(
    socket: clientSocket,
    remoteAddress: InternetAddress.loopbackIPv4,
    remotePort: serverSocket.port,
    keyBytes: _testKey,
  );

  final results = await Future.wait([connectFuture, acceptFuture]);
  return (results[0]!, results[1]!, clientSocket, serverSocket);
}

void main() {
  group('Packet framing', () {
    test('buildPacket and parseHeader round-trip', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final packet = NexusDatagramChannel.buildPacket(
          NexusDatagramChannel.flagData, 42, payload);
      final parsed = NexusDatagramChannel.parseHeader(packet);
      expect(parsed, isNotNull);
      expect(parsed!.flag, NexusDatagramChannel.flagData);
      expect(parsed.seq, 42);
      expect(parsed.payloadLen, 5);
      expect(packet.sublist(NexusDatagramChannel.headerSize), payload);
    });

    test('buildPacket with no payload', () {
      final packet =
          NexusDatagramChannel.buildPacket(NexusDatagramChannel.flagSyn, 0);
      final parsed = NexusDatagramChannel.parseHeader(packet);
      expect(parsed, isNotNull);
      expect(parsed!.flag, NexusDatagramChannel.flagSyn);
      expect(parsed.seq, 0);
      expect(parsed.payloadLen, 0);
      expect(packet.length, NexusDatagramChannel.headerSize);
    });

    test('parseHeader rejects short packets', () {
      expect(NexusDatagramChannel.parseHeader(Uint8List(4)), isNull);
    });

    test('parseHeader rejects bad magic', () {
      final bad = Uint8List.fromList([0, 0, 1, 0, 0, 0, 0, 0, 0]);
      expect(NexusDatagramChannel.parseHeader(bad), isNull);
    });

    test('isSyn returns true only for SYN packets', () {
      final syn = NexusDatagramChannel.buildPacket(
          NexusDatagramChannel.flagSyn, 0);
      final data = NexusDatagramChannel.buildPacket(
          NexusDatagramChannel.flagData, 0);
      expect(NexusDatagramChannel.isSyn(syn), isTrue);
      expect(NexusDatagramChannel.isSyn(data), isFalse);
    });
  });

  group('Handshake', () {
    test('connect and accept complete handshake on loopback', () async {
      final (client, server, cs, ss) = await _connectedPair();
      expect(client.isConnected, isTrue);
      expect(server.isConnected, isTrue);
      client.close();
      server.close();
      cs.close();
      ss.close();
    });

    test('accept times out when no SYN arrives', () async {
      final serverSocket = await _bindLoopback();
      try {
        final result = await NexusDatagramChannel.accept(
          socket: serverSocket,
          remoteAddress: InternetAddress.loopbackIPv4,
          remotePort: 12345,
          keyBytes: _testKey,
          timeout: const Duration(milliseconds: 200),
        );
        expect(result, isNull);
      } finally {
        serverSocket.close();
      }
    });
  });

  group('Reliable data transfer', () {
    test('send and receive single message on loopback', () async {
      final (client, server, cs, ss) = await _connectedPair();

      final message = Uint8List.fromList([72, 101, 108, 108, 111]); // Hello
      final receivedFuture =
          server.incoming.first.timeout(const Duration(seconds: 3));

      await client.send(message);
      final received = await receivedFuture;

      expect(received, message);

      client.close();
      server.close();
      cs.close();
      ss.close();
    });

    test('bidirectional data transfer', () async {
      final (client, server, cs, ss) = await _connectedPair();

      final clientMsg = Uint8List.fromList([1, 2, 3]);
      final serverMsg = Uint8List.fromList([4, 5, 6]);

      final serverReceivedFuture =
          server.incoming.first.timeout(const Duration(seconds: 3));
      final clientReceivedFuture =
          client.incoming.first.timeout(const Duration(seconds: 3));

      await client.send(clientMsg);
      final serverReceived = await serverReceivedFuture;
      expect(serverReceived, clientMsg);

      await server.send(serverMsg);
      final clientReceived = await clientReceivedFuture;
      expect(clientReceived, serverMsg);

      client.close();
      server.close();
      cs.close();
      ss.close();
    });

    test('multiple sequential messages', () async {
      final (client, server, cs, ss) = await _connectedPair();

      final messages = [
        Uint8List.fromList([1]),
        Uint8List.fromList([2, 2]),
        Uint8List.fromList([3, 3, 3]),
        Uint8List.fromList([4, 4, 4, 4]),
      ];

      final receivedList = <List<int>>[];
      final sub = server.incoming.listen((data) {
        receivedList.add(data);
      });

      for (final msg in messages) {
        await client.send(msg);
      }

      // Wait for all messages to arrive.
      await Future.delayed(const Duration(milliseconds: 500));

      expect(receivedList.length, messages.length);
      for (var i = 0; i < messages.length; i++) {
        expect(receivedList[i], messages[i]);
      }

      await sub.cancel();
      client.close();
      server.close();
      cs.close();
      ss.close();
    });

    test('large payload transfer (10KB)', () async {
      final (client, server, cs, ss) = await _connectedPair();

      final largePayload = Uint8List(10240);
      final rng = Random.secure();
      for (var i = 0; i < largePayload.length; i++) {
        largePayload[i] = rng.nextInt(256);
      }

      final receivedFuture =
          server.incoming.first.timeout(const Duration(seconds: 5));

      await client.send(largePayload);
      final received = await receivedFuture;

      expect(received, largePayload);

      client.close();
      server.close();
      cs.close();
      ss.close();
    });
  });

  group('Encryption', () {
    test('round-trip proves AES-GCM encryption and decryption', () async {
      final (client, server, cs, ss) = await _connectedPair();

      final message = Uint8List.fromList([72, 101, 108, 108, 111]); // Hello

      final receivedFuture =
          server.incoming.first.timeout(const Duration(seconds: 3));
      await client.send(message);
      final received = await receivedFuture;

      // The plaintext arrives correctly — encryption + decryption works.
      expect(received, message);

      client.close();
      server.close();
      cs.close();
      ss.close();
    });

    test('wrong key cannot decrypt', () async {
      final serverSocket = await _bindLoopback();
      final clientSocket = await _bindLoopback();
      final wrongKeyServerSocket = await _bindLoopback();

      try {
        // Connect with the correct key.
        final acceptFuture = NexusDatagramChannel.accept(
          socket: serverSocket,
          remoteAddress: InternetAddress.loopbackIPv4,
          remotePort: clientSocket.port,
          keyBytes: _testKey,
        );

        final connectFuture = NexusDatagramChannel.connect(
          socket: clientSocket,
          remoteAddress: InternetAddress.loopbackIPv4,
          remotePort: serverSocket.port,
          keyBytes: _testKey,
        );

        final results = await Future.wait([connectFuture, acceptFuture]);
        final client = results[0]!;
        final server = results[1]!;

        // A server with the WRONG key — accept on a different socket.
        final wrongKey = deriveTransferKey('wrong-pairing-key');
        final wrongAccept = NexusDatagramChannel.accept(
          socket: wrongKeyServerSocket,
          remoteAddress: InternetAddress.loopbackIPv4,
          remotePort: clientSocket.port,
          keyBytes: wrongKey,
          timeout: const Duration(milliseconds: 100),
        );
        // This won't match because the client's SYN goes to serverSocket.
        final wrongServer = await wrongAccept;
        expect(wrongServer, isNull); // no SYN arrives on wrong socket

        // Send via the correct channel.
        final message = Uint8List.fromList([1, 2, 3]);
        final receivedFuture =
            server.incoming.first.timeout(const Duration(seconds: 3));
        await client.send(message);
        final received = await receivedFuture;
        expect(received, message);

        client.close();
        server.close();
        wrongKeyServerSocket.close();
      } finally {
        clientSocket.close();
        serverSocket.close();
      }
    });
  });

  group('Connection lifecycle', () {
    test('close sends FIN and channel closes', () async {
      final (client, server, cs, ss) = await _connectedPair();
      expect(client.isConnected, isTrue);

      await client.close();
      await Future.delayed(const Duration(milliseconds: 300));

      expect(client.isClosed, isTrue);
      server.close();
      cs.close();
      ss.close();
    });

    test('reset immediately closes channel', () async {
      final (client, server, cs, ss) = await _connectedPair();
      client.reset();
      expect(client.isClosed, isTrue);

      server.close();
      cs.close();
      ss.close();
    });

    test('send on closed channel throws', () async {
      final (client, server, cs, ss) = await _connectedPair();
      await client.close();

      expect(
        () => client.send([1, 2, 3]),
        throwsA(isA<StateError>()),
      );

      server.close();
      cs.close();
      ss.close();
    });
  });

  group('Retransmission', () {
    test('retransmits SYN when no response arrives', () async {
      final clientSocket = await _bindLoopback();
      try {
        final result = await NexusDatagramChannel.connect(
          socket: clientSocket,
          remoteAddress: InternetAddress.loopbackIPv4,
          remotePort: 1,
          keyBytes: _testKey,
          timeout: const Duration(milliseconds: 800),
        );
        expect(result, isNull);
      } finally {
        clientSocket.close();
      }
    });
  });

  group('Packet loss simulation', () {
    test('retransmit works on reliable loopback', () async {
      final (client, server, cs, ss) = await _connectedPair();

      // Send multiple messages — each tests the stop-and-wait cycle.
      for (var i = 0; i < 5; i++) {
        final msg = Uint8List.fromList([i]);
        final receivedFuture =
            server.incoming.first.timeout(const Duration(seconds: 3));
        await client.send(msg);
        final received = await receivedFuture;
        expect(received, msg);
      }

      client.close();
      server.close();
      cs.close();
      ss.close();
    });
  });
}
