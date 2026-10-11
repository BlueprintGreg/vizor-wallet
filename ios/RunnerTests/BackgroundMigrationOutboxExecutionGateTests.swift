import Foundation
import XCTest
#if canImport(Runner)
@testable import Runner
#endif

final class BackgroundMigrationOutboxExecutionGateTests: XCTestCase {
  func testTorDeferredWakePreservesPendingVerifiedProofNotification() throws {
    try verifyDeferredProofNotification(verified: true)
  }

  func testTorDeferredWakePreservesPendingUnverifiedProofNotice() throws {
    try verifyDeferredProofNotification(verified: false)
  }

  func testTorDeferredWakeDoesNotInventProofReadiness() throws {
    try verifyDeferredProofNotification(verified: nil)
  }

  private func verifyDeferredProofNotification(verified: Bool?) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = BackgroundMigrationOutboxStore(
      fileURL: directory.appendingPathComponent("outbox.bin"),
      keyProvider: { Data(repeating: 0xCD, count: 32) }
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let batch = BackgroundMigrationOutboxBatch(
      batchId: "proof-watch", network: "test", accountUuid: "a", runId: "run-a",
      lightwalletdUrl: "https://example.invalid", timingMeanBlocks: 144,
      timingMaxBlocks: 576, createdAt: now, armedAt: nil,
      nextProofHeight: 288, proofReadyNotificationPendingAt: nil,
      proofReadyNotifiedAt: nil, items: []
    )
    _ = try store.update { snapshot in
      try snapshot.stage(batch)
      try snapshot.armBatch(batchId: batch.batchId, expectedDigests: [:], at: now)
      if let verified {
        if verified {
          XCTAssertTrue(snapshot.recordVerifiedProofReadiness(
            network: batch.network, accountUuid: batch.accountUuid, runId: batch.runId, at: now
          ))
        } else {
          XCTAssertNotNil(snapshot.markUnverifiedProofReadyNoticeIfNeeded(
            batchId: batch.batchId, at: now
          ))
        }
      }
    }
    let dependencies = BackgroundMigrationOutboxRunnerDependencies.background(
      torSelected: { true },
      transport: BackgroundMigrationOutboxRunnerDependencies(
        latestBlockHeight: { _, _ in
          XCTFail("A Tor-deferred wake contacted the network")
          return .success(288)
        },
        sendTransaction: { _, _, _ in
          XCTFail("A Tor-deferred wake broadcast a transaction")
          return .failure(.timedOut)
        }
      )
    )
    let expected = verified.map {
      BackgroundMigrationProofReadyMetadata(batchId: batch.batchId, observedHeight: 288, verified: $0)
    }
    // Delivery failure leaves the same metadata available on the next wake.
    for _ in 0..<2 {
      let result = BackgroundMigrationOutboxRunner.runOnce(
        store: store, cancellation: BackgroundMigrationCancellation(), now: now,
        requiresPreparationProofVerification: true, dependencies: dependencies
      )
      XCTAssertEqual(result.transport, .deferredToForeground)
      XCTAssertEqual(result.proofReady, expected)
    }
    if let verified {
      _ = try store.update { snapshot in
        if verified {
          try snapshot.acknowledgeProofReadyNotification(batchId: batch.batchId, at: now)
        } else {
          try snapshot.acknowledgeUnverifiedProofReadyNotice(batchId: batch.batchId, at: now)
        }
      }
      let result = BackgroundMigrationOutboxRunner.runOnce(
        store: store, cancellation: BackgroundMigrationCancellation(), now: now,
        requiresPreparationProofVerification: true, dependencies: dependencies
      )
      XCTAssertNil(result.proofReady, "An acknowledged notice must not be announced again")
    }
  }

