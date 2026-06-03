import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import '../models/distributor.dart';
import '../providers/distributor_provider.dart';

// ── Design tokens ─────────────────────────────────────────────────────────────

abstract final class _IdColors {
  /// Deep navy – header + footer backgrounds.
  static const Color navy = Color(0xFF0D1B2A);

  /// Bright blue accent bar + badge background.
  static const Color accent = Color(0xFF1565C0);

  /// Amber used for the live date chip.
  static const Color dateBadge = Color(0xFFFEBA54);

  static const Color onNavy = Colors.white;
  static const Color bodyText = Color(0xFF1A1A1A);
  static const Color subtleText = Color(0xFF555555);
  static const Color divider = Color(0xFFDDDDDD);
  static const Color photoRing = Color(0xFF1565C0);
}

// ── Company constants ─────────────────────────────────────────────────────────

abstract final class _Company {
  static const String name = 'Community Life Media';
  static const String vatNo = '4500285780';
  static const String registrationNo = '2013/128702/07';
  static const String addressLine1 = 'Unit 69, 27, 7th Avenue';
  static const String addressLine2 = 'The Old Timber Yard, Maitland';
  static const String addressLine3 = 'Cape Town, 7405';
  static const String contactName = 'Barrie';
  static const String contactPhone = '+27 71 909 0839';
  static const String logoAsset = 'assets/clmlogo.png';
  static const String disclaimer =
      'The holder of this name tag is an employee of Community Life Media '
      '(Pty) Ltd. He is tasked to distribute flyers to letterboxes. '
      'For any questions, please phone:';
}

// ── Entry points ──────────────────────────────────────────────────────────────

void showDigitalIdCard(BuildContext context, Distributor distributor) {
  showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _IdCardDialog(distributor: distributor),
  );
}

void showIdCardPicker(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1E1E2E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _DistributorPickerSheet(
      onSelected: (d) {
        Navigator.pop(ctx);
        showDigitalIdCard(context, d);
      },
    ),
  );
}

// ── Dialog wrapper ────────────────────────────────────────────────────────────

class _IdCardDialog extends StatelessWidget {
  const _IdCardDialog({required this.distributor});
  final Distributor distributor;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: SingleChildScrollView(
        child: _IdCard(distributor: distributor),
      ),
    );
  }
}

// ── ID Card ───────────────────────────────────────────────────────────────────

class _IdCard extends StatelessWidget {
  const _IdCard({required this.distributor});
  final Distributor distributor;

  @override
  Widget build(BuildContext context) {
    final today = DateFormat('dd MMMM yyyy').format(DateTime.now());

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
              color: Colors.black87, blurRadius: 28, offset: Offset(0, 10)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Navy header ──────────────────────────────────────────────────
          _Header(today: today),

          // ── Blue accent bar ──────────────────────────────────────────────
          Container(height: 5, color: _IdColors.accent),

          // ── Role badge ───────────────────────────────────────────────────
          const SizedBox(height: 14),
          _RoleBadge(label: distributor.role.displayName),

          // ── Photo ────────────────────────────────────────────────────────
          const SizedBox(height: 14),
          _Photo(imageUrl: distributor.imageUrl),

          // ── Name ─────────────────────────────────────────────────────────
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              distributor.name,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _IdColors.bodyText,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),

          // ── Employee ID chip ─────────────────────────────────────────────
          const SizedBox(height: 6),
          _IdChip(id: distributor.id),

          // ── Thin divider ─────────────────────────────────────────────────
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Divider(color: _IdColors.divider, height: 1),
          ),

          // ── Company registration details ─────────────────────────────────
          _CompanyDetails(),

          // ── Divider ──────────────────────────────────────────────────────
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Divider(color: _IdColors.divider, height: 1),
          ),

          // ── Disclaimer ───────────────────────────────────────────────────
          _Disclaimer(),

          // ── Navy footer ──────────────────────────────────────────────────
          const SizedBox(height: 10),
          _Footer(),
        ],
      ),
    );
  }
}

