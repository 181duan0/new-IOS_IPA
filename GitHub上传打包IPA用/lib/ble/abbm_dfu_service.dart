import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../core/crc32.dart';
import '../core/dfu_package.dart';
import 'ble_models.dart';

class AbbmIdentity {
  final String gi;
  final String gk;
  final int? key;
  final int? level;

  const AbbmIdentity({
    required this.gi,
    required this.gk,
    this.key,
    this.level,
  });
}

/// Reusable single-connection ABBM UART session (FFF1 write / FFF2 notify).
/// Avoids rapid connect/disconnect thrashing that causes Android GATT
/// `requestMtu: device is disconnected` errors.
class _AbbmUartSession {
  final BluetoothDevice device;
  final BluetoothCharacteristic tx;
  final BluetoothCharacteristic rx;
  final Queue<Uint8List> _inbox = Queue<Uint8List>();
  StreamSubscription<List<int>>? _sub;

  _AbbmUartSession._(this.device, this.tx, this.rx);

  static Future<_AbbmUartSession> open(
    BluetoothDevice device,
    List<BluetoothService> services,
  ) async {
    final tx = BleUuids.findChar(services, BleUuids.abbmTx);
    final rx = BleUuids.findChar(services, BleUuids.abbmRx);
    if (tx == null || rx == null) {
      throw Exception('ABBM UART characteristics (FFF1/FFF2) not found');
    }
    final sess = _AbbmUartSession._(device, tx, rx);
    try {
      await rx.setNotifyValue(true);
    } catch (_) {}
    sess._sub = rx.onValueReceived.listen((data) {
      sess._inbox.add(Uint8List.fromList(data));
    });
    await Future.delayed(const Duration(milliseconds: 300));
    return sess;
  }

  Future<String> send(
    String cmd, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    _inbox.clear();
    final useNoRsp = !tx.properties.write && tx.properties.writeWithoutResponse;
    final payload = ascii.encode('${cmd.trim()}\r');
    await tx.write(payload, withoutResponse: useNoRsp);

    final want = cmd.trim().toUpperCase();
    final deadline = DateTime.now().add(timeout);
    String lastTxt = '';

    while (DateTime.now().isBefore(deadline)) {
      if (_inbox.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 40));
        continue;
      }
      final raw = _inbox.removeFirst();
      final txt = ascii
          .decode(raw, allowInvalid: true)
          .replaceAll(RegExp(r'[\x00\r\n]+'), '')
          .trim();
      if (txt.isEmpty) continue;
      if (txt.toUpperCase() == want) {
        lastTxt = txt;
        continue;
      }
      if (txt.contains(',') && txt.startsWith(':')) {
        return txt;
      }
      lastTxt = txt;
    }

    if (rx.properties.read) {
      try {
        final raw = await rx.read();
        final txt = ascii
            .decode(raw, allowInvalid: true)
            .replaceAll(RegExp(r'[\x00\r\n]+'), '')
            .trim();
        if (txt.contains(',') && txt.startsWith(':')) return txt;
      } catch (_) {}
    }

    return lastTxt;
  }

  Future<void> writeBootloaderCmd(LogFn onLog) async {
    final useNoRsp = !tx.properties.write && tx.properties.writeWithoutResponse;
    try {
      await tx.write(ascii.encode(':GB\r'), withoutResponse: useNoRsp);
    } catch (e) {
      onLog('  :GB write returned error (normal as module reboots): $e');
    }
    await Future.delayed(const Duration(milliseconds: 1200));
  }

  Future<void> close() async {
    await _sub?.cancel();
    try {
      if (device.isConnected) await rx.setNotifyValue(false);
    } catch (_) {}
  }
}

/// ABBM BLE Nordic Secure DFU + Transparent Serial (FFF1/FFF2) Engine.
/// Key Android/iOS fixes:
/// 1) Single persistent connection for pre-flight (:GI, :GK, :VR, :GB) — no GATT thrash.
/// 2) Single persistent connection when already in NVISTI bootloader — no drop/reconnect.
/// 3) `mtu: null` on connect + `subscribeToServicesChanged: false` on discover.
/// 4) Writes DFU packet data (8EC90002) with `withoutResponse: true` (matching GATT spec)
///    paired with Nordic Packet Receipt Notification (PRN = 8) hardware flow control.
/// 5) Preserves original firmware BLE name after upgrade (never renames / never sends :RV).
class AbbmDfuService {
  static const Map<int, String> _dfuCodes = {
    0x01: 'Invalid state',
    0x02: 'Not supported',
    0x03: 'Data size exceeds limit',
    0x04: 'CRC error',
    0x05: 'Operation failed',
    0x06: 'SRAM overflow',
  };

