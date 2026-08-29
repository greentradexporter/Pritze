import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../state/app_state_scope.dart';
import '../theme/app_theme.dart';
import 'status_chip.dart';

class BookingStatusTimeline extends StatelessWidget {
  final BookingStatus status;
  final bool compact;
  final bool isInstant;

  const BookingStatusTimeline({
    super.key,
    required this.status,
    this.compact = false,
    this.isInstant = false,
  });

  @override
  Widget build(BuildContext context) {
    final steps = _stepsFor(status, isInstant: isInstant);

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
    final accent = _bookingPanelAccent(booking.status);
    return _BookingBottomCardShell(
      key: const Key('current-booking-bottom-panel'),
      accent: accent,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _BookingPanelIcon(
                icon: booking.isInstant
                    ? Icons.bolt_rounded
                    : Icons.event_available_rounded,
                accent: accent,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      booking.isInstant ? 'INSTANT BOOKING' : 'CURRENT BOOKING',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      booking.resolvedServiceName(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppColors.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusChip(status: booking.status),
            ],
          ),
          if (booking.isInstant &&
              (booking.status == BookingStatus.pending ||
                  booking.status == BookingStatus.confirmed)) ...[
            const SizedBox(height: 10),
            _BookingPanelInset(
              child: booking.status == BookingStatus.pending
                  ? const _PendingSalonResponseLine()
                  : _BookingArrivalTimerLine(
                      booking: booking,
                      audience: BookingTimerAudience.customer,
                    ),
            ),
          ],
          if (booking.status == BookingStatus.inProgress) ...[
            const SizedBox(height: 10),
            const _BookingPanelInset(child: _ServicePayablePendingLine()),
          ],
          const SizedBox(height: 11),
          _BookingPanelInset(
            child: BookingStatusTimeline(
              status: booking.status,
              compact: true,
              isInstant: booking.isInstant,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              Text(
                'View booking',
                key: const ValueKey('booking-panel-view-action'),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 3),
              Icon(Icons.arrow_forward_rounded, size: 18, color: accent),
            ],
          ),
        ],
      ),
    );
  }
}

class CustomerActiveBookingFooter extends StatelessWidget {
  final Widget? action;
  final VoidCallback onOpenBooking;

  const CustomerActiveBookingFooter({
    super.key,
    this.action,
    required this.onOpenBooking,
  });

  @override
  Widget build(BuildContext context) {
    final booking = AppStateScope.watch(context).activeCustomerBooking;
    final footerAction = action;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (booking != null)
          CurrentBookingBottomPanel(booking: booking, onTap: onOpenBooking),
        ?footerAction,
      ],
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
    final accent = _bookingPanelAccent(booking.status);
    return _BookingBottomCardShell(
      key: ValueKey('booking-arrival-bottom-panel-${audience.name}'),
      accent: accent,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _BookingPanelIcon(icon: Icons.timer_rounded, accent: accent),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      audienceLabel.toUpperCase(),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      booking.customerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppColors.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusChip(status: booking.status),
            ],
          ),
          const SizedBox(height: 10),
          _BookingPanelInset(
            child: booking.status == BookingStatus.pending
                ? const _PendingOwnerDecisionLine()
                : _BookingArrivalTimerLine(
                    booking: booking,
                    audience: audience,
                  ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              Text(
                'Open booking',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 3),
              Icon(Icons.arrow_forward_rounded, size: 18, color: accent),
            ],
          ),
        ],
      ),
    );
  }
}

class _BookingBottomCardShell extends StatelessWidget {
  final Color accent;
  final VoidCallback onTap;
  final Widget child;

  const _BookingBottomCardShell({
    super.key,
    required this.accent,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(18));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 12, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryDark.withAlpha(28),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white, AppColors.champagne.withAlpha(205)],
              ),
              borderRadius: radius,
              border: Border.all(color: accent.withAlpha(72)),
            ),
            child: InkWell(
              onTap: onTap,
              borderRadius: radius,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 14, 10),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BookingPanelIcon extends StatelessWidget {
  final IconData icon;
  final Color accent;

  const _BookingPanelIcon({required this.icon, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(13),
        boxShadow: [
          BoxShadow(
            color: accent.withAlpha(45),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: 22),
    );
  }
}

class _BookingPanelInset extends StatelessWidget {
  final Widget child;

  const _BookingPanelInset({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(190),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white),
      ),
      child: child,
    );
  }
}

