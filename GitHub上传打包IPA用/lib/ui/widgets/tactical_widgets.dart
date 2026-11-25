import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../ble/ble_models.dart';
import '../../theme/tactical_theme.dart';

class TacticalCard extends StatelessWidget {
  final String step;
  final String title;
  final Widget? trailing;
  final Widget child;

  const TacticalCard({
    super.key,
    required this.step,
    required this.title,
    this.trailing,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: TacticalColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TacticalColors.border),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: TacticalColors.crimsonGlow,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: TacticalColors.crimson.withValues(alpha: 0.5)),
                ),
                child: Text(
                  step,
                  style: const TextStyle(
                    color: TacticalColors.crimson,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: TacticalColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class KvRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const KvRow(this.label, this.value, {super.key, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: const TextStyle(color: TacticalColors.textMuted, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? TacticalColors.textPrimary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DeviceScannerCard extends StatelessWidget {
  final String step;
  final String title;
  final bool scanning;
  final bool busy;
  final List<BleDeviceItem> devices;
  final BleDeviceItem? selected;
  final VoidCallback onToggleScan;
  final ValueChanged<BleDeviceItem> onSelect;

  const DeviceScannerCard({
    super.key,
    required this.step,
    required this.title,
    required this.scanning,
    required this.busy,
    required this.devices,
    required this.selected,
    required this.onToggleScan,
    required this.onSelect,
  });

  Color _kindColor(DeviceKind k) => switch (k) {
        DeviceKind.ota => TacticalColors.emerald,
        DeviceKind.dfu => TacticalColors.amber,
        DeviceKind.app => TacticalColors.cyan,
      };

  @override
  Widget build(BuildContext context) {
    return TacticalCard(
      step: step,
      title: title,
      trailing: SizedBox(
        height: 32,
        child: OutlinedButton.icon(
          onPressed: busy ? null : onToggleScan,
          icon: scanning
              ? const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2, color: TacticalColors.crimson),
                )
              : const Icon(Icons.bluetooth_searching_rounded, size: 15),
          label: Text(scanning ? 'Stop Scan' : 'Scan', style: const TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            side: BorderSide(
              color: scanning ? TacticalColors.crimson : TacticalColors.border,
            ),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (selected != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: TacticalColors.crimsonGlow,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: TacticalColors.crimson.withValues(alpha: 0.6)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.bluetooth_connected_rounded, color: TacticalColors.crimson, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selected!.name,
                          style: const TextStyle(
                            color: TacticalColors.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          '${selected!.id}  ·  ${selected!.rssi} dBm',
                          style: const TextStyle(
                            color: TacticalColors.textSecondary,
                            fontSize: 11.5,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                  _Badge(label: selected!.kindLabel, color: _kindColor(selected!.kind)),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                scanning
                    ? 'Scanning nearby BLE devices (sorted by signal strength)...'
                    : 'No device selected. Tap "Scan" to search nearby BLE devices.',
                style: const TextStyle(color: TacticalColors.textSecondary, fontSize: 12.5),
              ),
            ),
          if (devices.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 205),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: devices.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, i) {
                  final d = devices[i];
                  final isSel = selected?.id == d.id;
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: busy ? null : () => onSelect(d),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSel ? TacticalColors.surfaceElevated : TacticalColors.bg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSel ? TacticalColors.crimson : TacticalColors.border,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  d.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: TacticalColors.textPrimary,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  d.id,
                                  style: const TextStyle(
                                    color: TacticalColors.textMuted,
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          _Badge(label: d.kindLabel, color: _kindColor(d.kind)),
                          const SizedBox(width: 8),
                          Text(
                            '${d.rssi} dBm',
                            style: const TextStyle(
                              color: TacticalColors.textSecondary,
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class ProgressConsoleCard extends StatelessWidget {
  final String stage;
  final int pct;
  final String detail;
  final List<String> logs;
  final VoidCallback onClearLogs;

  const ProgressConsoleCard({
    super.key,
    required this.stage,
    required this.pct,
    required this.detail,
    required this.logs,
    required this.onClearLogs,
  });

  @override
  Widget build(BuildContext context) {
    return TacticalCard(
      step: 'LOG',
      title: 'Progress & Console Log',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Copy Logs',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy_rounded, size: 16, color: TacticalColors.textSecondary),
            onPressed: logs.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: logs.join('\n')));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Logs copied to clipboard')),
                    );
                  },
          ),
          IconButton(
            tooltip: 'Clear Logs',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline_rounded, size: 16, color: TacticalColors.textSecondary),
            onPressed: logs.isEmpty ? null : onClearLogs,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  stage,
                  style: const TextStyle(
                    color: TacticalColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '$pct %',
                style: const TextStyle(
                  color: TacticalColors.crimson,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: pct / 100.0,
              minHeight: 7,
              backgroundColor: TacticalColors.bg,
              valueColor: const AlwaysStoppedAnimation<Color>(TacticalColors.crimson),
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              detail,
              style: const TextStyle(
                color: TacticalColors.textSecondary,
                fontSize: 11.5,
                fontFamily: 'monospace',
              ),
            ),
          ],
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            height: 185,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: TacticalColors.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: TacticalColors.border),
            ),
            child: logs.isEmpty
                ? const Center(
                    child: Text(
                      'No log output yet',
                      style: TextStyle(color: TacticalColors.textMuted, fontSize: 12),
                    ),
                  )
                : SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(
                      logs.join('\n'),
                      style: const TextStyle(
                        color: TacticalColors.textSecondary,
                        fontSize: 11,
                        height: 1.45,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