  func testCancellationBeforeDispatchLeavesTheItemArmedWithoutAnAttempt() throws {
    // The transport reports `.cancelled` only when nothing was sent, so the
    // outbox records a definite non-attempt rather than an uncertain one.
    let (store, directory) = try makeArmedOutboxStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = BackgroundMigrationOutboxRunner.runOnce(
      store: store, cancellation: BackgroundMigrationCancellation(),
      dependencies: BackgroundMigrationOutboxRunnerDependencies(
        latestBlockHeight: { _, _ in .success(100) },
        sendTransaction: { _, _, cancellation in
          cancellation.cancel()
          return .failure(.cancelled)
        }
      )
    )
    XCTAssertEqual(result.transport, .cancelled)
    let item = try XCTUnwrap(store.read().batches.first?.items.first)
    XCTAssertEqual(item.status, .armed)
    XCTAssertEqual(item.attemptCount, 0)
    XCTAssertNil(item.nextAttemptAt)
    XCTAssertTrue(try store.read().receipts.isEmpty)
  }

  func testCancellationAfterDispatchPersistsTheResponse() throws {
    // A foreground handoff cancels the pass while its broadcast is in flight.
    // The transport drains the dispatched request and returns its response,
    // which the outbox records as accepted, not as an uncertain attempt.
    let (store, directory) = try makeArmedOutboxStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = BackgroundMigrationOutboxRunner.runOnce(
      store: store, cancellation: BackgroundMigrationCancellation(),
      dependencies: BackgroundMigrationOutboxRunnerDependencies(
        latestBlockHeight: { _, _ in .success(100) },
        sendTransaction: { _, _, cancellation in
          cancellation.cancel()
          return .success(NativeLightwalletdSendResponse(errorCode: 0, errorMessage: ""))
        }
      )
    )
    let snapshot = try store.read()
    XCTAssertEqual(snapshot.batches.first?.items.first?.attemptCount, 0)
    XCTAssertEqual(snapshot.receipts.map(\.outcome), [.accepted])
  }


  func testReleasedLeaseCannotAuthorizeLatePauseDuringRetry() {
    let gate = BackgroundMigrationOutboxExecutionGate()
    gate.pause(leaseId: "expired")
    XCTAssertTrue(gate.contains(leaseId: "expired"))
    gate.resume(leaseId: "expired")
    gate.pause(leaseId: "retry")
    XCTAssertFalse(gate.contains(leaseId: "expired"))
    XCTAssertFalse(gate.waitUntilIdle(leaseId: "expired"))
    XCTAssertTrue(gate.contains(leaseId: "retry"))
    XCTAssertTrue(gate.waitUntilIdle(leaseId: "retry"))
  }

  func testReleasingLeaseWakesDrainWithoutCancellingBroadcast() {
    let gate = BackgroundMigrationOutboxExecutionGate()
    XCTAssertTrue(gate.tryBeginRun())
    gate.pause(leaseId: "expired")
    let drained = expectation(description: "retired lease stops waiting")
    DispatchQueue.global().async {
      XCTAssertFalse(gate.waitUntilIdle(leaseId: "expired"))
      drained.fulfill()
    }
    gate.resume(leaseId: "expired")
    wait(for: [drained], timeout: 2)
    XCTAssertFalse(gate.tryBeginRun())
    gate.finishRun()
    XCTAssertTrue(gate.tryBeginRun())
    gate.finishRun()
  }

  func testIdlePauseBlocksAdmissionUntilResume() {
    let gate = BackgroundMigrationOutboxExecutionGate()
    gate.pause(leaseId: "a")
    gate.waitUntilIdle()
    XCTAssertFalse(gate.tryBeginRun())
    XCTAssertTrue(gate.resume(leaseId: "a"))
    XCTAssertTrue(gate.tryBeginRun())
    gate.finishRun()
  }

  func testOverlappingAndRepeatedLeasesCannotResumeAnotherMutation() {
    let gate = BackgroundMigrationOutboxExecutionGate()
    gate.pause(leaseId: "a")
    gate.pause(leaseId: "a") // lost quiesce response, same retry
    gate.pause(leaseId: "b")
    XCTAssertFalse(gate.resume(leaseId: "a"))
    XCTAssertFalse(gate.resume(leaseId: "a")) // lost resume response
    XCTAssertFalse(gate.tryBeginRun())
    XCTAssertTrue(gate.resume(leaseId: "b"))
    XCTAssertTrue(gate.tryBeginRun())
    gate.finishRun()
  }