class _PendingSalonResponseLine extends StatelessWidget {
  const _PendingSalonResponseLine();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Waiting for the salon to accept. Your reach-by time will appear after confirmation.',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: AppColors.goldDeep,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _PendingOwnerDecisionLine extends StatelessWidget {
  const _PendingOwnerDecisionLine();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Accept or reject this request. The customer reach-by time will be set after acceptance.',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: AppColors.goldDeep,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _ServicePayablePendingLine extends StatelessWidget {
  const _ServicePayablePendingLine();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.payments_outlined, size: 18, color: AppColors.blue),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Your final payable amount will be shown after the salon ends the service.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.primaryDark,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

Color _bookingPanelAccent(BookingStatus status) => switch (status) {
  BookingStatus.pending => AppColors.goldDeep,
  BookingStatus.confirmed => AppColors.leaf,
  BookingStatus.inProgress => AppColors.blue,
  BookingStatus.completed => AppColors.success,
  BookingStatus.cancelled || BookingStatus.rejected => AppColors.coral,
};

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
    _timer = Timer.periodic(const Duration(minutes: 3), (_) {
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
    final deadline = widget.audience == BookingTimerAudience.salon
        ? widget.booking.salonArrivalDeadline
        : widget.booking.start;
    final remaining = deadline.difference(_now);
    final deadlineLabel = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(deadline));
    final remainingLabel = _remainingLabel(remaining);
    final text = switch (widget.audience) {
      BookingTimerAudience.customer =>
        remaining.isNegative
            ? 'Reach-by time was $deadlineLabel'
            : 'Reach by $deadlineLabel · $remainingLabel',
      BookingTimerAudience.salon =>
        remaining.isNegative
            ? 'Salon arrival window was $deadlineLabel'
            : 'Expect customer by $deadlineLabel · $remainingLabel',
      BookingTimerAudience.barber =>
        remaining.isNegative
            ? 'Customer arrival time was $deadlineLabel'
            : 'Customer expected by $deadlineLabel · $remainingLabel',
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

  String _remainingLabel(Duration duration) {
    final minutes = (duration.inSeconds / 60).ceil().clamp(0, 24 * 60);
    if (minutes < 1) {
      return 'under 1 min remaining';
    }
    return 'about $minutes min remaining';
  }
}

enum _StepState { upcoming, current, done, failed }

class _TimelineStepData {
  final String label;
  final _StepState state;

  const _TimelineStepData(this.label, this.state);
}

List<_TimelineStepData> _stepsFor(
  BookingStatus status, {
  required bool isInstant,
}) {
  switch (status) {
    case BookingStatus.pending:
      return const [
        _TimelineStepData('Booking sent', _StepState.done),
        _TimelineStepData('Salon response', _StepState.current),
        _TimelineStepData('Appointment', _StepState.upcoming),
      ];
    case BookingStatus.confirmed:
      return isInstant
          ? const [
              _TimelineStepData('Request sent', _StepState.done),
              _TimelineStepData('Accepted', _StepState.done),
              _TimelineStepData('Appointment', _StepState.current),
            ]
          : const [
              _TimelineStepData('Confirmed', _StepState.done),
              _TimelineStepData('Appointment', _StepState.current),
            ];
    case BookingStatus.inProgress:
      return [
        _TimelineStepData(
          isInstant ? 'Accepted' : 'Confirmed',
          _StepState.done,
        ),
        const _TimelineStepData('In service', _StepState.current),
      ];
    case BookingStatus.completed:
      return [
        _TimelineStepData(
          isInstant ? 'Accepted' : 'Confirmed',
          _StepState.done,
        ),
        const _TimelineStepData('Completed', _StepState.done),
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
