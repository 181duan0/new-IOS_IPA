import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../ble/abbm_dfu_service.dart';
import '../ble/ble_models.dart';
import '../core/dfu_package.dart';
import '../theme/tactical_theme.dart';
import 'widgets/tactical_widgets.dart';

class AbbmDfuTab extends StatefulWidget {
  const AbbmDfuTab({super.key});

  @override
  State<AbbmDfuTab> createState() => _AbbmDfuTabState();
}

class _AbbmDfuTabState extends State<AbbmDfuTab> {
  final List<BleDeviceItem> _devices = [];
  BleDeviceItem? _selected;
  DfuPackage? _builtinPkg;
  DfuPackage? _activePkg;

  bool _scanning = false;
  bool _busy = false;
  bool _cancelled = false;
  bool _forceNonNvisti = false;

  String _stage = 'Ready';
  int _pct = 0;
  String _detail = '';
  final List<String> _logs = [];

  final _keyCtrl = TextEditingController();
  final _levelCtrl = TextEditingController(text: '2');
  final _rawCmdCtrl = TextEditingController(text: ':VR');

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _scanStateSub;

  @override
  void initState() {
    super.initState();
    _loadBuiltinDfu();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _scanStateSub?.cancel();
    _keyCtrl.dispose();
    _levelCtrl.dispose();
    _rawCmdCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBuiltinDfu() async {
    try {
      final bd = await rootBundle.load('assets/firmware/ABBM-BLE-FIRE4000-v73.20.zip');
      final raw = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
      final pkg = DfuPackage.fromZipBytes(
        raw,
        'ABBM-BLE-FIRE4000-v73.20.zip',
        source: 'Built-in 73.20',
      );
      if (mounted) {
        setState(() {
          _builtinPkg = pkg;
          _activePkg = pkg;
        });
      }
      _log('ABBM DFU ready: built-in ${pkg.name} (${pkg.bin.length} B, CRC32=${pkg.crcBinHex})');
      _log('★ No-Rename Mode enabled: preserves original firmware BLE name after DFU.');
    } catch (e) {
      _log('✗ Failed to load built-in ABBM package: $e');
    }
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
    _log('Scanning for ABBM / NVISTI devices (8 s)...');

    await _scanSub?.cancel();
    await _scanStateSub?.cancel();

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      final map = <String, BleDeviceItem>{};
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        final su = r.advertisementData.serviceUuids;
        final kind = BleUuids.classify(name, su);
        if (name.trim().isEmpty && kind != DeviceKind.dfu) continue;
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
          int rank(BleDeviceItem d) {
            if (d.kind == DeviceKind.dfu) return 0;
            if (BleUuids.isAbbmAppName(d.name)) return 1;
            return 2;
          }

          final ar = rank(a);
          final br = rank(b);
          if (ar != br) return ar.compareTo(br);
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

  Future<void> _pickLocalDfuPackage() async {
    try {
      final res = await FilePicker.platform.pickFiles(withData: true);
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      Uint8List? raw = f.bytes;
      if (raw == null && f.path != null) {
        raw = await File(f.path!).readAsBytes();
      }
      if (raw == null || raw.isEmpty) {
        _toast('Cannot read package file');
        return;
      }

      DfuPackage pkg;
      final lower = f.name.toLowerCase();
      if (lower.endsWith('.zip') || (raw.length >= 2 && raw[0] == 0x50 && raw[1] == 0x4B)) {
        pkg = DfuPackage.fromZipBytes(raw, f.name, source: 'Local Nordic ZIP');
      } else {
        if (_builtinPkg == null) {
          throw Exception('Built-in template package not loaded yet');
        }
        pkg = DfuPackage.fromHexOrBin(raw, f.name, _builtinPkg!);
      }

      setState(() => _activePkg = pkg);
      _log('ABBM package selected: ${pkg.name} (${pkg.source}, bin ${pkg.bin.length} B, CRC32 ${pkg.crcBinHex})');
      if (pkg.warn.isNotEmpty) _log('⚠ ${pkg.warn}');
    } catch (e) {
      _toast('Package parse error: $e');
      _log('✗ Package parse error: $e');
    }
  }

  Future<void> _startDfu() async {
    if (_selected == null) {
      _toast('Select an ABBM / NVISTI device first');
      return;
    }
    if (_activePkg == null) {
      _toast('No ABBM firmware package loaded');
      return;
    }

    await _stopScan();
    setState(() {
      _busy = true;
      _cancelled = false;
      _pct = 0;
      _stage = 'Preparing ABBM Secure DFU...';
      _detail = '';
    });

    try {
      await AbbmDfuService.runDfu(
        item: _selected!,
        pkg: _activePkg!,
        forceNonNvisti: _forceNonNvisti,
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
        setState(() => _stage = 'ABBM DFU Complete (Name Preserved) ✓');
        _toast('ABBM firmware upgrade complete!');
      }
    } catch (e) {
      _log('✗ ABBM DFU failed: $e');
      if (mounted) {
        setState(() => _stage = 'Failed: $e');
        _toast('Upgrade failed: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readIdentityAndVersion() async {
    if (_selected == null) {
      _toast('Select an ABBM device first');
      return;
    }
    await _stopScan();
    setState(() {
      _busy = true;
      _stage = 'Reading ABBM identity & version...';
    });
    try {
      final (ident, ver, vraw) = await AbbmDfuService.readAllInfo(_selected!.device);
      _log(':GI → ${ident.gi}');
      _log(':GK → ${ident.gk}');
      _log(':VR → $vraw');
      if (ver.isNotEmpty) {
        final parts = ver.split('.');
        final maj = int.tryParse(parts[0]) ?? 0;
        final min = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
        if (maj < 73 || (maj == 73 && min < 20)) {
          _log('⚠ Generation $ver (bootloader AB-FIRE8000-DFU): BLE DFU rejected; SWD required.');
        }
      }
      if (mounted) setState(() => _stage = 'Identity read complete');
    } catch (e) {
      _log('✗ Read failed: $e');
      if (mounted) setState(() => _stage = 'Read failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _writeLicense() async {
    if (_selected == null) {
      _toast('Select an ABBM device first');
      return;
    }
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) {
      _toast('Enter license key first');
      return;
    }
    final lvl = int.tryParse(_levelCtrl.text.trim());
    await _stopScan();
    setState(() {
      _busy = true;
      _stage = 'Writing ABBM license (:SK)...';
    });
    try {
      final (cmd, wr, chk) = await AbbmDfuService.writeLicense(_selected!.device, key, lvl);
      _log('$cmd → $wr');
      _log(':GK verify → $chk');
      if (mounted) setState(() => _stage = 'License write complete');
    } catch (e) {
      _log('✗ License write failed: $e');
      if (mounted) setState(() => _stage = 'Write failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendRawCmd() async {
    if (_selected == null) {
      _toast('Select an ABBM device first');
      return;
    }
    final cmd = _rawCmdCtrl.text.trim();
    if (cmd.isEmpty) return;
    await _stopScan();
    setState(() {
      _busy = true;
      _stage = 'Sending $cmd ...';
    });
    try {
      final resp = await AbbmDfuService.sendSerialCmd(_selected!.device, cmd);
      _log('$cmd → ${resp.isNotEmpty ? resp : "(no reply)"}');
      if (mounted) setState(() => _stage = 'Command sent');
    } catch (e) {
      _log('✗ Command failed: $e');
      if (mounted) setState(() => _stage = 'Command failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pkg = _activePkg;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
      children: [
        DeviceScannerCard(
          step: '01',
          title: 'Select ABBM Module (nRF52)',
          scanning: _scanning,
          busy: _busy,
          devices: _devices,
          selected: _selected,
          onToggleScan: _toggleScan,
          onSelect: (d) {
            setState(() => _selected = d);
            _log('Selected ABBM device: ${d.name} (${d.id})');
          },
        ),
        const SizedBox(height: 12),
        TacticalCard(
          step: '02',
          title: 'ABBM Firmware Package (.zip / .hex / .bin)',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: _busy || _builtinPkg == null
                    ? null
                    : () {
                        setState(() => _activePkg = _builtinPkg);
                        _log('Restored built-in 73.20 DFU package');
                      },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  minimumSize: Size.zero,
                ),
                child: const Text('Built-in', style: TextStyle(fontSize: 11.5)),
              ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickLocalDfuPackage,
                icon: const Icon(Icons.folder_open_rounded, size: 14),
                label: const Text('Local', style: TextStyle(fontSize: 11.5)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  minimumSize: Size.zero,
                ),
              ),
            ],
          ),
          child: pkg == null
              ? const Text('Loading built-in package...', style: TextStyle(color: TacticalColors.textSecondary))
              : Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: TacticalColors.bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: TacticalColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      KvRow('Package', pkg.name),
                      KvRow('Source', pkg.source),
                      KvRow('Size', 'bin ${pkg.bin.length} B  ·  dat ${pkg.dat.length} B'),
                      KvRow('CRC32', 'bin ${pkg.crcBinHex}  ·  dat ${pkg.crcDatHex}'),
                      KvRow('SHA-256', '${pkg.shaBinHex.substring(0, 16)}...'),
                      if (pkg.warn.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          '⚠ ${pkg.warn}',
                          style: const TextStyle(color: TacticalColors.amber, fontSize: 11.5),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 12),
        TacticalCard(
          step: '03',
          title: 'Run ABBM Nordic Secure DFU',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: TacticalColors.emerald.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: TacticalColors.emerald.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.verified_outlined, color: TacticalColors.emerald, size: 17),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'No-Rename Mode active: original firmware BLE name is preserved after DFU (no :RV rename; license restored if present).',
                        style: TextStyle(color: TacticalColors.emerald, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  'Override 73.20 generation gate (experimental)',
                  style: TextStyle(color: TacticalColors.textSecondary, fontSize: 12.5),
                ),
                subtitle: const Text(
                  'Default OFF protects 73.12 / non-NVISTI bootloaders from 0x05 lockouts',
                  style: TextStyle(color: TacticalColors.textMuted, fontSize: 11),
                ),
                value: _forceNonNvisti,
                onChanged: _busy ? null : (v) => setState(() => _forceNonNvisti = v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _startDfu,
                      icon: const Icon(Icons.bluetooth_drive_rounded, size: 18),
                      label: Text(_busy ? 'Upgrading ABBM...' : 'Start ABBM DFU Upgrade'),
                    ),
                  ),
                  if (_busy) ...[
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () {
                        _cancelled = true;
                        _log('Cancelling DFU...');
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
          title: 'ABBM Identity / License / UART (FFF1/FFF2)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _readIdentityAndVersion,
                  icon: const Icon(Icons.badge_outlined, size: 16),
                  label: const Text('Read Identity, License & Version (:GI / :GK / :VR)'),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _keyCtrl,
                      style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
                      decoration: const InputDecoration(hintText: 'License Key'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    flex: 1,
                    child: TextField(
                      controller: _levelCtrl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
                      decoration: const InputDecoration(hintText: 'Lvl'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton(
                    onPressed: _busy ? null : _writeLicense,
                    child: const Text('Write :SK'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _rawCmdCtrl,
                      style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
                      decoration: const InputDecoration(hintText: 'Custom : command, e.g. :VR / :GI'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton(
                    onPressed: _busy ? null : _sendRawCmd,
                    child: const Text('Send'),
                  ),
                ],
              ),
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
