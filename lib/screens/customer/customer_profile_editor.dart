import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/booking_status_timeline.dart';
import 'my_bookings_screen.dart';

const customerStyleOptions = <String>[
  'Classic haircut',
  'Fade',
  'Beard styling',
  'Long hair',
  'Hair colour',
  'Facial',
  'Bridal',
  'Nail art',
];

class CustomerProfileEditor extends StatefulWidget {
  final UserAccount account;

  const CustomerProfileEditor({super.key, required this.account});

  @override
  State<CustomerProfileEditor> createState() => _CustomerProfileEditorState();
}

class _CustomerProfileEditorState extends State<CustomerProfileEditor> {
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late String _gender;
  late String _birthDate;
  late Set<String> _styles;
  late String _photoUrl;
  late List<String> _stylePhotoUrls;
  bool _saving = false;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.account.name);
    _phoneController = TextEditingController(
      text: widget.account.contact.replaceFirst(RegExp(r'^\+91'), ''),
    );
    _gender = widget.account.gender;
    _birthDate = widget.account.birthDate;
    _styles = widget.account.preferredStyles.toSet();
    _photoUrl = widget.account.photoUrl;
    _stylePhotoUrls = [...widget.account.stylePhotoUrls];
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit your profile')),
      bottomNavigationBar: CustomerActiveBookingFooter(
        onOpenBooking: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const MyBookingsScreen())),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
        children: [
          Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _EditableAvatar(photoUrl: _photoUrl, name: widget.account.name),
                Positioned(
                  right: -5,
                  bottom: -5,
                  child: IconButton.filled(
                    key: const ValueKey('edit-customer-profile-photo'),
                    onPressed: _uploading ? null : _pickProfilePhoto,
                    icon: _uploading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.camera_alt_outlined),
                    tooltip: 'Change profile picture',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            key: const ValueKey('edit-customer-name'),
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('edit-customer-phone'),
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            maxLength: 10,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Phone number',
              prefixText: '+91 ',
              counterText: '',
              helperText: 'This number cannot belong to a salon owner.',
              prefixIcon: Icon(Icons.phone_android_outlined),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const ValueKey('edit-customer-gender'),
            initialValue: _gender.isEmpty ? null : _gender,
            decoration: const InputDecoration(
              labelText: 'Gender (optional)',
              prefixIcon: Icon(Icons.wc_outlined),
            ),
            items: const [
              DropdownMenuItem(value: 'woman', child: Text('Woman')),
              DropdownMenuItem(value: 'man', child: Text('Man')),
              DropdownMenuItem(value: 'non-binary', child: Text('Non-binary')),
              DropdownMenuItem(
                value: 'prefer-not-to-say',
                child: Text('Prefer not to say'),
              ),
            ],
            onChanged: (value) => setState(() => _gender = value ?? ''),
          ),
          const SizedBox(height: 12),
          ListTile(
            key: const ValueKey('edit-customer-birthdate'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: AppColors.line),
            ),
            tileColor: Colors.white,
            leading: const Icon(Icons.cake_outlined),
            title: const Text('Birthdate'),
            subtitle: Text(
              _birthDate.isEmpty ? 'Optional' : _formatBirthDate(_birthDate),
            ),
            trailing: const Icon(Icons.calendar_month_outlined),
            onTap: _pickBirthDate,
          ),
          const SizedBox(height: 22),
          const SectionHeader(title: 'Preferred styles'),
          const SizedBox(height: 5),
          Text(
            'Choose the looks you usually enjoy. Salons can understand your taste before a visit.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final style in customerStyleOptions)
                FilterChip(
                  label: Text(style),
                  selected: _styles.contains(style),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _styles.add(style);
                      } else {
                        _styles.remove(style);
                      }
                    });
                  },
                ),
            ],
          ),
          const SizedBox(height: 22),
          SectionHeader(
            title: 'Style inspiration',
            actionLabel: _stylePhotoUrls.length < 8 ? 'Add photos' : null,
            onAction: _stylePhotoUrls.length < 8 && !_uploading
                ? _pickStylePhotos
                : null,
          ),
          const SizedBox(height: 5),
          Text(
            'Upload up to 8 reference photos of hair, beard or beauty styles you like.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          if (_stylePhotoUrls.isEmpty)
            const EmptyState(
              icon: Icons.collections_outlined,
              title: 'No style photos yet',
              message: 'Add references to show a salon what you have in mind.',
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: _stylePhotoUrls.length,
              itemBuilder: (context, index) {
                final url = _stylePhotoUrls[index];
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        url,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const ColoredBox(
                          color: AppColors.champagne,
                          child: Icon(Icons.image_outlined),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 3,
                      right: 3,
                      child: IconButton.filled(
                        onPressed: _uploading ? null : () => _removeStyle(url),
                        icon: const Icon(Icons.close, size: 17),
                        tooltip: 'Remove style photo',
                      ),
                    ),
                  ],
                );
              },
            ),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const ValueKey('save-customer-profile'),
            onPressed: _saving || _uploading ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Saving...' : 'Save profile'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickProfilePhoto() async {
    final photo = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 84,
      maxWidth: 1200,
      maxHeight: 1200,
    );
    if (photo == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final url = await AppStateScope.read(context).uploadCustomerProfilePhoto(
        bytes: await photo.readAsBytes(),
        fileName: photo.name,
        contentType: photo.mimeType,
      );
      if (mounted) setState(() => _photoUrl = url);
    } catch (error) {
      _showError('Profile photo upload failed: $error');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickStylePhotos() async {
    final photos = await ImagePicker().pickMultiImage(
      imageQuality: 82,
      maxWidth: 1600,
      maxHeight: 1600,
    );
    if (photos.isEmpty || !mounted) return;
    setState(() => _uploading = true);
    try {
      final appState = AppStateScope.read(context);
      for (final photo in photos.take(8 - _stylePhotoUrls.length)) {
        final url = await appState.uploadCustomerStylePhoto(
          bytes: await photo.readAsBytes(),
          fileName: photo.name,
          contentType: photo.mimeType,
        );
        if (mounted) setState(() => _stylePhotoUrls.add(url));
      }
    } catch (error) {
      _showError('Style photo upload failed: $error');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _removeStyle(String url) async {
    setState(() => _uploading = true);
    try {
      await AppStateScope.read(context).removeCustomerStylePhoto(url);
      if (mounted) setState(() => _stylePhotoUrls.remove(url));
    } catch (error) {
      _showError('Could not remove photo: $error');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickBirthDate() async {
    final parsed = DateTime.tryParse(_birthDate);
    final selected = await showDatePicker(
      context: context,
      initialDate: parsed ?? DateTime(2000, 1, 1),
      firstDate: DateTime(1920),
      lastDate: DateTime.now(),
    );
    if (selected != null && mounted) {
      setState(() {
        _birthDate =
            '${selected.year.toString().padLeft(4, '0')}-'
            '${selected.month.toString().padLeft(2, '0')}-'
            '${selected.day.toString().padLeft(2, '0')}';
      });
    }
  }

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty) {
      _showError('Enter your name.');
      return;
    }
    if (_phoneController.text.length != 10) {
      _showError('Enter a valid 10-digit Indian mobile number.');
      return;
    }
    setState(() => _saving = true);
    try {
      await AppStateScope.read(context).updateCustomerProfile(
        name: _nameController.text,
        phone: '+91${_phoneController.text}',
        gender: _gender,
        birthDate: _birthDate,
        preferredStyles: _styles.toList(growable: false),
        photoUrl: _photoUrl,
        stylePhotoUrls: _stylePhotoUrls,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(const SnackBar(content: Text('Profile updated.')));
    } catch (error) {
      _showError('Could not update profile: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _EditableAvatar extends StatelessWidget {
  final String photoUrl;
  final String name;

  const _EditableAvatar({required this.photoUrl, required this.name});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 52,
      backgroundColor: AppColors.champagne,
      foregroundColor: AppColors.primary,
      backgroundImage: photoUrl.isEmpty ? null : NetworkImage(photoUrl),
      child: photoUrl.isNotEmpty
          ? null
          : Text(
              name.trim().isEmpty ? 'C' : name.trim().characters.first,
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
            ),
    );
  }
}

String _formatBirthDate(String value) {
  final date = DateTime.tryParse(value);
  if (date == null) return value;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}
