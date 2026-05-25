import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XOR VPN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: const VpnScreen(),
    );
  }
}

class VpnScreen extends StatefulWidget {
  const VpnScreen({super.key});

  @override
  State<VpnScreen> createState() => _VpnScreenState();
}

class _VpnScreenState extends State<VpnScreen> with TickerProviderStateMixin {
  bool _connected = false;
  bool _holding = false;
  double _colorProgress = 0.0;

  static const _channel = MethodChannel('com.example.xor_vpn/vpn');

  Future<void> _startVpn() async {
    await _channel.invokeMethod('startVpn');
  }

  Future<void> _stopVpn() async {
    await _channel.invokeMethod('stopVpn');
  }

  late AnimationController _spinController;
  late AnimationController _colorController;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );
    _colorController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _colorController.addListener(() {
      setState(() {
        _colorProgress = _colorController.value;
      });
    });
    _colorController.addStatusListener((status) {
      if (status == AnimationStatus.completed && _holding) {
        _onConnected();
      }
    });
  }

  @override
  void dispose() {
    _spinController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  void _onHoldStart() {
    if (_connected) return;
    setState(() => _holding = true);
    _spinController.repeat();
    _colorController.forward(from: 0);
  }

  void _onHoldEnd() {
    if (_connected) return;
    setState(() => _holding = false);
    _spinController.stop();
    _colorController.reverse();
  }

  void _onConnected() {
    _startVpn();
    setState(() {
      _connected = true;
      _holding = false;
      _colorProgress = 1.0;
    });
    _spinController.stop();
    HapticFeedback.heavyImpact();
  }

  void _onDisconnect() {
    _stopVpn();
    setState(() {
      _connected = false;
      _colorProgress = 0.0;
    });
    _colorController.reverse(from: 1.0);
    HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final sunflowerSize = screenSize.width * 0.55;

    final bgColor = Color.lerp(
      const Color(0xFF2E2E2E),
      const Color(0xFFF5D84A),
      _colorProgress,
    )!;
    final textColor = Color.lerp(
      const Color(0xFF888888),
      const Color(0xFF5C3200),
      _colorProgress,
    )!;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        body: Container(
          width: double.infinity,
          height: double.infinity,
          color: bgColor,
          child: SafeArea(
            child: SizedBox(
              width: double.infinity,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Spacer(flex: 2),

                  // Status
                  Text(
                    _connected ? 'CONNECTED' : 'DISCONNECTED',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 11,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Title
                  Text(
                    'XOR VPN',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 32,
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  const Spacer(flex: 2),

                  // Sunflower
                  GestureDetector(
                    onTapDown: (_) =>
                        _connected ? _onDisconnect() : _onHoldStart(),
                    onTapUp: (_) => _onHoldEnd(),
                    onTapCancel: _onHoldEnd,
                    child: AnimatedBuilder(
                      animation: _spinController,
                      builder: (context, child) {
                        return CustomPaint(
                          size: Size(sunflowerSize, sunflowerSize),
                          painter: SunflowerPainter(
                            progress: _colorProgress,
                            spinAngle: _spinController.value * 2 * pi,
                          ),
                        );
                      },
                    ),
                  ),

                  const Spacer(flex: 2),

                  // Hint
                  Text(
                    _connected
                        ? 'tap to disconnect'
                        : _holding
                        ? 'connecting...'
                        : 'hold to connect',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: textColor, fontSize: 14),
                  ),

                  const SizedBox(height: 12),

                  // IP badge
                  AnimatedOpacity(
                    opacity: _connected ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 600),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'via 13.229.100.126',
                        style: TextStyle(
                          color: textColor,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),

                  const Spacer(flex: 3),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SunflowerPainter extends CustomPainter {
  final double progress;
  final double spinAngle;

  const SunflowerPainter({required this.progress, required this.spinAngle});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    const petalCount = 12;
    final petalDist = size.width * 0.28;
    final petalSize = size.width * 0.09 + progress * size.width * 0.03;
    final centerRadius = size.width * 0.16;
    final innerRadius = size.width * 0.10;

    final petalColor = Color.lerp(
      const Color(0xFF555555),
      const Color(0xFFF5A623),
      progress,
    )!;
    final centerColor = Color.lerp(
      const Color(0xFF555555),
      const Color(0xFF8B4513),
      progress,
    )!;
    final innerColor = Color.lerp(
      const Color(0xFF444444),
      const Color(0xFF5C2D00),
      progress,
    )!;

    // Draw petals
    for (int i = 0; i < petalCount; i++) {
      final angle = (i / petalCount) * 2 * pi + spinAngle;
      final px = cx + cos(angle) * petalDist;
      final py = cy + sin(angle) * petalDist;

      canvas.save();
      canvas.translate(px, py);
      canvas.rotate(angle + pi / 2);

      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: petalSize * 1.1,
          height: petalSize * 2.2,
        ),
        Paint()..color = petalColor,
      );
      canvas.restore();
    }

    // Center circles
    canvas.drawCircle(
      Offset(cx, cy),
      centerRadius,
      Paint()..color = centerColor,
    );
    canvas.drawCircle(Offset(cx, cy), innerRadius, Paint()..color = innerColor);
  }

  @override
  bool shouldRepaint(SunflowerPainter old) =>
      old.progress != progress || old.spinAngle != spinAngle;
}
