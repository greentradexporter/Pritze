import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../theme/app_theme.dart';
import 'status_chip.dart';

class BookingStatusTimeline extends StatelessWidget {
  final BookingStatus status;
  final bool compact;

  const BookingStatusTimeline({
    super.key,
    required this.status,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final steps = _stepsFor(status);

    return Semantics(
      label: 'Booking status: ${status.label}',
      child: Row(
        key: ValueKey('booking-status-timeline-${status.name}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < steps.length; index++) ...[
            Expanded(
              child: _TimelineStep(step: steps[index], compact: compact),
            ),
            if (index < steps.length - 1)
              _TimelineConnector(
                active: steps[index].state == _StepState.done,
                compact: compact,
              ),
          ],
        ],
      ),
    );
  }
}

class CurrentBookingBottomPanel extends StatelessWidget {
  final Booking booking;
  final VoidCallback onTap;

  const CurrentBookingBottomPanel({
    super.key,
    required this.booking,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('current-booking-bottom-panel'),
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 9),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.line)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.receipt_long_outlined,
                    size: 19,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Current booking · ${booking.resolvedServiceName()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  StatusChip(status: booking.status),
                ],
              ),
              if (booking.isInstant &&
                  booking.status != BookingStatus.cancelled &&
                  booking.status != BookingStatus.rejected) ...[
                const SizedBox(height: 7),
                _BookingArrivalTimerLine(
                  booking: booking,
                  audience: BookingTimerAudience.customer,
                ),
              ],
              const SizedBox(height: 9),
              BookingStatusTimeline(status: booking.status, compact: true),
            ],
          ),
        ),
      ),
    );
  }
}

enum BookingTimerAudience { customer, salon, barber }

class BookingArrivalBottomPanel extends StatelessWidget {
  final Booking booking;
  final BookingTimerAudience audience;
  final VoidCallback onTap;

  const BookingArrivalBottomPanel({
    super.key,
    required this.booking,
    required this.audience,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final audienceLabel = switch (audience) {
      BookingTimerAudience.customer => 'Your instant booking',
      BookingTimerAudience.salon => 'Incoming customer',
      BookingTimerAudience.barber => 'Your next customer',
    };
    return Material(
      key: ValueKey('booking-arrival-bottom-panel-${audience.name}'),
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.line)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.timer_outlined,
                    size: 19,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$audienceLabel · ${booking.customerName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  StatusChip(status: booking.status),
                ],
              ),
              const SizedBox(height: 7),
              _BookingArrivalTimerLine(booking: booking, audience: audience),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookingArrivalTimerLine extends StatefulWidget {
  final Booking booking;
  final BookingTimerAudience audience;

  const _BookingArrivalTimerLine({
    required this.booking,
    required this.audience,
  });

  @override
  State<_BookingArrivalTimerLine> createState() =>
      _BookingArrivalTimerLineState();
}

class _BookingArrivalTimerLineState extends State<_BookingArrivalTimerLine> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    final refreshInterval = widget.audience == BookingTimerAudience.customer
        ? const Duration(seconds: 1)
        : const Duration(minutes: 1);
    _timer = Timer.periodic(refreshInterval, (_) {
      if (mounted) {
        setState(() => _now = DateTime.now());
      }
    });
  }

