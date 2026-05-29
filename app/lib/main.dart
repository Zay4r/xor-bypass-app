import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'dart:math';

void main() {
  runApp(const MyApp());
}

const _navy    = Color(0xFF0D1B2A);
const _navyMid = Color(0xFF152436);
const _red     = Color(0xFFFF0000);
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
  double dist; // distance from button outer edge

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
  bool _holding   = false;

  static const _channel = MethodChannel('com.example.app/vpn');
  Future<void> _startVpn() async => _channel.invokeMethod('connect');
  Future<void> _stopVpn()  async => _channel.invokeMethod('disconnect');

  late AnimationController _warpLevelController;
  late Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  late List<_Star> _stars;
  static const int    _starCount = 220;
  static const int    _seed      = 42;
  static const double _maxDist   = 1400.0;

  // Button geometry — set once layout is known
  Offset _buttonCenter = Offset.zero;
  double _buttonOuterRadius = 0;

  @override
  void initState() {
    super.initState();

    final rng = Random(_seed);
    // Distribute stars evenly across all 4 corner directions so rays appear
    // uniformly around the screen, not clustered at the bottom.
    // Each star gets a base angle pointing toward one of the 4 corners
    // (NE/NW/SE/SW = pi*0.25, pi*0.75, pi*1.25, pi*1.75) plus a random
    // spread of ±50° so rays fan across the full corner zone.
    const cornerAngles = [pi * 0.25, pi * 0.75, pi * 1.25, pi * 1.75];
    const cornerSpread = pi * 0.55; // ±55° from each corner center
    _stars = List.generate(_starCount, (i) {
      final corner = cornerAngles[i % 4];
      final angle  = corner + (rng.nextDouble() - 0.5) * 2 * cornerSpread;
      return _Star(
        angle:      angle,
        size:       0.8 + rng.nextDouble() * 1.8,
        speed:      0.3  + rng.nextDouble() * 1.7,
        brightness: 0.25 + rng.nextDouble() * 0.6,
        dist:       rng.nextDouble() * _maxDist,
      );
    });

    _warpLevelController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _warpLevelController.addListener(() => setState(() {}));
    _warpLevelController.addStatusListener((status) {
      if (status == AnimationStatus.completed && _holding) _onConnected();
    });

    _ticker = createTicker(_onTick);
    _ticker.start();

    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onStatusChange') return;
      final String status = call.arguments as String;
      if (status == 'denied' || status.startsWith('denied:')) {
        _resetToDisconnected(); return;
      }
      setState(() {
        if (status == 'connected') {
          _connected = true; _holding = false;
          _warpLevelController.value = 1.0;
        } else if (status == 'connecting') {
          _holding = true; _connected = false;
        } else if (status == 'disconnected' || status.startsWith('error')) {
          _resetToDisconnected();
        }
      });
    });
  }

  void _onTick(Duration elapsed) {
    if (_lastElapsed == Duration.zero) { _lastElapsed = elapsed; return; }
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;

    final w = _warpLevelController.value;
    // 20 px/s idle → 1000 px/s at full warp
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
    setState(() { _connected = false; _holding = false; });
    _warpLevelController.animateBack(
      0, duration: const Duration(milliseconds: 1200), curve: Curves.easeOut);
  }

  void _onHoldStart() {
    if (_connected) return;
    setState(() => _holding = true);
    _warpLevelController.forward(from: 0);
  }

  void _onHoldEnd() {
    if (_connected) return;
    setState(() => _holding = false);
    _warpLevelController.animateBack(
      0, duration: const Duration(milliseconds: 700), curve: Curves.easeOut);
  }

  void _onConnected() {
    _startVpn();
    HapticFeedback.heavyImpact();
    _warpLevelController.value = 1.0;
    setState(() { _connected = true; _holding = false; });
  }

  void _onDisconnect() {
    _stopVpn();
    _resetToDisconnected();
    HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final w      = _warpLevelController.value;

    // Button size mirrors _PowerButton calculation
    final btnSize        = screen.width * 0.42;
    final btnOuterRadius = btnSize * 0.48; // matches _PowerButtonPainter outerR

    // Compute once; safe to overwrite every build (same values)
    _buttonCenter      = Offset(screen.width / 2, screen.height / 2);
    _buttonOuterRadius = btnOuterRadius;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _navy,
        body: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Color.lerp(_navy, const Color(0xFF080F18), w)!),

            // Warp streaks — full screen, origin = button outer edge
            RepaintBoundary(
              child: CustomPaint(
                painter: StarfieldPainter(
                  stars:        _stars,
                  warp:         w,
                  origin:       _buttonCenter,
                  originRadius: _buttonOuterRadius,
                ),
                child: const SizedBox.expand(),
              ),
            ),

            Center(
              child: _PowerButton(
                progress:     w,
                connected:    _connected,
                holding:      _holding,
                screenWidth:  screen.width,
                onHoldStart:  _onHoldStart,
                onHoldEnd:    _onHoldEnd,
                onDisconnect: _onDisconnect,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Power button
// ══════════════════════════════════════════════════════════════════════════════
class _PowerButton extends StatelessWidget {
  final double progress, screenWidth;
  final bool connected, holding;
  final VoidCallback onHoldStart, onHoldEnd, onDisconnect;

  const _PowerButton({
    required this.progress, required this.connected, required this.holding,
    required this.screenWidth, required this.onHoldStart,
    required this.onHoldEnd, required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final size = screenWidth * 0.42;
    return GestureDetector(
      onTapDown:   (_) => connected ? onDisconnect() : onHoldStart(),
      onTapUp:     (_) => onHoldEnd(),
      onTapCancel: onHoldEnd,
      child: CustomPaint(
        size: Size(size, size),
        painter: _PowerButtonPainter(progress: progress),
      ),
    );
  }
}

class _PowerButtonPainter extends CustomPainter {
  final double progress;
  const _PowerButtonPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2;
    final c  = Offset(cx, cy);
    final outerR = size.width * 0.48;
    final midR   = size.width * 0.38;
    final innerR = size.width * 0.28;

    final ringColor = Color.lerp(const Color(0xFF1A2E42), const Color(0xFF990000), progress)!;
    final fillColor = Color.lerp(const Color(0xFF0F2030), const Color(0xFFCC0000), progress)!;
    final iconColor = Color.lerp(const Color(0xFF4A6080), _litText, progress)!;

    if (progress > 0.05) {
      canvas.drawCircle(c, outerR + 4 + progress * 18,
        Paint()
          ..color = _red.withOpacity(progress * 0.25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20));
    }
    canvas.drawCircle(c, outerR,
      Paint()..color = ringColor.withOpacity(0.60)
             ..style = PaintingStyle.stroke ..strokeWidth = 1.2);
    canvas.drawCircle(c, midR,
      Paint()..color = ringColor.withOpacity(0.30)
             ..style = PaintingStyle.stroke ..strokeWidth = 0.8);
    canvas.drawCircle(c, innerR, Paint()..color = fillColor);
    canvas.drawCircle(c, innerR,
      Paint()..shader = RadialGradient(
        center: const Alignment(-0.4, -0.5), radius: 0.9,
        colors: [Colors.white.withOpacity(0.08 * (1 - progress * 0.5)), Colors.transparent],
      ).createShader(Rect.fromCircle(center: c, radius: innerR)));

    final iconR = innerR * 0.52;
    final ip = Paint()
      ..color = iconColor ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.022 ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: c, radius: iconR), -pi * 0.75, pi * 1.5, false, ip);
    canvas.drawLine(Offset(cx, cy - iconR * 0.38), Offset(cx, cy - iconR * 1.12), ip);
  }

  @override
  bool shouldRepaint(_PowerButtonPainter o) => o.progress != progress;
}