// ── Header ────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.today});
  final String today;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _IdColors.navy,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Logo
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                ),
                padding: const EdgeInsets.all(4),
                child: Image.asset(
                  _Company.logoAsset,
                  height: 50,
                  width: 50,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.business,
                    size: 50,
                    color: _IdColors.navy,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Company name
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _Company.name.toUpperCase(),
                      style: const TextStyle(
                        color: _IdColors.onNavy,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'EMPLOYEE IDENTIFICATION',
                      style: TextStyle(
                        color: Color(0xFFB0BEC5),
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.8,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Date strip
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 10),
            decoration: BoxDecoration(
              color: _IdColors.dateBadge,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.calendar_today,
                    size: 12, color: Colors.black87),
                const SizedBox(width: 5),
                Text(
                  'Working Date: $today',
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Role badge ────────────────────────────────────────────────────────────────

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
      decoration: BoxDecoration(
        color: _IdColors.accent,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

// ── Photo ─────────────────────────────────────────────────────────────────────

class _Photo extends StatelessWidget {
  const _Photo({this.imageUrl});
  final String? imageUrl;

  static const double _size = 170;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _size + 8,
      height: _size + 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: _IdColors.photoRing, width: 4),
        boxShadow: const [
          BoxShadow(
              color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      child: ClipOval(
        child: (imageUrl != null && imageUrl!.isNotEmpty)
            ? Image.network(
                imageUrl!,
                width: _size,
                height: _size,
                fit: BoxFit.cover,
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : const SizedBox(
                        width: _size,
                        height: _size,
                        child: Center(
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _IdColors.accent,
                          ),
                        ),
                      ),
                errorBuilder: (_, __, ___) => _placeholder(),
              )
            : _placeholder(),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      width: _size,
      height: _size,
      color: const Color(0xFFEEEEEE),
      child: const Icon(Icons.person, size: 80, color: Color(0xFFAAAAAA)),
    );
  }
}

// ── Employee ID chip ──────────────────────────────────────────────────────────

class _IdChip extends StatelessWidget {
  const _IdChip({required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F4FF),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFBBCCEE)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.fingerprint, size: 13, color: _IdColors.accent),
          const SizedBox(width: 5),
          Text(
            'ID: ${id.length > 12 ? id.substring(0, 12).toUpperCase() : id.toUpperCase()}',
            style: const TextStyle(
              color: _IdColors.accent,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

// ── Company details ───────────────────────────────────────────────────────────

class _CompanyDetails extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _DetailCell(label: 'VAT No', value: _Company.vatNo),
              Container(width: 1, height: 28, color: _IdColors.divider),
              _DetailCell(label: 'Reg No', value: _Company.registrationNo),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '${_Company.addressLine1} · ${_Company.addressLine2}',
            style: TextStyle(color: _IdColors.subtleText, fontSize: 10, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const Text(
            _Company.addressLine3,
            style: TextStyle(color: _IdColors.subtleText, fontSize: 10, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _DetailCell extends StatelessWidget {
  const _DetailCell({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: _IdColors.subtleText,
            fontSize: 8,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: _IdColors.bodyText,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// ── Disclaimer ────────────────────────────────────────────────────────────────

class _Disclaimer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FF),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFCCDDEE)),
      ),
      child: Column(
        children: [
          Text(
            _Company.disclaimer,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _IdColors.bodyText,
              fontSize: 10,
              height: 1.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.phone, size: 11, color: _IdColors.accent),
              const SizedBox(width: 4),
              Text(
                '${_Company.contactName}  ${_Company.contactPhone}',
                style: const TextStyle(
                  color: _IdColors.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Footer ────────────────────────────────────────────────────────────────────

class _Footer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: _IdColors.navy,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: const Text(
        'AUTHORISED FOR LETTERBOX DISTRIBUTION',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Color(0xFFB0BEC5),
          fontSize: 8,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.6,
        ),
      ),
    );
  }
}

// ── Distributor picker sheet ──────────────────────────────────────────────────

class _DistributorPickerSheet extends riverpod.ConsumerWidget {
  const _DistributorPickerSheet({required this.onSelected});
  final void Function(Distributor) onSelected;

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final provider = ref.watch(distributorRiverpod);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: const Color(0xFF555577),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Select ID to view',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        if (provider.loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          )
        else if (provider.distributors.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No distributors found',
              style: TextStyle(color: Color(0xFFAAAAAA)),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: provider.distributors.length,
              itemBuilder: (_, i) {
                final d = provider.distributors[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage:
                        (d.imageUrl != null && d.imageUrl!.isNotEmpty)
                            ? NetworkImage(d.imageUrl!) as ImageProvider
                            : null,
                    backgroundColor: const Color(0xFF333355),
                    child: (d.imageUrl == null || d.imageUrl!.isEmpty)
                        ? const Icon(Icons.person, color: Colors.white)
                        : null,
                  ),
                  title: Text(d.name,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    d.role.displayName,
                    style: const TextStyle(
                        color: Color(0xFFAAAAAA),
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                  onTap: () => onSelected(d),
                );
              },
            ),
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}
