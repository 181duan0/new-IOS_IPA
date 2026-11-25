import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart' hide Crc32;
import 'package:crypto/crypto.dart';
import 'crc32.dart';

/// ABBM BLE Nordic Secure DFU package (.zip or .hex/.bin patched with template .dat).
class DfuPackage {
  static const int dfuAppBase = 0x26000;

  final Uint8List bin;
  final Uint8List dat;
  final String name;
  final String source;
  final String warn;

  DfuPackage({
    required this.bin,
    required this.dat,
    required this.name,
    this.source = 'Built-in',
    this.warn = '',
  });

  int get crcBin => Crc32.compute(bin);
  int get crcDat => Crc32.compute(dat);
  String get crcBinHex => Crc32.hex(crcBin);
  String get crcDatHex => Crc32.hex(crcDat);
  String get shaBinHex => sha256.convert(bin).toString().toUpperCase();

  static DfuPackage fromZipBytes(Uint8List raw, String name, {String source = 'Nordic ZIP'}) {
    final archive = ZipDecoder().decodeBytes(raw);
    ArchiveFile? manifestFile;
    for (final f in archive.files) {
      if (f.name == 'manifest.json' || f.name.endsWith('/manifest.json')) {
        manifestFile = f;
        break;
      }
    }
    if (manifestFile == null) {
      throw const FormatException('ZIP package is missing manifest.json');
    }
    final man = jsonDecode(utf8.decode(manifestFile.content as List<int>))
        as Map<String, dynamic>;
    final app = (man['manifest'] as Map<String, dynamic>)['application']
        as Map<String, dynamic>;
    final binName = app['bin_file'] as String;
    final datName = app['dat_file'] as String;

    Uint8List? binBytes;
    Uint8List? datBytes;
    for (final f in archive.files) {
      if (f.name == binName || f.name.endsWith('/$binName')) {
        binBytes = Uint8List.fromList(f.content as List<int>);
      } else if (f.name == datName || f.name.endsWith('/$datName')) {
        datBytes = Uint8List.fromList(f.content as List<int>);
      }
    }
    if (binBytes == null || datBytes == null) {
      throw FormatException('ZIP package is missing $binName or $datName');
    }
    return DfuPackage(bin: binBytes, dat: datBytes, name: name, source: source);
  }

  /// Build DFU package from a local .hex or .bin by patching [template]'s init packet (.dat)
  /// with the new image's app_size (uvarint) and reversed SHA-256.
  static DfuPackage fromHexOrBin(
    Uint8List raw,
    String fname,
    DfuPackage template,
  ) {
    final (base, img) = _pickAppImage(raw, fname);
    if (base != dfuAppBase) {
      throw FormatException(
        'Application region starts at 0x${base.toRadixString(16).toUpperCase()}, expected 0x26000',
      );
    }
    if (img.length < 1024) {
      throw FormatException('Image is too small (${img.length} B)');
    }
    final bd = ByteData.sublistView(img, 0, 4);
    final sp = bd.getUint32(0, Endian.little);
    if (sp < 0x20000000 || sp > 0x20040000) {
      throw FormatException(
        'Not a valid nRF52 application image (initial SP=0x${sp.toRadixString(16).toUpperCase().padLeft(8, '0')})',
      );
    }
    final patchedDat = _patchDat(template, img);
    return DfuPackage(
      bin: img,
      dat: patchedDat,
      name: fname,
      source: 'HEX/BIN (recomputed size + SHA-256)',
      warn: 'Init signature reused from built-in template (NVISTI validates CRC/hash)',
    );
  }