// ══════════════════════════════════════════════════════════════════════════════
// StarfieldPainter
//
// Every star is positioned at:
//   origin  +  direction(angle)  *  (originRadius + dist)
//
// So dist=0 is exactly on the button's outer ring, and streaks shoot outward
// from there — pure Star Wars hyperspace jump from the button edge.
// ══════════════════════════════════════════════════════════════════════════════
class StarfieldPainter extends CustomPainter {
  final List<_Star> stars;
  final double      warp;
  final Offset      origin;       // screen-space button center
  final double      originRadius; // button outer ring radius

  const StarfieldPainter({
    required this.stars,
    required this.warp,
    required this.origin,
    required this.originRadius,
  });

  static double _easeIn(double t)  => t * t * t;
  static double _easeOut(double t) => 1 - pow(1 - t, 3).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    // Clip away a large circle around the button so no rays appear near it.
    // Stars whose ray would hit the center zone are skipped entirely.
    final clearance = originRadius * 8.5;

    // Clip: full screen minus the button exclusion circle
    final clipPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCircle(center: origin, radius: clearance))
      ..fillType = PathFillType.evenOdd;
    canvas.save();
    canvas.clipPath(clipPath);

    // Soft bloom ring around button at warp
    if (warp > 0.08) {
      final bt = ((warp - 0.08) / 0.92).clamp(0.0, 1.0);
      final br = originRadius * (1.0 + _easeOut(bt) * 2.8);
      canvas.drawCircle(origin, br,
        Paint()..shader = RadialGradient(colors: [
          const Color(0xFFCCE8FF).withOpacity(_easeOut(bt) * 0.22),
          const Color(0xFF4477FF).withOpacity(_easeOut(bt) * 0.10),
          Colors.transparent,
        ]).createShader(Rect.fromCircle(center: origin, radius: br)));
    }

    for (final s in stars) {
      final dx = cos(s.angle);
      final dy = sin(s.angle);

      // Head of streak starts at clearance boundary (uniform all directions)
      final headDist = clearance + s.dist;
      final hx = origin.dx + dx * headDist;
      final hy = origin.dy + dy * headDist;

      if (warp < 0.05) {
        // Idle: tiny dot drifting outward from button ring
        final fade = (s.dist / 600.0).clamp(0.0, 1.0);
        canvas.drawCircle(Offset(hx, hy), s.size * 0.75,
          Paint()..color = Colors.white.withOpacity(s.brightness * (0.15 + 0.85 * fade)));
        continue;
      }

      // Wedge: wide at the button ring, tapers to a point at the tail.
      // spread controls the half-angle of the fan — bigger = wider beams.
      final streakLen = _easeIn(warp) * 520 * s.speed;
      final tailDist  = headDist + streakLen;

      // Half-angle at the root (button ring). At warp=1 each beam is ~12° wide.
      final spread = 0.012 * warp;

      final aL = s.angle - spread;
      final aR = s.angle + spread;

      // Two points at the button ring (wide base of the wedge)
      final rootLx = origin.dx + cos(aL) * headDist;
      final rootLy = origin.dy + sin(aL) * headDist;
      final rootRx = origin.dx + cos(aR) * headDist;
      final rootRy = origin.dy + sin(aR) * headDist;

      // One point at the tip (far end)
      final tipX = origin.dx + cos(s.angle) * tailDist;
      final tipY = origin.dy + sin(s.angle) * tailDist;

      final path = Path()
        ..moveTo(rootLx, rootLy)
        ..lineTo(rootRx, rootRy)
        ..lineTo(tipX, tipY)
        ..close();

      final alpha = s.brightness * (0.45 + 0.55 * warp);

      canvas.drawPath(path,
        Paint()
          ..style  = PaintingStyle.fill
          ..shader = RadialGradient(
            center: Alignment(
              (origin.dx / 200 - 1).clamp(-1.0, 1.0),
              (origin.dy / 200 - 1).clamp(-1.0, 1.0),
            ),
            colors: [
              Colors.white.withOpacity(alpha),
              const Color(0xFFBBDDFF).withOpacity(alpha * 0.75),
              const Color(0xFF3366FF).withOpacity(alpha * 0.30),
              Colors.transparent,
            ],
            stops: const [0.0, 0.15, 0.50, 1.0],
          ).createShader(Rect.fromCircle(center: origin, radius: tailDist)));
    }

    canvas.restore();

    // Dark tunnel vignette — deepens from button edge outward at full warp
    if (warp > 0.55) {
      final t  = ((warp - 0.55) / 0.45).clamp(0.0, 1.0);
      final vr = originRadius + (size.longestSide - originRadius) * 0.9;
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..shader = RadialGradient(
          center: Alignment(
            (origin.dx / size.width  * 2 - 1),
            (origin.dy / size.height * 2 - 1),
          ),
          colors: [
            Colors.transparent,
            Colors.transparent,
            const Color(0xFF030810).withOpacity(_easeIn(t) * 0.72),
          ],
          stops: const [0.0, 0.35, 1.0],
          radius: vr / size.longestSide,
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)));
    }
  }

  @override
  bool shouldRepaint(StarfieldPainter o) => true;
}