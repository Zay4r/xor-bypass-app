import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'dart:math';

import 'device_identity.dart';

final DeviceIdentity _deviceIdentity = DeviceIdentity();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _deviceIdentity.getIdentity();
  runApp(const MyApp());
}

const _navy = Color(0xFF0D1B2A);
const _red = Color(0xFFFF0000);
const _litText = Color(0xFFFFFFFF);

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XorVPN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.dark(primary: _red, surface: _navy),
      ),
      home: const VpnScreen(),
    );
  }
}

class _Star {
  final double angle;
  final double size;
  final double speed;
  final double brightness;
  double dist;

  _Star({
    required this.angle,
    required this.size,
    required this.speed,
    required this.brightness,
    required this.dist,
  });
}

class VpnScreen extends StatefulWidget {
  const VpnScreen({super.key});
  @override
  State<VpnScreen> createState() => _VpnScreenState();
}

class _VpnScreenState extends State<VpnScreen> with TickerProviderStateMixin {
  bool _connected = false;
  bool _holding = false;

  static const _channel = MethodChannel('com.example.app/vpn');
  Future<void> _startVpn() async {
    try {
      final identity = await _deviceIdentity.getIdentity();
      await _channel.invokeMethod('connect', <String, String>{
        'deviceId': identity.deviceId,
        'publicKey': identity.publicKey,
      });
    } catch (_) {
      if (mounted) _resetToDisconnected();
    }
  }

  Future<void> _stopVpn() async => _channel.invokeMethod('disconnect');

  late AnimationController _warpLevelController;
  late Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  late List<_Star> _stars;
  static const int _starCount = 220;
  static const int _seed = 42;
  static const double _maxDist = 1400.0;

  // Switch geometry — origin for starfield rays
  Offset _switchCenter = Offset.zero;
  double _switchOriginRadius = 0;

