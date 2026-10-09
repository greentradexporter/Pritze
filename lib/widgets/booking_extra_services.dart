import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../state/app_state_scope.dart';
import 'app_error_dialog.dart';

class BookingExtraServices extends StatefulWidget {
  const BookingExtraServices({super.key, required this.booking});
  final Booking booking;
  @override
  State<BookingExtraServices> createState() => _BookingExtraServicesState();
}

class _BookingExtraServicesState extends State<BookingExtraServices> {
  bool _busy = false;
  String? _error;

  Future<void> _respond(String action) async {
    if (_busy) return;
    final pending = widget.booking.extraServiceRequest;
    if (pending == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppStateScope.read(context).updateBookingExtraServices(
        bookingId: widget.booking.id,
        requestId: pending.id,
        action: action,
      );
    } catch (error) {
      if (mounted) setState(() => _error = friendlyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.booking.status != BookingStatus.inProgress) {
      return const SizedBox.shrink();
    }
    final state = AppStateScope.watch(context);
    final pending = widget.booking.extraServiceRequest;
    final proposedByMe = pending?.proposedByRole == state.activeRole?.name;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Current total: ₹${widget.booking.customerPayableAmount}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (pending == null)
            OutlinedButton.icon(
              key: ValueKey('add-service-${widget.booking.id}'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _AddServicesDialog(booking: widget.booking),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Add a service'),
            )
          else ...[
            const SizedBox(height: 8),
            Text(
              '${pending.names.values.join(', ')} · +₹${pending.amount} · ${pending.durationMinutes} min',
            ),
            Text(
              'Total after approval: ₹${widget.booking.customerPayableAmount + pending.amount}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(
              proposedByMe
                  ? 'Waiting for the ${pending.proposedByRole == 'owner' ? 'customer' : 'salon'} to approve. Unapproved additions are not charged.'
                  : 'The ${pending.proposedByRole == 'owner' ? 'salon' : 'customer'} requested these extra services. Review the price before approving.',
            ),
            Wrap(
              spacing: 8,
              children: [
                if (proposedByMe)
                  TextButton(
                    onPressed: _busy ? null : () => _respond('cancel'),
                    child: const Text('Cancel addition'),
                  )
                else ...[
                  FilledButton(
                    onPressed: _busy ? null : () => _respond('approve'),
                    child: const Text('Approve addition'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _respond('reject'),
                    child: const Text('Decline addition'),
                  ),
                ],
              ],
            ),
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}

class _AddServicesDialog extends StatefulWidget {
  const _AddServicesDialog({required this.booking});
  final Booking booking;
  @override
  State<_AddServicesDialog> createState() => _AddServicesDialogState();
}

class _AddServicesDialogState extends State<_AddServicesDialog> {
  final _selected = <String>{};
  // Retained across retries so a response lost after commit cannot double-add.
  final _requestId = 'extra_${DateTime.now().microsecondsSinceEpoch}';
  bool _busy = false;
  String? _error;

  Future<void> _submit(List<SalonService> services) async {
    if (_busy || _selected.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppStateScope.read(context).updateBookingExtraServices(
        bookingId: widget.booking.id,
        requestId: _requestId,
        action: 'propose',
        expectedPrices: {
          for (final service in services.where((s) => _selected.contains(s.id)))
            service.id: service.price,
        },
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.watch(context);
    final booking =
        state.bookings.where((b) => b.id == widget.booking.id).firstOrNull ??
        widget.booking;
    final barber = state.getBarber(booking.barberId);
    final services =
        (state.getSalon(booking.salonId)?.services ?? <SalonService>[])
            .where(
              (service) =>
                  service.isAvailable &&
                  !booking.resolvedServiceIds.contains(service.id) &&
                  (barber?.serviceIds.contains(service.id) ?? false),
            )
            .toList();
    final selected = services.where((s) => _selected.contains(s.id)).toList();
    final extra = selected.fold<int>(0, (sum, service) => sum + service.price);
    final ready =
        booking.status == BookingStatus.inProgress &&
        booking.extraServiceRequest == null;
    return AlertDialog(
      title: const Text('Add services to this visit'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The other person must approve the additional price. Your existing discount and Proin stay applied; extra services use the prices below.',
              ),
              if (services.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'No additional services are available with this barber.',
                  ),
                ),
              for (final service in services)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(service.name),
                  subtitle: Text(
                    '₹${service.price} · ${service.durationMinutes} min',
                  ),
                  value: _selected.contains(service.id),
                  onChanged: _busy
                      ? null
                      : (checked) => setState(() {
                          if (checked == true) {
                            _selected.add(service.id);
                          } else {
                            _selected.remove(service.id);
                          }
                        }),
                ),
              const Divider(),
              Text('Current total: ₹${booking.customerPayableAmount}'),
              Text('Additional services: ₹$extra'),
              Text(
                'Total after approval: ₹${booking.customerPayableAmount + extra}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (!ready)
                const Text(
                  'This visit or its pending request has changed. Close this window to see the latest details.',
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy || selected.isEmpty || !ready
              ? null
              : () => _submit(services),
          child: Text(_busy ? 'Sending...' : 'Request addition'),
        ),
      ],
    );
  }
}
