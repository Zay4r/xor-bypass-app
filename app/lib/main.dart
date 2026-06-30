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

            Positioned(
              top: screen.height * 0.14,
              left: 0,
              right: 0,
              child: Center(
                child: _AppMonitorToggle(
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

    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 184,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF071522).withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? _red.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.18),
            width: 1.1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.30),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MonitorAppOption(
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
                width: 168,
                height: 38,
                child: OutlinedButton.icon(
                  onPressed: enabled ? onClear : null,
                  icon: const Icon(Icons.close, size: 17),
                  label: const Text('Disable automation'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white.withValues(alpha: 0.88),
                    side: BorderSide(color: _red.withValues(alpha: 0.50)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
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
  final bool selected;
  final bool enabled;
  final String semanticLabel;
  final String label;
  final ValueChanged<bool> onChanged;
  final Widget logo;

  const _MonitorAppOption({
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
        ? _red.withValues(alpha: 0.95)
        : Colors.white.withValues(alpha: 0.62);
    final fillColor = selected
        ? const Color(0xFF2C0B12).withValues(alpha: 0.95)
        : const Color(0xFF102B44).withValues(alpha: 0.94);

    return Semantics(
      button: true,
      checked: selected,
      label: semanticLabel,
      child: GestureDetector(
        onTap: enabled ? () => onChanged(!selected) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 168,
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: fillColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: 1.6),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: _red.withValues(alpha: 0.26),
                      blurRadius: 18,
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
                    color: Colors.white.withValues(alpha: 0.90),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: selected ? _red : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: selected
                        ? const Color(0xFFFF6A6A)
                        : Colors.white.withValues(alpha: 0.46),
                    width: 1.4,
                  ),
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
