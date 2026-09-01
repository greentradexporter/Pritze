import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/app_models.dart';
import '../../models/service_catalog.dart';
import '../../state/app_state.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_error_dialog.dart';
import '../../widgets/service_icon.dart';
import '../customer/customer_home_screen.dart';

class SalonProfileSetupScreen extends StatefulWidget {
  const SalonProfileSetupScreen({super.key});

  @override
  State<SalonProfileSetupScreen> createState() =>
      _SalonProfileSetupScreenState();
}

class _SalonProfileSetupScreenState extends State<SalonProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _salonNameController = TextEditingController();
  final _ownerNameController = TextEditingController();
  final _addressController = TextEditingController();
  final _directionsUrlController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _openTimeController = TextEditingController();
  final _closeTimeController = TextEditingController();
  final _upiIdController = TextEditingController();
  List<String> _photoUrls = [];
  bool _loaded = false;
  bool _isSaving = false;
  bool _isImportingServices = false;
  bool _isUploadingPhotos = false;
  bool _isSavingPaymentDetails = false;
  bool _isUploadingPaymentQr = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) {
      return;
    }
    final appState = AppStateScope.read(context);
    final salon = appState.ownerSalon;
    _salonNameController.text = salon.name;
    _ownerNameController.text = salon.ownerName;
    _addressController.text = salon.address;
    _directionsUrlController.text = salon.directionsUrl;
    _phoneController.text = salon.phone.contains('@') ? '' : salon.phone;
    final ownerContact =
        AppStateScope.read(context).ownerAccount?.contact ?? '';
    _emailController.text = salon.email.isNotEmpty
        ? salon.email
        : (ownerContact.contains('@') ? ownerContact : '');
    _photoUrls = [...salon.photoUrls];
    _openTimeController.text = formatSalonClockTime(salon.openTime);
    _closeTimeController.text = formatSalonClockTime(salon.closeTime);
    _upiIdController.text = appState.ownerPaymentUpiId;
    _loaded = true;
    if (appState.ownerSalonOrNull != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        try {
          await appState.refreshOwnerPaymentDetails();
          if (mounted && _upiIdController.text.trim().isEmpty) {
            _upiIdController.text = appState.ownerPaymentUpiId;
          }
        } catch (error) {
          if (mounted) {
            await showAppErrorDialog(context, friendlyOnboardingError(error));
          }
        }
      });
    }
    if (appState.ownerSalonOrNull == null &&
        !hasCanonicalSalonServices(salon.services)) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        try {
          await AppStateScope.read(context).addOwnerServicesFromCatalog();
        } catch (error) {
          if (mounted) {
            await showAppErrorDialog(context, friendlyOnboardingError(error));
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _salonNameController.dispose();
    _ownerNameController.dispose();
    _addressController.dispose();
    _directionsUrlController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _openTimeController.dispose();
    _closeTimeController.dispose();
    _upiIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.ownerSalon;
    final isNewOnboarding = appState.ownerSalonOrNull == null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shop registration'),
        leading: isNewOnboarding
            ? IconButton(
                key: const ValueKey('exit-salon-onboarding-icon'),
                onPressed: _isSaving ? null : () => _returnToCustomerHome(),
                icon: const Icon(Icons.home_outlined),
                tooltip: 'Back to customer home',
              )
            : null,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
          children: [
            if (isNewOnboarding) ...[
              OutlinedButton.icon(
                key: const ValueKey('exit-salon-onboarding'),
                onPressed: _isSaving ? null : () => _returnToCustomerHome(),
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('Not a salon owner? Back to customer home'),
              ),
              const SizedBox(height: 16),
            ],
            const SectionHeader(title: 'Shop details'),
            const SizedBox(height: 10),
            GlassCard(
              child: Column(
                children: [
                  TextFormField(
                    key: const ValueKey('salon-registration-name-field'),
                    controller: _salonNameController,
                    decoration: const InputDecoration(
                      labelText: 'Salon name',
                      prefixIcon: Icon(Icons.storefront_outlined),
                    ),
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('salon-registration-owner-field'),
                    controller: _ownerNameController,
                    decoration: const InputDecoration(
                      labelText: 'Owner name',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('salon-registration-address-field'),
                    controller: _addressController,
                    minLines: 2,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Address',
                      prefixIcon: Icon(Icons.location_on_outlined),
                    ),
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _directionsUrlController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Google Maps or directions link',
                      hintText: 'https://maps.app.goo.gl/…',
                      helperText:
                          'Customers will open this link from Directions.',
                      prefixIcon: Icon(Icons.map_outlined),
                    ),
                    validator: _optionalWebLink,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Owner phone number',
                      helperText:
                          'Required for the salon profile, even if you signed in by email.',
                      prefixIcon: Icon(Icons.phone_outlined),
                    ),
                    validator: _phone,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    textCapitalization: TextCapitalization.none,
                    decoration: const InputDecoration(
                      labelText: 'Owner email address',
                      helperText:
                          'Required for the salon profile, even if you signed in by phone.',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                    validator: _email,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _openTimeController,
                          readOnly: true,
                          onTap: () => _pickSalonTime(
                            controller: _openTimeController,
                            fallback: const TimeOfDay(hour: 9, minute: 0),
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Opening',
                            prefixIcon: Icon(Icons.wb_sunny_outlined),
                            suffixIcon: Icon(Icons.keyboard_arrow_down),
                          ),
                          validator: _time,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          controller: _closeTimeController,
                          readOnly: true,
                          onTap: () => _pickSalonTime(
                            controller: _closeTimeController,
                            fallback: const TimeOfDay(hour: 20, minute: 0),
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Closing',
                            prefixIcon: Icon(Icons.nights_stay_outlined),
                            suffixIcon: Icon(Icons.keyboard_arrow_down),
                          ),
                          validator: _closingTime,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _isSaving ? null : () => _saveProfile(context),
                    icon: const Icon(Icons.save_outlined),
                    label: Text(
                      _isSaving ? 'Saving...' : 'Save shop registration',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const SectionHeader(title: 'Private payment details'),
            const SizedBox(height: 10),
            _SalonPaymentDetailsCard(
              upiIdController: _upiIdController,
              qrCodeUrl: appState.ownerPaymentQrCodeUrl,
              profileSaved: !isNewOnboarding,
              isSaving: _isSavingPaymentDetails,
              isUploadingQr: _isUploadingPaymentQr,
              upiValidator: _upiId,
              onSaveUpi: () => _savePaymentDetails(context),
              onUploadQr: () => _pickAndUploadPaymentQr(context),
              onRemoveQr: () => _removePaymentQr(context),
            ),
            const SizedBox(height: 24),
            SectionHeader(
              title: 'Salon photos',
              actionLabel: _photoUrls.isEmpty ? null : 'Add more',
              onAction: _isUploadingPhotos
                  ? null
                  : () => _pickAndUploadSalonPhotos(context),
            ),
            const SizedBox(height: 10),
            _SalonPhotoManager(
              photoUrls: _photoUrls,
              isUploading: _isUploadingPhotos,
              onAddPhotos: () => _pickAndUploadSalonPhotos(context),
              onRemovePhoto: (url) => _removeSalonPhoto(context, url),
            ),
            const SizedBox(height: 24),
            SectionHeader(title: 'Service menu'),
            const SizedBox(height: 10),
            GlassCard(
              color: AppColors.champagne.withAlpha(70),
              child: Row(
                children: [
                  const ServiceImageIcon(category: 'Haircut', size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Every salon uses the same 30-service Pritze menu. You can set each price, duration and availability.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    key: const ValueKey('salon-import-services-button'),
                    onPressed: _isSaving || _isImportingServices
                        ? null
                        : () => _showServiceImportSheet(context),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: Text(
                      _isImportingServices ? 'Restoring...' : 'View all 30',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            for (final service in salon.services) ...[
              _ServiceCard(service: service),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _returnToCustomerHome() async {
    await AppStateScope.read(context).signOutActiveUser();
    if (!mounted) {
      return;
    }
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const CustomerHomeScreen()),
      (_) => false,
    );
  }

  Future<void> _addMasterServices(BuildContext context) async {
    setState(() => _isImportingServices = true);
    try {
      final added = await AppStateScope.read(
        context,
      ).addOwnerServicesFromCatalog();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added == 0
                ? 'Master service menu is already added'
                : 'Added $added services from the Pritze master menu',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await showAppErrorDialog(context, friendlyOnboardingError(error));
    } finally {
      if (mounted) {
        setState(() => _isImportingServices = false);
      }
    }
  }

  Future<void> _showServiceImportSheet(BuildContext context) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return FractionallySizedBox(
          heightFactor: 0.82,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Standard service menu',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 6),
                Text(
                  'These exact 30 services are used by every salon. Adjust price, duration and availability after closing this list.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    children: [
                      for (final service in serviceCatalog)
                        ListTile(
                          leading: const Icon(Icons.check_circle_outline),
                          title: Text(service.name),
                          subtitle: Text(
                            '${service.category} · ₹${service.price} · ${service.durationMinutes} min',
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('salon-confirm-import-services-button'),
                    onPressed: () => Navigator.pop(sheetContext, true),
                    icon: const Icon(Icons.download_done),
                    label: const Text('Use this 30-service menu'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (confirmed == true && context.mounted) {
      await _addMasterServices(context);
    }
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Required';
    }
    return null;
  }

  String? _phone(String? value) {
    final requiredError = _required(value);
    if (requiredError != null) {
      return requiredError;
    }
    final trimmed = value!.trim();
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 8 || digits.length > 15 || digits.startsWith('0')) {
      return 'Enter a valid phone number';
    }
    return null;
  }

  String? _email(String? value) {
    final requiredError = _required(value);
    if (requiredError != null) {
      return requiredError;
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value!.trim())) {
      return 'Enter a valid email address';
    }
    return null;
  }

  String? _time(String? value) {
    final requiredError = _required(value);
    if (requiredError != null) {
      return requiredError;
    }
    final normalized = value!.trim().toUpperCase().replaceAll('.', '');
    final match = RegExp(
      r'^(\d{1,2})(?::(\d{2}))?\s*([AP]M)?$',
    ).firstMatch(normalized);
    if (match == null) {
      return 'Use 9:00 AM or 18:30';
    }
    final hour = int.tryParse(match.group(1) ?? '');
    final minute = int.tryParse(match.group(2) ?? '0');
    final period = match.group(3);
    if (hour == null ||
        minute == null ||
        minute > 59 ||
        (period == null ? hour > 23 : hour < 1 || hour > 12)) {
      return 'Enter a valid time';
    }
    return null;
  }

  String? _closingTime(String? value) {
    final error = _time(value);
    if (error != null) {
      return error;
    }
    final opening = _minutesForTime(_openTimeController.text);
    final closing = _minutesForTime(value!);
    if (opening != null && closing != null && closing <= opening) {
      return 'Must be after opening';
    }
    return null;
  }

  Future<void> _pickSalonTime({
    required TextEditingController controller,
    required TimeOfDay fallback,
  }) async {
    final selected = await showTimePicker(
      context: context,
      initialTime: _timeOfDay(controller.text) ?? fallback,
      helpText: controller == _openTimeController
          ? 'SELECT OPENING TIME'
          : 'SELECT CLOSING TIME',
    );
    if (selected == null || !mounted) {
      return;
    }
    final minute = selected.minute.toString().padLeft(2, '0');
    setState(
      () => controller.text = formatSalonClockTime('${selected.hour}:$minute'),
    );
  }

  TimeOfDay? _timeOfDay(String value) {
    final minutes = _minutesForTime(value);
    return minutes == null
        ? null
        : TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);
  }

  int? _minutesForTime(String value) {
    final normalized = value.trim().toUpperCase().replaceAll('.', '');
    final match = RegExp(
      r'^(\d{1,2})(?::(\d{2}))?\s*([AP]M)?$',
    ).firstMatch(normalized);
    if (match == null) {
      return null;
    }
    var hour = int.tryParse(match.group(1) ?? '');
    final minute = int.tryParse(match.group(2) ?? '0');
    final period = match.group(3);
    if (hour == null || minute == null || minute > 59) {
      return null;
    }
    if (period != null) {
      if (hour < 1 || hour > 12) {
        return null;
      }
      if (period == 'AM') {
        hour = hour == 12 ? 0 : hour;
      } else if (hour != 12) {
        hour += 12;
      }
    } else if (hour > 23) {
      return null;
    }
    return hour * 60 + minute;
  }

  Future<void> _saveProfile(BuildContext context) async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _isSaving = true);
    try {
      await AppStateScope.read(context).updateOwnerSalon(
        name: _salonNameController.text,
        ownerName: _ownerNameController.text,
        address: _addressController.text,
        directionsUrl: _directionsUrlController.text,
        phone: _phoneController.text,
        email: _emailController.text,
        logoUrl: '',
        photoUrls: _photoUrls,
        openTime: _openTimeController.text,
        closeTime: _closeTimeController.text,
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Listing saved')));
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await showAppErrorDialog(context, friendlyOnboardingError(error));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _pickAndUploadSalonPhotos(BuildContext context) async {
    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Save valid shop details before uploading photos.'),
        ),
      );
      return;
    }
    setState(() => _isUploadingPhotos = true);
    try {
      final appState = AppStateScope.read(context);
      await appState.updateOwnerSalon(
        name: _salonNameController.text,
        ownerName: _ownerNameController.text,
        address: _addressController.text,
        directionsUrl: _directionsUrlController.text,
        phone: _phoneController.text,
        email: _emailController.text,
        logoUrl: '',
        photoUrls: _photoUrls,
        openTime: _openTimeController.text,
        closeTime: _closeTimeController.text,
      );
      final photos = await ImagePicker().pickMultiImage(
        imageQuality: 82,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (photos.isEmpty) {
        return;
      }
      final uploadedUrls = <String>[];
      for (final photo in photos.take(8 - _photoUrls.length)) {
        final bytes = await photo.readAsBytes();
        final url = await appState.uploadOwnerSalonPhoto(
          bytes: bytes,
          fileName: photo.name,
          contentType: photo.mimeType,
        );
        uploadedUrls.add(url);
      }
      if (!context.mounted) {
        return;
      }
      setState(() {
        _photoUrls = [...appState.ownerSalon.photoUrls];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            uploadedUrls.length == 1
                ? 'Salon photo uploaded'
                : '${uploadedUrls.length} salon photos uploaded',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await showAppErrorDialog(context, friendlyOnboardingError(error));
    } finally {
      if (mounted) {
        setState(() => _isUploadingPhotos = false);
      }
    }
  }

  Future<void> _savePaymentDetails(BuildContext context) async {
    final error = _upiId(_upiIdController.text);
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    setState(() => _isSavingPaymentDetails = true);
    try {
      await AppStateScope.read(
        context,
      ).saveOwnerPaymentUpiId(_upiIdController.text);
      if (!context.mounted) return;
      _upiIdController.text = AppStateScope.read(context).ownerPaymentUpiId;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Private payment details saved')),
      );
    } catch (error) {
      if (context.mounted) {
        await showAppErrorDialog(context, friendlyOnboardingError(error));
      }
    } finally {
      if (mounted) setState(() => _isSavingPaymentDetails = false);
    }
  }

  Future<void> _pickAndUploadPaymentQr(BuildContext context) async {
    final appState = AppStateScope.read(context);
    if (appState.ownerSalonOrNull == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save the shop registration first.')),
      );
      return;
    }
    final upiError = _upiId(_upiIdController.text);
    if (upiError != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(upiError)));
      return;
    }
    setState(() => _isUploadingPaymentQr = true);
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 92,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (image == null) return;
      await appState.saveOwnerPaymentUpiId(_upiIdController.text);
      await appState.uploadOwnerPaymentQrCode(
        bytes: await image.readAsBytes(),
        fileName: image.name,
        contentType: image.mimeType,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Private payment QR code uploaded')),
      );
    } catch (error) {
      if (context.mounted) {
        await showAppErrorDialog(context, friendlyOnboardingError(error));
      }
    } finally {
      if (mounted) setState(() => _isUploadingPaymentQr = false);
    }
  }

  Future<void> _removePaymentQr(BuildContext context) async {
    setState(() => _isUploadingPaymentQr = true);
    try {
      await AppStateScope.read(context).removeOwnerPaymentQrCode();
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Payment QR code removed')));
    } catch (error) {
      if (context.mounted) {
        await showAppErrorDialog(context, friendlyOnboardingError(error));
      }
    } finally {
      if (mounted) setState(() => _isUploadingPaymentQr = false);
    }
  }

  Future<void> _removeSalonPhoto(BuildContext context, String photoUrl) async {
    setState(() => _isUploadingPhotos = true);
    try {
      await AppStateScope.read(context).removeOwnerSalonPhoto(photoUrl);
      if (!context.mounted) {
        return;
      }
      setState(() {
        _photoUrls = [...AppStateScope.read(context).ownerSalon.photoUrls];
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Salon photo removed')));
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await showAppErrorDialog(context, friendlyOnboardingError(error));
    } finally {
      if (mounted) {
        setState(() => _isUploadingPhotos = false);
      }
    }
  }

  String? _optionalWebLink(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      return 'Paste a complete link beginning with https://';
    }
    return null;
  }

  String? _upiId(String? value) {
    final normalized = value?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty) return null;
    if (normalized.length > 100 ||
        !RegExp(
          r'^[a-z0-9._-]{2,64}@[a-z][a-z0-9.-]{1,32}$',
        ).hasMatch(normalized)) {
      return 'Enter a valid UPI ID, for example salon@bank.';
    }
    return null;
  }
}

class _SalonPaymentDetailsCard extends StatelessWidget {
  final TextEditingController upiIdController;
  final String qrCodeUrl;
  final bool profileSaved;
  final bool isSaving;
  final bool isUploadingQr;
  final FormFieldValidator<String> upiValidator;
  final VoidCallback onSaveUpi;
  final VoidCallback onUploadQr;
  final VoidCallback onRemoveQr;

  const _SalonPaymentDetailsCard({
    required this.upiIdController,
    required this.qrCodeUrl,
    required this.profileSaved,
    required this.isSaving,
    required this.isUploadingQr,
    required this.upiValidator,
    required this.onSaveUpi,
    required this.onUploadQr,
    required this.onRemoveQr,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      color: AppColors.mint.withAlpha(35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SoftIconBox(
                icon: Icons.account_balance_wallet_outlined,
                color: AppColors.primary,
                size: 46,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'UPI payout details',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Only your salon account and the Pritze backend team can access these details. Customers cannot see them.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const AppPill(
                icon: Icons.lock_outline,
                label: 'Private',
                color: AppColors.primary,
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const ValueKey('salon-payment-upi-id-field'),
            controller: upiIdController,
            enabled: profileSaved && !isSaving,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            textCapitalization: TextCapitalization.none,
            validator: upiValidator,
            decoration: const InputDecoration(
              labelText: 'UPI ID',
              hintText: 'salonname@bank',
              helperText: 'Used privately by Pritze for salon payouts.',
              prefixIcon: Icon(Icons.alternate_email),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('save-salon-payment-upi-id'),
              onPressed: !profileSaved || isSaving ? null : onSaveUpi,
              icon: isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(isSaving ? 'Saving...' : 'Save UPI ID'),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Payment QR code',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          if (qrCodeUrl.isEmpty)
            Container(
              key: const ValueKey('salon-payment-qr-empty'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(190),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.line),
              ),
              child: const Column(
                children: [
                  Icon(
                    Icons.qr_code_2_rounded,
                    size: 42,
                    color: AppColors.muted,
                  ),
                  SizedBox(height: 7),
                  Text('No payment QR code uploaded'),
                ],
              ),
            )
          else
            Center(
              child: Container(
                key: const ValueKey('salon-payment-qr-preview'),
                width: 220,
                height: 220,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.line),
                ),
                child: Image.network(
                  qrCodeUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(Icons.broken_image_outlined, size: 42),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('upload-salon-payment-qr'),
                  onPressed: !profileSaved || isUploadingQr ? null : onUploadQr,
                  icon: isUploadingQr
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_file_outlined),
                  label: Text(
                    isUploadingQr
                        ? 'Uploading...'
                        : qrCodeUrl.isEmpty
                        ? 'Upload QR image'
                        : 'Replace QR image',
                  ),
                ),
              ),
              if (qrCodeUrl.isNotEmpty) ...[
                const SizedBox(width: 8),
                IconButton.outlined(
                  key: const ValueKey('remove-salon-payment-qr'),
                  tooltip: 'Remove QR code',
                  onPressed: isUploadingQr ? null : onRemoveQr,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ],
          ),
          if (!profileSaved) ...[
            const SizedBox(height: 10),
            Text(
              'Save the shop registration first to add private payment details.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.coral,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SalonPhotoManager extends StatelessWidget {
  final List<String> photoUrls;
  final bool isUploading;
  final VoidCallback onAddPhotos;
  final ValueChanged<String> onRemovePhoto;

  const _SalonPhotoManager({
    required this.photoUrls,
    required this.isUploading,
    required this.onAddPhotos,
    required this.onRemovePhoto,
  });

  @override
  Widget build(BuildContext context) {
    final remaining = 8 - photoUrls.length;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SoftIconBox(
                icon: Icons.add_photo_alternate_outlined,
                color: AppColors.primary,
                size: 46,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Show customers your shop',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      photoUrls.isEmpty
                          ? 'Upload real salon photos. First photo becomes the cover image.'
                          : '${photoUrls.length}/8 photos uploaded · first photo is the cover.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (photoUrls.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.mint.withAlpha(55),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.primary.withAlpha(35)),
              ),
              child: Column(
                children: [
                  Icon(
                    Icons.photo_library_outlined,
                    color: AppColors.primary.withAlpha(210),
                    size: 34,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'No salon photos yet',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Add reception, chairs, interiors, or finished work photos.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            )
          else
            GridView.builder(
              itemCount: photoUrls.length,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.22,
              ),
              itemBuilder: (context, index) {
                final url = photoUrls[index];
                return _SalonPhotoTile(
                  url: url,
                  isCover: index == 0,
                  canRemove: !isUploading,
                  onRemove: () => onRemovePhoto(url),
                );
              },
            ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: isUploading || remaining <= 0 ? null : onAddPhotos,
              icon: isUploading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload_outlined),
              label: Text(
                isUploading
                    ? 'Uploading photos...'
                    : remaining <= 0
                    ? 'Photo limit reached'
                    : 'Upload salon photos',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SalonPhotoTile extends StatelessWidget {
  final String url;
  final bool isCover;
  final bool canRemove;
  final VoidCallback onRemove;

  const _SalonPhotoTile({
    required this.url,
    required this.isCover,
    required this.canRemove,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                color: AppColors.line,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withAlpha(180), width: 2),
            ),
          ),
        ),
        if (isCover)
          Positioned(
            left: 8,
            top: 8,
            child: AppPill(
              label: 'Cover',
              color: AppColors.primary,
              backgroundColor: Colors.white.withAlpha(232),
            ),
          ),
        Positioned(
          right: 6,
          top: 6,
          child: IconButton.filledTonal(
            onPressed: canRemove ? onRemove : null,
            icon: const Icon(Icons.close),
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withAlpha(238),
              foregroundColor: AppColors.coral,
              minimumSize: const Size(34, 34),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }
}

class _ServiceCard extends StatefulWidget {
  final SalonService service;

  const _ServiceCard({required this.service});

  @override
  State<_ServiceCard> createState() => _ServiceCardState();
}

class _ServiceCardState extends State<_ServiceCard> {
  late final TextEditingController _priceController;
  bool _isEditingPrice = false;
  bool _isSavingPrice = false;

  SalonService get service => widget.service;

  @override
  void initState() {
    super.initState();
    _priceController = TextEditingController(text: '${service.price}');
  }

  @override
  void didUpdateWidget(covariant _ServiceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isEditingPrice && oldWidget.service.price != service.price) {
      _priceController.text = '${service.price}';
    }
  }

  @override
  void dispose() {
    _priceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Row(
        children: [
          ServiceImageIcon(
            category: service.category,
            serviceName: service.name,
            color: serviceColorForCategory(service.category),
            size: 46,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  service.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${service.category} - ${service.durationMinutes} min',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    AppPill(
                      icon: service.isAvailable
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      label: service.isAvailable ? 'Available' : 'Hidden',
                      color: service.isAvailable
                          ? AppColors.success
                          : AppColors.muted,
                    ),
                    AppPill(
                      icon: Icons.bolt_outlined,
                      label:
                          service.isAvailable && service.instantBookingEnabled
                          ? 'Instant on'
                          : 'Instant off',
                      color:
                          service.isAvailable && service.instantBookingEnabled
                          ? AppColors.coral
                          : AppColors.muted,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_isEditingPrice)
            SizedBox(
              width: 112,
              child: TextField(
                key: ValueKey('service-price-editor-${service.id}'),
                controller: _priceController,
                autofocus: true,
                enabled: !_isSavingPrice,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                selectAllOnFocus: true,
                onSubmitted: (_) => _savePrice(context),
                decoration: InputDecoration(
                  prefixText: '₹',
                  labelText: 'Price',
                  isDense: true,
                  suffixIcon: IconButton(
                    tooltip: 'Save price',
                    onPressed: _isSavingPrice
                        ? null
                        : () => _savePrice(context),
                    icon: _isSavingPrice
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check, size: 19),
                  ),
                ),
              ),
            )
          else
            Tooltip(
              message: 'Tap to edit price',
              child: InkWell(
                key: ValueKey('service-price-${service.id}'),
                borderRadius: BorderRadius.circular(10),
                onTap: _beginPriceEdit,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '₹${service.price}',
                        style: const TextStyle(
                          color: AppColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 3),
                      const Icon(
                        Icons.edit_outlined,
                        size: 15,
                        color: AppColors.muted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          PopupMenuButton<String>(
            tooltip: 'Service actions',
            onSelected: (action) {
              switch (action) {
                case 'availability':
                  _updateServiceControls(
                    context,
                    isAvailable: !service.isAvailable,
                  );
                case 'instant':
                  _updateServiceControls(
                    context,
                    instantBookingEnabled: !service.instantBookingEnabled,
                  );
                case 'edit':
                  _showEditServiceDialog(context);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'availability',
                child: ListTile(
                  leading: Icon(
                    service.isAvailable
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  title: Text(
                    service.isAvailable
                        ? 'Hide from customers'
                        : 'Make available',
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'instant',
                enabled: service.isAvailable,
                child: ListTile(
                  leading: const Icon(Icons.bolt_outlined),
                  title: Text(
                    service.instantBookingEnabled
                        ? 'Disable instant'
                        : 'Enable instant',
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'edit',
                child: ListTile(
                  leading: Icon(Icons.edit_outlined),
                  title: Text('Edit service'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _beginPriceEdit() {
    _priceController
      ..text = '${service.price}'
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: '${service.price}'.length,
      );
    setState(() => _isEditingPrice = true);
  }

  Future<void> _savePrice(BuildContext context) async {
    if (_isSavingPrice) {
      return;
    }
    final price = int.tryParse(_priceController.text.trim()) ?? 0;
    if (price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a price greater than zero.')),
      );
      return;
    }
    if (price == service.price) {
      setState(() => _isEditingPrice = false);
      return;
    }
    setState(() => _isSavingPrice = true);
    try {
      await AppStateScope.read(context).updateOwnerService(
        serviceId: service.id,
        name: service.name,
        category: service.category,
        price: price,
        durationMinutes: service.durationMinutes,
        isAvailable: service.isAvailable,
        instantBookingEnabled: service.instantBookingEnabled,
      );
      if (mounted) {
        setState(() => _isEditingPrice = false);
      }
    } catch (error) {
      if (context.mounted) {
        await showAppErrorDialog(context, friendlyOnboardingError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _isSavingPrice = false);
      }
    }
  }

  Future<void> _updateServiceControls(
    BuildContext context, {
    bool? isAvailable,
    bool? instantBookingEnabled,
  }) async {
    try {
      await AppStateScope.read(context).updateOwnerService(
        serviceId: service.id,
        name: service.name,
        category: service.category,
        price: service.price,
        durationMinutes: service.durationMinutes,
        isAvailable: isAvailable,
        instantBookingEnabled: instantBookingEnabled,
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await showAppErrorDialog(context, friendlyOnboardingError(error));
    }
  }

  void _showEditServiceDialog(BuildContext context) {
    final nameController = TextEditingController(text: service.name);
    final priceController = TextEditingController(text: '${service.price}');
    final durationController = TextEditingController(
      text: '${service.durationMinutes}',
    );
    final category = service.category;
    var isAvailable = service.isAvailable;
    var instantBookingEnabled = service.instantBookingEnabled;
    var isSaving = false;

    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Edit service'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      readOnly: true,
                      decoration: const InputDecoration(
                        labelText: 'Service name',
                        helperText: 'Names follow the standard Pritze menu.',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      initialValue: category,
                      readOnly: true,
                      decoration: const InputDecoration(
                        labelText: 'Service type',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: priceController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Price (₹)'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: durationController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Duration minutes',
                      ),
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Available to customers'),
                      subtitle: const Text(
                        'Show this service and allow scheduled bookings.',
                      ),
                      value: isAvailable,
                      onChanged: (value) {
                        setDialogState(() => isAvailable = value);
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Allow instant booking'),
                      subtitle: const Text(
                        'Customers can request this service immediately.',
                      ),
                      value: instantBookingEnabled,
                      onChanged: isAvailable
                          ? (value) {
                              setDialogState(
                                () => instantBookingEnabled = value,
                              );
                            }
                          : null,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: isSaving
                      ? null
                      : () async {
                          final price = int.tryParse(priceController.text) ?? 0;
                          final duration =
                              int.tryParse(durationController.text) ?? 0;
                          if (nameController.text.trim().isEmpty ||
                              price <= 0 ||
                              duration <= 0) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Enter a service name, price, and duration greater than zero.',
                                ),
                              ),
                            );
                            return;
                          }
                          setDialogState(() => isSaving = true);
                          try {
                            await AppStateScope.read(
                              context,
                            ).updateOwnerService(
                              serviceId: service.id,
                              name: nameController.text,
                              category: category,
                              price: price,
                              durationMinutes: duration,
                              isAvailable: isAvailable,
                              instantBookingEnabled: instantBookingEnabled,
                            );
                            if (context.mounted) {
                              Navigator.pop(context);
                            }
                          } catch (error) {
                            if (context.mounted) {
                              await showAppErrorDialog(
                                context,
                                friendlyOnboardingError(error),
                              );
                            }
                          } finally {
                            if (context.mounted) {
                              setDialogState(() => isSaving = false);
                            }
                          }
                        },
                  child: Text(isSaving ? 'Saving...' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(() {
      nameController.dispose();
      priceController.dispose();
      durationController.dispose();
    });
  }
}
