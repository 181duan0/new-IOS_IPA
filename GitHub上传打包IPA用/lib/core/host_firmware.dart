import 'dart:typed_data';
import 'crc32.dart';

/// Host Firmware (CH582 / FIRE4000) parser & validator.
class HostFirmware {
  static const int appStart = 0x1000;
  static const int appLimit = 0x3C000;
  static const List<int> jumpIapSig = [0x6F, 0xC0, 0x03, 0x00];
  static const List<int> newIapEntry = [0x6F, 0x00, 0x40, 0x7B];
  static const List<int> oldIapEntry = [0x6F, 0x00, 0xC0, 0x76];

  final String name;
  final int base;
  final Uint8List data;
  final String source;
  final String iapNote;
  final bool iapWarning;

  HostFirmware({
    required this.name,
    required this.base,
    required this.data,
    required this.source,
    this.iapNote = '',
    this.iapWarning = false,
  });

  int get end => base + data.length;
  int get size => data.length;
  int get crc32 => Crc32.compute(data);
  String get crc32Hex => Crc32.hex(crc32);

  String get entry {
    if (data.length < 4) return '--';
    return data
        .sublist(0, 4)
        .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
        .join(' ');
  }

  int get imageFlag => data.length >= 8
      ? (data[4] & 0xFF) |
          ((data[5] & 0xFF) << 8) |
          ((data[6] & 0xFF) << 16) |
          ((data[7] & 0xFF) << 24)
      : 0;

  bool get isInAppRegion => base >= appStart && end <= appLimit && data.isNotEmpty;

  static Uint8List _trimTailFF(Uint8List b) {
    int n = b.length;
    while (n > 1 && b[n - 1] == 0xFF) {
      n--;
    }
    return Uint8List.sublistView(b, 0, n);
  }

  static bool isFullChipImage(Uint8List raw) {
    if (raw.length >= 4 &&
        raw[0] == jumpIapSig[0] &&
        raw[1] == jumpIapSig[1] &&
        raw[2] == jumpIapSig[2] &&
        raw[3] == jumpIapSig[3]) {
      return true;
    }
    if (raw.length >= appLimit) return true;
    if (raw.length < appStart + 4) return false;
    for (int i = 0; i < appStart; i++) {
      final v = raw[i];
      if (v != 0x00 && v != 0xFF) return false;
    }
    final e = raw[appStart];
    return e == 0x6F || e == 0x2F || e == 0xEF;
  }

  static bool looksLikeHex(Uint8List raw) {
    if (raw.isEmpty) return false;
    if (raw[0] == 0x3A) return true;
    final checkLen = raw.length < 400 ? raw.length : 400;
    bool hasColon = false;
    bool hasNewline = false;
    for (int i = 0; i < checkLen; i++) {
      if (i < 8 && raw[i] == 0x3A) hasColon = true;
      if (raw[i] == 0x0A) hasNewline = true;
    }
    return hasColon && hasNewline;
  }

  static (String note, bool warn) _checkIap(Uint8List fullChip) {
    if (fullChip.length < appLimit + 4) {
      return ('Image has no IAP region (short full-chip)', false);
    }
    final e = fullChip.sublist(appLimit, appLimit + 4);
    final hex = e.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');
    if (e[0] == newIapEntry[0] &&
        e[1] == newIapEntry[1] &&
        e[2] == newIapEntry[2] &&
        e[3] == newIapEntry[3]) {
      return ('Full-chip image carries the new IAP ($hex, matching ✓)', false);
    }
    if (e[0] == oldIapEntry[0] &&
        e[1] == oldIapEntry[1] &&
        e[2] == oldIapEntry[2] &&
        e[3] == oldIapEntry[3]) {
      return (
        '⚠ Full-chip image carries the old 2024 IAP ($hex) — OTA never writes this region, '
            'but flashing it over USB reverts the device to "cannot enter OTA"; repair it below first',
        true,
      );
    }
    return ('Full-chip image IAP entry $hex (unknown version)', false);
  }

  static HostFirmware fromBytes(Uint8List raw, String name) {
    if (raw.isEmpty) {
      throw const FormatException('Firmware file is empty');
    }
    if (looksLikeHex(raw)) {
      return _parseHex(raw, name);
    }
    return _fromBin(raw, name);
  }

