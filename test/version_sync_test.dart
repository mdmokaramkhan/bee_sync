import 'dart:io';

import 'package:bee_sync/src/version.dart';
import 'package:flutter_test/flutter_test.dart';

/// The version appears in six places; every one is sent in (or describes)
/// the X-BeeSync-Sdk header, so they must agree.
void main() {
  String match(String path, String pattern) {
    final m = RegExp(
      pattern,
      multiLine: true,
    ).firstMatch(File(path).readAsStringSync());
    expect(m, isNotNull, reason: 'no version found in $path');
    return m!.group(1)!;
  }

  test(
    'version is the same in pubspec, Dart, Kotlin, Swift, podspec and Gradle',
    () {
      final pubspec = match('pubspec.yaml', r'^version: (\S+)$');
      expect(beeSyncVersion, pubspec, reason: 'lib/src/version.dart');
      expect(
        match(
          'android/src/main/kotlin/dev/beesync/bee_sync/NativeUploader.kt',
          r'BEE_SYNC_VERSION = "([^"]+)"',
        ),
        pubspec,
      );
      expect(
        match(
          'ios/Classes/NativeUploader.swift',
          r'let beeSyncVersion = "([^"]+)"',
        ),
        pubspec,
      );
      expect(
        match('ios/bee_sync.podspec', r"s\.version\s*=\s*'([^']+)'"),
        pubspec,
      );
      expect(match('android/build.gradle', r'^version = "([^"]+)"'), pubspec);
    },
  );
}
