import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../ble/ble_models.dart';
import '../ble/host_ota_service.dart';
import '../core/host_firmware.dart';
import '../core/iap_repair.dart';
import '../theme/tactical_theme.dart';
import 'widgets/tactical_widgets.dart';

class HostOtaTab extends StatefulWidget {
  const HostOtaTab({super.key});

  @override
  State<HostOtaTab> createState() => _HostOtaTabState();
}

class _HostOtaTabState extends State<HostOtaTab> {
  final List<BleDeviceItem> _devices = [];
  BleDeviceItem? _selected;
  HostFirmware? _firmware;
  bool _scanning = false;
  bool _busy = false;
  bool _cancelled = false;
  bool _verifyEveryPacket = false;

  String _stage = 'Ready';
  int _pct = 0;
  String _detail = '';
  final List<String> _logs = [];

  // IAP Repair state
  String _iapResultText = '';
  bool _iapHasWarning = false;
  File? _repairedFile;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _scanStateSub;

  @override
  void initState() {
    super.initState();
    _log('Host OTA ready: connects even in normal APP mode and automatically triggers 0xFFE3 into OTA.');
    _log('If the device never enters OTA, it carries the old 2024 IAP — use Full-Chip IAP Repair below.');
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _scanStateSub?.cancel();
    super.dispose();
  }

