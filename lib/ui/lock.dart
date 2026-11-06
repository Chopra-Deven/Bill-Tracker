import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../pin_policy.dart';
import '../store.dart';
import 'common.dart';

class LockService {
  static final locked = ValueNotifier<bool>(false);
  static const _ss = FlutterSecureStorage();
  static int _outside = 0;

  static String _salt() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<void> resetFails() async {
    await _ss.delete(key: 'pin_fail');
    await _ss.delete(key: 'pin_until');
  }

  static Future<void> setPin(String p) async {
    await _ss.write(key: 'pin', value: hashPin(p, _salt()));
    await resetFails();
  }

  static Future<void> clearPin() async {
    await _ss.delete(key: 'pin');
    await resetFails();
  }

  /// Time left before another PIN try is allowed.
  static Future<Duration> waitLeft() async {
    final until = int.tryParse(await _ss.read(key: 'pin_until') ?? '') ?? 0;
    final left = until - DateTime.now().millisecondsSinceEpoch;
    return left > 0 ? Duration(milliseconds: left) : Duration.zero;
  }

  /// False while locked out, or when the PIN is wrong (which counts a failure).
  static Future<bool> check(String p) async {
    if (await waitLeft() > Duration.zero) return false;
    final stored = await _ss.read(key: 'pin');
    if (stored != null && verifyStored(stored, p)) {
      if (needsUpgrade(stored)) await _ss.write(key: 'pin', value: hashPin(p, _salt()));
      await resetFails();
      return true;
    }
    final n = (int.tryParse(await _ss.read(key: 'pin_fail') ?? '') ?? 0) + 1;
    await _ss.write(key: 'pin_fail', value: '$n');
    final w = lockoutFor(n);
    if (w > Duration.zero) {
      await _ss.write(key: 'pin_until', value: '${DateTime.now().millisecondsSinceEpoch + w.inMilliseconds}');
    }
    return false;
  }

  static String waitText(Duration d) => 'Too many tries. Try again in ${(d.inMilliseconds / 1000).ceil()}s.';

  static void lockNow() {
    if (AppStore.I.settings.lockOn) locked.value = true;
  }

  /// Wrap calls that leave the app on purpose (file picker, share menu,
  /// opening a PDF) so coming back does not lock the app.
  static Future<T> outside<T>(Future<T> Function() f) async {
    _outside++;
    try {
      return await f();
    } finally {
      Future.delayed(const Duration(seconds: 1), () => _outside--);
    }
  }

  static bool get isOutside => _outside > 0;

  static Future<bool> biometric() async {
    final a = LocalAuthentication();
    try {
      if (!await a.isDeviceSupported() || !await a.canCheckBiometrics) return false;
      return await a.authenticate(
        localizedReason: 'Unlock Bill Tracker',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }

  static Future<bool> verifyDialog(BuildContext context) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Enter your PIN'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          maxLength: 4,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Current PIN'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final good = await check(ctrl.text);
              if (c.mounted) Navigator.pop(c, good);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (!context.mounted) return ok == true;
    if (ok == false && ctrl.text.isNotEmpty) {
      final w = await waitLeft();
      if (context.mounted) toast(context, w > Duration.zero ? waitText(w) : 'That PIN is not right.');
    }
    return ok == true;
  }
}

Future<String?> setPinDialog(BuildContext context) async {
  final a = TextEditingController(), b = TextEditingController();
  String? err;
  return showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('Set a 4-digit PIN'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: a,
              autofocus: true,
              obscureText: true,
              maxLength: 4,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'New PIN')),
          TextField(
              controller: b,
              obscureText: true,
              maxLength: 4,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Repeat PIN')),
          if (err != null) Text(err!, style: TextStyle(color: Pal.of(c).bad)),
          const SizedBox(height: 4),
          Text('Fingerprint also unlocks once the lock is on.', style: TextStyle(fontSize: 12, color: Pal.of(c).muted)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (!RegExp(r'^\d{4}$').hasMatch(a.text)) return set(() => err = 'The PIN must be 4 digits.');
              if (a.text != b.text) return set(() => err = 'The two PINs do not match.');
              Navigator.pop(c, a.text);
            },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    ),
  );
}

/// Shows the lock screen over the app when needed.
class LockGate extends StatefulWidget {
  final Widget child;
  const LockGate({super.key, required this.child});
  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  DateTime? pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (AppStore.I.settings.lockOn) LockService.locked.value = true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final s = AppStore.I.settings;
      final at = pausedAt;
      pausedAt = null;
      if (s.lockOn && at != null && !LockService.isOutside) {
        if (DateTime.now().difference(at).inSeconds >= s.lockAfter * 60) LockService.locked.value = true;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: LockService.locked,
      builder: (context, locked, child) => Stack(children: [
        child!,
        if (locked) const Positioned.fill(child: LockScreen()),
      ]),
      child: widget.child,
    );
  }
}

class LockScreen extends StatefulWidget {
  const LockScreen({super.key});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String pin = '';
  bool wrong = false;
  Duration wait = Duration.zero;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _refreshWait();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bio());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _refreshWait() async {
    final w = await LockService.waitLeft();
    if (!mounted) return;
    setState(() => wait = w);
    _tick?.cancel();
    if (w > Duration.zero) _tick = Timer(const Duration(seconds: 1), _refreshWait);
  }

  Future<void> _bio() async {
    if (await LockService.biometric()) {
      await LockService.resetFails();
      LockService.locked.value = false;
    }
  }

  Future<void> _digit(String d) async {
    if (pin.length >= 4 || wait > Duration.zero) return;
    setState(() {
      pin += d;
      wrong = false;
    });
    if (pin.length == 4) {
      if (await LockService.check(pin)) {
        LockService.locked.value = false;
      } else {
        setState(() {
          pin = '';
          wrong = true;
        });
        await _refreshWait();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme, p = Pal.of(context);
    Widget key(Widget child, VoidCallback onTap, {bool plain = false}) => SizedBox(
          width: 72,
          height: 72,
          child: Material(
            shape: CircleBorder(side: plain ? BorderSide.none : BorderSide(color: p.line)),
            color: plain ? Colors.transparent : cs.surface,
            child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: Center(child: child)),
          ),
        );
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(16)),
                child: Icon(Icons.receipt_long, color: cs.onPrimary),
              ),
              const SizedBox(height: 12),
              const Text('Bill Tracker is locked', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                  wait > Duration.zero
                      ? LockService.waitText(wait)
                      : wrong
                          ? 'Wrong PIN. Try again.'
                          : 'Enter your PIN',
                  style: TextStyle(
                      color: wrong || wait > Duration.zero ? p.bad : p.muted,
                      fontWeight: wrong || wait > Duration.zero ? FontWeight.w600 : FontWeight.w400)),
              const SizedBox(height: 20),
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (var i = 0; i < 4; i++)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: cs.onSurface, width: 2),
                      color: i < pin.length ? cs.onSurface : Colors.transparent,
                    ),
                  ),
              ]),
              const SizedBox(height: 28),
              for (final row in [
                ['1', '2', '3'],
                ['4', '5', '6'],
                ['7', '8', '9']
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    for (final d in row)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: key(Text(d, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)), () => _digit(d)),
                      ),
                  ]),
                ),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: key(const Icon(Icons.fingerprint, size: 32), _bio, plain: true)),
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: key(const Text('0', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600)), () => _digit('0'))),
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: key(const Icon(Icons.backspace_outlined), () {
                      if (pin.isNotEmpty) setState(() => pin = pin.substring(0, pin.length - 1));
                    }, plain: true)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
