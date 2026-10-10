#!/usr/bin/env bash
# Run the production Swift outbox/gate/store with injected transport on macOS.
# No simulator, wallet DB, Keychain reads, or network access is needed.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/vizor-outbox-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/TransportStub.swift" <<'SWIFT'
import Foundation
final class BackgroundMigrationCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
enum NativeLightwalletdError: Error, Equatable { case cancelled, timedOut, routeBlocked, routeDeferredToForeground }
struct NativeLightwalletdSendResponse { let errorCode: Int32; let errorMessage: String }
enum NativeLightwalletdClient {
  static func latestBlockHeight(endpoint: String, cancellation: BackgroundMigrationCancellation) -> Result<UInt64, NativeLightwalletdError> { fatalError("Inject transport in tests") }
  static func sendTransaction(endpoint: String, rawTransaction: Data, cancellation: BackgroundMigrationCancellation) -> Result<NativeLightwalletdSendResponse, NativeLightwalletdError> { fatalError("Inject transport in tests") }
}
SWIFT
# Exercise the real lifecycle callback without Flutter/UIKit or a simulator.
# Substitute availability with both pre-26 and 26+ cases; framework stubs record
# the handoff. This checks callback wiring, not the native transport implementation.
python3 - "$test_dir/ForegroundLifecycle.swift" <<'PY'
from pathlib import Path
import sys

source = Path('ios/Runner/AppDelegate.swift').read_text()
start = source.index('  override func applicationWillEnterForeground(')
end = source.index('  func didInitializeImplicitFlutterEngine(', start)
callback = source[start:end].replace('#available(iOS 26.0, *)', 'supportsContinuedProcessing')
Path(sys.argv[1]).write_text('''
import XCTest
private var supportsContinuedProcessing = false
private class UIApplication {}
private class FlutterAppDelegate {
  func applicationWillEnterForeground(_ application: UIApplication) {}
}
private final class IronwoodMigrationNotificationGate {
  static let shared = IronwoodMigrationNotificationGate()
  func enforceOnForeground() {}
}
private final class BackgroundMigrationManager {
  static let shared = BackgroundMigrationManager()
  var handoffs = 0
  func handoffToForeground() { handoffs += 1 }
}
private final class AppDelegate: FlutterAppDelegate {
''' + callback + '''
}
final class BackgroundMigrationForegroundHandoffTests: XCTestCase {
  func testForegroundEntryHandsOffOnIOS15Through25() {
    verifyHandoff(continuedProcessing: false)
  }
  func testForegroundEntryHandsOffOnIOS26AndLater() {
    verifyHandoff(continuedProcessing: true)
  }
  private func verifyHandoff(continuedProcessing: Bool) {
    supportsContinuedProcessing = continuedProcessing
    let before = BackgroundMigrationManager.shared.handoffs
    AppDelegate().applicationWillEnterForeground(UIApplication())
    XCTAssertEqual(BackgroundMigrationManager.shared.handoffs, before + 1)
  }
}
''')
PY
# Compile the preparation manager's pure continuation-scope rules and their
# Tor-deferral tests on their own; the manager itself needs UIKit and
# BackgroundTasks.
python3 - "$test_dir/PreparationTorDeferral.swift" <<'PY'
from pathlib import Path
import sys

def declaration(source, header):
    start = source.index(header)
    end = source.index('\n}\n', start) + 3
    return source[start:end]

manager = Path('ios/Runner/BackgroundMigrationPreparationManager.swift').read_text()
tests = Path('ios/RunnerTests/RunnerTests.swift').read_text()
parts = ['import XCTest\n']
for header in [
    'enum BackgroundMigrationPreparationResumeTarget',
    'enum BackgroundMigrationPreparationContinuedTaskDisposition',
    'func migrationPreparationContinuedTaskDisposition(',
    'func migrationPreparationPendingTrackableScopes(',
    'func migrationPreparationHandoffContinuationScopes(',
    'func migrationPreparationForegroundOnlyLaunchContinuationScopes(',
]:
    parts.append(declaration(manager, header))
parts.append(declaration(tests, 'final class BackgroundMigrationPreparationTorDeferralTests'))
Path(sys.argv[1]).write_text('\n'.join(parts))
PY
cat > "$test_dir/main.swift" <<'SWIFT'
import XCTest
import Darwin
let suite = XCTestSuite(name: "Migration outbox and foreground handoff")
suite.addTest(BackgroundMigrationOutboxExecutionGateTests.defaultTestSuite)
suite.addTest(BackgroundMigrationForegroundHandoffTests.defaultTestSuite)
suite.addTest(BackgroundMigrationPreparationTorDeferralTests.defaultTestSuite)
suite.run()
exit(suite.testRun?.hasSucceeded == true && suite.testCaseCount == 15 ? 0 : 1)
SWIFT
test_frameworks="$(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks"
test_libraries="$(xcrun --show-sdk-platform-path)/Developer/usr/lib"
test_private_frameworks="$(xcrun --show-sdk-platform-path)/Developer/Library/PrivateFrameworks"
xcrun swiftc -swift-version 5 -Xlinker -rpath -Xlinker "$test_private_frameworks" -I "$test_libraries" -L "$test_libraries" -Xlinker -rpath -Xlinker "$test_libraries" -F "$test_frameworks" -Xlinker -rpath -Xlinker "$test_frameworks" \
  ios/Runner/BackgroundMigrationOutboxExecutionGate.swift \
  ios/Runner/BackgroundMigrationOutbox.swift \
  ios/Runner/BackgroundMigrationOutboxStore.swift \
  ios/Runner/BackgroundMigrationOutboxRunner.swift \
  "$test_dir/TransportStub.swift" \
  ios/RunnerTests/BackgroundMigrationOutboxExecutionGateTests.swift \
  "$test_dir/ForegroundLifecycle.swift" \
  "$test_dir/PreparationTorDeferral.swift" \
  "$test_dir/main.swift" -o "$test_dir/tests"
"$test_dir/tests"