  func testAccountRemovalRetiresOnlyItsFailedStopLeases() {
    let gate = BackgroundMigrationOutboxExecutionGate()
    gate.pause(leaseId: "stop:test:a:run-a")
    gate.pause(leaseId: "stop:test:b:run-b")
    gate.pause(leaseId: "remove-a")
    gate.discardStopLeases(network: "test", accountUuid: "a")
    XCTAssertFalse(gate.resume(leaseId: "remove-a"))
    XCTAssertFalse(gate.tryBeginRun())
    XCTAssertTrue(gate.resume(leaseId: "stop:test:b:run-b"))
  }

  func testWalletResetPreservesOtherLiveMutationLeases() {
    let gate = BackgroundMigrationOutboxExecutionGate()
    gate.pause(leaseId: "stop:test:a:run-a")
    gate.pause(leaseId: "reset")
    gate.discardStopLeases()
    XCTAssertFalse(gate.tryBeginRun())
    XCTAssertTrue(gate.resume(leaseId: "reset"))
  }

  func testDrainWaitsForSuccessfulBroadcastAndReceipt() throws {
    try verifyDrain(accepted: true)
  }

  func testDrainWaitsForUncertainBroadcastAndAttemptRecord() throws {
    try verifyDrain(accepted: false)
  }