  void _log(String msg) {
    final now = DateTime.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    if (!mounted) return;
    setState(() {
      _logs.add('$ts  $msg');
      if (_logs.length > 400) _logs.removeRange(0, 100);
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _toggleScan() async {
    if (_scanning) {
      await _stopScan();
      return;
    }
    final ok = await BlePermissions.ensure();
    if (!ok) {
      _toast('Bluetooth permission denied — cannot scan');
      return;
    }
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      _toast('Please turn on Bluetooth first');
      return;
    }

    setState(() {
      _devices.clear();
      _scanning = true;
    });
    _log('Scanning for Host BLE devices (8 s)...');

    await _scanSub?.cancel();
    await _scanStateSub?.cancel();

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      final map = <String, BleDeviceItem>{};
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        final su = r.advertisementData.serviceUuids;
        final hasRelevantSvc = su.any(
          (u) => BleUuids.matches(u, BleUuids.svcOta) || BleUuids.matches(u, BleUuids.svcApp),
        );
        if (name.trim().isEmpty && !hasRelevantSvc) continue;
        final kind = BleUuids.classify(name, su);
        map[r.device.remoteId.str] = BleDeviceItem(
          device: r.device,
          name: name.trim().isNotEmpty ? name.trim() : '(Unnamed Device)',
          id: r.device.remoteId.str,
          rssi: r.rssi,
          kind: kind,
        );
      }
      final list = map.values.toList()
        ..sort((a, b) {
          final ak = a.kind == DeviceKind.ota ? 0 : 1;
          final bk = b.kind == DeviceKind.ota ? 0 : 1;
          if (ak != bk) return ak.compareTo(bk);
          return b.rssi.compareTo(a.rssi);
        });
      if (mounted) {
        setState(() {
          _devices
            ..clear()
            ..addAll(list);
        });
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      // Wait for the scan to actually finish (or be stopped manually)
      bool sawScanning = false;
      _scanStateSub = FlutterBluePlus.isScanning.listen((isOn) {
        if (isOn) {
          sawScanning = true;
        } else if (sawScanning && _scanning && mounted) {
          setState(() => _scanning = false);
          _log('Scan finished — ${_devices.length} device(s) found');
        }
      });
    } catch (e) {
      _log('Scan failed: $e');
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (mounted && _scanning) {
      setState(() => _scanning = false);
      _log('Scan stopped — ${_devices.length} device(s) found');
    }
  }

  Future<void> _pickLocalFirmware() async {
    try {
      final res = await FilePicker.platform.pickFiles(withData: true);
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      Uint8List? bytes = f.bytes;
      if (bytes == null && f.path != null) {
        bytes = await File(f.path!).readAsBytes();
      }
      if (bytes == null || bytes.isEmpty) {
        _toast('Cannot read firmware file');
        return;
      }
      final fw = HostFirmware.fromBytes(bytes, f.name);
      setState(() => _firmware = fw);
      _log('Loaded local firmware: ${fw.name} (${fw.source}, ${fw.size} B, CRC32=${fw.crc32Hex})');
      if (fw.iapNote.isNotEmpty) _log(fw.iapNote);
    } catch (e) {
      _toast('Firmware parse error: $e');
      _log('✗ Firmware parse error: $e');
    }
  }

  Future<void> _loadPreset(String assetPath, String title) async {
    try {
      final bd = await rootBundle.load(assetPath);
      final bytes = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
      final fw = HostFirmware.fromBytes(bytes, title);
      setState(() => _firmware = fw);
      _log('Loaded built-in firmware: ${fw.name} (${fw.size} B, CRC32=${fw.crc32Hex})');
      if (fw.iapNote.isNotEmpty) _log(fw.iapNote);
    } catch (e) {
      _toast('Failed to load built-in firmware: $e');
    }
  }

  Future<void> _startUpgrade() async {
    if (_selected == null) {
      _toast('Select a device first');
      return;
    }
    if (_firmware == null) {
      _toast('Select a firmware file first');
      return;
    }
    if (!_firmware!.isInAppRegion) {
      _toast('Firmware address is outside APP region (0x1000~0x3C000)');
      return;
    }

    await _stopScan();
    setState(() {
      _busy = true;
      _cancelled = false;
      _pct = 0;
      _stage = 'Preparing Host OTA...';
      _detail = '';
    });

    try {
      await HostOtaService.upgrade(
        device: _selected!.device,
        fw: _firmware!,
        verifyEveryPacket: _verifyEveryPacket,
        onLog: _log,
        onStage: (s) {
          if (mounted) setState(() => _stage = s);
        },
        onProgress: (p, d) {
          if (mounted) {
            setState(() {
              _pct = p;
              _detail = d;
            });
          }
        },
        isCancelled: () => _cancelled,
      );
      if (mounted) {
        setState(() => _stage = 'Host OTA Complete ✓');
        _toast('Upgrade complete! Device will boot the new firmware');
      }
    } catch (e) {
      _log('✗ Upgrade failed: $e');
      if (mounted) {
        setState(() => _stage = 'Failed: $e');
        _toast('Upgrade failed: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndRepairIap() async {
    try {
      final res = await FilePicker.platform.pickFiles(withData: true);
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      Uint8List? raw = f.bytes;
      if (raw == null && f.path != null) {
        raw = await File(f.path!).readAsBytes();
      }
      if (raw == null || raw.isEmpty) {
        _toast('Cannot read this file');
        return;
      }

      final info = IapRepair.inspect(raw);
      _log('IAP check: ${info.iapState}; entry ${info.entry}; APP ${info.appBytes} B CRC32=${info.appCrcHex}');

      if (!info.fullChip) {
        setState(() {
          _iapHasWarning = false;
          _repairedFile = null;
          _iapResultText =
              'APP-only image (no IAP)\nAPP region: ${info.appBytes} B  CRC32=${info.appCrcHex}\n'
              'No IAP swap needed — ready for BLE OTA directly.';
        });
        return;
      }

      final iapBd = await rootBundle.load('assets/firmware/iap_new.bin');
      final iapBin = iapBd.buffer.asUint8List(iapBd.offsetInBytes, iapBd.lengthInBytes);
      final repairedBytes = IapRepair.repair(raw, iapBin);

      final dir = await getApplicationDocumentsDirectory();
      final baseName = f.name.replaceAll(RegExp(r'\.(bin|BIN)$'), '');
      final outName = '${baseName}_newIAP.bin';
      final outFile = File('${dir.path}/$outName');
      await outFile.writeAsBytes(repairedBytes, flush: true);

      setState(() {
        _iapHasWarning = info.oldIap;
        _repairedFile = outFile;
        _iapResultText =
            'Full-chip image ✓\nOriginal IAP: ${info.iapState}\nIAP entry: ${info.entry}\n'
            'APP region: ${info.appBytes} B  CRC32=${info.appCrcHex}\n\n'
            'Repaired image created: $outName\n'
            'Tap "Share Repaired" to send it to a PC and flash via USB once.';
      });
      _log('Repaired image exported: $outName');
      _toast('Repaired image ready — tap Share to send to PC');
    } catch (e) {
      _log('✗ Repair failed: $e');
      _toast('Repair failed: $e');
    }
  }

  Future<void> _shareRepaired() async {
    final f = _repairedFile;
    if (f == null || !await f.exists()) return;
    await Share.shareXFiles([XFile(f.path)], subject: 'Repaired Full-Chip Firmware');
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
      children: [
        DeviceScannerCard(
          step: '01',
          title: 'Connect Host Device (CH582 / FIRE4000)',
          scanning: _scanning,
          busy: _busy,
          devices: _devices,
          selected: _selected,
          onToggleScan: _toggleScan,
          onSelect: (d) {
            setState(() => _selected = d);
            _log('Selected host device: ${d.name} (${d.id})');
          },
        ),
        const SizedBox(height: 12),
        TacticalCard(
          step: '02',
          title: 'Select Host Firmware (.bin / .hex)',
          trailing: OutlinedButton.icon(
            onPressed: _busy ? null : _pickLocalFirmware,
            icon: const Icon(Icons.folder_open_rounded, size: 15),
            label: const Text('Local File', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _loadPreset(
                                'assets/firmware/FIRE4000-V0.3.6.5-AB73.12.bin',
                                'FIRE4000 V0.3.6.5 (AB73.12)',
                              ),
                      child: const Text('Preset V0.3.6.5', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _loadPreset(
                                'assets/firmware/FIRE4000-Original-AB31.bin',
                                'FIRE4000 Original (AB31)',
                              ),
                      child: const Text('Preset AB31', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_firmware == null)
                const Text(
                  'No firmware selected. Import a local .bin / .hex file or choose a built-in preset.',
                  style: TextStyle(color: TacticalColors.textSecondary, fontSize: 12.5),
                )
              else
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: TacticalColors.bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _firmware!.isInAppRegion
                          ? TacticalColors.border
                          : TacticalColors.crimson,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      KvRow('File', _firmware!.name),
                      KvRow('Type', _firmware!.source),
                      KvRow(
                        'Range',
                        '0x${_firmware!.base.toRadixString(16).toUpperCase()} ~ '
                            '0x${_firmware!.end.toRadixString(16).toUpperCase()}  (${_firmware!.size} B)',
                      ),
                      KvRow('CRC32', '${_firmware!.crc32Hex}   Entry ${_firmware!.entry}'),
                      if (_firmware!.iapNote.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          _firmware!.iapNote,
                          style: TextStyle(
                            color: _firmware!.iapWarning
                                ? TacticalColors.amber
                                : TacticalColors.emerald,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TacticalCard(
          step: '03',
          title: 'Start Host OTA Upgrade',
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  'Verify every packet (slower, ultra-safe)',
                  style: TextStyle(color: TacticalColors.textPrimary, fontSize: 13),
                ),
                subtitle: const Text(
                  'Default OFF uses fast write-without-response + verify every 32 packets',
                  style: TextStyle(color: TacticalColors.textMuted, fontSize: 11.5),
                ),
                value: _verifyEveryPacket,
                onChanged: _busy ? null : (v) => setState(() => _verifyEveryPacket = v),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _startUpgrade,
                      icon: const Icon(Icons.system_update_alt_rounded, size: 18),
                      label: Text(_busy ? 'Upgrading Host...' : 'Start Host OTA Upgrade'),
                    ),
                  ),
                  if (_busy) ...[
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () {
                        _cancelled = true;
                        _log('Cancelling upgrade...');
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: TacticalColors.crimson,
                        side: const BorderSide(color: TacticalColors.crimson),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TacticalCard(
          step: '04',
          title: 'Full-Chip IAP Repair Tool',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Inspect a full-chip .bin for old 2024 IAP, replace 0x3C000~0x40000 with the bundled new IAP, and export *_newIAP.bin for USB flashing.',
                style: TextStyle(color: TacticalColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _pickAndRepairIap,
                      icon: const Icon(Icons.build_circle_outlined, size: 16),
                      label: const Text('① Repair Full-Chip BIN'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _repairedFile == null ? null : _shareRepaired,
                      icon: const Icon(Icons.share_rounded, size: 16),
                      label: const Text('② Share Repaired'),
                    ),
                  ),
                ],
              ),
              if (_iapResultText.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: TacticalColors.bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _iapHasWarning ? TacticalColors.amber : TacticalColors.emerald,
                    ),
                  ),
                  child: Text(
                    _iapResultText,
                    style: const TextStyle(
                      color: TacticalColors.textPrimary,
                      fontSize: 12,
                      height: 1.45,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        ProgressConsoleCard(
          stage: _stage,
          pct: _pct,
          detail: _detail,
          logs: _logs,
          onClearLogs: () => setState(() => _logs.clear()),
        ),
      ],
    );
  }
}
