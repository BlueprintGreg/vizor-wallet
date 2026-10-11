import Foundation

struct BackgroundMigrationOutboxRunnerDependencies {
  var latestBlockHeight:
    (
      String,
      BackgroundMigrationCancellation
    ) -> Result<UInt64, NativeLightwalletdError>
  var sendTransaction:
    (
      String,
      Data,
      BackgroundMigrationCancellation
    ) -> Result<NativeLightwalletdSendResponse, NativeLightwalletdError>

  /// The app's own outbox pass (`runOutboxOnceNow`). Both requests follow the
  /// route this process is enforcing: Tor when it is selected and ready, an
  /// isolated circuit for each broadcast, direct only when Tor is off, and a
  /// refusal while Tor is starting or failed. Nothing falls back to direct.
  static let foreground = BackgroundMigrationOutboxRunnerDependencies(
    latestBlockHeight: { endpoint, cancellation in
      NativeLightwalletdClient.latestBlockHeight(
        endpoint: endpoint,
        cancellation: cancellation
      )
    },
    sendTransaction: { endpoint, rawTransaction, cancellation in
      NativeLightwalletdClient.sendTransaction(
        endpoint: endpoint,
        rawTransaction: rawTransaction,
        cancellation: cancellation
      )
    }
  )

  /// A background wake. Background work never brings Tor up, and on a cold
  /// launch this process may not have applied the user's route yet, so the
  /// saved route decides: with Tor saved, each request is deferred to the
  /// foreground before anything is dispatched. The saved route is read again
  /// immediately before every request, so a toggle between the chain-tip
  /// query and the broadcast is honoured. With Tor off the requests go through
  /// the same route-respecting transport as the foreground, which still
  /// refuses if this process has since switched to Tor.
  static func background(
    torSelected: @escaping () -> Bool = { BackgroundMigrationTorRoute.isSelected() },
    gate: BackgroundMigrationRouteGate = .shared,
    transport: BackgroundMigrationOutboxRunnerDependencies = .foreground
  ) -> BackgroundMigrationOutboxRunnerDependencies {
    // Only a saved Tor route defers to the foreground, which schedules no
    // further wake. A refusal by a save still in progress is transient: that
    // save may abort and leave the route direct, so the wake must retry.
    let refusal = { () -> NativeLightwalletdError in
      torSelected() ? .routeDeferredToForeground : .routeBlocked
    }
    return BackgroundMigrationOutboxRunnerDependencies(
      latestBlockHeight: { endpoint, cancellation in
        gate.admitDirect(torSaved: torSelected) {
          transport.latestBlockHeight(endpoint, cancellation)
        } ?? .failure(refusal())
      },
      sendTransaction: { endpoint, rawTransaction, cancellation in
        gate.admitDirect(torSaved: torSelected) {
          transport.sendTransaction(endpoint, rawTransaction, cancellation)
        } ?? .failure(refusal())
      }
    )
  }
}

/// The network route the user saved, as a cold background launch sees it.
///
/// Dart persists the "Use Tor" choice through `shared_preferences`
/// (`kTorEnabledPreferenceKey` in `network_privacy_provider.dart`), which on
/// iOS is `UserDefaults.standard` under a `flutter.` prefix. Dart writes it
/// before switching to Tor and after switching away, so it is never laxer than
/// the route the app enforces. Absent means the user never turned Tor on;
/// anything unreadable counts as Tor, matching Dart's fail-closed startup.
enum BackgroundMigrationTorRoute {
  static let defaultsKey = "flutter.zcash_tor_enabled"

  static func isSelected(defaults: UserDefaults = .standard) -> Bool {
    guard let stored = defaults.object(forKey: defaultsKey) else { return false }
    return (stored as? Bool) ?? true
  }
}