  private func verifyDrain(accepted: Bool) throws {
    let gate = BackgroundMigrationOutboxExecutionGate.shared
    let leaseId = "stop:test:a:" + UUID().uuidString
    let sendStarted = DispatchSemaphore(value: 0)
    let releaseSend = DispatchSemaphore(value: 0)
    let drained = DispatchSemaphore(value: 0)
    let runnerDone = DispatchSemaphore(value: 0)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = BackgroundMigrationOutboxStore(
      fileURL: directory.appendingPathComponent("outbox.bin"),
      keyProvider: { Data(repeating: 0xCD, count: 32) }
    )
    defer {
      releaseSend.signal()
      gate.resume(leaseId: leaseId)
      try? FileManager.default.removeItem(at: directory)
    }
    let item = BackgroundMigrationOutboxItem(
      itemId: "item-a", partIndex: 0, txidHex: String(repeating: "a", count: 64),
      rawTransaction: Data([1, 2]), anchorBoundaryHeight: 0,
      scheduledHeight: 100, scheduleStartHeight: 99, expiryHeight: 69_120
    )
    let batch = BackgroundMigrationOutboxBatch(
      batchId: "batch-a", network: "test", accountUuid: "a", runId: "run-a",
      lightwalletdUrl: "https://example.invalid", timingMeanBlocks: 144,
      timingMaxBlocks: 576, createdAt: Date(), armedAt: nil,
      nextProofHeight: nil, proofReadyNotificationPendingAt: nil,
      proofReadyNotifiedAt: nil, items: [item]
    )
    _ = try store.update {
      try $0.stage(batch)
      try $0.armBatch(batchId: batch.batchId,
        expectedDigests: [item.itemId: item.payloadDigestHex], at: Date())
    }
    // Foreground recovery for any account enters this same wallet-wide runner.
    DispatchQueue.global().async {
      _ = BackgroundMigrationOutboxRunner.runOnce(
        store: store, cancellation: BackgroundMigrationCancellation(),
        dependencies: BackgroundMigrationOutboxRunnerDependencies(
          latestBlockHeight: { _, _ in .success(100) },
          sendTransaction: { _, _, cancellation in
            sendStarted.signal()
            guard releaseSend.wait(timeout: .now() + 5) == .success else {
              XCTFail("Test did not release the broadcast")
              return .failure(.timedOut)
            }
            XCTAssertFalse(cancellation.isCancelled)
            return accepted
              ? .success(NativeLightwalletdSendResponse(errorCode: 0, errorMessage: ""))
              : .failure(.timedOut)
          }
        )
      )
      runnerDone.signal()
    }
    XCTAssertEqual(sendStarted.wait(timeout: .now() + 5), .success)
    gate.pause(leaseId: leaseId)
    DispatchQueue.global().async {
      gate.waitUntilIdle()
      drained.signal()
    }
    XCTAssertEqual(drained.wait(timeout: .now() + 0.05), .timedOut)
    let blocked = BackgroundMigrationOutboxRunner.runOnce(
      store: store, cancellation: BackgroundMigrationCancellation(),
      dependencies: BackgroundMigrationOutboxRunnerDependencies(
        latestBlockHeight: { _, _ in XCTFail("A paused runner contacted the network"); return .success(100) },
        sendTransaction: { _, _, _ in XCTFail("A paused runner broadcast"); return .failure(.timedOut) }
      )
    )
    XCTAssertEqual(blocked.transport, .temporarilyUnavailable)
    releaseSend.signal()
    XCTAssertEqual(drained.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(runnerDone.wait(timeout: .now() + 5), .success)
    let snapshot = try store.read()
    XCTAssertEqual(snapshot.batches.first?.items.first?.attemptCount, accepted ? 0 : 1)
    if accepted {
      XCTAssertEqual(snapshot.receipts.count, 1)
      XCTAssertEqual(snapshot.receipts.first?.outcome, .accepted)
    } else {
      // A timeout is not evidence that no submission happened. Rust stop must
      // reconcile this attempt rather than treating the input as unspent.
      XCTAssertEqual(snapshot.batches.first?.items.first?.status, .armed)
    }
    XCTAssertFalse(gate.tryBeginRun())
    gate.resume(leaseId: leaseId)
    XCTAssertTrue(gate.tryBeginRun())
    gate.finishRun()
  }
}

final class BackgroundMigrationSavedRouteDirectTests: XCTestCase {
  func testTheRearmObligationPersistsUntilCleared() throws {
    let suite = "vizor.test.rearm." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertFalse(BackgroundMigrationDirectRouteRearm.isPending(defaults: defaults))
    BackgroundMigrationDirectRouteRearm.markPending(defaults: defaults)
    // A failed submission leaves it set, so the next foreground retries.
    XCTAssertTrue(BackgroundMigrationDirectRouteRearm.isPending(defaults: defaults))
    BackgroundMigrationDirectRouteRearm.clear(defaults: defaults)
    XCTAssertFalse(BackgroundMigrationDirectRouteRearm.isPending(defaults: defaults))
  }

  func testConcurrentRearmsRunOneAtATimeAndShareTheFinalResult() throws {
    let suite = "vizor.test.rearm." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let serializer = BackgroundMigrationRearmSerializer(defaults: defaults)
    var attempts: [(Bool) -> Void] = []
    let attempt: BackgroundMigrationRearmSerializer.Attempt = { done in
      attempts.append(done)
    }
    var first: Bool?
    var second: Bool?
    serializer.request(attempt) { first = $0 }
    // A second caller arrives while the first attempt is still in flight; it
    // must not run a concurrent attempt that could cancel the first's wake.
    serializer.request(attempt) { second = $0 }
    XCTAssertEqual(attempts.count, 1)
    // The first attempt succeeds, but a request arrived meanwhile, so the
    // attempt runs once more and only its result is reported.
    attempts[0](true)
    XCTAssertEqual(attempts.count, 2)
    XCTAssertNil(first)
    attempts[1](false)
    XCTAssertEqual(first, false)
    XCTAssertEqual(second, false)
    // A failure keeps the durable obligation for the next foreground entry.
    XCTAssertTrue(BackgroundMigrationDirectRouteRearm.isPending(defaults: defaults))
  }

