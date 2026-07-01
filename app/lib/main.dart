import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
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

final class _UpdateNotice {
  const _UpdateNotice({
    required this.required,
    this.reason,
    this.minVersion,
    this.latestVersion,
    this.updateUrl,
  });

  final bool required;
  final String? reason;
  final String? minVersion;
  final String? latestVersion;
  final String? updateUrl;
}

enum _ConnectionVisualState { offline, connecting, connected }

Color _stateBackdropColor(_ConnectionVisualState state, double pulse) {
  return switch (state) {
    _ConnectionVisualState.offline => Color.lerp(
      const Color(0xFF081522),
      const Color(0xFF0C1D2E),
      0.28 + pulse * 0.08,
    )!,
    _ConnectionVisualState.connecting => Color.lerp(
      const Color(0xFF101323),
      const Color(0xFF1C0B15),
      0.48 + pulse * 0.26,
    )!,
    _ConnectionVisualState.connected => Color.lerp(
      const Color(0xFF10080D),
      const Color(0xFF240608),
      pulse,
    )!,
  };
}

Color _stateAccent(_ConnectionVisualState state) {
  return switch (state) {
    _ConnectionVisualState.offline => const Color(0xFF74D7FF),
    _ConnectionVisualState.connecting => const Color(0xFFFFB34A),
    _ConnectionVisualState.connected => _red,
  };
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HtetVPN',
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

class _VpnScreenState extends State<VpnScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  bool _connected = false;
  bool _holding = false;
  bool _monitorFacebook = false;
  bool _monitorChrome = false;
  bool _monitorInstagram = false;
  bool _monitorViber = false;
  int _automationStateVersion = 0;
  _UpdateNotice? _updateNotice;

  bool get _monitorApps =>
      _monitorFacebook || _monitorChrome || _monitorInstagram || _monitorViber;

  _ConnectionVisualState get _visualState {
    if (_connected) return _ConnectionVisualState.connected;
    if (_holding) return _ConnectionVisualState.connecting;
    return _ConnectionVisualState.offline;
  }

  List<String> get _monitorTargetPackages => <String>[
    if (_monitorFacebook) ...[
      'com.facebook.katana',
      'com.facebook.lite',
      'com.facebook.orca',
    ],
    if (_monitorChrome) 'com.android.chrome',
    if (_monitorInstagram) 'com.instagram.android',
    if (_monitorViber) 'com.viber.voip',
  ];

  static const _channel = MethodChannel('com.example.app/vpn');
  Future<void> _startVpn() async {
    try {
      final identity = await _deviceIdentity.getIdentity();
      if (identity.deviceId.isEmpty || identity.publicKey.isEmpty) {
        throw StateError('Device identity is missing');
      }
      await _channel.invokeMethod(
        'connect',
        jsonEncode(<String, Object>{
          'deviceId': identity.deviceId,
          'publicKey': identity.publicKey,
          'monitorApps': _monitorApps,
          'targetPackages': _monitorTargetPackages,
        }),
      );
    } catch (_) {
      if (mounted) _resetToDisconnected();
    }
  }

  Future<void> _stopVpn() async => _channel.invokeMethod('disconnect');

  Future<bool> _hasUsageAccess() async {
    try {
      return await _channel.invokeMethod<bool>('hasUsageAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _confirmUsageAccessDisclosure() async {
    if (!mounted) return false;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF071522),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: const Text('Allow app usage access?'),
        content: const Text(
          'Htet VPN accesses app usage activity only to detect when selected '
          'apps leave the foreground and automatically stop the VPN. This data '
          'stays on your device and is not sold or used for ads.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return accepted ?? false;
  }

  Future<void> _openUpdateUrl(String updateUrl) async {
    try {
      await _channel.invokeMethod('openUpdateUrl', updateUrl);
    } catch (_) {
      await _copyUpdateUrl(updateUrl);
    }
  }

  Future<void> _copyUpdateUrl(String updateUrl) async {
    try {
      await _channel.invokeMethod('copyUpdateUrl', updateUrl);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: updateUrl));
    }
  }

  Future<void> _setAutomationSelection({
    bool? facebook,
    bool? chrome,
    bool? instagram,
    bool? viber,
  }) async {
    final targetPackages = <String>[
      if (facebook ?? _monitorFacebook) ...[
        'com.facebook.katana',
        'com.facebook.lite',
        'com.facebook.orca',
      ],
      if (chrome ?? _monitorChrome) 'com.android.chrome',
      if (instagram ?? _monitorInstagram) 'com.instagram.android',
      if (viber ?? _monitorViber) 'com.viber.voip',
    ];
    if (targetPackages.isNotEmpty && !await _hasUsageAccess()) {
      final accepted = await _confirmUsageAccessDisclosure();
      if (!accepted) return;
    }
    final stateVersion = ++_automationStateVersion;
    try {
      final targets = await _channel.invokeMethod<List<Object?>>(
        'setAutomationTargets',
        jsonEncode(<String, Object>{'targetPackages': targetPackages}),
      );
      if (!mounted || stateVersion != _automationStateVersion) return;
      _applyAutomationTargetPackages(
        targets?.whereType<String>().toSet() ?? {},
      );
    } catch (_) {
      if (mounted) _restoreAutomationTargets(attempts: 1);
    }
  }

  Future<void> _clearAutomationSelection() => _setAutomationSelection(
    facebook: false,
    chrome: false,
    instagram: false,
    viber: false,
  );

  void _applyAutomationTargetPackages(Set<String> targetPackages) {
    setState(() {
      _monitorFacebook =
          targetPackages.contains('com.facebook.katana') ||
          targetPackages.contains('com.facebook.lite') ||
          targetPackages.contains('com.facebook.orca');
      _monitorChrome = targetPackages.contains('com.android.chrome');
      _monitorInstagram = targetPackages.contains('com.instagram.android');
      _monitorViber = targetPackages.contains('com.viber.voip');
    });
  }

  Future<void> _restoreAutomationTargets({int attempts = 4}) async {
    final stateVersion = _automationStateVersion;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final targets = await _channel.invokeMethod<List<Object?>>(
          'getAutomationTargets',
        );
        if (!mounted || stateVersion != _automationStateVersion) return;
        final targetPackages = targets?.whereType<String>().toSet() ?? {};
        _applyAutomationTargetPackages(targetPackages);
        return;
      } catch (_) {
        if (attempt == attempts - 1) return;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

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
    WidgetsBinding.instance.addObserver(this);

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
      if (call.method == 'getDeviceIdentity') {
        final identity = await _deviceIdentity.getIdentity();
        return jsonEncode(<String, String>{
          'deviceId': identity.deviceId,
          'publicKey': identity.publicKey,
        });
      }
      if (call.method == 'signAuthChallenge') {
        final arguments = Map<String, Object?>.from(call.arguments as Map);
        return _deviceIdentity.signChallenge(
          buildNumber: arguments['buildNumber']! as String,
          appVersion: arguments['appVersion'] as String?,
          platform: arguments['platform'] as String?,
          challengeId: arguments['challengeId']! as String,
          challenge: arguments['challenge']! as String,
        );
      }
      if (call.method == 'onAutomationTargetsChanged') {
        final targetPackages =
            (call.arguments as List<Object?>?)?.whereType<String>().toSet() ??
            {};
        _automationStateVersion++;
        _applyAutomationTargetPackages(targetPackages);
        return null;
      }
      if (call.method != 'onStatusChange') return null;
      final String status = call.arguments as String;
      if (status.startsWith('update_required:')) {
        setState(() {
          _updateNotice = _parseUpdateNotice(status, required: true);
        });
        _resetToDisconnected();
        return null;
      }
      if (status.startsWith('update_available:')) {
        setState(() {
          _updateNotice = _parseUpdateNotice(status, required: false);
        });
        return null;
      }
      if (status == 'denied' || status.startsWith('denied:')) {
        _resetToDisconnected();
        return null;
      }
      setState(() {
        if (status == 'connected') {
          _connected = true;
          _holding = false;
          _warpLevelController.animateTo(
            1.0,
            duration: const Duration(milliseconds: 520),
            curve: Curves.easeOutCubic,
          );
        } else if (status == 'connecting') {
          _holding = true;
          _connected = false;
          _warpLevelController.animateTo(
            0.62,
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
          );
        } else if (status == 'disconnected' || status.startsWith('error')) {
          _resetToDisconnected();
        }
      });
      return null;
    });

    _restoreAutomationTargets();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _restoreAutomationTargets(attempts: 1);
    }
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
    WidgetsBinding.instance.removeObserver(this);
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

  _UpdateNotice _parseUpdateNotice(String status, {required bool required}) {
    final payload = status.substring(status.indexOf(':') + 1);
    final json = jsonDecode(payload) as Map<String, Object?>;
    return _UpdateNotice(
      required: required,
      reason: json['reason'] as String?,
      minVersion: json['min_version'] as String?,
      latestVersion: json['latest_version'] as String?,
      updateUrl: json['update_url'] as String?,
    );
  }

  Future<void> _onConnected() async {
    if (_monitorApps) {
      final hasAccess = await _hasUsageAccess();
      if (!mounted) return;
      if (!hasAccess && !await _confirmUsageAccessDisclosure()) {
        return;
      }
    }
    _startVpn();
    HapticFeedback.heavyImpact();
    setState(() {
      _connected = false;
      _holding = true;
    });
    _warpLevelController.animateTo(
      0.62,
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
    );
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
    final visualState = _visualState;

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
            AnimatedContainer(
              duration: const Duration(milliseconds: 480),
              curve: Curves.easeOutCubic,
              color: _stateBackdropColor(visualState, w),
            ),

            RepaintBoundary(
              child: CustomPaint(
                painter: _ConnectionAuraPainter(
                  state: visualState,
                  pulse: w,
                  switchCenter: _switchCenter,
                ),
                child: const SizedBox.expand(),
              ),
            ),

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

            // Dynamic island status
            Positioned(
              top: max(18.0, MediaQuery.of(context).padding.top + 10),
              left: 0,
              right: 0,
              child: Center(
                child: _DynamicIslandStatus(state: visualState, warpLevel: w),
              ),
            ),

            Positioned(
              top: screen.height * 0.14,
              left: 0,
              right: 0,
              child: Center(
                child: _AppMonitorToggle(
                  state: visualState,
                  facebookSelected: _monitorFacebook,
                  chromeSelected: _monitorChrome,
                  instagramSelected: _monitorInstagram,
                  viberSelected: _monitorViber,
                  enabled: !_holding && !_connected,
                  onFacebookChanged: (selected) {
                    _setAutomationSelection(facebook: selected);
                  },
                  onChromeChanged: (selected) {
                    _setAutomationSelection(chrome: selected);
                  },
                  onInstagramChanged: (selected) {
                    _setAutomationSelection(instagram: selected);
                  },
                  onViberChanged: (selected) {
                    _setAutomationSelection(viber: selected);
                  },
                  onClear: _clearAutomationSelection,
                ),
              ),
            ),

            // Light switch — bottom center
            if (_updateNotice case final notice?)
              Positioned(
                top: screen.height * 0.14,
                left: 20,
                right: 20,
                child: _UpdateNoticeBanner(
                  notice: notice,
                  onOpen: notice.updateUrl == null
                      ? null
                      : () => _openUpdateUrl(notice.updateUrl!),
                  onCopy: notice.updateUrl == null
                      ? null
                      : () => _copyUpdateUrl(notice.updateUrl!),
                  onDismiss: notice.required
                      ? null
                      : () => setState(() => _updateNotice = null),
                ),
              ),

            Positioned(
              bottom: 80,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  _ConnectionActionHint(state: visualState),
                  const SizedBox(height: 24),
                  Center(
                    child: _LightSwitch(
                      connected: _connected,
                      connecting: _holding,
                      warpLevel: w,
                      onConnect: () => _onConnected(),
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

class _DynamicIslandStatus extends StatelessWidget {
  final _ConnectionVisualState state;
  final double warpLevel;

  const _DynamicIslandStatus({required this.state, required this.warpLevel});

  @override
  Widget build(BuildContext context) {
    final active = state != _ConnectionVisualState.offline;
    final connected = state == _ConnectionVisualState.connected;
    final connecting = state == _ConnectionVisualState.connecting;
    final width = connected ? 206.0 : (connecting ? 190.0 : 152.0);
    final label = switch (state) {
      _ConnectionVisualState.offline => 'Ready',
      _ConnectionVisualState.connecting => 'Connecting',
      _ConnectionVisualState.connected => 'Connected',
    };
    final accent = Color.lerp(_stateAccent(state), _red, warpLevel * 0.25)!;
    final dotColor = switch (state) {
      _ConnectionVisualState.offline => const Color(0xFF72DCFF),
      _ConnectionVisualState.connecting => const Color(0xFFFFB23D),
      _ConnectionVisualState.connected => const Color(0xFF3DFF84),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      width: width,
      height: active ? 56 : 52,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(31),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: connected ? 0.28 : 0.14),
            blurRadius: connected ? 34 : 22,
            spreadRadius: connected ? 2 : 0,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.38),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: CustomPaint(
        painter: _DynamicIslandRingPainter(
          progress: connected ? 1 : (connecting ? 0.62 : 0.28),
          color: accent,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: const Color(
              0xFF02070D,
            ).withValues(alpha: active ? 0.98 : 0.88),
            borderRadius: BorderRadius.circular(27),
            border: Border.all(
              color: Colors.white.withValues(alpha: active ? 0.12 : 0.08),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                width: active ? 34 : 30,
                height: active ? 34 : 30,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: active ? 0.22 : 0.14),
                  border: Border.all(
                    color: accent.withValues(alpha: active ? 0.56 : 0.34),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: active ? 0.25 : 0.12),
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: ClipOval(
                  child: Image.asset(
                    'assets/logo.png',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Icon(
                      Icons.shield_rounded,
                      color: active ? _litText : Colors.white70,
                      size: 18,
                    ),
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 10),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: TextStyle(
                        color: active
                            ? _litText
                            : Colors.white.withValues(alpha: 0.78),
                        fontSize: active ? 14 : 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 260),
                      width: connecting ? 9 : 7,
                      height: connecting ? 9 : 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: dotColor,
                        boxShadow: [
                          BoxShadow(
                            color: dotColor.withValues(alpha: 0.50),
                            blurRadius: connecting ? 16 : 10,
                            spreadRadius: connecting ? 2 : 1,
                          ),
                        ],
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

class _DynamicIslandRingPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _DynamicIslandRingPainter({
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(1.4),
      Radius.circular(size.height / 2),
    );
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = color.withValues(alpha: 0.16 * progress)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..shader = SweepGradient(
        colors: [
          color.withValues(alpha: 0.16),
          color.withValues(alpha: 0.95),
          Colors.white.withValues(alpha: 0.82),
          color.withValues(alpha: 0.95),
          color.withValues(alpha: 0.16),
        ],
        stops: const [0, 0.25, 0.5, 0.75, 1],
      ).createShader(rect);

    canvas.drawRRect(rrect, glow);
    canvas.drawRRect(rrect, ring);
  }

  @override
  bool shouldRepaint(_DynamicIslandRingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class _ConnectionActionHint extends StatelessWidget {
  final _ConnectionVisualState state;

  const _ConnectionActionHint({required this.state});

  @override
  Widget build(BuildContext context) {
    final accent = _stateAccent(state);
    final text = switch (state) {
      _ConnectionVisualState.offline => 'SLIDE UP TO CONNECT',
      _ConnectionVisualState.connecting => 'SECURING LINK',
      _ConnectionVisualState.connected => 'SLIDE DOWN TO DISCONNECT',
    };
    final icon = switch (state) {
      _ConnectionVisualState.offline => Icons.keyboard_arrow_up_rounded,
      _ConnectionVisualState.connecting => Icons.sync_rounded,
      _ConnectionVisualState.connected => Icons.keyboard_arrow_down_rounded,
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF06111C).withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.24)),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: Row(
          key: ValueKey(state),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: accent.withValues(alpha: 0.92), size: 18),
            const SizedBox(width: 7),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.62),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionAuraPainter extends CustomPainter {
  final _ConnectionVisualState state;
  final double pulse;
  final Offset switchCenter;

  const _ConnectionAuraPainter({
    required this.state,
    required this.pulse,
    required this.switchCenter,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final accent = _stateAccent(state);
    final statePower = switch (state) {
      _ConnectionVisualState.offline => 0.34,
      _ConnectionVisualState.connecting => 0.66,
      _ConnectionVisualState.connected => 1.0,
    };
    final center = switchCenter == Offset.zero
        ? Offset(size.width / 2, size.height * 0.78)
        : switchCenter;

    final bottomGlow = Paint()
      ..shader = RadialGradient(
        colors: [
          accent.withValues(alpha: 0.24 * statePower),
          accent.withValues(alpha: 0.08 * statePower),
          Colors.transparent,
        ],
        stops: const [0, 0.38, 1],
      ).createShader(Rect.fromCircle(center: center, radius: 170 + 48 * pulse));
    canvas.drawCircle(center, 170 + 48 * pulse, bottomGlow);

    final topCenter = Offset(size.width / 2, size.height * 0.23);
    final topGlow = Paint()
      ..shader =
          RadialGradient(
            colors: [
              Colors.white.withValues(
                alpha: state == _ConnectionVisualState.offline ? 0.07 : 0.03,
              ),
              accent.withValues(alpha: 0.12 * statePower),
              Colors.transparent,
            ],
          ).createShader(
            Rect.fromCircle(center: topCenter, radius: 155 + 28 * pulse),
          );
    canvas.drawCircle(topCenter, 155 + 28 * pulse, topGlow);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = accent.withValues(alpha: 0.12 * statePower);
    canvas.drawCircle(center, 90 + 24 * pulse, ringPaint);
    canvas.drawCircle(center, 126 + 34 * pulse, ringPaint);
  }

  @override
  bool shouldRepaint(_ConnectionAuraPainter oldDelegate) {
    return oldDelegate.state != state ||
        oldDelegate.pulse != pulse ||
        oldDelegate.switchCenter != switchCenter;
  }
}

class _UpdateNoticeBanner extends StatelessWidget {
  final _UpdateNotice notice;
  final VoidCallback? onOpen;
  final VoidCallback? onCopy;
  final VoidCallback? onDismiss;

  const _UpdateNoticeBanner({
    required this.notice,
    required this.onOpen,
    required this.onCopy,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final title = notice.required ? 'Update required' : 'Update available';
    final detail = switch ((notice.minVersion, notice.latestVersion)) {
      (final minVersion?, final latestVersion?) =>
        'Minimum $minVersion. Latest $latestVersion.',
      (final minVersion?, null) => 'Minimum $minVersion.',
      (null, final latestVersion?) => 'Latest $latestVersion.',
      _ =>
        notice.required
            ? 'Install the latest version to connect.'
            : 'A newer version is ready.',
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF120D12).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _red.withValues(alpha: 0.64), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.32),
            blurRadius: 18,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(
            notice.required ? Icons.error_outline : Icons.system_update_alt,
            color: _red.withValues(alpha: 0.95),
            size: 24,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.68),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (onOpen != null)
            IconButton(
              tooltip: 'Open update',
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new),
              color: Colors.white,
            ),
          if (onCopy != null)
            IconButton(
              tooltip: 'Copy update link',
              onPressed: onCopy,
              icon: const Icon(Icons.copy),
              color: Colors.white,
            ),
          if (onDismiss != null)
            IconButton(
              tooltip: 'Dismiss',
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
              color: Colors.white.withValues(alpha: 0.72),
            ),
        ],
      ),
    );
  }
}

class _AppMonitorToggle extends StatelessWidget {
  final _ConnectionVisualState state;
  final bool facebookSelected;
  final bool chromeSelected;
  final bool instagramSelected;
  final bool viberSelected;
  final bool enabled;
  final ValueChanged<bool> onFacebookChanged;
  final ValueChanged<bool> onChromeChanged;
  final ValueChanged<bool> onInstagramChanged;
  final ValueChanged<bool> onViberChanged;
  final VoidCallback onClear;

  const _AppMonitorToggle({
    required this.state,
    required this.facebookSelected,
    required this.chromeSelected,
    required this.instagramSelected,
    required this.viberSelected,
    required this.enabled,
    required this.onFacebookChanged,
    required this.onChromeChanged,
    required this.onInstagramChanged,
    required this.onViberChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final selected =
        facebookSelected ||
        chromeSelected ||
        instagramSelected ||
        viberSelected;
    final accent = _stateAccent(state);
    final activeState = state != _ConnectionVisualState.offline;

    return Opacity(
      opacity: enabled ? 1.0 : 0.58,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
        width: 250,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(
                0xFF112B43,
              ).withValues(alpha: activeState ? 0.58 : 0.84),
              const Color(0xFF07131F).withValues(alpha: 0.92),
              Color.lerp(
                const Color(0xFF061421),
                accent,
                activeState ? 0.10 : 0.04,
              )!,
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? accent.withValues(alpha: 0.72)
                : Colors.white.withValues(alpha: activeState ? 0.16 : 0.26),
            width: 1.4,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.38),
              blurRadius: 28,
              offset: const Offset(0, 18),
            ),
            BoxShadow(
              color: accent.withValues(alpha: selected ? 0.20 : 0.08),
              blurRadius: 28,
              spreadRadius: selected ? 1 : 0,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MonitorAppOption(
              accent: accent,
              selected: facebookSelected,
              enabled: enabled,
              semanticLabel: 'Facebook app monitor',
              label: 'Facebook',
              onChanged: onFacebookChanged,
              logo: CustomPaint(
                size: const Size(38, 38),
                painter: _FacebookLogoPainter(),
              ),
            ),
            const SizedBox(height: 8),
            _MonitorAppOption(
              accent: accent,
              selected: chromeSelected,
              enabled: enabled,
              semanticLabel: 'Chrome app monitor',
              label: 'Chrome',
              onChanged: onChromeChanged,
              logo: CustomPaint(
                size: const Size(38, 38),
                painter: _ChromeLogoPainter(),
              ),
            ),
            const SizedBox(height: 8),
            _MonitorAppOption(
              accent: accent,
              selected: instagramSelected,
              enabled: enabled,
              semanticLabel: 'Instagram app monitor',
              label: 'Instagram',
              onChanged: onInstagramChanged,
              logo: CustomPaint(
                size: const Size(38, 38),
                painter: _InstagramLogoPainter(),
              ),
            ),
            const SizedBox(height: 8),
            _MonitorAppOption(
              accent: accent,
              selected: viberSelected,
              enabled: enabled,
              semanticLabel: 'Viber app monitor',
              label: 'Viber',
              onChanged: onViberChanged,
              logo: CustomPaint(
                size: const Size(38, 38),
                painter: _ViberLogoPainter(),
              ),
            ),
            if (selected) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: 226,
                height: 38,
                child: OutlinedButton.icon(
                  onPressed: enabled ? onClear : null,
                  icon: const Icon(Icons.close, size: 17),
                  label: const Text('Disable automation'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white.withValues(alpha: 0.88),
                    side: BorderSide(color: accent.withValues(alpha: 0.50)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MonitorAppOption extends StatelessWidget {
  final Color accent;
  final bool selected;
  final bool enabled;
  final String semanticLabel;
  final String label;
  final ValueChanged<bool> onChanged;
  final Widget logo;

  const _MonitorAppOption({
    required this.accent,
    required this.selected,
    required this.enabled,
    required this.semanticLabel,
    required this.label,
    required this.onChanged,
    required this.logo,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? accent.withValues(alpha: 0.95)
        : Colors.white.withValues(alpha: 0.48);
    final fillColor = selected
        ? Color.lerp(
            const Color(0xFF102B44),
            accent,
            0.20,
          )!.withValues(alpha: 0.95)
        : const Color(0xFF0D263C).withValues(alpha: 0.92);

    return Semantics(
      button: true,
      checked: selected,
      label: semanticLabel,
      child: GestureDetector(
        onTap: enabled ? () => onChanged(!selected) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          width: 226,
          height: 62,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [fillColor, Color.lerp(fillColor, Colors.black, 0.22)!],
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: selected ? 1.9 : 1.4),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.30),
                      blurRadius: 22,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              logo,
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.94),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: selected ? accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected
                        ? Colors.white.withValues(alpha: 0.72)
                        : Colors.white.withValues(alpha: 0.46),
                    width: 1.4,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.36),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: selected
                    ? const Icon(Icons.check, size: 17, color: Colors.white)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FacebookLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    canvas.drawCircle(center, radius, Paint()..color = const Color(0xFF1877F2));

    final textPainter = TextPainter(
      text: TextSpan(
        text: 'f',
        style: TextStyle(
          color: Colors.white,
          fontSize: size.height * 0.86,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width * 0.40,
        center.dy - textPainter.height * 0.42,
      ),
    );
  }

  @override
  bool shouldRepaint(_FacebookLogoPainter oldDelegate) => false;
}

class _ChromeLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawArc(
      rect,
      -pi / 2,
      2 * pi / 3,
      true,
      Paint()..color = const Color(0xFFDB4437),
    );
    canvas.drawArc(
      rect,
      pi / 6,
      2 * pi / 3,
      true,
      Paint()..color = const Color(0xFFF4B400),
    );
    canvas.drawArc(
      rect,
      5 * pi / 6,
      2 * pi / 3,
      true,
      Paint()..color = const Color(0xFF0F9D58),
    );
    canvas.drawCircle(center, radius * 0.45, Paint()..color = Colors.white);
    canvas.drawCircle(
      center,
      radius * 0.34,
      Paint()..color = const Color(0xFF4285F4),
    );
  }

  @override
  bool shouldRepaint(_ChromeLogoPainter oldDelegate) => false;
}

class _InstagramLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = size.shortestSide / 2;
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFFFEDA75),
          Color(0xFFFA7E1E),
          Color(0xFFD62976),
          Color(0xFF962FBF),
          Color(0xFF4F5BD5),
        ],
      ).createShader(rect);

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius * 0.32)),
      paint,
    );
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.shortestSide * 0.08
      ..strokeCap = StrokeCap.round;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(size.shortestSide * 0.22),
        Radius.circular(radius * 0.20),
      ),
      stroke,
    );
    canvas.drawCircle(rect.center, size.shortestSide * 0.16, stroke);
    canvas.drawCircle(
      Offset(size.width * 0.70, size.height * 0.30),
      size.shortestSide * 0.045,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_InstagramLogoPainter oldDelegate) => false;
}