/// Orders background direct requests against saving Tor as the route.
///
/// Background migration never uses Tor, so it reads the saved route before
/// each request. Reading it and then sending is a check-then-act race: Dart can
/// save Tor in between, and the request still goes out directly because this
/// process has not switched its route yet. Every background request is
/// therefore admitted here, and Dart calls [beginTorSave] before writing Tor:
/// from then on nothing new is admitted, and the save waits for admitted
/// requests to finish (each is bounded by its RPC deadline). A request is thus
/// either admitted before the save starts and completes before it is written,
/// or refused.
///
/// Each save holds its own lease, so overlapping saves cannot release each
/// other: requests stay refused until every lease has ended.
final class BackgroundMigrationRouteGate: @unchecked Sendable {
  static let shared = BackgroundMigrationRouteGate()
  /// Covers an admitted request's whole life: the 10-second connect deadline,
  /// the 20-second unary RPC deadline, and teardown.
  static let saveDrainTimeout: TimeInterval = 35

  private let condition = NSCondition()
  private var torSaveLeases = Set<String>()
  private var admitted = 0

  init() {}

  /// Runs `request` unless Tor is saved or being saved; returns nil, having
  /// sent nothing, when refused.
  func admitDirect<T>(torSaved: () -> Bool, _ request: () -> T) -> T? {
    condition.lock()
    guard torSaveLeases.isEmpty, !torSaved() else {
      condition.unlock()
      return nil
    }
    admitted += 1
    condition.unlock()
    defer {
      condition.lock()
      admitted -= 1
      condition.broadcast()
      condition.unlock()
    }
    return request()
  }

  /// Takes a save lease: refuses new background requests and waits for
  /// admitted ones. Returns false if they did not finish in time; the caller
  /// must then not save Tor. Either way the lease holds until [endTorSave].
  func beginTorSave(
    leaseId: String,
    timeout: TimeInterval = saveDrainTimeout
  ) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    torSaveLeases.insert(leaseId)
    let deadline = Date().addingTimeInterval(timeout)
    while admitted > 0 {
      if !condition.wait(until: deadline) { return admitted == 0 }
    }
    return true
  }

  /// Ends only this save's lease, written or not. A written Tor route keeps
  /// refusing through the saved-route check.
  func endTorSave(leaseId: String) {
    condition.lock()
    torSaveLeases.remove(leaseId)
    condition.unlock()
  }
}

/// What to re-arm once the saved route has become direct.
struct BackgroundMigrationSavedRouteDirectActions: Equatable {
  /// Submit the outbox/preparation `BGProcessingTask` wake.
  let scheduleBackgroundWake: Bool
  /// Ask the preparation manager to submit confirmation tracking again.
  let restartPreparationTracking: Bool
}

/// The re-arm decision for work a saved Tor route held back.
///
/// With Tor saved, a background wake defers to the foreground and schedules
/// no further wake, and preparation tracking is not submitted. When the saved
/// route becomes direct that work is runnable again, so it is re-armed exactly
/// here rather than left for a later poll or sync that may never come before
/// the app is closed. The saved route is read again by the caller: if Tor was
/// saved again in the meantime, nothing is re-armed.
func backgroundMigrationSavedRouteDirectActions(
  torSelected: Bool,
  hasRunnableOutboxWork: Bool,
  hasResumablePreparationWork: Bool
) -> BackgroundMigrationSavedRouteDirectActions {
  guard !torSelected else {
    return BackgroundMigrationSavedRouteDirectActions(
      scheduleBackgroundWake: false,
      restartPreparationTracking: false
    )
  }
  return BackgroundMigrationSavedRouteDirectActions(
    scheduleBackgroundWake: hasRunnableOutboxWork || hasResumablePreparationWork,
    restartPreparationTracking: hasResumablePreparationWork
  )
}

enum BackgroundMigrationOutboxRunner {