  static (int, int) _verTuple(String s) {
    final parts = s.split('.');
    final a = int.tryParse(parts.isNotEmpty ? parts[0] : '0') ?? 0;
    final b = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
    return (a, b);
  }

  static AbbmIdentity _parseIdent(String gi, String gk) {
    int? key;
    int? level;
    if (gk.toUpperCase().startsWith(':GK,')) {
      final parts = gk.substring(4).split(',');
      key = int.tryParse(parts[0].trim());
      if (parts.length > 1) level = int.tryParse(parts[1].trim());
    }
    return AbbmIdentity(gi: gi, gk: gk, key: key, level: level);
  }

  /// Send one custom ABBM serial command (:VR, :GI, :GK, etc.).
  static Future<String> sendSerialCmd(
    BluetoothDevice device,
    String cmd, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    await BleConnectionHelper.connectClean(device, timeout: const Duration(seconds: 12));
    _AbbmUartSession? uart;
    try {
      final services = await BleConnectionHelper.discoverSafe(device);
      uart = await _AbbmUartSession.open(device, services);
      return await uart.send(cmd, timeout: timeout);
    } finally {
      await uart?.close();
      await BleConnectionHelper.disconnectClean(device);
    }
  }

  /// Read :GI, :GK, and :VR over a SINGLE BLE connection.
  static Future<(AbbmIdentity ident, String ver, String vraw)> readAllInfo(
    BluetoothDevice device,
  ) async {
    await BleConnectionHelper.connectClean(device, timeout: const Duration(seconds: 12));
    _AbbmUartSession? uart;
    try {
      final services = await BleConnectionHelper.discoverSafe(device);
      uart = await _AbbmUartSession.open(device, services);
      final gi = await uart.send(':GI');
      await Future.delayed(const Duration(milliseconds: 120));
      final gk = await uart.send(':GK');
      await Future.delayed(const Duration(milliseconds: 120));
      String ver = '';
      String vraw = '';
      for (int i = 0; i < 3; i++) {
        vraw = await uart.send(':VR');
        if (vraw.toUpperCase().startsWith(':VR,')) {
          ver = vraw.substring(4).split(',').first.trim();
          break;
        }
        await Future.delayed(const Duration(milliseconds: 250));
      }
      return (_parseIdent(gi, gk), ver, vraw);
    } finally {
      await uart?.close();
      await BleConnectionHelper.disconnectClean(device);
    }
  }

  /// Write :SK license key and read back :GK.
  static Future<(String cmd, String wr, String chk)> writeLicense(
    BluetoothDevice device,
    String keyOr32Hex,
    int? level,
  ) async {
    final cmd = level != null ? ':SK,$keyOr32Hex,$level' : ':SK,$keyOr32Hex';
    String wr = '';
    try {
      wr = await sendSerialCmd(device, cmd, timeout: const Duration(seconds: 2));
    } catch (e) {
      wr = '(module rebooting: $e)';
    }
    await Future.delayed(const Duration(seconds: 3));
    String chk = '';
    try {
      chk = await sendSerialCmd(device, ':GK');
    } catch (e) {
      chk = '($e)';
    }
    return (cmd, wr, chk);
  }

