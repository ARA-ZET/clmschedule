import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class CLMAdvertPage extends StatelessWidget {
  final bool showInvalidBanner;

  const CLMAdvertPage({super.key, this.showInvalidBanner = false});

  static final Uri _websiteUri =
      Uri.parse('https://www.communitylifemedia.co.za/');
  static final Uri _phoneUri = Uri(scheme: 'tel', path: '+27719090839');
  static final Uri _emailUri = Uri(
    scheme: 'mailto',
    path: 'sales@communitylifemedia.co.za',
    query: 'subject=CLM map link assistance',
  );

  Future<void> _launch(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not launch $uri');
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isCompact = size.width < 760;
    final isShort = size.height < 680;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/map.jpg', fit: BoxFit.cover),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xCC08111F),
                  Color(0xE6101824),
                  Color(0xF20A1018),
                ],
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: IntrinsicHeight(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: isCompact ? 20 : 52,
                          vertical: isShort ? 16 : 28,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _BrandHeader(
                              isCompact: isCompact,
                              onWebsiteTap: () => _launch(_websiteUri),
                            ),
                            SizedBox(height: isShort ? 24 : 42),
                            if (showInvalidBanner)
                              _InvalidHero(
                                isCompact: isCompact,
                                onCall: () => _launch(_phoneUri),
                                onEmail: () => _launch(_emailUri),
                              )
                            else
                              _HomeHero(
                                isCompact: isCompact,
                                onCall: () => _launch(_phoneUri),
                                onWebsite: () => _launch(_websiteUri),
                              ),
                            SizedBox(height: isShort ? 20 : 34),
                            _ServiceStrip(isCompact: isCompact),
                            const Spacer(),
                            SizedBox(height: isShort ? 18 : 28),
                            _ContactFooter(
                              isCompact: isCompact,
                              onCall: () => _launch(_phoneUri),
                              onEmail: () => _launch(_emailUri),
                              onWebsite: () => _launch(_websiteUri),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  final bool isCompact;
  final VoidCallback onWebsiteTap;

  const _BrandHeader({
    required this.isCompact,
    required this.onWebsiteTap,
  });

  @override
  Widget build(BuildContext context) {
    final brand = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
          ),
          child: const Icon(
            Icons.route_rounded,
            color: Color(0xFFFFC247),
            size: 25,
          ),
        ),
        const SizedBox(width: 12),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Community Life Media',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'GPS-tracked distribution maps',
              style: TextStyle(
                color: Color(0xCCFFFFFF),
                fontSize: 12,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ],
    );

    final websiteButton = OutlinedButton.icon(
      onPressed: onWebsiteTap,
      icon: const Icon(Icons.open_in_new_rounded, size: 17),
      label: const Text('Website'),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.38)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );

    if (isCompact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          brand,
          const SizedBox(height: 14),
          Align(alignment: Alignment.centerLeft, child: websiteButton),
        ],
      );
    }

    return Row(
      children: [
        brand,
        const Spacer(),
        websiteButton,
      ],
    );
  }
}

class _InvalidHero extends StatelessWidget {
  final bool isCompact;
  final VoidCallback onCall;
  final VoidCallback onEmail;

  const _InvalidHero({
    required this.isCompact,
    required this.onCall,
    required this.onEmail,
  });

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment:
          isCompact ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            color: const Color(0xFFFF6B35).withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: const Color(0xFFFF9A62).withValues(alpha: 0.65),
              width: 1.4,
            ),
          ),
          child: const Icon(
            Icons.link_off_rounded,
            color: Color(0xFFFFA36C),
            size: 42,
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'Invalid map link',
          style: TextStyle(
            color: Colors.white,
            fontSize: 38,
            height: 1.04,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'This share link has expired or does not exist. Contact Community Life Media and we will send you a fresh map link.',
          style: TextStyle(
            color: Color(0xDDEDF4FF),
            fontSize: 16,
            height: 1.45,
            letterSpacing: 0,
          ),
          textAlign: TextAlign.start,
        ),
        const SizedBox(height: 22),
        _HeroActions(
          primaryIcon: Icons.phone_rounded,
          primaryText: '071 909 0839',
          secondaryIcon: Icons.mail_outline_rounded,
          secondaryText: 'Email us',
          onPrimary: onCall,
          onSecondary: onEmail,
          stacked: isCompact,
        ),
      ],
    );

    if (isCompact) {
      return content;
    }

    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: content,
      ),
    );
  }
}

class _HomeHero extends StatelessWidget {
  final bool isCompact;
  final VoidCallback onCall;
  final VoidCallback onWebsite;

  const _HomeHero({
    required this.isCompact,
    required this.onCall,
    required this.onWebsite,
  });

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _ProofBadge(),
        const SizedBox(height: 20),
        const Text(
          'Reliable flyer and pamphlet distribution in Cape Town',
          style: TextStyle(
            color: Colors.white,
            fontSize: 42,
            height: 1.04,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'We plan, distribute, track, and report each campaign with GPS proof so clients can see exactly where their material went.',
          style: TextStyle(
            color: Color(0xDDEDF4FF),
            fontSize: 17,
            height: 1.45,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 24),
        _HeroActions(
          primaryIcon: Icons.open_in_new_rounded,
          primaryText: 'Visit website',
          secondaryIcon: Icons.phone_rounded,
          secondaryText: 'Call us',
          onPrimary: onWebsite,
          onSecondary: onCall,
          stacked: isCompact,
        ),
      ],
    );

