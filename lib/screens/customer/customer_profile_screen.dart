import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/account_actions.dart';
import '../../widgets/app_bottom_nav.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/auth_login_panel.dart';
import 'customer_profile_editor.dart';
import 'my_bookings_screen.dart';

class CustomerProfileScreen extends StatelessWidget {
  const CustomerProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final account = appState.customerAccount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          CustomerNotificationButton(
            onNotificationOpened: (destination, {bookingId}) {
              if (destination == AppNotificationDestination.bookings) {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MyBookingsScreen()),
                );
              }
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: const AppBottomNav(selectedIndex: 1),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
        children: [
          if (account == null)
            _LoggedOutProfile(onLogin: () => _showLogin(context))
          else ...[
            _ProfileHero(
              account: account,
              onEdit: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CustomerProfileEditor(account: account),
                ),
              ),
            ),
            const SizedBox(height: 18),
            _PersonalDetails(account: account),
            if (account.stylePhotoUrls.isNotEmpty) ...[
              const SizedBox(height: 18),
              _StyleGallery(photoUrls: account.stylePhotoUrls),
            ],
            const SizedBox(height: 22),
            _SalonRatingsSection(
              account: account,
              ratings: appState.customerSalonRatings,
            ),
            const SizedBox(height: 18),
            _FeedbackSharedSection(feedback: appState.customerSalonFeedback),
          ],
          const SizedBox(height: 22),
          const SectionHeader(title: 'Account'),
          const SizedBox(height: 10),
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  key: const ValueKey('customer-profile-bookings'),
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('Bookings'),
                  subtitle: const Text('Upcoming, completed and cancelled'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const MyBookingsScreen()),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('customer-profile-notifications'),
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Notifications'),
                  subtitle: const Text('Booking and appointment updates'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openCustomerNotifications(context),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('customer-profile-support'),
                  leading: const Icon(Icons.support_agent_outlined),
                  title: const Text('Support'),
                  subtitle: const Text('Contact Pritze support'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showSupportSheet(context),
                ),
              ],
            ),
          ),
          if (account != null) ...[
            const SizedBox(height: 18),
            OutlinedButton.icon(
              key: const ValueKey('customer-profile-logout'),
              onPressed: () async {
                final didLogout = await confirmAndLogout(context);
                if (didLogout && context.mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(
                      builder: (_) => const CustomerProfileScreen(),
                    ),
                    (route) => false,
                  );
                }
              },
              icon: const Icon(Icons.logout),
              label: const Text('Log out'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showLogin(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          4,
          18,
          MediaQuery.viewInsetsOf(sheetContext).bottom + 18,
        ),
        child: SingleChildScrollView(
          child: AuthLoginPanel(
            role: UserRole.customer,
            embedded: true,
            onLoggedIn: () => Navigator.pop(sheetContext),
          ),
        ),
      ),
    );
  }
}

class _LoggedOutProfile extends StatelessWidget {
  final VoidCallback onLogin;

  const _LoggedOutProfile({required this.onLogin});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SoftIconBox(
            icon: Icons.person_outline,
            color: AppColors.primary,
            size: 52,
          ),
          const SizedBox(height: 12),
          Text(
            'Your account',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 5),
          Text(
            'Log in to manage your details, style preferences and bookings.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const ValueKey('customer-profile-login'),
            onPressed: onLogin,
            icon: const Icon(Icons.login),
            label: const Text('Log in'),
          ),
        ],
      ),
    );
  }
}

class _ProfileHero extends StatelessWidget {
  final UserAccount account;
  final VoidCallback onEdit;

  const _ProfileHero({required this.account, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, AppColors.champagne.withAlpha(210)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.gold.withAlpha(80)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 34,
            backgroundColor: AppColors.mint,
            foregroundColor: AppColors.primary,
            backgroundImage: account.photoUrl.isEmpty
                ? null
                : NetworkImage(account.photoUrl),
            child: account.photoUrl.isNotEmpty
                ? null
                : Text(
                    account.name.trim().isEmpty
                        ? 'C'
                        : account.name.trim().characters.first.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.name,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 3),
                Text(
                  account.contact,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (account.salonRatingCount > 0) ...[
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        color: AppColors.amber,
                        size: 18,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${account.salonRating.toStringAsFixed(1)} from ${account.salonRatingCount} salon ${account.salonRatingCount == 1 ? 'visit' : 'visits'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          IconButton.filledTonal(
            key: const ValueKey('edit-customer-profile'),
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit profile',
          ),
        ],
      ),
    );
  }
}

class _PersonalDetails extends StatelessWidget {
  final UserAccount account;

