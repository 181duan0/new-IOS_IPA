import 'package:flutter/material.dart';
import '../theme/tactical_theme.dart';
import 'abbm_dfu_tab.dart';
import 'host_ota_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TacticalColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // Tactical Brand Header
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: const BoxDecoration(
                color: TacticalColors.surface,
                border: Border(bottom: BorderSide(color: TacticalColors.border)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset(
                          'assets/images/app_icon.png',
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'TANGOINNOS OTA',
                              style: TextStyle(
                                color: TacticalColors.textPrimary,
                                fontSize: 16.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.0,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Host OTA  ·  ABBM Secure DFU Suite',
                              style: TextStyle(
                                color: TacticalColors.textSecondary,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: TacticalColors.bg,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: TacticalColors.border),
                        ),
                        child: const Text(
                          'v2.0.2',
                          style: TextStyle(
                            color: TacticalColors.textSecondary,
                            fontSize: 11,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Dual Main Mode Switcher
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: TacticalColors.bg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: TacticalColors.border),
                    ),
                    child: Row(
                      children: [
                        _ModeButton(
                          selected: _tabIndex == 0,
                          icon: Icons.memory_rounded,
                          title: 'Host OTA',
                          subtitle: 'CH582 · IAP Repair',
                          onTap: () => setState(() => _tabIndex = 0),
                        ),
                        const SizedBox(width: 4),
                        _ModeButton(
                          selected: _tabIndex == 1,
                          icon: Icons.bluetooth_audio_rounded,
                          title: 'ABBM DFU',
                          subtitle: 'nRF52 · No Rename',
                          onTap: () => setState(() => _tabIndex = 1),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Active Mode Body (IndexedStack preserves state across mode switches)
            Expanded(
              child: IndexedStack(
                index: _tabIndex,
                children: const [
                  HostOtaTab(),
                  AbbmDfuTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ModeButton({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? TacticalColors.crimson : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? Colors.white : TacticalColors.textSecondary,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? Colors.white : TacticalColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? Colors.white.withValues(alpha: 0.85)
                            : TacticalColors.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
