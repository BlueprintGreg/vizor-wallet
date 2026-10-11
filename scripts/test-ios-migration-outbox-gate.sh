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
start = source.index('  override func application(\n    _ application: UIApplication,\n    didFinishLaunchingWithOptions')
end = source.index('  func didInitializeImplicitFlutterEngine(', start)
callback = source[start:end].replace('#available(iOS 26.0, *)', 'supportsContinuedProcessing')
Path(sys.argv[1]).write_text('''
import XCTest
private var supportsContinuedProcessing = false
private class UIApplication {
  enum State { case active, inactive, background }
  struct LaunchOptionsKey: Hashable {}
  let applicationState: State
  init(state: State = .active) { applicationState = state }
}
private class FlutterAppDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool { true }
  func applicationWillEnterForeground(_ application: UIApplication) {}
}
private enum FreshInstallKeychainCleaner {
  static func runIfNeeded() {}
}
private final class BGTaskScheduler {
  static let shared = BGTaskScheduler()
  func cancel(taskRequestWithIdentifier identifier: String) {}
}
private final class BackgroundMigrationPreparationManager {
  static let shared = BackgroundMigrationPreparationManager()
  func handoffPendingRequestForForegroundLaunch() {}
  func registerBackgroundTask() {}
}
private final class IronwoodMigrationNotificationGate {
  static let shared = IronwoodMigrationNotificationGate()
  func enforceOnForeground() {}
}
private final class BackgroundMigrationManager {
  static let shared = BackgroundMigrationManager()
  var handoffs = 0
  var rearmResumes = 0
  func handoffToForeground() { handoffs += 1 }
  func resumePendingDirectRouteRearm() { rearmResumes += 1 }
  func registerBackgroundTask() {}
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
  func testColdForegroundLaunchResumesAPendingRearm() {
    // No applicationWillEnterForeground follows a cold foreground launch.
    verifyLaunch(state: .active, resumes: 1)
  }
  func testBackgroundLaunchLeavesTheRearmForForegroundEntry() {
    verifyLaunch(state: .background, resumes: 0)
  }
  private func verifyLaunch(state: UIApplication.State, resumes: Int) {
    supportsContinuedProcessing = true
    let before = BackgroundMigrationManager.shared.rearmResumes
    _ = AppDelegate().application(
      UIApplication(state: state),
      didFinishLaunchingWithOptions: nil
    )
    XCTAssertEqual(BackgroundMigrationManager.shared.rearmResumes, before + resumes)
  }
  private func verifyHandoff(continuedProcessing: Bool) {
    supportsContinuedProcessing = continuedProcessing
    let before = BackgroundMigrationManager.shared.handoffs
    let rearmsBefore = BackgroundMigrationManager.shared.rearmResumes
    AppDelegate().applicationWillEnterForeground(UIApplication())
    XCTAssertEqual(BackgroundMigrationManager.shared.handoffs, before + 1)
    // A direct-route re-arm still owed is retried on every foreground entry.
    XCTAssertEqual(BackgroundMigrationManager.shared.rearmResumes, rearmsBefore + 1)
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
    'func migrationPreparationRouteRefusalEndsTracking(',
    'func migrationPreparationDirectRouteNeedsTracking(',
    'func migrationPreparationTrackerArmed(',
    'func migrationPreparationTrackingStopRequested(',
]:
    parts.append(declaration(manager, header))
parts.append(declaration(tests, 'final class BackgroundMigrationPreparationTorDeferralTests'))
Path(sys.argv[1]).write_text('\n'.join(parts))
PY
# Exercise the production route-deferred completion methods with framework
# stubs. A direct-route save during notification cleanup must not submit a
# replacement that the old task subsequently cancels.
python3 - "$test_dir/PreparationRouteHandoff.swift" <<'PY'
from pathlib import Path
import sys

manager = Path('ios/Runner/BackgroundMigrationPreparationManager.swift').read_text()

def method(header):
    start = manager.index(header)
    body = manager.index('{', start)
    depth = 1
    cursor = body + 1
    while depth:
        depth += (manager[cursor] == '{') - (manager[cursor] == '}')
        cursor += 1
    return manager[start:cursor].replace(
        'BackgroundMigrationTorRoute', 'RouteHandoffTorRoute'
    ).replace('BackgroundMigrationManager', 'RouteHandoffManager')

headers = [
    '  private func finishRouteDeferredTrackingTask(',
    '  private func finishForegroundOnlyTask(',
    '  private func rearmDeferredTracker(',
    '  private func isDeferredRearmStopped(',
]
for optional in [
    '  private func completeForegroundOnlyTask(',
    '  private func prepareForegroundOnlyCompletion(',
]:
    if optional in manager:
        headers.append(optional)

latch_start = manager.index('final class MigrationPreparationCompletionLatch')
latch_body = manager.index('{', latch_start)
depth, cursor = 1, latch_body + 1
while depth:
    depth += (manager[cursor] == '{') - (manager[cursor] == '}')
    cursor += 1
latch = manager[latch_start:cursor]

Path(sys.argv[1]).write_text('''
import XCTest
''' + latch + '''
private extension NSLock {
  func withPreparationLock<T>(_ body: () -> T) -> T {
    lock(); defer { unlock() }; return body()
  }
}
private enum RouteHandoffTorRoute {
  private static let lock = NSLock()
  private static var saved = true
  static func isSelected() -> Bool { lock.withPreparationLock { saved } }
  static func setSaved(_ value: Bool) { lock.withPreparationLock { saved = value } }
}
private enum BackgroundMigrationPrivateRecovery {
  static func isEnabled() -> Bool { false }
}
private final class BGContinuedProcessingTask {
  let completed = DispatchSemaphore(value: 0)
  var expirationHandler: (() -> Void)?
  /// Whether the replacement wake already existed when the task completed;
  /// iOS may suspend the app as soon as it does.
  var replacementAtCompletion: Bool?
  var success: Bool?
  var completions = 0
  func setTaskCompleted(success: Bool) {
    completions += 1
    replacementAtCompletion = BGTaskScheduler.shared.hasReplacement
    self.success = success
    completed.signal()
  }
}
private final class BGTaskScheduler {
  static let shared = BGTaskScheduler()
  private let lock = NSLock()
  private var pending = false
  func submitReplacement() { lock.withPreparationLock { pending = true } }
  func cancel(taskRequestWithIdentifier: String) {
    lock.withPreparationLock { pending = false }
  }
  var hasReplacement: Bool { lock.withPreparationLock { pending } }
}
private final class RouteHandoffManager {
  static let shared = RouteHandoffManager()
  var rearm: (() -> Void)?
  /// Results of successive re-arm attempts; empty means success. Reported
  /// asynchronously, as the native completion is.
  var results: [Bool] = []
  var attempts = 0
  func savedRouteBecameDirect(completion: @escaping (Bool) -> Void) {
    attempts += 1
    let succeeded = results.isEmpty ? true : results.removeFirst()
    if succeeded && !RouteHandoffTorRoute.isSelected() { rearm?() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
      completion(succeeded)
    }
  }
}
private final class PreparationRouteHandoffProbe {
  static let taskIdentifier = "test.preparation"
  static var rearmSubmissionTimeout: TimeInterval = 2
  static let deferredRearmRetryDelay: TimeInterval = 0.01
  var mutationQuiesced = false
  let queue = DispatchQueue(label: "test.preparation.route-handoff")
  let stateLock = NSLock()
  var taskRunning = true
  var taskProgress: Int? = 1
  var trackingCancellation: Int? = 1
  var latestTrackingProgress: Int? = 1
  var foregroundHandoffRequested = false
  var routeDeferralStopping = true
  var notificationAuthorization = NotificationState()
  var makeDirectDuringCleanup = false
  struct NotificationState { var isDisabled = false }
  func run(_ task: BGContinuedProcessingTask) {
    queue.async { self.finishRouteDeferredTrackingTask(task) }
  }
  func tryStartReplacement() {
    guard stateLock.withPreparationLock({ !taskRunning }) else { return }
    BGTaskScheduler.shared.submitReplacement()
  }
  func stopAuthorizationMonitoring() {}
  func recordSchedulingState(_ value: String) {}
  func cancelWatchdog() {}
  func preparationResumeTarget() -> BackgroundMigrationPreparationResumeTarget {
    .continuedProcessing
  }
  func markForegroundContinuationsReadyForLaunch(
    resumeTarget: BackgroundMigrationPreparationResumeTarget,
    privateRecovery: Bool, torSelected: Bool
  ) {}
  func foregroundRecoveryNotificationEvents(ensureFallback: Bool) -> [Int] { [] }
  func submitNotificationEvents(_ events: [Int]) -> Bool {
    if makeDirectDuringCleanup {
      RouteHandoffTorRoute.setSaved(false)
      RouteHandoffManager.shared.savedRouteBecameDirect { _ in }
    }
    return true
  }
''' + '\n'.join(method(header) for header in headers) + '''
}
final class BackgroundMigrationPreparationRouteHandoffTests: XCTestCase {
  func testAFailedReArmIsRetriedBeforeTheTaskCompletes() {
    // The re-arm during cleanup and the first one after it both fail; the
    // task keeps its execution and retries until the replacement is in place.
    RouteHandoffManager.shared.results = [false, false, true]
    defer { RouteHandoffManager.shared.results = [] }
    let task = verifyCompletion(turnDirect: true)
    XCTAssertEqual(task.success, true)
    XCTAssertEqual(task.completions, 1)
    XCTAssertEqual(RouteHandoffManager.shared.attempts, 3)
  }
  func testAReArmThatNeverSucceedsCompletesAsFailed() {
    PreparationRouteHandoffProbe.rearmSubmissionTimeout = 0.2
    RouteHandoffManager.shared.results = Array(repeating: false, count: 1_000)
    defer {
      PreparationRouteHandoffProbe.rearmSubmissionTimeout = 2
      RouteHandoffManager.shared.results = []
    }
    RouteHandoffTorRoute.setSaved(true)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "test.preparation")
    let probe = PreparationRouteHandoffProbe()
    probe.makeDirectDuringCleanup = true
    let task = BGContinuedProcessingTask()
    probe.run(task)
    XCTAssertEqual(task.completed.wait(timeout: .now() + 3), .success)
    // Never reported as armed tracking when no re-arm succeeded.
    XCTAssertEqual(task.success, false)
    XCTAssertEqual(task.replacementAtCompletion, false)
    // A retry already queued when the task completed sends nothing more.
    let attemptsAtCompletion = RouteHandoffManager.shared.attempts
    Thread.sleep(forTimeInterval: 0.1)
    XCTAssertEqual(task.completions, 1)
    XCTAssertEqual(RouteHandoffManager.shared.attempts, attemptsAtCompletion)
  }
  func testAStoppedTrackerSendsNoFurtherReArm() {
    // A wallet mutation (or disabled notifications) stops the retry before
    // it reaches native, so no obligation is registered again.
    RouteHandoffManager.shared.results = Array(repeating: false, count: 10)
    defer { RouteHandoffManager.shared.results = [] }
    RouteHandoffManager.shared.attempts = 0
    RouteHandoffTorRoute.setSaved(true)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "test.preparation")
    let probe = PreparationRouteHandoffProbe()
    probe.makeDirectDuringCleanup = true
    probe.mutationQuiesced = true
    let task = BGContinuedProcessingTask()
    probe.run(task)
    XCTAssertEqual(task.completed.wait(timeout: .now() + 3), .success)
    XCTAssertEqual(task.success, false)
    // Only the hook that ran during cleanup; none after the stop.
    XCTAssertEqual(RouteHandoffManager.shared.attempts, 1)
  }
  func testDirectSaveDuringCleanupRearmsAfterTheOldTaskFinishes() {
    verifyCompletion(turnDirect: true)
  }
  func testSavedTorCompletesWithoutRearmingBackgroundRequests() {
    verifyCompletion(turnDirect: false)
  }
  @discardableResult
  private func verifyCompletion(turnDirect: Bool) -> BGContinuedProcessingTask {
    RouteHandoffManager.shared.attempts = 0
    RouteHandoffTorRoute.setSaved(true)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "test.preparation")
    let probe = PreparationRouteHandoffProbe()
    probe.makeDirectDuringCleanup = turnDirect
    RouteHandoffManager.shared.rearm = { [weak probe] in probe?.tryStartReplacement() }
    defer { RouteHandoffManager.shared.rearm = nil }
    let task = BGContinuedProcessingTask()
    probe.run(task)
    XCTAssertEqual(task.completed.wait(timeout: .now() + 2), .success)
    // Service the main-queue re-arm after terminal cleanup.
    let deadline = Date().addingTimeInterval(0.1)
    while Date() < deadline { RunLoop.current.run(until: deadline) }
    XCTAssertFalse(probe.stateLock.withPreparationLock { probe.taskRunning })
    XCTAssertEqual(BGTaskScheduler.shared.hasReplacement, turnDirect)
    // The re-arm is in place before the task completes, not after.
    XCTAssertEqual(task.replacementAtCompletion, turnDirect)
    return task
  }
}
''')
PY
cat > "$test_dir/main.swift" <<'SWIFT'
import XCTest
import Darwin
let suite = XCTestSuite(name: "Migration outbox and foreground handoff")
suite.addTest(BackgroundMigrationOutboxExecutionGateTests.defaultTestSuite)
suite.addTest(BackgroundMigrationSavedRouteDirectTests.defaultTestSuite)
suite.addTest(BackgroundMigrationRouteGateTests.defaultTestSuite)
suite.addTest(BackgroundMigrationForegroundHandoffTests.defaultTestSuite)
suite.addTest(BackgroundMigrationPreparationTorDeferralTests.defaultTestSuite)
suite.addTest(BackgroundMigrationPreparationRouteHandoffTests.defaultTestSuite)
suite.run()
exit(suite.testRun?.hasSucceeded == true && suite.testCaseCount == 43 ? 0 : 1)
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
  "$test_dir/PreparationRouteHandoff.swift" \
  "$test_dir/main.swift" -o "$test_dir/tests"
"$test_dir/tests"
