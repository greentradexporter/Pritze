import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../state/app_state_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_ui.dart';

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
  final _phoneController = TextEditingController();
  final _openTimeController = TextEditingController();
  final _closeTimeController = TextEditingController();
  bool _loaded = false;
  bool _isSaving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) {
      return;
    }
    final salon = AppStateScope.read(context).ownerSalon;
    _salonNameController.text = salon.name;
    _ownerNameController.text = salon.ownerName;
    _addressController.text = salon.address;
    _phoneController.text = salon.phone;
    _openTimeController.text = salon.openTime;
    _closeTimeController.text = salon.closeTime;
    _loaded = true;
  }

  @override
  void dispose() {
    _salonNameController.dispose();
    _ownerNameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _openTimeController.dispose();
    _closeTimeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.watch(context);
    final salon = appState.ownerSalon;

    return Scaffold(
      appBar: AppBar(title: const Text('Shop registration')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
          children: [
            const AppHeroHeader(
              eyebrow: 'Owner profile',
              title: 'Register your shop for customer bookings',
              subtitle:
                  'Add shop name, address, operating hours, and the service menu shown to customers.',
              icon: Icons.storefront,
            ),
            const SizedBox(height: 22),
            const SectionHeader(title: 'Shop details'),
            const SizedBox(height: 10),
            GlassCard(
              child: Column(
                children: [
                  TextFormField(
                    controller: _salonNameController,
                    decoration: const InputDecoration(
                      labelText: 'Salon name',
                      prefixIcon: Icon(Icons.storefront_outlined),
                    ),
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _ownerNameController,
                    decoration: const InputDecoration(
                      labelText: 'Owner name',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
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
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Phone number',
                      prefixIcon: Icon(Icons.phone_outlined),
                    ),
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _openTimeController,
                          decoration: const InputDecoration(
                            labelText: 'Opening',
                            prefixIcon: Icon(Icons.schedule),
                          ),
                          validator: _required,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          controller: _closeTimeController,
                          decoration: const InputDecoration(
                            labelText: 'Closing',
                            prefixIcon: Icon(Icons.schedule),
                          ),
                          validator: _required,
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
            SectionHeader(
              title: 'Service menu',
              actionLabel: 'Add',
              onAction: () => _showAddServiceDialog(context),
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

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Required';
    }
    return null;
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
        phone: _phoneController.text,
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Save failed: $error')));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _showAddServiceDialog(BuildContext context) {
    final nameController = TextEditingController();
    final priceController = TextEditingController();
    final durationController = TextEditingController(text: '30');
    var category = 'Hair';
    var isSaving = false;
    const categories = [
      'Hair',
      'Beard',
      'Treatment',
      'Skin',
      'Color',
      'Grooming',
    ];

    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Add service'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Service name',
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: category,
                      decoration: const InputDecoration(
                        labelText: 'Service type',
                      ),
                      items: [
                        for (final item in categories)
                          DropdownMenuItem(value: item, child: Text(item)),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => category = value);
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: priceController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Price'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: durationController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Duration minutes',
                      ),
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
                              int.tryParse(durationController.text) ?? 30;
                          if (nameController.text.trim().isEmpty ||
                              price <= 0) {
                            return;
                          }
                          setDialogState(() => isSaving = true);
                          try {
                            await AppStateScope.read(context).addOwnerService(
                              name: nameController.text,
                              category: category,
                              price: price,
                              durationMinutes: duration,
                            );
                            if (context.mounted) {
                              Navigator.pop(context);
                            }
                          } catch (error) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Service save failed: $error'),
                                ),
                              );
                            }
                          } finally {
                            if (context.mounted) {
                              setDialogState(() => isSaving = false);
                            }
                          }
                        },
                  child: Text(isSaving ? 'Saving...' : 'Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final SalonService service;

  const _ServiceCard({required this.service});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Row(
        children: [
          SoftIconBox(
            icon: Icons.spa_outlined,
            color: AppColors.primary,
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
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '₹${service.price}',
            style: const TextStyle(
              color: AppColors.ink,
              fontWeight: FontWeight.w900,
            ),
          ),
          IconButton(
            onPressed: () async {
              try {
                await AppStateScope.read(
                  context,
                ).removeOwnerService(service.id);
              } catch (error) {
                if (!context.mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Remove failed: $error')),
                );
              }
            },
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove service',
          ),
        ],
      ),
    );
  }
}
