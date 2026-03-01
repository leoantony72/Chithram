import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../services/share_service.dart';
import '../../services/auth_service.dart';

class ShareWithUserSheet extends StatefulWidget {
  final String imageId;
  final Future<Uint8List?> Function() fetchImageBytes;
  final Future<String?> Function(String receiverUsername, String shareType, Uint8List imageBytes) onCreateShare;

  const ShareWithUserSheet({
    super.key,
    required this.imageId,
    required this.fetchImageBytes,
    required this.onCreateShare,
  });

  @override
  State<ShareWithUserSheet> createState() => _ShareWithUserSheetState();
}

class _ShareWithUserSheetState extends State<ShareWithUserSheet> {
  final _usernameController = TextEditingController();
  final _focusNode = FocusNode();
  List<String> _suggestions = [];
  Timer? _debounce;
  String _shareType = 'normal';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_onUsernameChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _usernameController.removeListener(_onUsernameChanged);
    _usernameController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onUsernameChanged() {
    _debounce?.cancel();
    final q = _usernameController.text.trim();
    if (q.length < 2) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final session = await AuthService().loadSession();
      final exclude = session?['username'] as String?;
      final list = await ShareService().searchUsers(q, excludeUsername: exclude);
      if (mounted) setState(() => _suggestions = list);
    });
  }

  void _selectUsername(String username) {
    _usernameController.text = username;
    _usernameController.selection = TextSelection.collapsed(offset: username.length);
    setState(() => _suggestions = []);
  }

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    if (username.isEmpty) return;

    setState(() => _loading = true);
    final bytes = await widget.fetchImageBytes();
    if (bytes == null || bytes.isEmpty || !mounted) {
      setState(() => _loading = false);
      return;
    }

    final shareId = await widget.onCreateShare(username, _shareType, bytes);
    if (!mounted) return;
    setState(() => _loading = false);
    if (shareId != null) {
      Navigator.pop(context, true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Share failed. User may not exist.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.white.withOpacity(0.15),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0F),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 30, offset: const Offset(0, -10)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 28),
            // Title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(color: const Color(0xFF6366F1).withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 4)),
                      ],
                    ),
                    child: const Icon(Icons.person_add_rounded, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 16),
                  const Text(
                    'Share with user',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            // Username field with autocomplete
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Username',
                    style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withOpacity(0.08)),
                        ),
                        child: TextField(
                          controller: _usernameController,
                          focusNode: _focusNode,
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                          decoration: InputDecoration(
                            hintText: 'Enter username...',
                            hintStyle: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 16),
                            filled: false,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                          ),
                          onSubmitted: (_) => _submit(),
                        ),
                      ),
                      if (_suggestions.isNotEmpty)
                        Positioned(
                          top: 56,
                          left: 0,
                          right: 0,
                            child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 220),
                            child: SingleChildScrollView(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF12121A),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 20)],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: _suggestions.map((u) {
                                      return Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          onTap: () => _selectUsername(u),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                                            child: Row(
                                              children: [
                                                CircleAvatar(
                                                  radius: 14,
                                                  backgroundColor: const Color(0xFF6366F1).withOpacity(0.3),
                                                  child: Text(
                                                    u.isNotEmpty ? u[0].toUpperCase() : '?',
                                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Text(
                                                  u,
                                                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Share type selector
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Share type',
                    style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _ShareTypeChip(
                          label: 'Normal',
                          subtitle: 'Ongoing access',
                          icon: Icons.all_inclusive_rounded,
                          isSelected: _shareType == 'normal',
                          onTap: () => setState(() => _shareType = 'normal'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _ShareTypeChip(
                          label: 'One-time',
                          subtitle: 'View once',
                          icon: Icons.lock_clock_rounded,
                          isSelected: _shareType == 'one_time',
                          onTap: () => setState(() => _shareType = 'one_time'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            // Share button
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
              child: GestureDetector(
                onTap: _loading ? null : _submit,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    gradient: _loading
                        ? null
                        : const LinearGradient(
                            colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                          ),
                    color: _loading ? Colors.white.withOpacity(0.1) : null,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: _loading ? null : [BoxShadow(color: const Color(0xFF6366F1).withOpacity(0.4), blurRadius: 16, offset: const Offset(0, 6))],
                  ),
                  child: Center(
                    child: _loading
                        ? SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white.withOpacity(0.8)),
                          )
                        : const Text(
                            'Share',
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareTypeChip extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _ShareTypeChip({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF6366F1).withOpacity(0.2) : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? const Color(0xFF6366F1).withOpacity(0.5) : Colors.white.withOpacity(0.08),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 22,
              color: isSelected ? const Color(0xFFA78BFA) : Colors.white.withOpacity(0.4),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white.withOpacity(0.7),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: isSelected ? Colors.white.withOpacity(0.7) : Colors.white.withOpacity(0.4),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