    if (isCompact) {
      return content;
    }

    return Row(
      children: [
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 650),
            child: content,
          ),
        ),
        const SizedBox(width: 48),
        const Expanded(child: _ProofPanel()),
      ],
    );
  }
}

class _ProofBadge extends StatelessWidget {
  const _ProofBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0FB981).withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: const Color(0xFF40E0A0).withValues(alpha: 0.5)),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_rounded, color: Color(0xFF49E2A3), size: 18),
            SizedBox(width: 8),
            Text(
              'GPS proof with every completed campaign',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProofPanel extends StatelessWidget {
  const _ProofPanel();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ProofLine(
              icon: Icons.route_rounded,
              label: 'Tracked routes',
              text: 'Blue GPS lines show where distributors walked.',
            ),
            SizedBox(height: 14),
            _ProofLine(
              icon: Icons.outlined_flag_rounded,
              label: 'Letterbox points',
              text: 'Delivery points are captured as proof on the map.',
            ),
            SizedBox(height: 14),
            _ProofLine(
              icon: Icons.summarize_rounded,
              label: 'Detailed reports',
              text: 'Clients receive delivery summaries and map evidence.',
            ),
          ],
        ),
      ),
    );
  }
}

class _ProofLine extends StatelessWidget {
  final IconData icon;
  final String label;
  final String text;

  const _ProofLine({
    required this.icon,
    required this.label,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: const Color(0xFFFFC247), size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                text,
                style: const TextStyle(
                  color: Color(0xCCFFFFFF),
                  fontSize: 13,
                  height: 1.35,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HeroActions extends StatelessWidget {
  final IconData primaryIcon;
  final String primaryText;
  final IconData secondaryIcon;
  final String secondaryText;
  final VoidCallback onPrimary;
  final VoidCallback onSecondary;
  final bool stacked;

  const _HeroActions({
    required this.primaryIcon,
    required this.primaryText,
    required this.secondaryIcon,
    required this.secondaryText,
    required this.onPrimary,
    required this.onSecondary,
    required this.stacked,
  });

  @override
  Widget build(BuildContext context) {
    final primary = FilledButton.icon(
      onPressed: onPrimary,
      icon: Icon(primaryIcon, size: 19),
      label: Text(primaryText),
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFFFC247),
        foregroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
      ),
    );

    final secondary = OutlinedButton.icon(
      onPressed: onSecondary,
      icon: Icon(secondaryIcon, size: 19),
      label: Text(secondaryText),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.38)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
    );

    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          primary,
          const SizedBox(height: 10),
          secondary,
        ],
      );
    }

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [primary, secondary],
    );
  }
}

class _ServiceStrip extends StatelessWidget {
  final bool isCompact;

  const _ServiceStrip({required this.isCompact});

  @override
  Widget build(BuildContext context) {
    const services = [
      _ServiceChip(Icons.home_work_outlined, 'Door-to-door flyers'),
      _ServiceChip(Icons.mark_email_read_outlined, 'Addressed deliveries'),
      _ServiceChip(Icons.print_outlined, 'Design and printing'),
      _ServiceChip(Icons.traffic_outlined, 'Handouts'),
      _ServiceChip(Icons.location_on_outlined, 'Cape Town and beyond'),
    ];

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: isCompact ? WrapAlignment.start : WrapAlignment.center,
      children: services,
    );
  }
}

class _ServiceChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ServiceChip(this.icon, this.label);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: const Color(0xFF7DD3FC)),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactFooter extends StatelessWidget {
  final bool isCompact;
  final VoidCallback onCall;
  final VoidCallback onEmail;
  final VoidCallback onWebsite;

  const _ContactFooter({
    required this.isCompact,
    required this.onCall,
    required this.onEmail,
    required this.onWebsite,
  });

  @override
  Widget build(BuildContext context) {
    final contactItems = [
      _FooterAction(
        icon: Icons.phone_rounded,
        label: '071 909 0839',
        onPressed: onCall,
      ),
      _FooterAction(
        icon: Icons.mail_outline_rounded,
        label: 'sales@communitylifemedia.co.za',
        onPressed: onEmail,
      ),
      _FooterAction(
        icon: Icons.language_rounded,
        label: 'communitylifemedia.co.za',
        onPressed: onWebsite,
      ),
    ];

    return Column(
      crossAxisAlignment:
          isCompact ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Wrap(
          spacing: 18,
          runSpacing: 8,
          alignment: isCompact ? WrapAlignment.start : WrapAlignment.center,
          children: contactItems,
        ),
        const SizedBox(height: 10),
        const Text(
          'Unit 69, The Old Timber Yard, 27 7th Avenue, Kensington, Cape Town',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(0xAFFFFFFF),
            fontSize: 12,
            height: 1.35,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _FooterAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _FooterAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16, color: const Color(0xFFFFC247)),
      label: Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      ),
    );
  }
}
