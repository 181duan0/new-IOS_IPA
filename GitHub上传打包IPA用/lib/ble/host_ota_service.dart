import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../core/host_firmware.dart';
import 'ble_models.dart';

/// Host Firmware OTA Engine (CH582 / FIRE4000).
/// Matches the battle-tested Android Ballistic Computer OTA v1.8.2 protocol:
/// - Connects with `mtu: null`, discovers with `subscribeToServicesChanged: false`
///   (prevents CH582 `GATT_INSUFFICIENT_RESOURCES` on 0x2A05).
/// - Requests high connection priority and MTU 247 with retry.
/// - Automatically triggers 0xFFE3 -> 0x01 if device is running normal APP firmware.
/// - Executes 0x84 Info ([0x84, 0x00] -> r[1..4]=limit, r[5..6]=block, r[7..8]=CHIP_ID),
///   0x81 Erase (4 KB blocks), 0x80 Program + 0x82 Verify, 0x83 End.
class HostOtaService {
  static const int cmdProm = 0x80;
  static const int cmdErase = 0x81;
  static const int cmdVerify = 0x82;
  static const int cmdEnd = 0x83;
  static const int cmdInfo = 0x84;

  static const int defaultBlockSize = 4096;

  @visibleForTesting
  static ({int limit, int blockSize, int chipId}) parseDeviceInfo(List<int> info) {
    if (info.length < 9) {
      throw Exception('0x84 device info reply too short (${info.length} bytes, expected >= 9)');
    }
    final limit = (info[1] & 0xFF) |
        ((info[2] & 0xFF) << 8) |
        ((info[3] & 0xFF) << 16) |
        ((info[4] & 0xFF) << 24);
    final rawBlk = (info[5] & 0xFF) | ((info[6] & 0xFF) << 8);
    final blockSize = rawBlk == 0 ? defaultBlockSize : rawBlk;
    final chipId = (info[7] & 0xFF) | ((info[8] & 0xFF) << 8);
    return (limit: limit, blockSize: blockSize, chipId: chipId);
  }

