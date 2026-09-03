import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config.dart';
import 'core/theme.dart';
import 'data/backend.dart';
import 'domain/models.dart';
import 'features/role_screens.dart';

final backendProvider = Provider<Backend?>((ref) {
  if (!AppConfig.isConfigured) return null;
  return Backend(Supabase.instance.client);
});

class RequestRideApp extends StatelessWidget {
  const RequestRideApp({this.configured, super.key});

  final bool? configured;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Request Ride',
        debugShowCheckedModeBanner: false,
        theme: RequestRideTheme.dark,
        home: (configured ?? AppConfig.isConfigured)
            ? const SessionGate()
            : const SetupRequiredScreen(),
      );
}

class SetupRequiredScreen extends StatelessWidget {
  const SetupRequiredScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: BrandedBackdrop(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                child: const Padding(
                  padding: EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.all(Radius.circular(18)),
                        child: Image(
                          image: AssetImage(
                            'assets/branding/request_ride_icon.png',
                          ),
                          width: 72,
                          height: 72,
                        ),
                      ),
                      SizedBox(height: 16),
                      Text(
                        'Request Ride',
                        style: TextStyle(
                            fontSize: 32, fontWeight: FontWeight.w800),
                      ),
                      SizedBox(height: 12),
                      Text(
                        'Add SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY as '
                        '--dart-define values to connect this build.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class SessionGate extends ConsumerWidget {
  const SessionGate({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.watch(backendProvider)!;
    return StreamBuilder<AuthState>(
      stream: backend.authChanges,
      builder: (context, _) => backend.currentUser == null
          ? const AuthScreen()
          : FutureBuilder<Profile?>(
              future: backend.getProfile(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Scaffold(
                    body: BrandedBackdrop(
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  );
                }
                return RoleHome(profile: snapshot.data!);
              },
            ),
    );
  }
}

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final email = TextEditingController();
  final password = TextEditingController();
  final name = TextEditingController();
  var register = false;
  var role = UserRole.customer;
  var busy = false;
  String? error;
  String? info;

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
      info = null;
    });
    try {
      final backend = ref.read(backendProvider)!;
      if (register) {
        final confirmationRequired = await backend.register(
          email: email.text.trim(),
          password: password.text,
          fullName: name.text.trim(),
          role: role,
        );
        if (confirmationRequired && mounted) {
          setState(() {
            info =
                'Account created. Check your email and open the confirmation '
                'link, then return here and sign in.';
          });
        }
      } else {
        await backend.signIn(email.text.trim(), password.text);
      }
    } on AuthException catch (exception) {
      final message = switch (exception.code) {
        'over_email_send_rate_limit' =>
          'Your account already exists and a confirmation email was sent. '
              'Wait one minute before requesting another email. Check your inbox '
              'and spam folder, confirm the account, then choose Sign in.',
        'email_not_confirmed' =>
          'Confirm your email address using the link in your inbox, then sign in.',
        'user_already_exists' =>
          'This account already exists. Confirm the email, then choose Sign in.',
        'invalid_credentials' => 'The email address or password is incorrect.',
        _ => exception.message,
      };
      setState(() => error = message);
    } catch (_) {
      setState(() => error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> forgotPassword() async {
    if (!email.text.contains('@')) {
      setState(() => error = 'Enter your email address first.');
      return;
    }
    try {
      await ref.read(backendProvider)!.sendPasswordReset(email.text.trim());
      if (mounted) {
        setState(() {
          error = null;
          info = 'Password reset email sent. Check your inbox and spam folder.';
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Could not send the reset email.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: BrandedBackdrop(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'SOUTH AFRICA',
                          style: TextStyle(
                            color: RequestRideColors.gold,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2.4,
                          ),
                        ),
                        const SizedBox(height: 14),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.asset(
                            'assets/branding/request_ride_icon.png',
                            width: 72,
                            height: 72,
                          ),
                        ),
                        Text(
                          'Request Ride',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Move with confidence',
                          style: TextStyle(color: RequestRideColors.aqua),
                        ),
                        const SizedBox(height: 24),
                        if (register) ...[
                          TextField(
                            controller: name,
                            decoration:
                                const InputDecoration(labelText: 'Full name'),
                          ),
                          const SizedBox(height: 12),
                        ],
                        TextField(
                          controller: email,
                          decoration: const InputDecoration(labelText: 'Email'),
                        ),
                        if (!register)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: forgotPassword,
                              child: const Text('Forgot password?'),
                            ),
                          ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: password,
                          obscureText: true,
                          decoration:
                              const InputDecoration(labelText: 'Password'),
                        ),
                        if (register) ...[
                          const SizedBox(height: 12),
                          SegmentedButton<UserRole>(
                            segments: const [
                              ButtonSegment(
                                value: UserRole.customer,
                                label: Text('Customer'),
                              ),
                              ButtonSegment(
                                value: UserRole.driver,
                                label: Text('Driver'),
                              ),
                            ],
                            selected: {role},
                            onSelectionChanged: (value) =>
                                setState(() => role = value.first),
                          ),
                        ],
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              error!,
                              style: const TextStyle(
                                  color: RequestRideColors.coral),
                            ),
                          ),
                        if (info != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              info!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: busy ? null : submit,
                          child: Text(
                            busy
                                ? 'Please wait…'
                                : register
                                    ? 'Create account'
                                    : 'Sign in',
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() => register = !register),
                          child: Text(
                            register
                                ? 'Already registered? Sign in'
                                : 'Create an account',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class RoleHome extends ConsumerWidget {
  const RoleHome({required this.profile, super.key});
  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.read(backendProvider)!;
    final content = switch (profile.role) {
      UserRole.customer => CustomerWorkspace(backend: backend),
      UserRole.driver => DriverWorkspace(backend: backend),
      UserRole.admin => AdminWorkspace(backend: backend),
    };
    return Scaffold(
      drawer: _MainMenu(profile: profile, backend: backend),
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Image.asset(
                'assets/branding/request_ride_icon.png',
                width: 34,
                height: 34,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Hello, ${profile.fullName}')),
          ],
        ),
        actions: [
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: backend.notifications(),
            builder: (context, snapshot) {
              final unread = (snapshot.data ?? const [])
                  .where((item) => item['read_at'] == null)
                  .length;
              return IconButton(
                tooltip: 'Notifications',
                onPressed: () => showNotificationInbox(context, backend),
                icon: Badge(
                  isLabelVisible: unread > 0,
                  label: Text(unread > 99 ? '99+' : '$unread'),
                  child: Icon(unread > 0
                      ? Icons.notifications_active
                      : Icons.notifications_none),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Account and safety settings',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => _AccountSettingsDialog(
                backend: backend,
              ),
            ),
            icon: const Icon(Icons.manage_accounts),
          ),
        ],
      ),
      body: BrandedBackdrop(child: content),
    );
  }
}

class _MainMenu extends StatelessWidget {
  const _MainMenu({required this.profile, required this.backend});

  final Profile profile;
  final Backend backend;

  void _closeThen(BuildContext context, VoidCallback action) {
    Navigator.pop(context);
    action();
  }

  @override
  Widget build(BuildContext context) => Drawer(
        child: SafeArea(
          child: Column(
            children: [
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/branding/request_ride_icon.png',
                    width: 42,
                    height: 42,
                  ),
                ),
                title: Text(profile.fullName),
                subtitle: Text(profile.role.name),
              ),
              const Divider(),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    if (profile.role != UserRole.admin)
                      ListTile(
                        leading: const Icon(Icons.history),
                        title: const Text('Trip history'),
                        subtitle: const Text('Completed and cancelled rides'),
                        onTap: () => _closeThen(
                          context,
                          () => showTripHistory(context, backend),
                        ),
                      ),
                    ListTile(
                      leading: const Icon(Icons.notifications_outlined),
                      title: const Text('Notifications'),
                      onTap: () => _closeThen(
                        context,
                        () => showNotificationInbox(context, backend),
                      ),
                    ),
                    if (profile.role == UserRole.customer)
                      ListTile(
                        leading:
                            const Icon(Icons.account_balance_wallet_outlined),
                        title: const Text('Payment methods'),
                        subtitle: const Text('Cash and card preferences'),
                        onTap: () => _closeThen(
                          context,
                          () => showDialog<void>(
                            context: context,
                            builder: (context) => const AlertDialog(
                              title: Text('Payment methods'),
                              content: Text(
                                'Cash is available. Card payments become available when the secure payment provider is connected.',
                              ),
                            ),
                          ),
                        ),
                      ),
                    ListTile(
                      leading: const Icon(Icons.shield_outlined),
                      title: const Text('Account and safety'),
                      subtitle:
                          const Text('Profile, emergency contact and password'),
                      onTap: () => _closeThen(
                        context,
                        () => showDialog<void>(
                          context: context,
                          builder: (context) =>
                              _AccountSettingsDialog(backend: backend),
                        ),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.help_outline),
                      title: const Text('Help and support'),
                      subtitle: const Text('Ride help and safety information'),
                      onTap: () => _closeThen(
                        context,
                        () => showDialog<void>(
                          context: context,
                          builder: (context) => const AlertDialog(
                            title: Text('Help and support'),
                            content: Text(
                              'For an active ride, use the safety shield on the trip screen. In an emergency, contact local emergency services immediately.',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Log out'),
                onTap: () async {
                  Navigator.pop(context);
                  await backend.signOut();
                },
              ),
            ],
          ),
        ),
      );
}

class _AccountSettingsDialog extends StatefulWidget {
  const _AccountSettingsDialog({required this.backend});
  final Backend backend;

  @override
  State<_AccountSettingsDialog> createState() => _AccountSettingsDialogState();
}

class _AccountSettingsDialogState extends State<_AccountSettingsDialog> {
  final name = TextEditingController();
  final phone = TextEditingController();
  final emergencyName = TextEditingController();
  final emergencyPhone = TextEditingController();
  final newPassword = TextEditingController();
  var consent = false;
  var loading = true;
  var busy = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final profile = await widget.backend.getProfileDetails();
    if (!mounted) return;
    setState(() {
      name.text = '${profile['full_name'] ?? ''}';
      phone.text = '${profile['phone'] ?? ''}';
      emergencyName.text = '${profile['emergency_contact_name'] ?? ''}';
      emergencyPhone.text = '${profile['emergency_contact_phone'] ?? ''}';
      consent = profile['privacy_consent_at'] != null;
      loading = false;
    });
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      await widget.backend.updateProfile(
        fullName: name.text.trim(),
        phone: phone.text.trim(),
        emergencyName: emergencyName.text.trim(),
        emergencyPhone: emergencyPhone.text.trim(),
        privacyConsent: consent,
      );
      if (newPassword.text.isNotEmpty) {
        if (newPassword.text.length < 8) {
          throw Exception(
              'The new password must contain at least 8 characters.');
        }
        await widget.backend.updatePassword(newPassword.text);
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> requestDeletion() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request account deletion?'),
        content: const Text(
          'Your account will be disabled for driving and queued for secure deletion after legal retention checks.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep account'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Request deletion'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.backend.requestAccountDeletion();
      await widget.backend.signOut();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    emergencyName.dispose();
    emergencyPhone.dispose();
    newPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Account and safety settings'),
        content: SizedBox(
          width: 560,
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  shrinkWrap: true,
                  children: [
                    TextField(
                        controller: name,
                        decoration:
                            const InputDecoration(labelText: 'Full name')),
                    const SizedBox(height: 10),
                    TextField(
                        controller: phone,
                        decoration:
                            const InputDecoration(labelText: 'Phone number')),
                    const SizedBox(height: 10),
                    TextField(
                        controller: emergencyName,
                        decoration: const InputDecoration(
                            labelText: 'Emergency contact name')),
                    const SizedBox(height: 10),
                    TextField(
                        controller: emergencyPhone,
                        decoration: const InputDecoration(
                            labelText: 'Emergency contact phone')),
                    const SizedBox(height: 10),
                    TextField(
                      controller: newPassword,
                      obscureText: true,
                      decoration: const InputDecoration(
                          labelText: 'New password (optional)'),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: consent,
                      onChanged: (value) =>
                          setState(() => consent = value ?? false),
                      title: const Text(
                          'I consent to location and trip-data processing'),
                      subtitle: const Text(
                          'Required to provide ride matching, tracking and safety services under the privacy policy.'),
                    ),
                    TextButton.icon(
                      onPressed: requestDeletion,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Request account deletion'),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
          FilledButton(
              onPressed: loading || busy ? null : save,
              child: Text(busy ? 'Saving…' : 'Save')),
        ],
      );
}

class CustomerHome extends StatelessWidget {
  const CustomerHome({super.key});
  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          _HeroCard(
            icon: Icons.map,
            title: 'Where are you going?',
            subtitle:
                'Use your GPS, drop a map pin, or search for pickup and destination.',
          ),
          SizedBox(height: 16),
          _ActionTile(
            icon: Icons.my_location,
            title: 'Choose pickup',
            subtitle: 'Current location or map search',
          ),
          _ActionTile(
            icon: Icons.flag,
            title: 'Choose destination',
            subtitle: 'Search for an address or landmark',
          ),
          _ActionTile(
            icon: Icons.history,
            title: 'Trip history',
            subtitle: 'Receipts, completed trips and ratings',
          ),
        ],
      );
}

class DriverHome extends StatefulWidget {
  const DriverHome({super.key});
  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> {
  var online = false;
  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _HeroCard(
            icon: online ? Icons.online_prediction : Icons.cloud_off,
            title: online ? 'You are online' : 'You are offline',
            subtitle: online
                ? 'Nearby ride requests will appear here.'
                : 'Go online when you are ready to drive.',
          ),
          SwitchListTile(
            title: const Text('Available for rides'),
            value: online,
            onChanged: (value) => setState(() => online = value),
          ),
          const _ActionTile(
            icon: Icons.verified_user,
            title: 'Driver application',
            subtitle:
                'Vehicle, licence, roadworthy, insurance and proof of address',
          ),
          const _ActionTile(
            icon: Icons.directions_car,
            title: 'Vehicle',
            subtitle: 'Cars only — bakkies are not eligible',
          ),
          const _ActionTile(
            icon: Icons.route,
            title: 'Trip history',
            subtitle: 'Completed rides and earnings',
          ),
        ],
      );
}

class AdminHome extends StatelessWidget {
  const AdminHome({super.key});
  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          _HeroCard(
            icon: Icons.admin_panel_settings,
            title: 'Operations dashboard',
            subtitle:
                'Review drivers, monitor active rides, and configure fares.',
          ),
          SizedBox(height: 16),
          _ActionTile(
            icon: Icons.fact_check,
            title: 'Pending driver approvals',
            subtitle: 'Review identity, documents, address and vehicle',
          ),
          _ActionTile(
            icon: Icons.monitor_heart,
            title: 'Live trips',
            subtitle: 'Monitor active trip state and safety events',
          ),
          _ActionTile(
            icon: Icons.payments,
            title: 'Fare rules',
            subtitle: 'Base, distance, time and minimum fare in ZAR',
          ),
        ],
      );
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 42),
              const SizedBox(height: 18),
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(subtitle),
            ],
          ),
        ),
      );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
        ),
      );
}
