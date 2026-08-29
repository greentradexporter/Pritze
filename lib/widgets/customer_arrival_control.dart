import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../models/app_models.dart';
import '../state/app_state_scope.dart';
import '../theme/app_theme.dart';
import 'app_error_dialog.dart';

class CustomerArrivalControl extends StatefulWidget {
  final Booking booking;

  const CustomerArrivalControl({super.key, required this.booking});

  @override
  State<CustomerArrivalControl> createState() => _CustomerArrivalControlState();
}

class _CustomerArrivalControlState extends State<CustomerArrivalControl> {
  StreamSubscription<Position>? _positionSubscription;
  bool _working = false;
  String _error = '';
  DateTime? _lastSentAt;

  @override
  void initState() {
    super.initState();
    if (widget.booking.arrivalSharingActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resumeSharing());
    }
  }

  @override
  void didUpdateWidget(CustomerArrivalControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.booking.arrivalSharingActive &&
        oldWidget.booking.arrivalSharingActive) {
      unawaited(_positionSubscription?.cancel());
      _positionSubscription = null;
    }
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sharing = widget.booking.arrivalSharingActive;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(15),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.primary.withAlpha(36)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.near_me_outlined, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Arrival update',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _ArrivalPill(status: widget.booking.arrivalStatus),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Tell the salon where you are in your journey. Location sharing is optional.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                _statusButton(CustomerArrivalStatus.leavingNow),
                _statusButton(CustomerArrivalStatus.onTheWay),
                _statusButton(CustomerArrivalStatus.runningLate),
                _statusButton(CustomerArrivalStatus.arrived),
              ],
            ),
            const SizedBox(height: 12),
            if (sharing)
              Row(
                children: [
                  const Icon(
                    Icons.location_on_outlined,
                    size: 18,
                    color: AppColors.success,
                  ),
                  const SizedBox(width: 7),
                  const Expanded(
                    child: Text(
                      'Live location is shared while this app is open.',
                    ),
                  ),
                  TextButton(
                    onPressed: _working ? null : _stopSharing,
                    child: const Text('Stop'),
                  ),
                ],
              )
            else
              OutlinedButton.icon(
                onPressed: _working ? null : _askToShare,
                icon: const Icon(Icons.share_location_outlined),
                label: const Text('Share live location'),
              ),
            if (_working) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _error,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 7),
            Text(
              'Privacy: foreground only, no location history, stops automatically within 1 hour or when you tap Arrived.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusButton(CustomerArrivalStatus status) {
    final selected = widget.booking.arrivalStatus == status;
    return ChoiceChip(
      label: Text(status.label),
      selected: selected,
      onSelected: _working ? null : (_) => _setStatus(status),
    );
  }

  Future<void> _setStatus(CustomerArrivalStatus status) async {
    setState(() {
      _working = true;
      _error = '';
    });
    try {
      await AppStateScope.read(
        context,
      ).updateCustomerArrivalStatus(widget.booking.id, status);
      if (status == CustomerArrivalStatus.arrived) {
        await _positionSubscription?.cancel();
        _positionSubscription = null;
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _askToShare() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Share live location?'),
        content: const Text(
          'Pritze will share only your latest location with the salon administrator while this app is open. It expires automatically, and you can stop at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await _startSharing();
  }

  Future<void> _startSharing() async {
    final appState = AppStateScope.read(context);
    final bookingId = widget.booking.id;
    setState(() {
      _working = true;
      _error = '';
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('Turn on location services to share your journey.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError(
          permission == LocationPermission.deniedForever
              ? 'Location access is blocked. Enable it in device settings.'
              : 'Location permission was not granted.',
        );
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      await appState.startCustomerArrivalSharing(
        bookingId,
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
        speedMetersPerSecond: position.speed,
        capturedAt: position.timestamp,
      );
      await _listenForLocation();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _resumeSharing() async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always) {
      await _listenForLocation();
    }
  }

  Future<void> _listenForLocation() async {
    final appState = AppStateScope.read(context);
    final bookingId = widget.booking.id;
    await _positionSubscription?.cancel();
    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 50,
          ),
        ).listen((position) async {
          final now = DateTime.now();
          if (_lastSentAt != null &&
              now.difference(_lastSentAt!).inSeconds < 20) {
            return;
          }
          _lastSentAt = now;
          try {
            await appState.updateCustomerArrivalLocation(
              bookingId,
              latitude: position.latitude,
              longitude: position.longitude,
              accuracyMeters: position.accuracy,
              speedMetersPerSecond: position.speed,
              capturedAt: position.timestamp,
            );
          } catch (error) {
            if (mounted) setState(() => _error = _message(error));
          }
        });
  }

  Future<void> _stopSharing() async {
    final appState = AppStateScope.read(context);
    final bookingId = widget.booking.id;
    setState(() {
      _working = true;
      _error = '';
    });
    try {
      await _positionSubscription?.cancel();
      _positionSubscription = null;
      await appState.stopCustomerArrivalSharing(bookingId);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _message(Object error) => friendlyErrorMessage(
    error,
    fallback: 'Your arrival status could not be updated. Please try again.',
  );
}

class _ArrivalPill extends StatelessWidget {
  final CustomerArrivalStatus status;

  const _ArrivalPill({required this.status});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(26),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(
          status.label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: AppColors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
