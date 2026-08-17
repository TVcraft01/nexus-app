import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A successfully opened external endpoint: the public IP and the external
/// TCP port that now forwards to our local receive port.
class PortMapping {
  final String publicIp;
  final int externalPort;

  const PortMapping(this.publicIp, this.externalPort);
}

/// Opens (and removes) a public TCP port mapping so a paired device on another
/// network can reach our local receive server. Tries UPnP IGD first (most
/// consumer routers), then NAT-PMP (Apple routers and others). Both are
/// implemented directly over dart:io / HTTP — no native plugin, no cloud, no
/// third-party relay. The mapping only ever exposes our own port; no user data
/// ever passes through these control channels.
class PortMapper {
  static const _ssdpGroup = '239.255.255.250';
  static const _ssdpPort = 1900;
  static const _natPmpPort = 5351;

  /// Maps the local TCP [internalPort] to an external port. Returns null when
  /// neither UPnP nor NAT-PMP could open a mapping (e.g. disabled router, or
  /// no gateway).
  Future<PortMapping?> mapTcpPort(int internalPort, {int lifetime = 3600}) async {
    final gateway = await _defaultGateway();
    if (gateway == null) return null;

    final upnp = await _mapViaUpnp(gateway, internalPort, internalPort);
    if (upnp != null) return upnp;

    final natPmp = await _mapViaNatPmp(gateway, internalPort, internalPort, lifetime);
    return natPmp;
  }

  /// Removes a mapping opened with [externalPort] for the local [internalPort].
  Future<void> releaseTcpPort(int internalPort, int externalPort) async {
    final gateway = await _defaultGateway();
    if (gateway == null) return;
    await _releaseViaNatPmp(gateway, internalPort, externalPort);
    await _releaseViaUpnp(gateway, internalPort, externalPort);
  }

  // ---- NAT-PMP ------------------------------------------------------------

  Future<PortMapping?> _mapViaNatPmp(
      InternetAddress gateway, int internalPort, int externalPort, int lifetime) async {
    final publicIp = await _natPmpExternalAddress(gateway);
    if (publicIp == null) return null;

    final req = Uint8List(12);
    final bd = ByteData.sublistView(req);
    bd.setUint8(0, 0); // version
    bd.setUint8(1, 2); // opcode: map TCP
    bd.setUint16(2, 0); // reserved
    bd.setUint16(4, internalPort);
    bd.setUint16(6, externalPort); // requested external port
    bd.setUint32(8, lifetime);

    final resp = await _natPmpRequest(gateway, req);
    if (resp == null || resp.length < 16) return null;
    final rb = ByteData.sublistView(resp);
    if (rb.getUint8(0) != 0 || rb.getUint8(1) != 130) return null; // ver + map TCP reply
    if (rb.getUint16(2) != 0) return null; // result code != success
    return PortMapping(publicIp, rb.getUint16(10));
  }

  Future<String?> _natPmpExternalAddress(InternetAddress gateway) async {
    final resp = await _natPmpRequest(gateway, Uint8List.fromList([0, 0]));
    if (resp == null || resp.length < 12) return null;
    final rb = ByteData.sublistView(resp);
    if (rb.getUint8(0) != 0 || rb.getUint8(1) != 128) return null;
    if (rb.getUint16(2) != 0) return null;
    return '${resp[8]}.${resp[9]}.${resp[10]}.${resp[11]}';
  }

  Future<void> _releaseViaNatPmp(
      InternetAddress gateway, int internalPort, int externalPort) async {
    final req = Uint8List(12);
    final bd = ByteData.sublistView(req);
    bd.setUint8(0, 0);
    bd.setUint8(1, 2); // map TCP
    bd.setUint16(4, internalPort);
    bd.setUint16(6, externalPort);
    bd.setUint32(8, 0); // lifetime 0 = delete
    await _natPmpRequest(gateway, req);
  }