class _ViberLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    canvas.drawCircle(center, radius, Paint()..color = const Color(0xFF665CAC));

    final textPainter = TextPainter(
      text: TextSpan(
        text: 'V',
        style: TextStyle(
          color: Colors.white,
          fontSize: size.height * 0.62,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(_ViberLogoPainter oldDelegate) => false;
}

// ══════════════════════════════════════════════════════════════════════════════
// Light Switch
// ══════════════════════════════════════════════════════════════════════════════

class _LightSwitch extends StatefulWidget {
  final bool connected;
  final bool connecting;
  final double warpLevel;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  const _LightSwitch({
    required this.connected,
    required this.connecting,
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
    final base = widget.connected
        ? 1.0
        : widget.connecting
        ? 0.56
        : 0.0;
    final drag = _dragDelta / _travel;
    return (base + drag).clamp(0.0, 1.0);
  }

  void _onPanStart(DragStartDetails d) {
    if (widget.connecting) return;
    setState(() {
      _dragDelta = 0.0;
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (widget.connecting) return;
    setState(() {
      // drag up = negative dy = positive delta
      _dragDelta = (_dragDelta - d.delta.dy).clamp(
        widget.connected ? -_travel : 0.0,
        widget.connected ? 0.0 : _travel,
      );
    });
  }

  void _onPanEnd(DragEndDetails d) {
    if (widget.connecting) return;
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
    final state = widget.connected
        ? _ConnectionVisualState.connected
        : widget.connecting
        ? _ConnectionVisualState.connecting
        : _ConnectionVisualState.offline;
    final accent = _stateAccent(state);

    final trackColor = Color.lerp(
      const Color(0xFF0B2236),
      Color.lerp(const Color(0xFF291118), accent, 0.18)!,
      widget.connecting ? 0.58 : warp,
    )!;
    final trackBorder = Color.lerp(const Color(0xFF2D5B78), accent, p)!;
    final thumbColor = Color.lerp(const Color(0xFF16324A), accent, p)!;
    final thumbBorder = Color.lerp(const Color(0xFF67B8DF), Colors.white, p)!;
    final iconColor = Color.lerp(const Color(0xFF86DFFF), _litText, p)!;

    // p=0 → thumb at bottom, p=1 → thumb at top
    final thumbOffset = (1.0 - p) * _travel;

    return GestureDetector(
      onVerticalDragStart: _onPanStart,
      onVerticalDragUpdate: _onPanUpdate,
      onVerticalDragEnd: _onPanEnd,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
        width: _thumbD + 24,
        height: _trackH,
        decoration: BoxDecoration(
          color: trackColor,
          borderRadius: BorderRadius.circular(_trackH / 2),
          border: Border.all(
            color: trackBorder,
            width: widget.connecting ? 2.0 : 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.10 + p * 0.22),
              blurRadius: 30,
              spreadRadius: 2,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.32),
              blurRadius: 22,
              offset: const Offset(0, 14),
            ),
          ],
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
                    color: trackBorder.withValues(
                      alpha: widget.connecting ? 0.95 : 0.6,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),

            // Thumb
            AnimatedPositioned(
              duration: const Duration(milliseconds: 360),
              curve: Curves.easeOutCubic,
              top: thumbOffset + 8,
              left: 0,
              right: 0,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  width: _thumbD,
                  height: _thumbD,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: thumbColor,
                    border: Border.all(color: thumbBorder, width: 1.5),
                    boxShadow: p > 0.05
                        ? [
                            BoxShadow(
                              color: accent.withValues(
                                alpha: widget.connecting ? 0.52 : p * 0.50,
                              ),
                              blurRadius: widget.connecting ? 34 : 28 * p,
                              spreadRadius: widget.connecting ? 6 : 4 * p,
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