  func testASatisfiedRearmClearsTheObligation() throws {
    let suite = "vizor.test.rearm." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let serializer = BackgroundMigrationRearmSerializer(defaults: defaults)
    var result: Bool?
    serializer.request({ done in
      // Recorded before the attempt runs, so a crash mid-attempt keeps it.
      XCTAssertTrue(BackgroundMigrationDirectRouteRearm.isPending(defaults: defaults))
      done(true)
    }) { result = $0 }
    XCTAssertEqual(result, true)
    XCTAssertFalse(BackgroundMigrationDirectRouteRearm.isPending(defaults: defaults))
  }

  func testANewRequestKeepsItsObligationWhileTheLastAttemptFinishes() throws {
    // A request that arrives as an attempt is finishing must not have its
    // obligation cleared by that attempt's success.
    let suite = "vizor.test.rearm." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let serializer = BackgroundMigrationRearmSerializer(defaults: defaults)
    var attempts: [(Bool) -> Void] = []
    let attempt: BackgroundMigrationRearmSerializer.Attempt = { done in
      attempts.append(done)
    }
    serializer.request(attempt) { _ in }
    // The first attempt finishes successfully before the next request.
    attempts[0](true)
    XCTAssertFalse(BackgroundMigrationDirectRouteRearm.isPending(defaults: defaults))
    serializer.request(attempt) { _ in }
    // While the new attempt is in flight its obligation is recorded, so an
    // app suspended now still retries on the next foreground entry.
    XCTAssertEqual(attempts.count, 2)
    XCTAssertTrue(BackgroundMigrationDirectRouteRearm.isPending(defaults: defaults))
    attempts[1](true)
    XCTAssertFalse(BackgroundMigrationDirectRouteRearm.isPending(defaults: defaults))
  }

  func testAPendingWakeIsKeptRatherThanReplaced() {
    // Replacing cancels first; a failed replacement would revoke a wake that
    // a concurrent re-arm had already confirmed.
    XCTAssertTrue(
      backgroundMigrationShouldKeepPendingWake(
        pendingIdentifiers: ["other", "com.keplr.vizor.ironwood-migration"],
        identifier: "com.keplr.vizor.ironwood-migration"
      )
    )
    XCTAssertFalse(
      backgroundMigrationShouldKeepPendingWake(
        pendingIdentifiers: ["other"],
        identifier: "com.keplr.vizor.ironwood-migration"
      )
    )
  }

  func testDirectRouteReArmsHeldBackOutboxAndPreparationWork() {
    XCTAssertEqual(
      backgroundMigrationSavedRouteDirectActions(
        torSelected: false,
        hasRunnableOutboxWork: true,
        hasResumablePreparationWork: true
      ),
      BackgroundMigrationSavedRouteDirectActions(
        scheduleBackgroundWake: true,
        restartPreparationTracking: true
      )
    )
    XCTAssertEqual(
      backgroundMigrationSavedRouteDirectActions(
        torSelected: false,
        hasRunnableOutboxWork: false,
        hasResumablePreparationWork: true
      ),
      BackgroundMigrationSavedRouteDirectActions(
        scheduleBackgroundWake: true,
        restartPreparationTracking: true
      )
    )
  }