  Future<Uint8List?> _natPmpRequest(InternetAddress gateway, List<int> request) async {
    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (_) {
      return null;
    }
    try {
      final completer = Completer<Uint8List?>();
      late final StreamSubscription<RawSocketEvent> sub;
      sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = socket.receive();
        if (d == null) return;
        if (!completer.isCompleted) completer.complete(d.data);
      });
      try {
        socket.send(request, gateway, _natPmpPort);
        return await completer.future
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
      } finally {
        await sub.cancel();
      }
    } finally {
      socket.close();
    }
  }

  // ---- UPnP IGD -----------------------------------------------------------

  Future<PortMapping?> _mapViaUpnp(
      InternetAddress gateway, int internalPort, int externalPort) async {
    final location = await _ssdpSearch();
    if (location == null) return null;

    final deviceXml = await _httpGet(location);
    if (deviceXml == null) return null;

    final control = _findControlUrl(deviceXml, location);
    if (control == null) return null;

    final serviceType = control.serviceType;
    final controlUrl = control.url;
    final publicIp = await _upnpExternalIp(controlUrl, serviceType);
    if (publicIp == null) return null;

    final internalIp = await _localIp();
    final ok = await _upnpAddPortMapping(
      controlUrl,
      serviceType,
      internalPort,
      externalPort,
      internalIp,
    );
    if (!ok) return null;
    return PortMapping(publicIp, externalPort);
  }

  Future<void> _releaseViaUpnp(
      InternetAddress gateway, int internalPort, int externalPort) async {
    final location = await _ssdpSearch();
    if (location == null) return;
    final deviceXml = await _httpGet(location);
    if (deviceXml == null) return;
    final control = _findControlUrl(deviceXml, location);
    if (control == null) return;
    await _upnpDeletePortMapping(
        control.url, control.serviceType, externalPort);
  }

  /// Sends a multicast SSDP M-SEARCH for an InternetGatewayDevice and returns
  /// the LOCATION URL of the first responder.
  Future<String?> _ssdpSearch() async {
    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (_) {
      return null;
    }
    try {
      socket.joinMulticast(InternetAddress(_ssdpGroup));
      final search = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: $_ssdpGroup:$_ssdpPort\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 1\r\n'
          'ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n'
          '\r\n';

      final completer = Completer<String?>();
      late final StreamSubscription<RawSocketEvent> sub;
      sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = socket.receive();
        if (d == null) return;
        final text = utf8.decode(d.data, allowMalformed: true);
        final m =
            RegExp(r'LOCATION:\s*(\S+)', caseSensitive: false).firstMatch(text);
        if (m != null && !completer.isCompleted) {
          completer.complete(m.group(1)!.trim());
        }
      });
      try {
        socket.send(ascii.encode(search), InternetAddress(_ssdpGroup), _ssdpPort);
        return await completer.future
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
      } finally {
        await sub.cancel();
      }
    } finally {
      socket.close();
    }
  }

  /// Finds the WANIPConnection (or WANPPPConnection) control URL inside the
  /// device description XML.
  _UpnpControl? _findControlUrl(String deviceXml, String location) {
    final base = Uri.parse(location);
    for (final m in RegExp(r'<service>.*?</service>', dotAll: true)
        .allMatches(deviceXml)) {
      final block = m.group(0)!;
      final type = RegExp(r'<serviceType>(.*?)</serviceType>', dotAll: true)
              .firstMatch(block)
              ?.group(1) ??
          '';
      final isWanIp = type.contains('WANIPConnection');
      final isWanPpp = type.contains('WANPPPConnection');
      if (!isWanIp && !isWanPpp) continue;

      final controlPath = RegExp(r'<controlURL>(.*?)</controlURL>', dotAll: true)
              .firstMatch(block)
              ?.group(1)
              ?.trim();
      if (controlPath == null || controlPath.isEmpty) continue;

      final url = base.resolve(controlPath).toString();
      return _UpnpControl(url, isWanIp ? 'WANIPConnection' : 'WANPPPConnection');
    }
    return null;
  }

  Future<String?> _upnpExternalIp(String controlUrl, String serviceType) async {
    final body = _soap(
      serviceType,
      'GetExternalIPAddress',
      '',
    );
    try {
      final resp = await _soapPost(controlUrl, serviceType, 'GetExternalIPAddress', body);
      if (resp == null) return null;
      final m = RegExp(r'<NewExternalIPAddress>\s*([^<]+)\s*</NewExternalIPAddress>')
          .firstMatch(resp);
      return m?.group(1)?.trim();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _upnpAddPortMapping(
    String controlUrl,
    String serviceType,
    int internalPort,
    int externalPort,
    String internalIp,
  ) async {
    final body = _soap(
      serviceType,
      'AddPortMapping',
      '<NewRemoteHost></NewRemoteHost>'
          '<NewExternalPort>$externalPort</NewExternalPort>'
          '<NewProtocol>TCP</NewProtocol>'
          '<NewInternalPort>$internalPort</NewInternalPort>'
          '<NewInternalClient>$internalIp</NewInternalClient>'
          '<NewEnabled>1</NewEnabled>'
          '<NewPortMappingDescription>Nexus</NewPortMappingDescription>'
          '<NewLeaseDuration>0</NewLeaseDuration>',
    );
    final resp = await _soapPost(controlUrl, serviceType, 'AddPortMapping', body);
    if (resp == null) return false;
    return !resp.contains('errorCode') && !resp.contains('UPnPError');
  }

  Future<void> _upnpDeletePortMapping(
      String controlUrl, String serviceType, int externalPort) async {
    final body = _soap(
      serviceType,
      'DeletePortMapping',
      '<NewRemoteHost></NewRemoteHost>'
          '<NewExternalPort>$externalPort</NewExternalPort>'
          '<NewProtocol>TCP</NewProtocol>',
    );
    await _soapPost(controlUrl, serviceType, 'DeletePortMapping', body);
  }

  String _soap(String serviceType, String action, String inner) {
    return '<?xml version="1.0"?>\n'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
        '<s:Body>\n'
        '<u:$action xmlns:u="urn:schemas-upnp-org:service:$serviceType:1">\n'
        '$inner\n'
        '</u:$action>\n'
        '</s:Body>\n'
        '</s:Envelope>';
  }

  Future<String?> _soapPost(
      String controlUrl, String serviceType, String action, String body) async {
    try {
      final resp = await http
          .post(
            Uri.parse(controlUrl),
            headers: {
              'Content-Type': 'text/xml; charset="utf-8"',
              'SOAPAction':
                  '"urn:schemas-upnp-org:service:$serviceType:1#$action"',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      return resp.body;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _httpGet(String url) async {
    try {
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      return resp.body;
    } catch (_) {
      return null;
    }
  }

  // ---- common helpers -----------------------------------------------------

  /// Reads the default IPv4 gateway from the routing table (works on Linux and
  /// Android without a platform channel).
  Future<InternetAddress?> _defaultGateway() async {
    try {
      final lines = await File('/proc/net/route').readAsLines();
      for (final line in lines.skip(1)) {
        final cols = line.trim().split(RegExp(r'\s+'));
        if (cols.length < 3) continue;
        if (cols[1] == '00000000') {
          // Destination 0.0.0.0; the gateway is little-endian hex.
          final gw = int.parse(cols[2], radix: 16);
          final ip = '${gw & 0xff}.${(gw >> 8) & 0xff}.'
              '${(gw >> 16) & 0xff}.${(gw >> 24) & 0xff}';
          if (ip == '0.0.0.0') continue;
          return InternetAddress(ip);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String> _localIp() async {
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    )) {
      for (final addr in interface.addresses) {
        if (!addr.isLoopback) return addr.address;
      }
    }
    return '0.0.0.0';
  }
}

class _UpnpControl {
  final String url;
  final String serviceType;
  const _UpnpControl(this.url, this.serviceType);
}