  static Future<void> upgrade({
    required BluetoothDevice device,
    required HostFirmware fw,
    required bool verifyEveryPacket,
    required LogFn onLog,
    required StageFn onStage,
    required ProgressFn onProgress,
    required CancelCheck isCancelled,
  }) async {
    if (!fw.isInAppRegion) {
      throw Exception(
        'Firmware address 0x${fw.base.toRadixString(16).toUpperCase()}~'
        '0x${fw.end.toRadixString(16).toUpperCase()} is outside Image A (0x1000~0x3C000)',
      );
    }

    final sw = Stopwatch()..start();
    onLog(
      'Firmware ${fw.name} [${fw.source}] '
      '0x${fw.base.toRadixString(16).toUpperCase()}~0x${fw.end.toRadixString(16).toUpperCase()}  '
      '${fw.size} B  CRC32=${fw.crc32Hex}  entry ${fw.entry}  '
      'ImageFlag=0x${fw.imageFlag.toRadixString(16).toUpperCase()}',
    );
    if (fw.iapNote.isNotEmpty) {
      onLog(fw.iapNote);
    }

    BluetoothDevice target = device;

    // 1) Connect and detect OTA vs normal APP mode
    onStage('Connecting to device...');
    var (mtu, services) = await _openSessionWithRetry(target, onLog, isCancelled);
    var otaChar = BleUuids.findChar(services, BleUuids.chrOta, serviceUuid: BleUuids.svcOta) ??
        BleUuids.findChar(services, BleUuids.chrOta);
    final app3Char = BleUuids.findChar(services, BleUuids.chrApp3, serviceUuid: BleUuids.svcApp) ??
        BleUuids.findChar(services, BleUuids.chrApp3);

    if (otaChar == null && app3Char != null) {
      onLog('Connected to ${target.remoteId.str}, MTU=$mtu (normal APP mode)');
      onStage('Switching device into OTA mode...');
      try {
        await app3Char.write([0x01], withoutResponse: false);
        onLog('0xFFE3 written, device rebooting into OTA bootloader...');
      } catch (e) {
        onLog('0xFFE3 write returned error (device usually rebooting now): $e');
      }
      await BleConnectionHelper.disconnectClean(
        target,
        settle: const Duration(milliseconds: 1500),
      );

      onStage('Waiting for device to advertise in OTA mode...');
      final otaSession = await _waitForOtaSession(
        originalId: device.remoteId.str,
        timeout: const Duration(seconds: 90),
        onLog: onLog,
        onStage: onStage,
        isCancelled: isCancelled,
      );
      target = otaSession.device;
      mtu = otaSession.mtu;
      services = otaSession.services;
      otaChar = otaSession.otaChar;
      onLog('OTA connected, MTU=$mtu');
    } else if (otaChar == null) {
      await BleConnectionHelper.disconnectClean(target);
      throw Exception('Neither 0xFEE0/0xFEE1 nor 0xFFE3 is present — unsupported device');
    } else {
      onLog('Connected to ${target.remoteId.str}, MTU=$mtu');
    }

    try {
      if (mtu < 100) {
        onLog('⚠ MTU negotiated only $mtu; transfer will be slower (reconnecting usually reaches 247)');
      }

      // 2) 0x84 Device info
      onStage('Reading device info...');
      final (:limit, :blockSize, :chipId) = await _otaInfo(otaChar);
      onLog(
        'Device info: partition limit 0x${limit.toRadixString(16).toUpperCase()}, '
        'block $blockSize B, CHIP_ID 0x${chipId.toRadixString(16).toUpperCase().padLeft(4, '0')}',
      );
      if (fw.end > limit) {
        throw Exception(
          'Firmware end 0x${fw.end.toRadixString(16).toUpperCase()} '
          'exceeds partition limit 0x${limit.toRadixString(16).toUpperCase()}',
        );
      }

      // 3) 0x81 Erase 4 KB blocks
      final blocks = (fw.end - fw.base + blockSize - 1) ~/ blockSize;
      onStage('Erasing $blocks blocks from 0x${fw.base.toRadixString(16).toUpperCase()}...');
      onProgress(0, 'Erasing $blocks blocks ($blockSize B each)...');
      onLog('Erasing $blocks blocks from 0x${fw.base.toRadixString(16).toUpperCase()}...');
      final er = await _otaErase(otaChar, fw.base, blocks, isCancelled);
      if (er.isEmpty || er[0] != 0) {
        final code = er.isNotEmpty ? er[0] : 0xFF;
        throw Exception(
          'Erase failed, status=0x${code.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }
      onLog('Erase complete');

      // 4) 0x80 Program + 0x82 Verify
      int chunk = ((mtu - 3 - 4) ~/ 16) * 16;
      if (chunk < 16) chunk = 16;
      if (chunk > 240) chunk = 240;

      bool perPacket = verifyEveryPacket || !otaChar.properties.writeWithoutResponse;
      final total = fw.size;
      onLog(
        'Chunk $chunk bytes (MTU $mtu, ${perPacket ? "verify every packet" : "write without response"})',
      );
      onStage('Writing firmware...');

      Uint8List buildPkt(int addrI, int dataOff, int len) {
        final a16 = addrI ~/ 16;
        final pkt = Uint8List(4 + len);
        pkt[0] = cmdProm;
        pkt[1] = len;
        pkt[2] = a16 & 0xFF;
        pkt[3] = (a16 >> 8) & 0xFF;
        pkt.setRange(4, 4 + len, fw.data, dataOff);
        return pkt;
      }

      // Probe writeWithoutResponse with the first chunk before entering the fast loop
      if (!perPacket && total > 0) {
        try {
          final firstLen = total < chunk ? total : chunk;
          await _writeNoRspWithRetry(otaChar, buildPkt(fw.base, 0, firstLen), isCancelled);
          await Future.delayed(const Duration(milliseconds: 80));
        } catch (e) {
          if (e.toString().contains('Cancelled')) rethrow;
          perPacket = true;
          onLog('⚠ Write-without-response is unusable on this device ($e), switching to per-packet mode');
        }
      }

      int off = 0;
      int since = 0;
      int lastPct = -1;
      final writeSw = Stopwatch()..start();

      while (off < total) {
        if (isCancelled()) throw Exception('Cancelled by user');

        final n = (total - off) < chunk ? (total - off) : chunk;
        final addrI = fw.base + off;
        final pkt = buildPkt(addrI, off, n);

        if (perPacket) {
          final r1 = await _otaCmd(otaChar, pkt, minLen: 1);
          if (r1[0] != 0) {
            throw Exception(
              'Write failed @0x${addrI.toRadixString(16).toUpperCase()}, '
              'status=0x${r1[0].toRadixString(16).toUpperCase().padLeft(2, '0')}',
            );
          }
          if (verifyEveryPacket) {
            final vPkt = Uint8List.fromList(pkt)..[0] = cmdVerify;
            final r2 = await _otaCmd(otaChar, vPkt, minLen: 1);
            if (r2[0] != 0) {
              throw Exception(
                'Verify failed @0x${addrI.toRadixString(16).toUpperCase()}, '
                'status=0x${r2[0].toRadixString(16).toUpperCase().padLeft(2, '0')}',
              );
            }
          }
        } else {
          try {
            await _writeNoRspWithRetry(otaChar, pkt, isCancelled);
            await Future.delayed(Duration(milliseconds: (since & 7) == 0 ? 2 : 1));
            since++;
            if (since >= 32) {
              since = 0;
              onLog('Sent ${off + n} / $total B, waiting for the device...');
              await Future.delayed(const Duration(milliseconds: 130));
              final vPkt = Uint8List.fromList(pkt)..[0] = cmdVerify;
              final r = await _otaCmd(otaChar, vPkt, minLen: 1);
              if (r[0] != 0) {
                throw Exception(
                  'Verify failed @0x${addrI.toRadixString(16).toUpperCase()}, '
                  'status=0x${r[0].toRadixString(16).toUpperCase().padLeft(2, '0')}',
                );
              }
            }
          } catch (e) {
            final msg = e.toString();
            if (msg.contains('Verify failed') || msg.contains('Cancelled')) {
              rethrow;
            }
            onLog('⚠ Write-without-response failed ($e), switching to per-packet mode');
            perPacket = true;
            continue;
          }
        }

        off += n;
        final pct = (off * 100) ~/ total;
        if (pct != lastPct) {
          lastPct = pct;
          final sec = writeSw.elapsedMilliseconds / 1000.0;
          final kbps = sec > 0.1 ? (off / 1024.0 / sec) : 0.0;
          onProgress(
            pct,
            '$off / $total B  ·  0x${addrI.toRadixString(16).toUpperCase()}  ·  ${kbps.toStringAsFixed(1)} KB/s',
          );
        }
      }

      if (!perPacket) {
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // 5) 0x83 End marker
      onStage('Writing end marker...');
      onProgress(100, 'Finalizing and rebooting device...');
      try {
        await otaChar.write([cmdEnd, 0x00], withoutResponse: false);
      } catch (e) {
        onLog('End marker response error (normal as device jumps to APP immediately): $e');
      }
      await Future.delayed(const Duration(milliseconds: 800));

      final dt = sw.elapsedMilliseconds / 1000.0;
      onLog(
        'Upgrade complete in ${dt.toStringAsFixed(1)} s '
        '(${(total / 1024.0 / (dt > 0.1 ? dt : 0.1)).toStringAsFixed(1)} KB/s). '
        'Device sets ImageFlag back to A and boots the new firmware.',
      );
    } finally {
      await BleConnectionHelper.disconnectClean(target);
    }
  }

  static Future<(int mtu, List<BluetoothService> services)> _openSessionWithRetry(
    BluetoothDevice dev,
    LogFn onLog,
    CancelCheck isCancelled,
  ) async {
    Object? lastErr;
    for (int attempt = 1; attempt <= 3; attempt++) {
      if (isCancelled()) throw Exception('Cancelled by user');
      try {
        await BleConnectionHelper.connectClean(dev, timeout: const Duration(seconds: 12));
        int mtu = await BleConnectionHelper.negotiateMtu(dev, desired: 247);
        final services = await BleConnectionHelper.discoverSafe(dev);
        if (mtu < 100) {
          mtu = await BleConnectionHelper.negotiateMtu(dev, desired: 247);
        }
        return (mtu, services);
      } catch (e) {
        lastErr = e;
        await BleConnectionHelper.disconnectClean(dev, settle: const Duration(milliseconds: 300));
        if (attempt < 3) {
          onLog('Connection attempt $attempt failed ($e), retrying...');
          await Future.delayed(const Duration(milliseconds: 1200));
        }
      }
    }
    throw Exception('Cannot connect to ${dev.remoteId.str}: $lastErr');
  }

  static Future<
      ({
        BluetoothDevice device,
        int mtu,
        List<BluetoothService> services,
        BluetoothCharacteristic otaChar,
      })> _waitForOtaSession({
    required String originalId,
    required Duration timeout,
    required LogFn onLog,
    required StageFn onStage,
    required CancelCheck isCancelled,
  }) async {
    final deadline = DateTime.now().add(timeout);
    String lastErr = 'Device not found';
    int bounce = 0;
    int appSeen = 0;

    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled()) throw Exception('Cancelled by user');

      final scanStartedAt = DateTime.now();
      final completer = Completer<ScanResult?>();
      ScanResult? otaFallback;
      StreamSubscription<List<ScanResult>>? sub;

      sub = FlutterBluePlus.scanResults.listen((results) {
        // Ignore first 1200 ms to skip stale Android scan cache replays from before 0xFFE3
        if (DateTime.now().difference(scanStartedAt).inMilliseconds < 1200) {
          return;
        }
        for (final r in results) {
          final name = r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : r.device.platformName;
          final isSameMac = r.device.remoteId.str.toUpperCase() == originalId.toUpperCase();
          final isOtaName = name.toUpperCase().startsWith('OTAOTA');
          final hasOtaSvc = r.advertisementData.serviceUuids
              .any((u) => BleUuids.matches(u, BleUuids.svcOta));
          if (isSameMac) {
            if (!completer.isCompleted) completer.complete(r);
            return;
          }
          if (isOtaName || hasOtaSvc) {
            otaFallback ??= r;
          }
        }
      });

      ScanResult? result;
      try {
        await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
        result = await completer.future
            .timeout(const Duration(seconds: 6), onTimeout: () => otaFallback);
        await FlutterBluePlus.stopScan();
      } finally {
        await sub.cancel();
      }

      if (result == null) {
        lastErr = 'Device not found in scan';
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      final dev = result.device;
      final nm = result.advertisementData.advName.isNotEmpty
          ? result.advertisementData.advName
          : dev.platformName;
      final hasOtaSvc = result.advertisementData.serviceUuids
          .any((u) => BleUuids.matches(u, BleUuids.svcOta));

      if (nm.isNotEmpty && !nm.toUpperCase().startsWith('OTAOTA') && !hasOtaSvc) {
        appSeen++;
        onLog('Found $nm (not in OTA yet), still waiting... ($appSeen)');
        if (appSeen >= 3) {
          appSeen = 0;
          try {
            final (mtu, services) = await _openSessionWithRetry(dev, onLog, isCancelled);
            final otaChar = BleUuids.findChar(services, BleUuids.chrOta, serviceUuid: BleUuids.svcOta) ??
                BleUuids.findChar(services, BleUuids.chrOta);
            if (otaChar != null) {
              onLog('Found OTA bootloader device: $nm');
              return (device: dev, mtu: mtu, services: services, otaChar: otaChar);
            }
            final app3 = BleUuids.findChar(services, BleUuids.chrApp3, serviceUuid: BleUuids.svcApp) ??
                BleUuids.findChar(services, BleUuids.chrApp3);
            if (app3 != null) {
              try {
                await app3.write([0x01], withoutResponse: false);
              } catch (_) {}
              onLog('Still in APP mode, writing 0xFFE3 once more...');
            }
          } catch (_) {}
          await BleConnectionHelper.disconnectClean(
            dev,
            settle: const Duration(milliseconds: 1500),
          );
        } else {
          await Future.delayed(const Duration(milliseconds: 600));
        }
        continue;
      }

      onStage('Connecting to OTA bootloader...');
      try {
        final (mtu, services) = await _openSessionWithRetry(dev, onLog, isCancelled);
        final otaChar = BleUuids.findChar(services, BleUuids.chrOta, serviceUuid: BleUuids.svcOta) ??
            BleUuids.findChar(services, BleUuids.chrOta);
        if (otaChar != null) {
          final label = nm.isNotEmpty ? nm : dev.remoteId.str;
          onLog('Found OTA bootloader device: $label');
          return (device: dev, mtu: mtu, services: services, otaChar: otaChar);
        }

        final app3 = BleUuids.findChar(services, BleUuids.chrApp3, serviceUuid: BleUuids.svcApp) ??
            BleUuids.findChar(services, BleUuids.chrApp3);
        if (app3 != null) {
          bounce++;
          if (bounce >= 2) {
            await BleConnectionHelper.disconnectClean(dev);
            throw Exception(
              'The IAP bounced the device back to normal APP firmware ($bounce times in a row). '
              'This indicates the old 2024 IAP deadlock: use Full-Chip IAP Repair below to generate a repaired full-chip image and flash it over USB once.',
            );
          }
          onLog('Bounced back to APP after trigger #$bounce, writing 0xFFE3 again...');
          try {
            await app3.write([0x01], withoutResponse: false);
          } catch (_) {}
        }
        lastErr = 'Connected to normal firmware, reboot not finished';
        await BleConnectionHelper.disconnectClean(
          dev,
          settle: const Duration(milliseconds: 800),
        );
      } catch (e) {
        if (e.toString().contains('2024 IAP') || e.toString().contains('Cancelled')) {
          rethrow;
        }
        lastErr = e.toString();
        await BleConnectionHelper.disconnectClean(
          dev,
          settle: const Duration(milliseconds: 500),
        );
      }
    }

    throw Exception(
      'OTA mode never appeared within ${timeout.inSeconds} s ($lastErr). '
      'If the device keeps bouncing back to normal APP, it may carry the old 2024 IAP — use Full-Chip IAP Repair.',
    );
  }

  static Future<void> _writeNoRspWithRetry(
    BluetoothCharacteristic ch,
    Uint8List pkt,
    CancelCheck isCancelled,
  ) async {
    Object? lastErr;
    int waitMs = 8;
    for (int i = 0; i < 6; i++) {
      if (isCancelled()) throw Exception('Cancelled by user');
      try {
        await ch.write(pkt, withoutResponse: true);
        return;
      } catch (e) {
        lastErr = e;
        if (ch.device.isDisconnected) rethrow;
        await Future.delayed(Duration(milliseconds: waitMs));
        waitMs = (waitMs * 2).clamp(8, 200);
      }
    }
    throw Exception('Write without response rejected after 6 retries: $lastErr');
  }

  static Future<List<int>> _otaCmd(
    BluetoothCharacteristic ch,
    List<int> pkt, {
    int minLen = 1,
    int tries = 3,
  }) async {
    Object? lastErr;
    for (int i = 0; i < tries; i++) {
      try {
        await ch.write(pkt, withoutResponse: false);
        final r = await ch.read();
        if (r.length >= minLen) return r;
        lastErr = Exception('Reply is only ${r.length} bytes');
      } catch (e) {
        lastErr = e;
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
    throw Exception(
      'Command 0x${pkt[0].toRadixString(16).toUpperCase().padLeft(2, '0')} failed: $lastErr',
    );
  }

  static Future<({int limit, int blockSize, int chipId})> _otaInfo(
    BluetoothCharacteristic ch,
  ) async {
    try {
      final r = await _otaCmd(ch, [cmdInfo, 0x00], minLen: 20);
      return parseDeviceInfo(r);
    } catch (_) {
      await ch.write([cmdInfo, 0x00], withoutResponse: false);
      await Future.delayed(const Duration(milliseconds: 200));
      final r = await ch.read();
      return parseDeviceInfo(r);
    }
  }

  static Future<List<int>> _otaErase(
    BluetoothCharacteristic ch,
    int start,
    int blocks,
    CancelCheck isCancelled,
  ) async {
    final a16 = start ~/ 16;
    final pkt = [
      cmdErase,
      0x04,
      a16 & 0xFF,
      (a16 >> 8) & 0xFF,
      blocks & 0xFF,
      (blocks >> 8) & 0xFF,
    ];
    await ch.write(pkt, withoutResponse: false);
    await Future.delayed(Duration(milliseconds: blocks * 25 + 200));

    final deadline = DateTime.now().add(Duration(milliseconds: blocks * 45 + 5000));
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled()) throw Exception('Cancelled by user');
      try {
        final r = await ch.read();
        if (r.length == 2) return r;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 120));
    }
    throw Exception('Erase timed out ($blocks blocks)');
  }
}
