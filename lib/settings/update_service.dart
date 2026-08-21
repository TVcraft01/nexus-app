import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Checks the public GitHub Releases API for a newer version of Nexus,
/// downloads the update, and (on Android) hands it to the system installer.
///
/// No auth token is needed — the repo is public.
class UpdateService {
  static const _repo = 'TVcraft01/nexus-app';
  static const _apiUrl =
      'https://api.github.com/repos/$_repo/releases/latest';


  /// Returns the current app version string (e.g. "0.1.0").
  static Future<String> currentVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  /// Fetches the latest release from GitHub. Returns null if the network
  /// call fails or the repo has no releases yet.
  static Future<ReleaseInfo?> checkForUpdate() async {
    final current = await currentVersion();
    try {
      final resp = await http.get(
        Uri.parse(_apiUrl),
        headers: {'Accept': 'application/vnd.github+json'},
      );
      if (resp.statusCode != 200) return null;

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final tagName = json['tag_name'] as String? ?? '';
      final name = json['name'] as String? ?? tagName;
      final body = json['body'] as String? ?? '';
      final publishedAt = json['published_at'] as String?;
      final assets = (json['assets'] as List<dynamic>?) ?? [];

      final remoteVersion = _normalizeVersion(tagName);
      final localVersion = _normalizeVersion(current);
      final isNewer = _isNewer(localVersion, remoteVersion);

      final apkUrl = _findAsset(assets, '.apk');
      final linuxTarUrl = _findAsset(assets, '.tar.gz');

      return ReleaseInfo(
        tagName: tagName,
        name: name,
        body: body,
        publishedAt: publishedAt != null ? DateTime.tryParse(publishedAt) : null,
        isNewer: isNewer,
        currentVersion: current,
        apkDownloadUrl: apkUrl,
        linuxTarDownloadUrl: linuxTarUrl,
      );
    } catch (_) {
      return null;
    }
  }

  /// Downloads the APK to the app's cache directory and returns the file.
  /// The caller is responsible for opening it with the system installer.
  static Future<File?> downloadApk(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final filePath = p.join(dir.path, 'nexus_update.apk');
      final file = File(filePath);

      final request = await http.Client().send(http.Request('GET', Uri.parse(url)));
      final contentLength = request.contentLength ?? 0;
      final sink = file.openWrite();

      int received = 0;
      await for (final chunk in request.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          onProgress?.call(received / contentLength);
        }
      }
      await sink.flush();
      await sink.close();

      return file;
    } catch (_) {
      return null;
    }
  }

  /// Downloads the Linux bundle tarball and extracts it to a temp directory.
  /// Returns the path to the extracted bundle directory, or null on failure.
  static Future<String?> downloadLinuxBundle(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final tarPath = p.join(dir.path, 'nexus_update.tar.gz');
      final file = File(tarPath);

      final request = await http.Client().send(http.Request('GET', Uri.parse(url)));
      final contentLength = request.contentLength ?? 0;
      final sink = file.openWrite();

      int received = 0;
      await for (final chunk in request.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          onProgress?.call(received / contentLength);
        }
      }
      await sink.flush();
      await sink.close();

      // Extract the tarball
      final extractDir = p.join(dir.path, 'nexus_update_bundle');
      final result = await Process.run('tar', [
        'xzf', tarPath, '-C', extractDir, '--strip-components=0',
      ], runInShell: true);
      if (result.exitCode != 0) {
        // Try without strip-components in case the tarball layout differs
        await Directory(extractDir).create(recursive: true);
        await Process.run('tar', [
          'xzf', tarPath, '-C', extractDir,
        ], runInShell: true);
      }

      return extractDir;
    } catch (_) {
      return null;
    }
  }

  /// Generates a self-update shell script for Linux that replaces the
  /// running binary and relaunches. Returns the script content.
  static String generateLinuxUpdateScript(String extractedBundlePath) {
    // Find the binary in the extracted bundle
    return '''#!/bin/bash
# Nexus self-update script
# Generated by Nexus at ${DateTime.now().toIso8601String()}
#
# This script replaces the current Nexus installation with the
# newly downloaded version. Run it after closing Nexus.

set -e

BUNDLE_SRC="$extractedBundlePath"
INSTALL_DIR="\$(dirname "\$(readlink -f "\$(which nexus_app 2>/dev/null || echo /usr/local/bin/nexus_app)")")"

echo "Nexus self-update"
echo "================="
echo ""
echo "Source: \$BUNDLE_SRC"
echo "Target: \$INSTALL_DIR"
echo ""

if [ ! -d "\$BUNDLE_SRC" ]; then
    echo "ERROR: Extracted bundle not found at \$BUNDLE_SRC"
    echo "Please re-download the update."
    exit 1
fi

# Check the binary exists in the bundle
if [ ! -f "\$BUNDLE_SRC/nexus_app" ]; then
    echo "ERROR: nexus_app binary not found in the extracted bundle."
    echo "Contents of bundle directory:"
    ls -la "\$BUNDLE_SRC/" 2>/dev/null
    exit 1
fi

# Stop Nexus if running
if pgrep -x nexus_app > /dev/null 2>&1; then
    echo "Stopping running Nexus instance..."
    pkill -x nexus_app || true
    sleep 1
fi

# Back up current version
if [ -f "\$INSTALL_DIR/nexus_app" ]; then
    echo "Backing up current binary..."
    cp "\$INSTALL_DIR/nexus_app" "\$INSTALL_DIR/nexus_app.bak"
fi

# Copy new files
echo "Installing update..."
cp -r "\$BUNDLE_SRC/"* "\$INSTALL_DIR/"

# Make executable
chmod +x "\$INSTALL_DIR/nexus_app"

echo ""
echo "Update complete! Starting Nexus..."
exec "\$INSTALL_DIR/nexus_app"
''';
  }

  // ---- helpers -----------------------------------------------------------

  /// Strip leading 'v' and normalize "0.1.0" style versions for comparison.
  static List<int> _normalizeVersion(String v) {
    final cleaned = v.replaceFirst(RegExp(r'^v'), '');
    return cleaned
        .split('.')
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
  }

  /// Returns true if [remote] is strictly newer than [local].
  static bool _isNewer(List<int> local, List<int> remote) {
    for (var i = 0; i < max(local.length, remote.length); i++) {
      final l = i < local.length ? local[i] : 0;
      final r = i < remote.length ? remote[i] : 0;
      if (r > l) return true;
      if (r < l) return false;
    }
    return false; // same version
  }

  /// Finds the first asset whose name ends with [suffix].
  static String? _findAsset(List<dynamic> assets, String suffix) {
    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (name.endsWith(suffix)) {
        return asset['browser_download_url'] as String?;
      }
    }
    return null;
  }
}

/// Parsed info about a GitHub release.
class ReleaseInfo {
  final String tagName;
  final String name;
  final String body;
  final DateTime? publishedAt;
  final bool isNewer;
  final String currentVersion;
  final String? apkDownloadUrl;
  final String? linuxTarDownloadUrl;

  const ReleaseInfo({
    required this.tagName,
    required this.name,
    required this.body,
    this.publishedAt,
    required this.isNewer,
    required this.currentVersion,
    this.apkDownloadUrl,
    this.linuxTarDownloadUrl,
  });

  String get publishedLabel {
    if (publishedAt == null) return '';
    final diff = DateTime.now().difference(publishedAt!);
    if (diff.inDays > 30) return '${publishedAt!.month}/${publishedAt!.day}/${publishedAt!.year}';
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'just now';
  }
}