  /// Full ABBM Nordic Secure DFU workflow.
  /// ★ Does NOT rename the device after upgrade — preserves original firmware BLE name!
  static Future<void> runDfu({
    required BleDeviceItem item,
    required DfuPackage pkg,
    required bool forceNonNvisti,
    required LogFn onLog,
    required StageFn onStage,
    required ProgressFn onProgress,
    required CancelCheck isCancelled,
  }) async {
    final sw = Stopwatch()..start();
    final origId = item.id;
    AbbmIdentity? origIdent;

    onLog(
      'ABBM package: ${pkg.name}  bin=${pkg.bin.length} B  dat=${pkg.dat.length} B  [${pkg.source}]',
    );
    if (pkg.warn.isNotEmpty) {
      onLog('⚠ ${pkg.warn}');
    }

    // 1) Connect ONCE to target device to inspect whether it is already in DFU
    //    or in ABBM APP mode (read :GI/:GK/:VR and send :GB in the SAME session!).
    BluetoothDevice? readyBootDevice;
    List<BluetoothService>? readyBootServices;

    onStage('Connecting and inspecting device...');
    onLog('DFU: Inspecting ${item.name} (${item.id})...');

    try {
      await BleConnectionHelper.connectClean(item.device, timeout: const Duration(seconds: 15));
      final services = await BleConnectionHelper.discoverSafe(item.device);

      final cp = BleUuids.findChar(services, BleUuids.dfuSecureCp);
      final abbmTx = BleUuids.findChar(services, BleUuids.abbmTx);
      final btnless = BleUuids.findChar(services, BleUuids.dfuButtonless);
      final legacyCp = BleUuids.findChar(services, BleUuids.dfuLegacyCp);

      if (cp != null) {
        // Already in DFU bootloader — KEEP THIS CONNECTION OPEN!
        String gapName = item.name;
        final gapChar = BleUuids.findChar(services, BleUuids.gapDeviceName);
        if (gapChar != null) {
          try {
            final bytes = await gapChar.read();
            final n = ascii.decode(bytes, allowInvalid: true).replaceAll('\x00', '').trim();
            if (n.isNotEmpty) gapName = n;
          } catch (_) {}
        }
        onLog('DFU: Device is already in bootloader ($gapName), starting directly');
        if (gapName.isNotEmpty &&
            !gapName.toUpperCase().contains('NVISTI') &&
            !forceNonNvisti) {
          await BleConnectionHelper.disconnectClean(item.device);
          throw Exception(
            'Bootloader is $gapName (not NVISTI) — rejects BLE DFU init packets (0x05). '
            '73.12 requires factory SWD flashing. Stopped safely.',
          );
        }
        readyBootDevice = item.device;
        readyBootServices = services;
      } else if (abbmTx != null) {
        // In ABBM APP mode — do :GI, :GK, :VR, and :GB in ONE single connection!
        final uart = await _AbbmUartSession.open(item.device, services);
        try {
          onStage('Reading identity & firmware version...');
          try {
            final gi = await uart.send(':GI');
            await Future.delayed(const Duration(milliseconds: 120));
            final gk = await uart.send(':GK');
            origIdent = _parseIdent(gi, gk);
            onLog('Pre-DFU identity: ${origIdent.gi}  ${origIdent.gk}');
            onLog('Policy: Keep original firmware BLE name after DFU (no :RV rename).');
          } catch (e) {
            onLog('⚠ Failed to read identity (DFU can still proceed): $e');
          }

          if (!forceNonNvisti) {
            await Future.delayed(const Duration(milliseconds: 120));
            String ver = '';
            String vraw = '';
            for (int i = 0; i < 3; i++) {
              vraw = await uart.send(':VR');
              if (vraw.toUpperCase().startsWith(':VR,')) {
                ver = vraw.substring(4).split(',').first.trim();
                break;
              }
              await Future.delayed(const Duration(milliseconds: 250));
            }
            onLog('Module version: ${vraw.isNotEmpty ? vraw : "(no reply)"}');
            if (ver.isNotEmpty) {
              final (maj, min) = _verTuple(ver);
              if (maj < 73 || (maj == 73 && min < 20)) {
                throw Exception(
                  'Module is generation $ver (bootloader AB-FIRE8000-DFU), which rejects BLE DFU (0x05). '
                  'Enable "Override 73.20 gate" only for experimental attempts.',
                );
              }
            }
          }

          onStage('Switching ABBM into Nordic DFU bootloader...');
          onLog('DFU: Found ABBM UART (FFF1/FFF2), writing :GB to enter Nordic bootloader...');
          await uart.writeBootloaderCmd(onLog);
        } finally {
          await uart.close();
          await BleConnectionHelper.disconnectClean(
            item.device,
            settle: const Duration(milliseconds: 1200),
          );
        }
      } else if (btnless != null) {
        onStage('Triggering Buttonless DFU...');
        onLog('DFU: Sending 0x01 to Buttonless DFU (8EC90003)...');
        try {
          await btnless.setNotifyValue(true);
        } catch (_) {}
        try {
          await btnless.write([0x01], withoutResponse: false);
        } catch (e) {
          onLog('  Write returned error (module rebooting): $e');
        }
        await BleConnectionHelper.disconnectClean(
          item.device,
          settle: const Duration(milliseconds: 1200),
        );
      } else if (legacyCp != null) {
        await BleConnectionHelper.disconnectClean(item.device);
        throw Exception('Device uses Legacy DFU (0x1530); only Nordic Secure DFU is supported.');
      } else {
        await BleConnectionHelper.disconnectClean(item.device);
        throw Exception('Device has neither Secure DFU (8EC90001) nor ABBM UART (FFF1/FFF2).');
      }
    } catch (e) {
      if (e.toString().contains('not NVISTI') ||
          e.toString().contains('generation') ||
          e.toString().contains('Legacy') ||
          e.toString().contains('neither Secure DFU')) {
        rethrow;
      }
      await BleConnectionHelper.disconnectClean(item.device);
      // Maybe the device was already rebooting into NVISTI when user tapped Start
      onLog('DFU: Initial connect interrupted ($e); scanning for NVISTI bootloader...');
    }

    // 2) Run Secure DFU with up to 3 reconnect/resume attempts
    BluetoothDevice? bootDev = readyBootDevice;
    List<BluetoothService>? bootServices = readyBootServices;
    Object? lastErr;
    bool dfuDone = false;

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        if (bootDev == null) {
          onStage('Scanning for NVISTI DFU bootloader...');
          onLog('DFU: Waiting for bootloader advertisement (NVISTI / *DFU*)...');
          final found = await _scanForDfuBootloader(
            timeout: const Duration(seconds: 45),
            isCancelled: isCancelled,
          );
          if (found == null) {
            throw Exception(
              'Timed out (45 s) waiting for DFU bootloader. Verify power and ensure no other phone is connected.',
            );
          }
          onLog('DFU: Found bootloader ${found.name} (${found.id})');
          if (!found.name.toUpperCase().contains('NVISTI') && !forceNonNvisti) {
            throw Exception(
              'Bootloader is ${found.name} (not NVISTI) — rejects BLE DFU init packets (0x05). Stopped safely.',
            );
          }
          bootDev = found.device;
          // Give bootloader a brief moment to settle after scan stop
          await Future.delayed(const Duration(milliseconds: 500));
        }

        onStage('Running Nordic Secure DFU...');
        await _dfuSession(
          bootDev,
          pkg,
          existingServices: bootServices,
          onLog: onLog,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
        dfuDone = true;
        break;
      } catch (e) {
        lastErr = e;
        bootServices = null;
        if (bootDev != null) {
          await BleConnectionHelper.disconnectClean(bootDev);
        }
        final msg = e.toString();
        if (msg.contains('Cancelled') || msg.contains('not NVISTI') || msg.contains('Legacy')) {
          rethrow;
        }
        onLog('DFU: Session attempt $attempt interrupted ($e)');
        if (attempt < 3) {
          onLog('DFU: Retrying and resuming from bootloader offset in 2 s...');
          await Future.delayed(const Duration(seconds: 2));
          bootDev = null; // re-scan freshly so Android Bluetooth stack has fresh handle
        }
      }
    }