  @override
  void didUpdateWidget(covariant _BookingArrivalTimerLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.booking.id != widget.booking.id ||
        oldWidget.booking.start != widget.booking.start) {
      _now = DateTime.now();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.booking.start.difference(_now);
    final countdown = _countdownLabel(remaining);
    final text = switch (widget.audience) {
      BookingTimerAudience.customer =>
        remaining.isNegative
            ? 'Your booking starts now'
            : 'Reach the salon in $countdown',
      BookingTimerAudience.salon =>
        remaining.isNegative
            ? 'Customer arrival time reached'
            : 'Customer ETA $countdown',
      BookingTimerAudience.barber =>
        remaining.isNegative
            ? 'Customer arrival time reached'
            : 'Customer ETA $countdown',
    };
    final selectedWindow =
        '${widget.booking.customerArrivalMinutes} min selected';
    final salonWindow =
        '${widget.booking.salonArrivalMinutes} min salon window';
    final subtitle = widget.audience == BookingTimerAudience.customer
        ? selectedWindow
        : '$selectedWindow · $salonWindow';

    return Row(
      children: [
        Expanded(
          child: Text(
            '$text · $subtitle',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: remaining.isNegative
                  ? AppColors.coral
                  : AppColors.primaryDark,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  String _countdownLabel(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 24 * 60 * 60);
    if (widget.audience != BookingTimerAudience.customer) {
      final minutes = (totalSeconds / 60).ceil();
      return '$minutes min';
    }
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}

enum _StepState { upcoming, current, done, failed }

class _TimelineStepData {
  final String label;
  final _StepState state;

  const _TimelineStepData(this.label, this.state);
}

List<_TimelineStepData> _stepsFor(BookingStatus status) {
  switch (status) {
    case BookingStatus.pending:
      return const [
        _TimelineStepData('Booking sent', _StepState.done),
        _TimelineStepData('Salon response', _StepState.current),
        _TimelineStepData('Appointment', _StepState.upcoming),
      ];
    case BookingStatus.confirmed:
      return const [
        _TimelineStepData('Booking sent', _StepState.done),
        _TimelineStepData('Accepted', _StepState.current),
        _TimelineStepData('Appointment', _StepState.upcoming),
      ];
    case BookingStatus.inProgress:
      return const [
        _TimelineStepData('Booking sent', _StepState.done),
        _TimelineStepData('Accepted', _StepState.done),
        _TimelineStepData('In service', _StepState.current),
      ];
    case BookingStatus.completed:
      return const [
        _TimelineStepData('Booking sent', _StepState.done),
        _TimelineStepData('Accepted', _StepState.done),
        _TimelineStepData('Completed', _StepState.done),
      ];
    case BookingStatus.rejected:
      return const [
        _TimelineStepData('Booking sent', _StepState.done),
        _TimelineStepData('Rejected', _StepState.failed),
      ];
    case BookingStatus.cancelled:
      return const [
        _TimelineStepData('Booking sent', _StepState.done),
        _TimelineStepData('Cancelled', _StepState.failed),
      ];
  }
}

class _TimelineStep extends StatelessWidget {
  final _TimelineStepData step;
  final bool compact;

  const _TimelineStep({required this.step, required this.compact});

  @override
  Widget build(BuildContext context) {
    final color = switch (step.state) {
      _StepState.done => AppColors.success,
      _StepState.current => AppColors.goldDeep,
      _StepState.failed => AppColors.coral,
      _StepState.upcoming => AppColors.muted,
    };
    final icon = switch (step.state) {
      _StepState.done => Icons.check,
      _StepState.failed => Icons.close,
      _StepState.current => Icons.circle,
      _StepState.upcoming => Icons.circle_outlined,
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: compact ? 22 : 26,
          height: compact ? 22 : 26,
          decoration: BoxDecoration(
            color: step.state == _StepState.upcoming
                ? Colors.white
                : color.withAlpha(24),
            border: Border.all(color: color, width: 1.5),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: compact ? 12 : 14, color: color),
        ),
        const SizedBox(height: 5),
        Text(
          step.label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: color,
            fontSize: 14,
            fontWeight:
                step.state == _StepState.current ||
                    step.state == _StepState.failed
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

class _TimelineConnector extends StatelessWidget {
  final bool active;
  final bool compact;

  const _TimelineConnector({required this.active, required this.compact});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: compact ? 18 : 24,
      height: 2,
      margin: EdgeInsets.only(top: compact ? 10 : 12),
      color: active ? AppColors.success : AppColors.line,
    );
  }
}
