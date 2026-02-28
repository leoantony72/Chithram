import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/auth_service.dart';
import '../services/api_config.dart';
import '../services/auth_service.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _usernameController = TextEditingController();
  bool _isLogin = true; // Toggle between Login and Signup
  bool _isLoading = false;
  bool _isCheckingPersistence = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeAuthService();
  }

  Future<void> _initializeAuthService() async {
    await AuthService().init();
    await _checkPersistentLogin();
  }

  Future<void> _checkPersistentLogin() async {
    final keys = await AuthService().loadSession();
    if (keys != null) {
      print('Persistent login successful.');
      if (mounted) {
        context.go('/');
      }
    } else {
      if (mounted) {
        setState(() {
          _isCheckingPersistence = false;
        });
      }
    }
  }

  Future<void> _submit() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final username = _usernameController.text.trim();

    if (email.isEmpty || password.isEmpty || (!_isLogin && username.isEmpty)) {
      setState(() {
        _errorMessage = 'Please enter all fields.';
        _isLoading = false;
      });
      return;
    }

    bool success = false;
    if (_isLogin) {
      final keys = await AuthService().login(email, password);
      success = keys != null;
      if (success) {
        // Handle successful login (e.g., store keys, navigate)
        print('Login successful! Keys received: ${keys.keys}');
         if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Login Successful! Redirecting...')),
          );
          // Navigate to main page
          context.go('/'); 
        }
      } else {
        setState(() {
          _errorMessage = 'Login failed. Check credentials or network.';
        });
      }
    } else {
      success = await AuthService().signup(username, email, password);
      if (success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Signup Successful! Please login.')),
          );
          setState(() {
            _isLogin = true; // Switch to login after signup
          });
        }
      } else {
        setState(() {
          _errorMessage = 'Signup failed. Username or Email might be taken.';
        });
      }
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isCheckingPersistence) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isLogin ? 'Login' : 'Signup'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
            tooltip: 'Configure Backend Server',
            onPressed: () async {
              final currentIp = await ApiConfig().getCurrentIp();
              if (!mounted) return;
              
              final controller = TextEditingController(text: currentIp);
              
              showGeneralDialog(
                context: context,
                barrierColor: Colors.black.withValues(alpha: 0.5),
                barrierDismissible: true,
                barrierLabel: "ConfigDialog",
                pageBuilder: (ctx, anim1, anim2) => Center(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        width: 340,
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E1E), // Solid dark grey base
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white10),
                          boxShadow: const [
                            BoxShadow(color: Colors.black54, blurRadius: 20, spreadRadius: 5),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.dns_rounded, color: Colors.blueAccent, size: 24),
                                SizedBox(width: 12),
                                Text(
                                  'Backend Server',
                                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Set the IPv4 address or domain where the backend is hosted.',
                              style: TextStyle(color: Colors.white54, fontSize: 13),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: controller,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'e.g. 192.168.1.5',
                                hintStyle: const TextStyle(color: Colors.white30),
                                filled: true,
                                fillColor: Colors.white.withValues(alpha: 0.05),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton(
                                  onPressed: () async {
                                    if (controller.text.isNotEmpty) {
                                      await ApiConfig().setCustomIp(controller.text);
                                      if (!context.mounted) return;
                                      Navigator.pop(ctx);
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Backend address set to ${controller.text}')),
                                      );
                                    }
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blueAccent,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  child: const Text('Save'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                transitionBuilder: (ctx, anim1, anim2, child) {
                  return Transform.scale(
                    scale: Curves.easeOutBack.transform(anim1.value),
                    child: FadeTransition(
                      opacity: anim1,
                      child: child,
                    ),
                  );
                },
                transitionDuration: const Duration(milliseconds: 300),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Chithram',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).primaryColor,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Secure E2EE Photos',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 32),
              if (!_isLogin) ...[
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 24),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              _isLoading
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                      onPressed: _submit,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                      ),
                      child: Text(_isLogin ? 'Login' : 'Signup'),
                    ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  setState(() {
                    _isLogin = !_isLogin;
                    _errorMessage = null;
                  });
                },
                child: Text(_isLogin
                    ? 'Don\'t have an account? Signup'
                    : 'Already have an account? Login'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