  func testNothingIsArmedWithoutWorkOrWhileTorIsSavedAgain() {
    let none = BackgroundMigrationSavedRouteDirectActions(
      scheduleBackgroundWake: false,
      restartPreparationTracking: false
    )
    XCTAssertEqual(
      backgroundMigrationSavedRouteDirectActions(
        torSelected: false,
        hasRunnableOutboxWork: false,
        hasResumablePreparationWork: false
      ),
      none
    )
    // A stale call that arrives after Tor was saved again must not schedule
    // a wake that would only defer.
    XCTAssertEqual(
      backgroundMigrationSavedRouteDirectActions(
        torSelected: true,
        hasRunnableOutboxWork: true,
        hasResumablePreparationWork: true
      ),
      none
    )
  }
}

final class BackgroundMigrationRouteGateTests: XCTestCase {
  func testTorSaveWaitsForAnAdmittedRequestAndRefusesNewOnes() {
    let gate = BackgroundMigrationRouteGate()
    let inside = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let requestDone = DispatchSemaphore(value: 0)
    let saveStarted = DispatchSemaphore(value: 0)
    let saveDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = gate.admitDirect(torSaved: { false }) {
        inside.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      requestDone.signal()
    }
    XCTAssertEqual(inside.wait(timeout: .now() + 5), .success)
    var drained = false
    DispatchQueue.global().async {
      saveStarted.signal()
      drained = gate.beginTorSave(leaseId: "save", timeout: 5)
      saveDone.signal()
    }
    XCTAssertEqual(saveStarted.wait(timeout: .now() + 5), .success)
    // The admitted request has not finished, so Tor is not saved yet.
    XCTAssertEqual(saveDone.wait(timeout: .now() + 0.1), .timedOut)
    // Nothing new is admitted while the save is pending.
    var refusedRan = false
    XCTAssertNil(gate.admitDirect(torSaved: { false }) { refusedRan = true })
    XCTAssertFalse(refusedRan)
    release.signal()
    XCTAssertEqual(requestDone.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(saveDone.wait(timeout: .now() + 5), .success)
    XCTAssertTrue(drained)
    // An aborted save admits again while the saved route is still direct.
    gate.endTorSave(leaseId: "save")
    XCTAssertEqual(gate.admitDirect(torSaved: { false }) { 1 }, 1)
    XCTAssertNil(gate.admitDirect(torSaved: { true }) { 1 })
  }

  func testTorSaveReportsARequestThatOutlivesTheTimeout() {
    let gate = BackgroundMigrationRouteGate()
    let inside = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let requestDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = gate.admitDirect(torSaved: { false }) {
        inside.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      requestDone.signal()
    }
    XCTAssertEqual(inside.wait(timeout: .now() + 5), .success)
    XCTAssertFalse(gate.beginTorSave(leaseId: "save", timeout: 0.05))
    release.signal()
    XCTAssertEqual(requestDone.wait(timeout: .now() + 5), .success)
    // A timed-out save keeps its lease until its caller ends it.
    XCTAssertNil(gate.admitDirect(torSaved: { false }) { 1 })
    gate.endTorSave(leaseId: "save")
    XCTAssertEqual(gate.admitDirect(torSaved: { false }) { 1 }, 1)
  }

  func testOverlappingSavesCannotReleaseEachOther() {
    // An earlier save that failed or timed out ends while a later save is
    // still draining or writing. Its end must not reopen admission.
    let gate = BackgroundMigrationRouteGate()
    XCTAssertTrue(gate.beginTorSave(leaseId: "earlier", timeout: 1))
    XCTAssertTrue(gate.beginTorSave(leaseId: "later", timeout: 1))
    gate.endTorSave(leaseId: "earlier")
    var ran = false
    XCTAssertNil(gate.admitDirect(torSaved: { false }) { ran = true })
    XCTAssertFalse(ran)
    // Ending a lease twice, or one never taken, changes nothing either.
    gate.endTorSave(leaseId: "earlier")
    gate.endTorSave(leaseId: "unknown")
    XCTAssertNil(gate.admitDirect(torSaved: { false }) { 1 })
    gate.endTorSave(leaseId: "later")
    XCTAssertEqual(gate.admitDirect(torSaved: { false }) { 1 }, 1)
  }

  func testTheDrainCoversConnectAndRpcDeadlines() {
    // 10-second connect plus 20-second unary RPC, with room for teardown.
    XCTAssertGreaterThan(BackgroundMigrationRouteGate.saveDrainTimeout, 30)
  }

  func testBackgroundOutboxRequestsAreRefusedDuringATorSave() {
    let gate = BackgroundMigrationRouteGate()
    XCTAssertTrue(gate.beginTorSave(leaseId: "save", timeout: 1))
    defer { gate.endTorSave(leaseId: "save") }
    let transport = BackgroundMigrationOutboxRunnerDependencies(
      latestBlockHeight: { _, _ in
        XCTFail("A background tip query went out during a Tor save")
        return .success(1)
      },
      sendTransaction: { _, _, _ in
        XCTFail("A background broadcast went out during a Tor save")
        return .failure(.timedOut)
      }
    )
    let cancellation = BackgroundMigrationCancellation()
    // A save still in progress may abort and leave the route direct, so the
    // refusal must stay retryable rather than wait for the foreground.
    let pending = BackgroundMigrationOutboxRunnerDependencies.background(
      torSelected: { false }, gate: gate, transport: transport
    )
    XCTAssertEqual(
      pending.latestBlockHeight("https://example.invalid", cancellation),
      .failure(.routeBlocked)
    )
    switch pending.sendTransaction("https://example.invalid", Data([1]), cancellation) {
    case .failure(.routeBlocked): break
    default: XCTFail("Expected the broadcast to stay retryable")
    }
    // Once Tor is saved, the request belongs to the foreground.
    let saved = BackgroundMigrationOutboxRunnerDependencies.background(
      torSelected: { true }, gate: gate, transport: transport
    )
    XCTAssertEqual(
      saved.latestBlockHeight("https://example.invalid", cancellation),
      .failure(.routeDeferredToForeground)
    )
  }

  func testAWakeRefusedByAnAbortedTorSaveIsRetried() throws {
    // The save that refused this wake then aborts, so Tor is never saved.
    // The wake must be rescheduled, not parked for a foreground that has no
    // route change left to re-arm it.
    let gate = BackgroundMigrationRouteGate()
    XCTAssertTrue(gate.beginTorSave(leaseId: "save", timeout: 1))
    let (store, directory) = try makeArmedOutboxStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = BackgroundMigrationOutboxRunner.runOnce(
      store: store, cancellation: BackgroundMigrationCancellation(),
      dependencies: .background(
        torSelected: { false },
        gate: gate,
        transport: BackgroundMigrationOutboxRunnerDependencies(
          latestBlockHeight: { _, _ in .success(100) },
          sendTransaction: { _, _, _ in .failure(.timedOut) }
        )
      )
    )
    gate.endTorSave(leaseId: "save")
    XCTAssertEqual(result.transport, .temporarilyUnavailable)
    let item = try XCTUnwrap(store.read().batches.first?.items.first)
    XCTAssertEqual(item.status, .armed)
    XCTAssertEqual(item.attemptCount, 0)
  }
}

fileprivate func makeArmedOutboxStore() throws -> (BackgroundMigrationOutboxStore, URL) {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let store = BackgroundMigrationOutboxStore(
    fileURL: directory.appendingPathComponent("outbox.bin"),
    keyProvider: { Data(repeating: 0xCD, count: 32) }
  )
  let item = BackgroundMigrationOutboxItem(
    itemId: "item-a", partIndex: 0, txidHex: String(repeating: "a", count: 64),
    rawTransaction: Data([1, 2]), anchorBoundaryHeight: 0,
    scheduledHeight: 100, scheduleStartHeight: 99, expiryHeight: 69_120
  )
  let batch = BackgroundMigrationOutboxBatch(
    batchId: "batch-a", network: "test", accountUuid: "a", runId: "run-a",
    lightwalletdUrl: "https://example.invalid", timingMeanBlocks: 144,
    timingMaxBlocks: 576, createdAt: Date(), armedAt: nil,
    nextProofHeight: nil, proofReadyNotificationPendingAt: nil,
    proofReadyNotifiedAt: nil, items: [item]
  )
  _ = try store.update {
    try $0.stage(batch)
    try $0.armBatch(batchId: batch.batchId,
      expectedDigests: [item.itemId: item.payloadDigestHex], at: Date())
  }
  return (store, directory)
}
