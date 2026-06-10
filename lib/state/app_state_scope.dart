import 'package:flutter/widgets.dart';

import 'app_state.dart';

class AppStateProvider extends StatefulWidget {
  final Widget child;
  final AppState Function()? createAppState;

  const AppStateProvider({super.key, required this.child, this.createAppState});

  @override
  State<AppStateProvider> createState() => _AppStateProviderState();
}

class _AppStateProviderState extends State<AppStateProvider> {
  late final AppState _state = widget.createAppState?.call() ?? AppState();

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(notifier: _state, child: widget.child);
  }
}

class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required super.notifier,
    required super.child,
  });

  static AppState watch(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'No AppStateScope found in context');
    return scope!.notifier!;
  }

  static AppState read(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<AppStateScope>();
    assert(element != null, 'No AppStateScope found in context');
    final scope = element!.widget as AppStateScope;
    return scope.notifier!;
  }
}
