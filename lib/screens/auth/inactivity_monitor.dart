import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../services/inactivity_service.dart';

class InactivityMonitor extends StatefulWidget {
  final Widget child;
  final GoRouter router;
  const InactivityMonitor({super.key, required this.child, required this.router});
  @override
  State<InactivityMonitor> createState() => _InactivityMonitorState();
}
class _InactivityMonitorState extends State<InactivityMonitor> with WidgetsBindingObserver {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_key);
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => widget.router.refresh());
  }
  bool _key(KeyEvent event) { if (event is KeyDownEvent) _activity(); return false; }
  void _activity() {
    // Check expiry before recording any new interaction.
    // Record activity without forcing a synchronous router rebuild while a
    // TextField/Overlay is handling the same pointer or focus event.
    unawaited(InactivityService.instance.activity().catchError((Object _) {}));
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.router.refresh();
  }
  @override
  void dispose() {
    _timer?.cancel();
    HardwareKeyboard.instance.removeHandler(_key);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _activity(), onPointerSignal: (_) => _activity(),
    child: widget.child,
  );
}