  const _PersonalDetails({required this.account});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'About you'),
          const SizedBox(height: 10),
          _ProfileDetail(
            icon: Icons.wc_outlined,
            label: 'Gender',
            value: account.gender.isEmpty
                ? 'Not added'
                : account.gender.replaceAll('-', ' '),
          ),
          const Divider(height: 20),
          _ProfileDetail(
            icon: Icons.cake_outlined,
            label: 'Birthdate',
            value: account.birthDate.isEmpty ? 'Not added' : account.birthDate,
          ),
          const Divider(height: 20),
          const _ProfileDetail(
            icon: Icons.auto_awesome_outlined,
            label: 'Preferred styles',
            value: '',
          ),
          const SizedBox(height: 8),
          if (account.preferredStyles.isEmpty)
            Text(
              'No preferences added yet.',
              style: Theme.of(context).textTheme.bodyMedium,
            )
          else
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final style in account.preferredStyles)
                  Chip(label: Text(style)),
              ],
            ),
        ],
      ),
    );
  }
}

class _ProfileDetail extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ProfileDetail({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primary, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (value.isNotEmpty)
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
      ],
    );
  }
}

class _StyleGallery extends StatelessWidget {
  final List<String> photoUrls;

  const _StyleGallery({required this.photoUrls});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Styles you like'),
        const SizedBox(height: 10),
        SizedBox(
          height: 112,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: photoUrls.length,
            separatorBuilder: (_, _) => const SizedBox(width: 9),
            itemBuilder: (context, index) => ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                photoUrls[index],
                width: 112,
                height: 112,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const ColoredBox(
                  color: AppColors.champagne,
                  child: SizedBox(
                    width: 112,
                    child: Icon(Icons.image_outlined),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SalonRatingsSection extends StatelessWidget {
  final UserAccount account;
  final List<CustomerSalonRating> ratings;

  const _SalonRatingsSection({required this.account, required this.ratings});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Ratings from salons'),
        const SizedBox(height: 10),
        GlassCard(
          child: ratings.isEmpty
              ? const Text('No salon has rated a completed visit yet.')
              : Column(
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.star_rounded,
                          color: AppColors.amber,
                          size: 30,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          account.salonRating.toStringAsFixed(1),
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(width: 6),
                        Text('across ${ratings.length} visits'),
                      ],
                    ),
                    for (final rating in ratings) ...[
                      const Divider(height: 22),
                      _RatingEntry(
                        salonName: rating.salonName,
                        rating: rating.rating,
                        note: rating.note,
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _FeedbackSharedSection extends StatelessWidget {
  final List<SalonFeedback> feedback;

  const _FeedbackSharedSection({required this.feedback});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Feedback you shared'),
        const SizedBox(height: 10),
        GlassCard(
          child: feedback.isEmpty
              ? const Text('Your completed-visit feedback will appear here.')
              : Column(
                  children: [
                    for (var index = 0; index < feedback.length; index++) ...[
                      if (index > 0) const Divider(height: 22),
                      _RatingEntry(
                        salonName: feedback[index].salonName,
                        rating: feedback[index].rating,
                        note: feedback[index].note,
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _RatingEntry extends StatelessWidget {
  final String salonName;
  final int rating;
  final String note;

  const _RatingEntry({
    required this.salonName,
    required this.rating,
    required this.note,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SoftIconBox(
          icon: Icons.storefront_outlined,
          color: AppColors.primary,
          size: 40,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(salonName, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 3),
              Row(
                children: [
                  for (var index = 0; index < 5; index++)
                    Icon(
                      index < rating
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: AppColors.amber,
                      size: 17,
                    ),
                ],
              ),
              if (note.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(note, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
