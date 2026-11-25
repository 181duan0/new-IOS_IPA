import 'dart:typed_data';
import 'crc32.dart';
import 'host_firmware.dart';

class IapInspectInfo {
  final bool fullChip;
  final String iapState;
  final bool oldIap;
  final String entry;
  final int appCrc;
  final int appBytes;

  const IapInspectInfo({
    required this.fullChip,
    required this.iapState,
    required this.oldIap,
    required this.entry,
    required this.appCrc,
    required this.appBytes,
  });

  String get appCrcHex => Crc32.hex(appCrc);
}

class IapRepair {
  static const int iapOff = 0x3C000;
  static const int iapSize = 0x4000; // 16,384 bytes

  static bool isFullChip(Uint8List raw) {
    if (raw.length < iapOff + 4) return false;
    return raw[0] == HostFirmware.jumpIapSig[0] &&
        raw[1] == HostFirmware.jumpIapSig[1] &&
        raw[2] == HostFirmware.jumpIapSig[2] &&
        raw[3] == HostFirmware.jumpIapSig[3];
  }

  static IapInspectInfo inspect(Uint8List raw) {
    if (!isFullChip(raw)) {
      return IapInspectInfo(
        fullChip: false,
        iapState: 'Not a full-chip image (APP only, no IAP involved)',
        oldIap: false,
        entry: '--',
        appCrc: Crc32.compute(raw),
        appBytes: raw.length,
      );
    }

    final e = raw.sublist(iapOff, iapOff + 4);
    final entryStr =
        e.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');
    final appSlice = Uint8List.sublistView(raw, HostFirmware.appStart, iapOff);
    final appCrc = Crc32.compute(appSlice);

    final isNew = e[0] == HostFirmware.newIapEntry[0] &&
        e[1] == HostFirmware.newIapEntry[1] &&
        e[2] == HostFirmware.newIapEntry[2] &&
        e[3] == HostFirmware.newIapEntry[3];
    final isOld = e[0] == HostFirmware.oldIapEntry[0] &&
        e[1] == HostFirmware.oldIapEntry[1] &&
        e[2] == HostFirmware.oldIapEntry[2] &&
        e[3] == HostFirmware.oldIapEntry[3];

    if (isNew) {
      return IapInspectInfo(
        fullChip: true,
        iapState: 'New IAP (matches this APP ✓)',
        oldIap: false,
        entry: entryStr,
        appCrc: appCrc,
        appBytes: appSlice.length,
      );
    }
    if (isOld) {
      return IapInspectInfo(
        fullChip: true,
        iapState: 'Old 2024 IAP (blocks device from entering OTA ✗)',
        oldIap: true,
        entry: entryStr,
        appCrc: appCrc,
        appBytes: appSlice.length,
      );
    }
    return IapInspectInfo(
      fullChip: true,
      iapState: 'Unknown IAP (recommended to replace)',
      oldIap: false,
      entry: entryStr,
      appCrc: appCrc,
      appBytes: appSlice.length,
    );
  }

  /// Replaces 0x3C000..0x40000 in [raw] with [newIapBin] (assets/firmware/iap_new.bin).
  static Uint8List repair(Uint8List raw, Uint8List newIapBin) {
    if (!isFullChip(raw)) {
      throw const FormatException('Not a full-chip image (no JumpIAP at 0x0); no IAP swap needed');
    }
    if (raw.length < iapOff + iapSize) {
      throw const FormatException('Full-chip image is shorter than 0x40000 bytes');
    }
    if (newIapBin.length != iapSize) {
      throw FormatException('Bundled iap_new.bin has unexpected size (${newIapBin.length} B)');
    }
    final out = Uint8List.fromList(raw);
    out.setRange(iapOff, iapOff + iapSize, newIapBin);
    return out;
  }
}
