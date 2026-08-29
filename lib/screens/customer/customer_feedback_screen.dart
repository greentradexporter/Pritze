import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_error_dialog.dart';

class CustomerFeedbackScreen extends StatefulWidget {
  final Booking booking;

  const CustomerFeedbackScreen({super.key, required this.booking});

  @override
  State<CustomerFeedbackScreen> createState() => _CustomerFeedbackScreenState();
}

class _CustomerFeedbackScreenState extends State<CustomerFeedbackScreen> {
  final _noteController = TextEditingController();
  int _rating = 5;
  bool _submitting = false;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      await AppStateScope.read(context).submitSalonFeedback(
        bookingId: widget.booking.id,
        rating: _rating,
        note: _noteController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thank you for your feedback.')),
      );
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            friendlyErrorMessage(
              error,
              fallback: 'Feedback could not be sent. Please try again.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.getSalon(widget.booking.salonId);
    final alreadySubmitted = appState.customerSalonFeedback.any(
      (feedback) => feedback.bookingId == widget.booking.id,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Your feedback')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.champagne,
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Icon(
              Icons.reviews_rounded,
              size: 36,
              color: AppColors.goldDeep,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'How was your visit?',
            style: Theme.of(context).textTheme.headlineMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Tell ${salon?.name ?? 'the salon'} how your experience went.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var star = 1; star <= 5; star++)
                IconButton(
                  onPressed: alreadySubmitted
                      ? null
                      : () => setState(() => _rating = star),
                  icon: Icon(
                    star <= _rating
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    size: 38,
                    color: AppColors.amber,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _noteController,
            enabled: !alreadySubmitted,
            minLines: 4,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Add a note (optional)',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 22),
          if (alreadySubmitted)
            const Center(child: Text('Feedback already submitted.'))
          else
            FilledButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
              label: Text(_submitting ? 'Submitting...' : 'Submit feedback'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(alreadySubmitted ? 'Done' : 'Maybe later'),
          ),
        ],
      ),
    );
  }
}