  static func runOnce(
    store: BackgroundMigrationOutboxStore = .shared,
    cancellation: BackgroundMigrationCancellation,
    now: Date = Date(),
    requiresPreparationProofVerification: Bool = false,
    dependencies: BackgroundMigrationOutboxRunnerDependencies
  ) -> BackgroundMigrationOutboxRunResult {
    let gate = BackgroundMigrationOutboxExecutionGate.shared
    guard gate.tryBeginRun() else {
      return BackgroundMigrationOutboxRunResult(
        transport: .temporarilyUnavailable,
        proofReady: nil
      )
    }
    defer { gate.finishRun() }

    if cancellation.isCancelled {
      return BackgroundMigrationOutboxRunResult(
        transport: .cancelled,
        proofReady: nil
      )
    }

    var broadcastComplete: BackgroundMigrationBroadcastCompleteMetadata?
    var proofReady: BackgroundMigrationProofReadyMetadata?
    let endpoint: String
    do {
      var selectedEndpoint: String?
      _ = try store.update { snapshot in
        snapshot.recoverInterruptedSubmissions(at: now)
        broadcastComplete = snapshot.pendingBroadcastCompleteNotification()
        // Already queued notifications need no network observation. Preserve
        // them even when the saved route defers this wake to the foreground.
        proofReady = snapshot.pendingProofReadyNotification()
          ?? snapshot.pendingUnverifiedProofReadyNotice()
        selectedEndpoint = snapshot.nextEndpointForInspection()
      }
      guard let selectedEndpoint else {
        return BackgroundMigrationOutboxRunResult(
          transport: .noWork,
          proofReady: proofReady,
          broadcastComplete: broadcastComplete
        )
      }
      endpoint = selectedEndpoint
    } catch BackgroundMigrationOutboxStoreError.temporarilyUnavailable {
      return BackgroundMigrationOutboxRunResult(
        transport: .temporarilyUnavailable,
        proofReady: proofReady,
        broadcastComplete: broadcastComplete
      )
    } catch {
      return BackgroundMigrationOutboxRunResult(
        transport: .needsUserAction,
        proofReady: proofReady,
        broadcastComplete: broadcastComplete
      )
    }

    let remoteHeight: UInt64
    switch dependencies.latestBlockHeight(endpoint, cancellation) {
    case .success(let height):
      remoteHeight = height
    case .failure(.cancelled):
      return BackgroundMigrationOutboxRunResult(
        transport: .cancelled,
        proofReady: proofReady,
        broadcastComplete: broadcastComplete
      )
    case .failure(.routeDeferredToForeground):
      return BackgroundMigrationOutboxRunResult(
        transport: .deferredToForeground,
        proofReady: proofReady,
        broadcastComplete: broadcastComplete
      )
    case .failure:
      return BackgroundMigrationOutboxRunResult(
        transport: .temporarilyUnavailable,
        proofReady: proofReady,
        broadcastComplete: broadcastComplete
      )
    }
    if cancellation.isCancelled {
      return BackgroundMigrationOutboxRunResult(
        transport: .cancelled,
        proofReady: proofReady,
        broadcastComplete: broadcastComplete
      )
    }

    var attemptedAccountUuid: String?
    let selection: BackgroundMigrationOutboxSelection
    do {
      var selected: BackgroundMigrationOutboxSelection?
      let snapshot = try store.update { snapshot in
        snapshot.expireItems(remoteHeight: remoteHeight, endpoint: endpoint, at: now)
        snapshot.markDueItemsNeedingResign(
          remoteHeight: remoteHeight,
          endpoint: endpoint,
          at: now
        )
        proofReady =
          requiresPreparationProofVerification
          ? snapshot.pendingProofReadyNotification()
            ?? snapshot.pendingUnverifiedProofReadyNotice()
            ?? snapshot.proofReadinessCandidate(
              remoteHeight: remoteHeight,
              endpoint: endpoint
            )
          : snapshot.markProofReadyIfNeeded(
            remoteHeight: remoteHeight,
            endpoint: endpoint,
            at: now
          )
        selected = snapshot.selectDue(
          remoteHeight: remoteHeight,
          endpoint: endpoint,
          at: now
        )
        if let selected {
          attemptedAccountUuid = selected.accountUuid
          try snapshot.validateReschedulingAfterAcceptance(
            itemId: selected.item.itemId,
            remoteHeight: remoteHeight
          )
          try snapshot.beginSubmission(
            itemId: selected.item.itemId,
            attemptId: UUID().uuidString,
            at: now
          )
        }
      }
      guard let selected else {
        if snapshot.receipts.contains(where: {
          ($0.outcome == .expired || $0.outcome == .needsResign)
            && $0.remoteHeight == remoteHeight
        }) {
          let accountUuid = snapshot.receipts.first(where: {
            ($0.outcome == .expired || $0.outcome == .needsResign)
              && $0.remoteHeight == remoteHeight
          })?.accountUuid
          return BackgroundMigrationOutboxRunResult(
            transport: .needsUserAction,
            proofReady: proofReady,
            broadcastComplete: broadcastComplete,
            transportAccountUuid: accountUuid
          )
        }
        let nextHeight = snapshot.nextActionHeight(endpoint: endpoint)
        let transport: BackgroundMigrationTransportOutcome
        if let nextHeight {
          transport = .waiting(
            nextHeight: nextHeight,
            observedHeight: remoteHeight,
            delay: BackgroundMigrationOutboxCadence.nextCheckDelay(
              remoteHeight: remoteHeight,
              nextScheduledHeight: nextHeight
            )
          )
        } else {
          transport = .noWork
        }
        return BackgroundMigrationOutboxRunResult(
          transport: transport,
          proofReady: proofReady,
          broadcastComplete: broadcastComplete,
          transportAccountUuid: nextHeight.flatMap {
            snapshot.nextActionAccountUuid(endpoint: endpoint, height: $0)
          }
        )
      }
      selection = selected
    } catch BackgroundMigrationOutboxError.invalidSchedule {
      return BackgroundMigrationOutboxRunResult(
        transport: .needsUserAction,
        proofReady: nil,
        broadcastComplete: broadcastComplete,
        transportAccountUuid: attemptedAccountUuid
      )
    } catch BackgroundMigrationOutboxStoreError.temporarilyUnavailable {
      return BackgroundMigrationOutboxRunResult(
        transport: .temporarilyUnavailable,
        proofReady: proofReady,
        broadcastComplete: broadcastComplete
      )
    } catch {
      return BackgroundMigrationOutboxRunResult(
        transport: .needsUserAction,
        proofReady: proofReady,
        broadcastComplete: broadcastComplete,
        transportAccountUuid: attemptedAccountUuid
      )
    }

    if cancellation.isCancelled {
      recordCancelledBeforeSubmission(
        store: store,
        itemId: selection.item.itemId,
        error: "Background execution expired before submission."
      )
      return BackgroundMigrationOutboxRunResult(
        transport: .cancelled,
        proofReady: proofReady,
        broadcastComplete: broadcastComplete,
        transportAccountUuid: selection.accountUuid
      )
    }

    switch dependencies.sendTransaction(
      selection.lightwalletdUrl,
      selection.item.rawTransaction,
      cancellation
    ) {
    case .failure(let error)
    where error == .routeBlocked || error == .routeDeferredToForeground
      || error == .cancelled:
      // Refused or cancelled before the transaction left this device, so this
      // is a definite non-attempt: the item stays armed for the next pass
      // without counting a retry or waiting for expiry. The transport ignores
      // cancellation once a broadcast is dispatched and returns its response.
      let reason: String
      let transport: BackgroundMigrationTransportOutcome
      switch error {
      case .routeBlocked:
        reason = "The selected network route is not available yet."
        transport = .temporarilyUnavailable
      case .cancelled:
        reason = "Background execution stopped before submission."
        transport = .cancelled
      default:
        reason = "Waiting for Vizor to open to submit over Tor."
        transport = .deferredToForeground
      }
      recordCancelledBeforeSubmission(
        store: store,
        itemId: selection.item.itemId,
        error: reason
      )
      return BackgroundMigrationOutboxRunResult(
        transport: transport,
        proofReady: proofReady,
        broadcastComplete: broadcastComplete,
        transportAccountUuid: selection.accountUuid
      )
    case .failure(let error):
      recordUncertain(
        store: store,
        itemId: selection.item.itemId,
        error: String(describing: error),
        at: now
      )
      return BackgroundMigrationOutboxRunResult(
        transport: .temporarilyUnavailable,
        proofReady: proofReady,
        broadcastComplete: broadcastComplete,
        transportAccountUuid: selection.accountUuid
      )
    case .success(let response):
      do {
        if response.errorCode == 0 || isAcceptedEquivalent(response.errorMessage) {
          var random = SystemRandomNumberGenerator()
          let snapshot = try store.update { snapshot in
            try snapshot.recordAccepted(
              itemId: selection.item.itemId,
              equivalent: response.errorCode != 0,
              remoteHeight: remoteHeight,
              responseCode: response.errorCode,
              responseMessage: response.errorMessage,
              at: now,
              random: &random
            )
            broadcastComplete =
              snapshot.markBroadcastCompleteIfNeeded(
                batchId: selection.batchId,
                at: now
              ) ?? broadcastComplete
          }
          let nextHeight = snapshot.nextActionHeight(endpoint: endpoint)
          return BackgroundMigrationOutboxRunResult(
            transport: .accepted(
              nextHeight: nextHeight,
              observedHeight: remoteHeight,
              delay: BackgroundMigrationOutboxCadence.nextCheckDelay(
                remoteHeight: remoteHeight,
                nextScheduledHeight: nextHeight
              )
            ),
            proofReady: proofReady,
            broadcastComplete: broadcastComplete,
            transportAccountUuid: selection.accountUuid
          )
        }
        _ = try store.update { snapshot in
          try snapshot.recordRejected(
            itemId: selection.item.itemId,
            remoteHeight: remoteHeight,
            responseCode: response.errorCode,
            responseMessage: response.errorMessage,
            at: now
          )
        }
        return BackgroundMigrationOutboxRunResult(
          transport: .needsUserAction,
          proofReady: nil,
          broadcastComplete: broadcastComplete,
          transportAccountUuid: selection.accountUuid
        )
      } catch BackgroundMigrationOutboxStoreError.temporarilyUnavailable {
        return BackgroundMigrationOutboxRunResult(
          transport: .temporarilyUnavailable,
          proofReady: proofReady,
          broadcastComplete: broadcastComplete,
          transportAccountUuid: selection.accountUuid
        )
      } catch {
        return BackgroundMigrationOutboxRunResult(
          transport: .needsUserAction,
          proofReady: proofReady,
          broadcastComplete: broadcastComplete,
          transportAccountUuid: selection.accountUuid
        )
      }
    }
  }

  static func isAcceptedEquivalent(_ message: String) -> Bool {
    let message = message.lowercased()
    return message.contains("transaction was committed to the best chain")
      || message.contains("already in mempool")
      || message.contains("already have transaction")
      || message.contains("transaction already in block chain")
      || message.contains("transaction is already in state")
      || message.contains("transaction already exists")
      || message.contains("txn-already-known")
      || message.contains("txn-already-in-mempool")
      || message.contains("already known")
  }

  private static func recordUncertain(
    store: BackgroundMigrationOutboxStore,
    itemId: String,
    error: String,
    at date: Date
  ) {
    _ = try? store.update { snapshot in
      try snapshot.recordUncertain(itemId: itemId, error: error, at: date)
    }
  }

  private static func recordCancelledBeforeSubmission(
    store: BackgroundMigrationOutboxStore,
    itemId: String,
    error: String
  ) {
    _ = try? store.update { snapshot in
      try snapshot.recordCancelledBeforeSubmission(itemId: itemId, error: error)
    }
  }
}
