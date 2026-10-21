import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/ledger/services/ledger_mobile_ble_service.dart';

/// Fakes native messages, retaining the production discovery stream adapter.
/// Stopping discovery deliberately emits neither another event nor channel EOF.
class LedgerDiscoveryChannel {
  LedgerDiscoveryChannel() {
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'bluetoothAccessStatus':
          return {'permission': 'granted', 'bluetoothEnabled': true};
        case 'requestPermissions':
          return true;
        case 'startDiscovery':
          await starting;
          if (startError case final error?) throw error;
        case 'connect':
          await connecting;
        case 'stopDiscovery':
          await stopping;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(events, (call) async {
      eventCalls.add(call.method);
      return null;
    });
  }

  static const methods = MethodChannel(kLedgerMobileMethodChannel);
  static const events = MethodChannel(
    'com.zcash.wallet/ledger_mobile/discovery',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final service = MethodChannelLedgerMobileBleService();
  final calls = <String>[];
  final eventCalls = <String>[];
  Future<void>? starting;
  Future<void>? connecting;
  Future<void>? stopping;
  Object? startError;

  Future<void> emit(Object? event) => _send(
    event == null
        ? null
        : const StandardMethodCodec().encodeSuccessEnvelope(event),
  );

  Future<void> error(String code) =>
      _send(const StandardMethodCodec().encodeErrorEnvelope(code: code));

  Future<void> _send(ByteData? data) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(events.name, data, (_) => done.complete());
    await done.future;
  }

  Future<void> devices() => emit({
    'type': 'devices',
    'devices': [
      {'id': 'stax', 'name': 'A37E', 'model': 'Ledger Stax'},
    ],
  });

  Future<void> dispose() async {
    await emit(null);
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  }
}

/// Drain real platform-stream cancellation futures as well as widget frames.
Future<void> pumpLedgerDiscovery(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
}
