import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

enum DeviceKind { ota, dfu, app }

class BleDeviceItem {
  final BluetoothDevice device;
  final String name;
  final String id;
  final int rssi;
  final DeviceKind kind;

  const BleDeviceItem({
    required this.device,
    required this.name,
    required this.id,
    required this.rssi,
    required this.kind,
  });

  String get kindLabel => switch (kind) {
        DeviceKind.ota => 'HOST OTA',
        DeviceKind.dfu => 'ABBM DFU',
        DeviceKind.app => 'APP MODE',
      };
}

class BleUuids {
  // Host OTA (CH582 / FIRE4000)
  static final Guid svcApp = Guid('0000ffe0-0000-1000-8000-00805f9b34fb');
  static final Guid chrApp3 = Guid('0000ffe3-0000-1000-8000-00805f9b34fb');
  static final Guid svcOta = Guid('0000fee0-0000-1000-8000-00805f9b34fb');
  static final Guid chrOta = Guid('0000fee1-0000-1000-8000-00805f9b34fb');

  // ABBM Nordic Secure DFU & Serial
  static final Guid dfuSecureCp = Guid('8ec90001-f315-4f60-9fb8-838830daea50');
  static final Guid dfuSecurePkt = Guid('8ec90002-f315-4f60-9fb8-838830daea50');
  static final Guid dfuButtonless = Guid('8ec90003-f315-4f60-9fb8-838830daea50');
  static final Guid dfuLegacySvc = Guid('00001530-1212-efde-1523-785feabcd123');
  static final Guid dfuLegacyCp = Guid('00001531-1212-efde-1523-785feabcd123');
  static final Guid abbmTx = Guid('0000fff1-0000-1000-8000-00805f9b34fb');
  static final Guid abbmRx = Guid('0000fff2-0000-1000-8000-00805f9b34fb');
  static final Guid gapDeviceName = Guid('00002a00-0000-1000-8000-00805f9b34fb');

  static bool matches(Guid a, Guid b) =>
      a.str128.toLowerCase() == b.str128.toLowerCase();

  static BluetoothCharacteristic? findChar(
    List<BluetoothService> services,
    Guid charUuid, {
    Guid? serviceUuid,
  }) {
    for (final s in services) {
      if (serviceUuid != null && !matches(s.uuid, serviceUuid)) continue;
      for (final c in s.characteristics) {
        if (matches(c.uuid, charUuid)) return c;
      }
    }
    return null;
  }

  static DeviceKind classify(String name, List<Guid> serviceUuids) {
    final up = name.trim().toUpperCase();
    final su = serviceUuids.map((g) => g.str128.toLowerCase()).toList();
    if (up.startsWith('OTAOTA')) return DeviceKind.ota;
    if (up.contains('NVISTI') ||
        up.contains('DFU') ||
        up.startsWith('AB-FIRE') ||
        su.any(
          (u) =>
              u.startsWith('8ec90001') ||
              u.startsWith('00001530') ||
              u.startsWith('0000fe59'),
        )) {
      return DeviceKind.dfu;
    }
    return DeviceKind.app;
  }

  static bool isAbbmAppName(String name) {
    final up = name.trim().toUpperCase();
    return up.startsWith('FIRE8000-') || up.startsWith('WMLRF-');
  }
}

/// Safe BLE connection & discovery helpers avoiding Android GATT quirks:
/// 1) Connect with `mtu: null` so flutter_blue_plus does not trigger an
///    unguarded auto requestMtu(512) that throws `device is disconnected`.
/// 2) Discover services with `subscribeToServicesChanged: false` so CH582
///    does not fail with `GATT_INSUFFICIENT_RESOURCES` (android-code: 17)
///    on GATT Service Changed 0x2A05.
class BleConnectionHelper {
  static Future<void> connectClean(
    BluetoothDevice d, {
    Duration timeout = const Duration(seconds: 15),
    bool requestHighPriority = true,
  }) async {
    try {
      if (d.isConnected) {
        await d.disconnect();
        await Future.delayed(const Duration(milliseconds: 600));
      }
    } catch (_) {}

    await d.connect(timeout: timeout, mtu: null, autoConnect: false);
    await Future.delayed(const Duration(milliseconds: 300));

    if (Platform.isAndroid && requestHighPriority) {
      try {
        await d.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high,
        );
      } catch (_) {}
    }
  }

  static Future<List<BluetoothService>> discoverSafe(BluetoothDevice d) async {
    return d.discoverServices(subscribeToServicesChanged: false);
  }

  static Future<int> negotiateMtu(
    BluetoothDevice d, {
    int desired = 247,
  }) async {
    if (!Platform.isAndroid) {
      final m = d.mtuNow;
      return m >= 23 ? m : 185;
    }
    int mtu = d.mtuNow;
    for (int attempt = 0; attempt < 2; attempt++) {
      if (d.isDisconnected) break;
      try {
        mtu = await d.requestMtu(desired);
        if (mtu >= 100) break;
      } catch (_) {
        mtu = d.mtuNow;
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return mtu >= 23 ? mtu : 23;
  }

  static Future<void> disconnectClean(
    BluetoothDevice d, {
    Duration settle = const Duration(milliseconds: 700),
  }) async {
    try {
      if (d.isConnected) {
        await d.disconnect();
      }
    } catch (_) {}
    if (settle > Duration.zero) {
      await Future.delayed(settle);
    }
  }
}

class BlePermissions {
  static Future<bool> ensure() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? true;
      final connOk = statuses[Permission.bluetoothConnect]?.isGranted ?? true;
      final locOk = statuses[Permission.locationWhenInUse]?.isGranted ?? true;
      return (scanOk && connOk) || locOk;
    }
    return true;
  }
}

typedef LogFn = void Function(String msg);
typedef StageFn = void Function(String stage);
typedef ProgressFn = void Function(int pct, String detail);
typedef CancelCheck = bool Function();
