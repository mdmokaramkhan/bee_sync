# Contributing to bee_sync

Thanks for helping! This guide covers setting up the project, running the tests, and what a good pull request looks like.

**Contents:** [Ways to help](#ways-to-help) · [Setup](#setup) · [Project layout](#project-layout) · [Running tests](#running-tests) · [The golden rule: spec first](#the-golden-rule-spec-first) · [Code style](#code-style) · [Commits and pull requests](#commits-and-pull-requests) · [Releasing](#releasing-maintainers)

## Ways to help

- **Report a bug:** open an issue with the bug template. Include your Flutter version, platform, and the inspector's Status and Activity tabs if you can.
- **Suggest a feature:** open an issue first so we can agree on the approach before you write code.
- **Improve docs:** typo fixes and clearer explanations are always welcome, no issue needed.
- **Send code:** see below.

## Setup

**You need:**

| Tool | Version | Notes |
|---|---|---|
| Flutter | 3.38.x stable | `fvm` works too |
| Xcode | current | for iOS builds and XCTests |
| Android Studio | current | its bundled JDK runs the Android tests |
| CocoaPods | 1.16+ | run with `LANG=en_US.UTF-8` (otherwise `pod install` fails with an encoding error) |

**Get the code:**

```bash
git clone https://github.com/mdmokaramkhan/bee_sync.git
```

```bash
cd bee_sync && flutter pub get && (cd example && flutter pub get)
```

## Project layout

| Path | What's there |
|---|---|
| `lib/` | The Dart package. `src/core/flush_controller.dart` is the reference uploader. |
| `android/src/main/kotlin/` | Native Android uploader (WorkManager). |
| `ios/Classes/` | Native iOS uploader (background exit, BGTasks). |
| `spec/` | **Shared contract:** SQL, uploader algorithm, and test cases for all three runtimes. |
| `pigeons/` | Definition of the Dart ↔ native channel (generates `messages.g.*`). |
| `test/` | Dart tests. |
| `android/src/test/`, `example/ios/RunnerTests/` | Kotlin (Robolectric) and Swift (XCTest) tests. |
| `benchmark/`, `example/integration_test/` | `track()` throughput benchmarks. |
| `tool/test_server.dart` | Local endpoint for end-to-end testing. |
| `example/` | Demo app with the inspector. |
| `doc/` | User guides and the design document. |

## Running tests

CI runs all of the following on every pull request: Dart format, analysis, tests and a publish dry run; the Android tests; and the iOS tests.

**Dart** (fast; run often):

```bash
flutter test
```

**Android** (Robolectric). Build the example once first; that generates the Gradle wrapper:

```bash
cd example && flutter build apk --debug
```

```bash
cd example/android && ./gradlew :bee_sync:testDebugUnitTest
```

**iOS** (XCTest). Build once, then test on any simulator:

```bash
cd example && flutter build ios --simulator --debug
```

```bash
cd example/ios && xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17'
```

**End to end:** start the local server, then run the example app against it:

```bash
dart run tool/test_server.dart --mode fail
```

```bash
cd example && flutter run --dart-define=BEE_ENDPOINT=http://10.0.2.2:8080/events --dart-define=BEE_DEMO_EVENTS=3
```

Use `localhost` instead of `10.0.2.2` on the iOS Simulator. [doc/test-plan.md](doc/test-plan.md) lists every manual scenario (failure modes, consent, Android and iOS background sync) with expected results; use it before releases.

**Benchmarks**, when you touch `track()` or the store:

```bash
flutter test benchmark/track_benchmark_test.dart
```

Compare with `benchmark/README.md`.

## The golden rule: spec first

Three uploaders (Dart, Kotlin, Swift) share one database. They stay correct only because they follow the same written contract in `spec/`.

- **Changing SQL?** Edit `spec/schema.sql` or `spec/claim_protocol.sql` first, then copy the statement verbatim into `lib/src/store/sql.dart`, `Sql.kt` and `Sql.swift`. Conformance tests in all three fail if they differ.
- **Changing uploader behaviour?** Update `spec/uploader_contract.md`, add or adjust a case in `spec/fixtures/uploader/`, and make all three test suites pass.
- **SQL must run on SQLite 3.8** (Android API 24): no `UPSERT`, `RETURNING` or window functions.
- **Changing the Dart ↔ native API?** Edit `pigeons/messages.dart` and regenerate:

  ```bash
  dart run pigeon --input pigeons/messages.dart
  ```

## Code style

- **Dart:** `dart format .` and `flutter analyze` must be clean; CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) and pub.dev scoring check both.
- **Kotlin and Swift:** follow the style of the surrounding code.
- **Comments:** explain *why*, not *what*. Public Dart APIs need doc comments.
- **Tests:** add one for every behaviour change. Use `fake_async` or the `Rig` in `test/core/bee_sync_test.dart` for time-dependent code.

## Commits and pull requests

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `perf:`, `docs:`, `test:`, `chore:`. Optionally add a scope, as in `feat(ios): …`. Explain *why* in the body.

**Before opening a PR:**

- [ ] `flutter test` and `flutter analyze` pass.
- [ ] Native code changed? The Android and iOS tests pass.
- [ ] `spec/` changed? All three runtimes updated and passing.
- [ ] Public API or behaviour changed? Docs and `CHANGELOG.md` (under the unreleased version) updated.
- [ ] Performance-sensitive change? Benchmark numbers before and after are in the PR description.

## Releasing (maintainers)

1. **Bump the version in all six places:**
   - `pubspec.yaml`
   - `lib/src/version.dart`
   - `NativeUploader.kt` (`BEE_SYNC_VERSION`)
   - `NativeUploader.swift` (`beeSyncVersion`)
   - `ios/bee_sync.podspec`
   - `android/build.gradle`

   `test/version_sync_test.dart` fails if they differ.
2. **Date the changelog section:** `## x.y.z — YYYY-MM-DD`.
3. **Merge to `main`**, then tag: `git tag -a vX.Y.Z -m "bee_sync X.Y.Z"` and `git push origin vX.Y.Z`.
4. **Publish:** run `flutter pub publish --dry-run` (expect 0 warnings), then `flutter pub publish`.