  @override
  void initState() {
    super.initState();

    final rng = Random(_seed);
    const cornerAngles = [pi * 0.25, pi * 0.75, pi * 1.25, pi * 1.75];
    const cornerSpread = pi * 0.55;
    _stars = List.generate(_starCount, (i) {
      final corner = cornerAngles[i % 4];
      final angle = corner + (rng.nextDouble() - 0.5) * 2 * cornerSpread;
      return _Star(
        angle: angle,
        size: 0.8 + rng.nextDouble() * 1.8,
        speed: 0.3 + rng.nextDouble() * 1.7,
        brightness: 0.25 + rng.nextDouble() * 0.6,
        dist: rng.nextDouble() * _maxDist,
      );
    });

    _warpLevelController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _warpLevelController.addListener(() => setState(() {}));

    _ticker = createTicker(_onTick);
    _ticker.start();

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'signAuthChallenge') {
        final arguments = Map<String, Object?>.from(call.arguments as Map);
        return _deviceIdentity.signChallenge(
          buildNumber: arguments['buildNumber']! as String,
          challengeId: arguments['challengeId']! as String,
          challenge: arguments['challenge']! as String,
        );
      }
      if (call.method != 'onStatusChange') return null;
      final String status = call.arguments as String;
      if (status == 'denied' || status.startsWith('denied:')) {
        _resetToDisconnected();
        return null;
      }
      setState(() {
        if (status == 'connected') {
          _connected = true;
          _holding = false;
          _warpLevelController.value = 1.0;
        } else if (status == 'connecting') {
          _holding = true;
          _connected = false;
        } else if (status == 'disconnected' || status.startsWith('error')) {
          _resetToDisconnected();
        }
      });
      return null;
    });
  }

  void _onTick(Duration elapsed) {
    if (_lastElapsed == Duration.zero) {
      _lastElapsed = elapsed;
      return;
    }
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;

    final w = _warpLevelController.value;
    final baseSpeed = 20.0 + w * w * 980.0;

    for (final s in _stars) {
      s.dist += baseSpeed * s.speed * dt;
      if (s.dist > _maxDist) {
        s.dist = _connected ? Random().nextDouble() * 8 : 0;
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    _warpLevelController.dispose();
    super.dispose();
  }

  void _resetToDisconnected() {
    setState(() {
      _connected = false;
      _holding = false;
    });
    _warpLevelController.animateBack(
      0,
      duration: const Duration(milliseconds: 1200),
      curve: Curves.easeOut,
    );
  }

  void _onConnected() {
    _startVpn();
    HapticFeedback.heavyImpact();
    setState(() {
      _connected = false;
      _holding = true;
    });
  }

  void _onDisconnect() {
    _stopVpn();
    _resetToDisconnected();
    HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final w = _warpLevelController.value;

    // Starfield origin: center of screen (where switch lives)
    _switchCenter = Offset(screen.width / 2, screen.height - 160);
    _switchOriginRadius = 40.0;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _navy,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Background
            ColoredBox(color: Color.lerp(_navy, const Color(0xFF080F18), w)!),

            // Warp starfield
            RepaintBoundary(
              child: CustomPaint(
                painter: _StarfieldPainter(
                  stars: _stars,
                  warp: w,
                  origin: _switchCenter,
                  originRadius: _switchOriginRadius,
                ),
                child: const SizedBox.expand(),
              ),
            ),

            // Status label top-center
            Positioned(
              top: 80,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  Text(
                    _connected ? 'CONNECTED' : 'DISCONNECTED',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _connected
                          ? _red.withValues(alpha: 0.9)
                          : Colors.white.withValues(alpha: 0.25),
                      fontSize: 11,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),

            // Light switch — bottom center
            Positioned(
              bottom: 80,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  Text(
                    _connected
                        ? 'slide down to disconnect'
                        : _holding
                        ? 'connecting...'
                        : 'slide up to connect',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 13,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: _LightSwitch(
                      connected: _connected,
                      warpLevel: w,
                      onConnect: _onConnected,
                      onDisconnect: _onDisconnect,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Light Switch
// ══════════════════════════════════════════════════════════════════════════════

class _LightSwitch extends StatefulWidget {
  final bool connected;
  final double warpLevel;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  const _LightSwitch({
    required this.connected,
    required this.warpLevel,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  State<_LightSwitch> createState() => _LightSwitchState();
}

class _LightSwitchState extends State<_LightSwitch> {
  static const double _trackH = 160.0;
  static const double _thumbD = 64.0;
  static const double _travel = _trackH - _thumbD - 16.0; // ~80px

  double _dragDelta = 0.0;

  // 0.0 = bottom (disconnected), 1.0 = top (connected)
  double get _thumbProgress {
    final base = widget.connected ? 1.0 : 0.0;
    final drag = _dragDelta / _travel;
    return (base + drag).clamp(0.0, 1.0);
  }

  void _onPanStart(DragStartDetails d) {
    setState(() {
      _dragDelta = 0.0;
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    setState(() {
      // drag up = negative dy = positive delta
      _dragDelta = (_dragDelta - d.delta.dy).clamp(
        widget.connected ? -_travel : 0.0,
        widget.connected ? 0.0 : _travel,
      );
    });
  }

  void _onPanEnd(DragEndDetails d) {
    final threshold = _travel * 0.4;
    final delta = _dragDelta;
    setState(() {
      _dragDelta = 0.0;
    });
    if (!widget.connected && delta > threshold) {
      widget.onConnect();
    } else if (widget.connected && delta < -threshold) {
      widget.onDisconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _thumbProgress;
    final warp = widget.warpLevel;

    final trackColor = Color.lerp(
      const Color(0xFF0E2235),
      const Color(0xFF1A0808),
      warp,
    )!;
    final trackBorder = Color.lerp(
      const Color(0xFF1A3348),
      const Color(0xFF660000),
      p,
    )!;
    final thumbColor = Color.lerp(
      const Color(0xFF152436),
      const Color(0xFFCC0000),
      p,
    )!;
    final thumbBorder = Color.lerp(
      const Color(0xFF1E3550),
      const Color(0xFFFF2222),
      p,
    )!;
    final iconColor = Color.lerp(const Color(0xFF3A6080), _litText, p)!;

    // p=0 → thumb at bottom, p=1 → thumb at top
    final thumbOffset = (1.0 - p) * _travel;

    return GestureDetector(
      onVerticalDragStart: _onPanStart,
      onVerticalDragUpdate: _onPanUpdate,
      onVerticalDragEnd: _onPanEnd,
      child: Container(
        width: _thumbD + 24,
        height: _trackH,
        decoration: BoxDecoration(
          color: trackColor,
          borderRadius: BorderRadius.circular(_trackH / 2),
          border: Border.all(color: trackBorder, width: 1.5),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Top notch indicator
            Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 20,
                  height: 3,
                  decoration: BoxDecoration(
                    color: trackBorder.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),

            // Thumb
            Positioned(
              top: thumbOffset + 8,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: _thumbD,
                  height: _thumbD,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: thumbColor,
                    border: Border.all(color: thumbBorder, width: 1.5),
                    boxShadow: p > 0.05
                        ? [
                            BoxShadow(
                              color: _red.withValues(alpha: p * 0.50),
                              blurRadius: 28 * p,
                              spreadRadius: 4 * p,
                            ),
                          ]
                        : null,
                  ),
                  child: Center(
                    child: CustomPaint(
                      size: const Size(24, 24),
                      painter: _SunIconPainter(color: iconColor),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Sun / power icon inside thumb
// ══════════════════════════════════════════════════════════════════════════════

class _SunIconPainter extends CustomPainter {
  final Color color;
  const _SunIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final p = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // 8 rays
    for (int i = 0; i < 8; i++) {
      final a = (i / 8) * 2 * pi;
      canvas.drawLine(
        Offset(cx + cos(a) * 5, cy + sin(a) * 5),
        Offset(cx + cos(a) * 10, cy + sin(a) * 10),
        p,
      );
    }
    canvas.drawCircle(Offset(cx, cy), 3.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SunIconPainter o) => o.color != color;
}

// ══════════════════════════════════════════════════════════════════════════════
// StarfieldPainter
// ══════════════════════════════════════════════════════════════════════════════

class _StarfieldPainter extends CustomPainter {
  final List<_Star> stars;
  final double warp;
  final Offset origin;
  final double originRadius;

  const _StarfieldPainter({
    required this.stars,
    required this.warp,
    required this.origin,
    required this.originRadius,
  });

  static double _easeIn(double t) => t * t * t;
  static double _easeOut(double t) => 1 - pow(1 - t, 3).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    final clearance = originRadius * 8.5;

    final clipPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCircle(center: origin, radius: clearance))
      ..fillType = PathFillType.evenOdd;
    canvas.save();
    canvas.clipPath(clipPath);

    if (warp > 0.08) {
      final bt = ((warp - 0.08) / 0.92).clamp(0.0, 1.0);
      final br = originRadius * (1.0 + _easeOut(bt) * 2.8);
      canvas.drawCircle(
        origin,
        br,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0xFFCCE8FF).withValues(alpha: _easeOut(bt) * 0.22),
              const Color(0xFF4477FF).withValues(alpha: _easeOut(bt) * 0.10),
              Colors.transparent,
            ],
          ).createShader(Rect.fromCircle(center: origin, radius: br)),
      );
    }

    for (final s in stars) {
      final dx = cos(s.angle);
      final dy = sin(s.angle);
      final headDist = clearance + s.dist;
      final hx = origin.dx + dx * headDist;
      final hy = origin.dy + dy * headDist;

      if (warp < 0.05) {
        final fade = (s.dist / 600.0).clamp(0.0, 1.0);
        canvas.drawCircle(
          Offset(hx, hy),
          s.size * 0.75,
          Paint()
            ..color = Colors.white.withValues(
              alpha: s.brightness * (0.15 + 0.85 * fade),
            ),
        );
        continue;
      }

      final streakLen = _easeIn(warp) * 520 * s.speed;
      final tailDist = headDist + streakLen;
      final spread = 0.012 * warp;
      final aL = s.angle - spread;
      final aR = s.angle + spread;

      final rootLx = origin.dx + cos(aL) * headDist;
      final rootLy = origin.dy + sin(aL) * headDist;
      final rootRx = origin.dx + cos(aR) * headDist;
      final rootRy = origin.dy + sin(aR) * headDist;
      final tipX = origin.dx + cos(s.angle) * tailDist;
      final tipY = origin.dy + sin(s.angle) * tailDist;

      final path = Path()
        ..moveTo(rootLx, rootLy)
        ..lineTo(rootRx, rootRy)
        ..lineTo(tipX, tipY)
        ..close();

      final alpha = s.brightness * (0.45 + 0.55 * warp);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..shader = RadialGradient(
            center: Alignment(
              (origin.dx / 200 - 1).clamp(-1.0, 1.0),
              (origin.dy / 200 - 1).clamp(-1.0, 1.0),
            ),
            colors: [
              Colors.white.withValues(alpha: alpha),
              const Color(0xFFBBDDFF).withValues(alpha: alpha * 0.75),
              const Color(0xFF3366FF).withValues(alpha: alpha * 0.30),
              Colors.transparent,
            ],
            stops: const [0.0, 0.15, 0.50, 1.0],
          ).createShader(Rect.fromCircle(center: origin, radius: tailDist)),
      );
    }

    canvas.restore();

    if (warp > 0.55) {
      final t = ((warp - 0.55) / 0.45).clamp(0.0, 1.0);
      final vr = originRadius + (size.longestSide - originRadius) * 0.9;
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()
          ..shader = RadialGradient(
            center: Alignment(
              (origin.dx / size.width * 2 - 1),
              (origin.dy / size.height * 2 - 1),
            ),
            colors: [
              Colors.transparent,
              Colors.transparent,
              const Color(0xFF030810).withValues(alpha: _easeIn(t) * 0.72),
            ],
            stops: const [0.0, 0.35, 1.0],
            radius: vr / size.longestSide,
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
      );
    }
  }

  @override
  bool shouldRepaint(_StarfieldPainter o) => true;
}