  static HostFirmware _fromBin(Uint8List raw, String name) {
    if (isFullChipImage(raw)) {
      final end = raw.length < appLimit ? raw.length : appLimit;
      if (end <= appStart) {
        throw const FormatException('This full-chip BIN has no APP region');
      }
      final img = _trimTailFF(Uint8List.sublistView(raw, appStart, end));
      if (img.isEmpty) {
        throw const FormatException('APP region (0x1000~0x3C000) is empty');
      }
      final (note, warn) = _checkIap(raw);
      return HostFirmware(
        name: name,
        base: appStart,
        data: img,
        source: 'BIN (full-chip -> APP region)',
        iapNote: note,
        iapWarning: warn,
      );
    }
    final img = _trimTailFF(raw);
    return HostFirmware(
      name: name,
      base: appStart,
      data: img,
      source: 'BIN',
    );
  }

  static HostFirmware _parseHex(Uint8List raw, String name) {
    int baseAddr = 0;
    final pieces = <(int addr, Uint8List bytes)>[];
    int minA = 0x7FFFFFFF;
    int maxA = 0;

    final line = <int>[];
    void flush() {
      if (line.isEmpty) return;
      int s = 0;
      while (s < line.length && line[s] != 0x3A) {
        final b = line[s];
        if (b == 0x20 || b == 0x09 || b == 0xEF || b == 0xBB || b == 0xBF) {
          s++;
          continue;
        }
        return;
      }
      if (s >= line.length) return;
      final rec = <int>[];
      int k = s + 1;
      while (k + 1 < line.length) {
        final hi = _hexVal(line[k]);
        final lo = _hexVal(line[k + 1]);
        if (hi < 0 || lo < 0) return;
        rec.add((hi << 4) | lo);
        k += 2;
      }
      if (rec.length < 5) return;
      final ln = rec[0];
      final addr = (rec[1] << 8) | rec[2];
      final typ = rec[3];
      if (typ == 0x01) return;
      if (typ == 0x02 && rec.length >= 6) {
        baseAddr = ((rec[4] << 8) | rec[5]) << 4;
        return;
      }
      if (typ == 0x04 && rec.length >= 6) {
        baseAddr = ((rec[4] << 8) | rec[5]) << 16;
        return;
      }
      if (typ != 0x00 || ln == 0 || 4 + ln > rec.length) return;
      final a = baseAddr + addr;
      final d = Uint8List.fromList(rec.sublist(4, 4 + ln));
      pieces.add((a, d));
      if (a < minA) minA = a;
      if (a + ln > maxA) maxA = a + ln;
    }

    for (int i = 0; i <= raw.length; i++) {
      final c = i == raw.length ? 0x0A : raw[i];
      if (c == 0x0A || c == 0x0D) {
        flush();
        line.clear();
      } else {
        line.add(c);
      }
    }

    if (pieces.isEmpty) {
      throw const FormatException('No valid address record in the HEX file');
    }

    final img = Uint8List(maxA - minA)..fillRange(0, maxA - minA, 0xFF);
    for (final (a, d) in pieces) {
      img.setRange(a - minA, a - minA + d.length, d);
    }

    int lo = minA;
    int hi = maxA;
    String src = 'HEX';
    if (lo < appStart || hi > appLimit) {
      lo = lo < appStart ? appStart : lo;
      hi = hi > appLimit ? appLimit : hi;
      src = 'HEX (APP region only)';
      if (hi <= lo) {
        throw FormatException(
          'HEX 0x${minA.toRadixString(16).toUpperCase()}~0x${maxA.toRadixString(16).toUpperCase()} '
          'has no data inside the APP region (0x1000~0x3C000)',
        );
      }
    }

    final sl = _trimTailFF(Uint8List.sublistView(img, lo - minA, hi - minA));
    if (sl.isEmpty) {
      throw const FormatException('APP region is empty after slicing');
    }
    return HostFirmware(name: name, base: lo, data: sl, source: src);
  }

  static int _hexVal(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return -1;
  }
}