    if (!dfuDone) {
      throw lastErr ?? Exception('DFU failed');
    }

    // 3) Wait for device to reboot back into application mode
    onStage('Waiting for module to reboot...');
    onProgress(100, 'Waiting for application advertisement...');
    final back = await _waitAppBack(
      timeout: const Duration(seconds: 60),
      preferId: origId,
      isCancelled: isCancelled,
    );

    if (back != null) {
      onLog('DFU succeeded: device re-advertised as ${back.name} (${back.id}).');
      onLog('★ Original firmware BLE name preserved (${back.name}) — no rename performed.');

      // 4) Restore license ONLY if device had a valid license key before DFU (NO :RV rename!)
      if (origIdent?.key != null && origIdent!.key! >= 0) {
        onStage('Verifying / restoring license (:SK)...');
        await _restoreLicenseOnly(
          back.device,
          origIdent.key!,
          origId: origId,
          onLog: onLog,
          isCancelled: isCancelled,
        );
      }
    } else {
      onLog(
        '⚠ DFU transfer completed, but no APP advertisement seen within 60 s. '
        'Power-cycle the unit to verify.',
      );
    }

    final dt = sw.elapsedMilliseconds / 1000.0;
    onLog('ABBM firmware upgrade finished in ${dt.toStringAsFixed(1)} s.');
  }

  static Future<void> _dfuSession(
    BluetoothDevice dev,
    DfuPackage pkg, {
    List<BluetoothService>? existingServices,
    required LogFn onLog,
    required ProgressFn onProgress,
    required CancelCheck isCancelled,
  }) async {
    if (!dev.isConnected || existingServices == null) {
      await BleConnectionHelper.connectClean(dev, timeout: const Duration(seconds: 20));
    }

    final inbox = Queue<Uint8List>();
    StreamSubscription<List<int>>? sub;
    BluetoothCharacteristic? cp;

    try {
      final mtu = await BleConnectionHelper.negotiateMtu(dev, desired: 247);
      final services = existingServices ?? await BleConnectionHelper.discoverSafe(dev);

      cp = BleUuids.findChar(services, BleUuids.dfuSecureCp);
      final pkt = BleUuids.findChar(services, BleUuids.dfuSecurePkt);
      if (cp == null || pkt == null) {
        throw Exception('Nordic Secure DFU characteristics (8EC90001/8EC90002) not found');
      }

      await cp.setNotifyValue(true);
      sub = cp.onValueReceived.listen((data) {
        inbox.add(Uint8List.fromList(data));
      });
      await Future.delayed(const Duration(milliseconds: 150));

      Future<Uint8List> waitResp(
        int expectOp, {
        Duration timeout = const Duration(seconds: 8),
      }) async {
        final deadline = DateTime.now().add(timeout);
        while (DateTime.now().isBefore(deadline)) {
          if (isCancelled()) throw Exception('Cancelled by user');
          if (inbox.isEmpty) {
            await Future.delayed(const Duration(milliseconds: 10));
            continue;
          }
          final r = inbox.removeFirst();
          if (r.length >= 3 && r[0] == 0x60) {
            if (r[1] != expectOp) {
              throw Exception(
                'DFU response opcode mismatch: expected 0x${expectOp.toRadixString(16)}, '
                'got ${r.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
              );
            }
            if (r[2] != 0x01) {
              throw Exception(
                'DFU rejected 0x${expectOp.toRadixString(16).toUpperCase().padLeft(2, '0')}, '
                'code 0x${r[2].toRadixString(16).toUpperCase().padLeft(2, '0')} '
                '(${_dfuCodes[r[2]] ?? "Unknown"})',
              );
            }
            return r;
          }
        }
        throw Exception(
          'DFU command 0x${expectOp.toRadixString(16).toUpperCase().padLeft(2, '0')} timed out',
        );
      }

      Future<Uint8List> ctrl(
        List<int> cmd, {
        Duration timeout = const Duration(seconds: 8),
      }) async {
        inbox.clear();
        await cp!.write(cmd, withoutResponse: false);
        return waitResp(cmd[0], timeout: timeout);
      }

      Future<(int maxSz, int off, int crc)> dfuSelect(int objType) async {
        final r = await ctrl([0x06, objType]);
        if (r.length >= 15) {
          final bd = ByteData.sublistView(r);
          return (
            bd.getUint32(3, Endian.little),
            bd.getUint32(7, Endian.little),
            bd.getUint32(11, Endian.little),
          );
        } else if (r.length >= 11) {
          final bd = ByteData.sublistView(r);
          return (bd.getUint32(3, Endian.little), bd.getUint32(7, Endian.little), 0);
        }
        return (4096, 0, 0);
      }

      Future<void> dfuCreate(int objType, int size) async {
        final buf = Uint8List(6);
        buf[0] = 0x01;
        buf[1] = objType;
        ByteData.sublistView(buf).setUint32(2, size, Endian.little);
        await ctrl(buf);
      }

      // Nordic Secure DFU 8EC90002 strictly declares WRITE_NO_RESPONSE (not WRITE)!
      final bool pktNoRsp = pkt.properties.writeWithoutResponse || !pkt.properties.write;
      final int step = (mtu - 3).clamp(20, 244);

      Future<void> dfuWrite(
        Uint8List data, {
        required int prn,
      }) async {
        int pos = 0;
        int pktsSincePrn = 0;
        while (pos < data.length) {
          if (isCancelled()) throw Exception('Cancelled by user');
          final n = (data.length - pos) < step ? (data.length - pos) : step;
          await pkt.write(
            Uint8List.sublistView(data, pos, pos + n),
            withoutResponse: pktNoRsp,
          );
          pos += n;
          pktsSincePrn++;

          if (pktNoRsp) {
            if (prn > 0 && pktsSincePrn >= prn) {
              // Hardware-synchronized Packet Receipt Notification (0x60 0x03 0x01 ...)
              await waitResp(0x03, timeout: const Duration(seconds: 6));
              pktsSincePrn = 0;
            } else {
              // Gentle inter-packet pacing so nRF52 flash buffer never overflows
              await Future.delayed(Duration(milliseconds: prn > 0 ? 12 : 40));
            }
          }
        }
        if (pktNoRsp) {
          await Future.delayed(const Duration(milliseconds: 35));
        }
      }

      Future<void> dfuCrc(int objType, int expect, String label) async {
        final r = await ctrl([0x03, objType]);
        if (r.length >= 11) {
          final devCrc = ByteData.sublistView(r).getUint32(7, Endian.little);
          if (devCrc != expect) {
            throw Exception('$label CRC mismatch: device ${Crc32.hex(devCrc)} / local ${Crc32.hex(expect)}');
          }
        }
      }

      Future<void> dfuExecute(int objType) async {
        await ctrl([0x04, objType]);
      }

      onLog(
        'DFU: Connected to ${dev.remoteId.str}, MTU=$mtu, pkt=${step}B '
        '(${pktNoRsp ? "writeWithoutResponse" : "writeWithResponse"})',
      );

      // Disable PRN for small init object (145 B)
      try {
        await ctrl([0x02, 0x00, 0x00]);
      } catch (_) {}

      // 1) Command object (init packet .dat)
      final (initMx, initOff, _) = await dfuSelect(0x01);
      onLog('DFU: Init object max=$initMx B, offset=$initOff');
      await dfuCreate(0x01, pkg.dat.length);
      await dfuWrite(pkg.dat, prn: 0);
      await dfuCrc(0x01, Crc32.compute(pkg.dat), 'Init');
      await dfuExecute(0x01);
      onLog('DFU: Init packet written & executed (CRC OK ✓)');

      // Enable PRN = 8 for reliable flow-controlled data transfer over writeWithoutResponse
      int activePrn = 0;
      if (pktNoRsp) {
        try {
          await ctrl([0x02, 0x08, 0x00]);
          activePrn = 8;
          onLog('DFU: PRN flow control enabled (every 8 packets)');
        } catch (e) {
          onLog('DFU: PRN not supported ($e), using paced transfer');
        }
      }

      // 2) Data objects in 4096-byte chunks with cumulative CRC32
      final total = pkg.bin.length;
      int pos = 0;
      int idx = 0;
      final txSw = Stopwatch()..start();

      while (pos < total) {
        if (isCancelled()) throw Exception('Cancelled by user');
        var (mx, off, _) = await dfuSelect(0x02);
        if (mx == 0 || mx > 4096) mx = 4096;
        if (off != pos) {
          onLog('DFU: Resuming at bootloader offset $off (was $pos)');
          pos = off;
          if (pos >= total) break;
        }
        final end = (pos + mx) < total ? (pos + mx) : total;
        final chunk = Uint8List.sublistView(pkg.bin, pos, end);
        await dfuCreate(0x02, chunk.length);
        await dfuWrite(chunk, prn: activePrn);
        // Cumulative CRC32 from byte 0 to end
        await dfuCrc(0x02, Crc32.compute(pkg.bin, 0, end), 'Block #${idx + 1}');
        await dfuExecute(0x02);

        pos = end;
        idx++;
        final pct = (pos * 100) ~/ total;
        final sec = txSw.elapsedMilliseconds / 1000.0;
        final kbps = sec > 0.1 ? (pos / 1024.0 / sec) : 0.0;
        onProgress(pct, '$pos / $total B  ·  Block #$idx  ·  ${kbps.toStringAsFixed(1)} KB/s');
        if (idx <= 3 || pct >= 100 || idx % 8 == 0) {
          onLog('DFU: Block #$idx (${chunk.length} B) done — $pos / $total B ($pct%)');
        }
      }

      onLog('DFU: All $idx blocks written, waiting for device verification & reboot...');
      await Future.delayed(const Duration(seconds: 2));
    } finally {
      await sub?.cancel();
      try {
        if (dev.isConnected) await cp?.setNotifyValue(false);
      } catch (_) {}
      await BleConnectionHelper.disconnectClean(dev);
    }
  }

  static Future<void> _restoreLicenseOnly(
    BluetoothDevice dev,
    int origKey, {
    required String origId,
    required LogFn onLog,
    required CancelCheck isCancelled,
  }) async {
    BluetoothDevice target = dev;
    AbbmIdentity? cur;
    for (int i = 0; i < 4; i++) {
      if (isCancelled()) return;
      try {
        final (ident, _, _) = await readAllInfo(target);
        cur = ident;
        break;
      } catch (e) {
        onLog('  :GK read attempt ${i + 1} failed ($e), waiting for device...');
        await Future.delayed(const Duration(seconds: 2));
        final found = await _waitAppBack(
          timeout: const Duration(seconds: 10),
          preferId: origId,
          isCancelled: isCancelled,
        );
        if (found != null) target = found.device;
      }
    }

    if (cur == null) {
      onLog('⚠ Could not read current license; skipped auto-restore (verify manually below).');
      return;
    }

    onLog('DFU: Current license ${cur.gk} / original key=$origKey');
    if (cur.key == origKey) {
      onLog('DFU: License intact ✓');
      return;
    }

    try {
      final r = await sendSerialCmd(target, ':SK,$origKey', timeout: const Duration(seconds: 2));
      onLog('DFU: Wrote license :SK,$origKey → $r (module rebooting)');
    } catch (e) {
      onLog('DFU: :SK sent, module rebooting (normal): $e');
    }

    for (int i = 0; i < 5; i++) {
      if (isCancelled()) return;
      await Future.delayed(const Duration(seconds: 4));
      try {
        final (chk, _, _) = await readAllInfo(target);
        if (chk.key == origKey) {
          onLog('DFU: License restored & verified (${chk.gk}) ✓');
          return;
        }
        onLog('  License still ${chk.gk}, waiting...');
      } catch (_) {
        final found = await _waitAppBack(
          timeout: const Duration(seconds: 8),
          preferId: origId,
          isCancelled: isCancelled,
        );
        if (found != null) target = found.device;
      }
    }
    onLog('⚠ License verify timed out; tap "Read Identity & Version" below to confirm.');
  }

  static Future<BleDeviceItem?> _scanForDfuBootloader({
    required Duration timeout,
    required CancelCheck isCancelled,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled()) throw Exception('Cancelled by user');
      final completer = Completer<BleDeviceItem?>();
      StreamSubscription<List<ScanResult>>? sub;
      sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final name = r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : r.device.platformName;
          final kind = BleUuids.classify(name, r.advertisementData.serviceUuids);
          if (kind == DeviceKind.dfu) {
            if (!completer.isCompleted) {
              completer.complete(
                BleDeviceItem(
                  device: r.device,
                  name: name.isNotEmpty ? name : 'DFU Bootloader',
                  id: r.device.remoteId.str,
                  rssi: r.rssi,
                  kind: kind,
                ),
              );
            }
            return;
          }
        }
      });

      try {
        await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
        final found = await completer.future
            .timeout(const Duration(seconds: 4), onTimeout: () => null);
        await FlutterBluePlus.stopScan();
        if (found != null) return found;
      } finally {
        await sub.cancel();
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
    return null;
  }

  static Future<BleDeviceItem?> _waitAppBack({
    required Duration timeout,
    required String preferId,
    required CancelCheck isCancelled,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled()) return null;
      final completer = Completer<BleDeviceItem?>();
      BleDeviceItem? fallback;
      StreamSubscription<List<ScanResult>>? sub;
      sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final name = r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : r.device.platformName;
          if (!BleUuids.isAbbmAppName(name)) continue;
          final item = BleDeviceItem(
            device: r.device,
            name: name,
            id: r.device.remoteId.str,
            rssi: r.rssi,
            kind: DeviceKind.app,
          );
          if (item.id.toUpperCase() == preferId.toUpperCase()) {
            if (!completer.isCompleted) completer.complete(item);
            return;
          }
          fallback ??= item;
        }
      });

      try {
        await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
        final found = await completer.future
            .timeout(const Duration(seconds: 4), onTimeout: () => null);
        await FlutterBluePlus.stopScan();
        if (found != null) return found;
        if (fallback != null) return fallback;
      } finally {
        await sub.cancel();
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
    return null;
  }
}
