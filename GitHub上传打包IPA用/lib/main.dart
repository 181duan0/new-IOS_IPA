import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme/tactical_theme.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: TacticalColors.bg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const TangoInnosOtaApp());
}

class TangoInnosOtaApp extends StatelessWidget {
  const TangoInnosOtaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TANGOINNOS OTA',
      debugShowCheckedModeBanner: false,
      theme: buildTacticalTheme(),
      home: const HomeScreen(),
    );
  }
}