  static (int base, Uint8List data) _pickAppImage(Uint8List raw, String fname) {
    int base;
    Uint8List data;
    if (fname.toLowerCase().endsWith('.hex') || (raw.isNotEmpty && raw[0] == 0x3A)) {
      final segs = _parseHexSegments(raw);
      if (segs.isEmpty) {
        throw const FormatException('No data records found in HEX file');
      }
      segs.sort((a, b) => a.$1.compareTo(b.$1));
      final merged = <(int, List<int>)>[];
      for (final (a, d) in segs) {
        if (merged.isNotEmpty && a == merged.last.$1 + merged.last.$2.length) {
          merged.last.$2.addAll(d);
        } else {
          merged.add((a, List<int>.from(d)));
        }
      }
      var cand = merged.where((m) => m.$1 == dfuAppBase).toList();
      if (cand.isEmpty) {
        cand = merged.where((m) => m.$1 >= 0x1000).toList();
        if (cand.isEmpty) {
          throw const FormatException('No application region found in HEX (>= 0x1000)');
        }
        cand.sort((a, b) => b.$2.length.compareTo(a.$2.length));
      }
      base = cand.first.$1;
      data = Uint8List.fromList(cand.first.$2);
    } else {
      base = dfuAppBase;
      data = raw;
    }

    int n = data.length;
    while (n > 4 && data[n - 1] == 0xFF) {
      n--;
    }
    return (base, Uint8List.sublistView(data, 0, n));
  }

  static List<(int, Uint8List)> _parseHexSegments(Uint8List raw) {
    final segs = <(int, Uint8List)>[];
    int base = 0;
    final text = latin1.decode(raw, allowInvalid: true);
    for (var line in text.split(RegExp(r'\r?\n'))) {
      line = line.trim();
      if (!line.startsWith(':')) continue;
      final hex = line.substring(1);
      if (hex.length < 10 || hex.length.isOdd) continue;
      final rec = Uint8List(hex.length ~/ 2);
      bool ok = true;
      for (int i = 0; i < rec.length; i++) {
        final v = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
        if (v == null) {
          ok = false;
          break;
        }
        rec[i] = v;
      }
      if (!ok || rec.length < 5) continue;
      final ln = rec[0];
      final addr = (rec[1] << 8) | rec[2];
      final typ = rec[3];
      if (typ == 4 && rec.length >= 6) {
        base = ((rec[4] << 8) | rec[5]) << 16;
      } else if (typ == 2 && rec.length >= 6) {
        base = ((rec[4] << 8) | rec[5]) << 4;
      } else if (typ == 0 && 4 + ln <= rec.length) {
        segs.add((base + addr, Uint8List.sublistView(rec, 4, 4 + ln)));
      }
    }
    return segs;
  }

  static Uint8List _uvarint(int v) {
    final out = <int>[];
    while (true) {
      final b = v & 0x7F;
      v >>>= 7;
      if (v != 0) {
        out.add(b | 0x80);
      } else {
        out.add(b);
        return Uint8List.fromList(out);
      }
    }
  }

  static int _indexOfBytes(Uint8List haystack, Uint8List needle) {
    int count = 0;
    int found = -1;
    for (int i = 0; i <= haystack.length - needle.length; i++) {
      bool match = true;
      for (int j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        count++;
        found = i;
      }
    }
    return count == 1 ? found : -1;
  }

  static Uint8List _patchDat(DfuPackage template, Uint8List newBin) {
    final dat = Uint8List.fromList(template.dat);
    final oldSize = _uvarint(template.bin.length);
    final newSize = _uvarint(newBin.length);
    if (oldSize.length != newSize.length) {
      throw FormatException(
        'Image size varint length mismatch (${oldSize.length} -> ${newSize.length} bytes)',
      );
    }
    final i = _indexOfBytes(dat, oldSize);
    if (i < 0) {
      throw const FormatException('Could not locate unique app_size field in template init packet');
    }
    dat.setRange(i, i + newSize.length, newSize);

    final oldHash = Uint8List.fromList(sha256.convert(template.bin).bytes.reversed.toList());
    final j = _indexOfBytes(dat, oldHash);
    if (j < 0) {
      throw const FormatException('Could not locate unique SHA-256 field in template init packet');
    }
    final newHash = Uint8List.fromList(sha256.convert(newBin).bytes.reversed.toList());
    dat.setRange(j, j + 32, newHash);
    return dat;
  }
}
