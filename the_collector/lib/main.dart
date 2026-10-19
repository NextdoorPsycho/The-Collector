import 'dart:async';

import 'package:arcane/arcane.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:the_collector/utils/firebase_environment.dart';
import 'package:the_collector/pages/admin/admin.dart';
import 'package:the_collector/pages/dock/hub.dart';
import 'package:the_collector/theme/theme.dart';
import 'package:the_collector/theme/collector_brand.dart';
import 'package:the_collector/pages/account/collector_sign_in_screen.dart';
import 'package:the_collector/utils/crud.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:collector_models/user/app_user_restricted.dart';
import 'package:the_collector/utils/auth/collector_auth.dart';
import 'package:the_collector/utils/auth/account_deletion.dart';
import 'package:the_collector/utils/auth/local_account_data.dart';
import 'package:the_collector/pages/account/account_deletion_dialog.dart';

Widget _systemBars(BuildContext context, Widget? child) =>
    AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: child ?? const SizedBox.shrink(),
    );

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeCollectorFirebase();
  runApp('the_collector', const MyAdwApp());
}

class MyAdwApp extends StatefulWidget {
  const MyAdwApp({super.key});

  @override
  State<MyAdwApp> createState() => _MyAdwAppState();
}

class _MyAdwAppState extends State<MyAdwApp> {
  late Future<void> _localSetup = _initializeLocalAccounts();
  StreamSubscription<User?>? _auth;
  User? _user;
  bool _authReady = false;

  @override
  void initState() {
    super.initState();
    _auth = FirebaseAuth.instance.authStateChanges().listen((User? user) {
      if (mounted) {
        setState(() {
          _user = user;
          _authReady = true;
        });
      }
    });
  }

  @override
  void dispose() {
    unawaited(_auth?.cancel());
    super.dispose();
  }

  Future<void> _initializeLocalAccounts() async {
    await LocalAccountData.initialize();
    for (final String uid in LocalAccountData.deletingUids.value) {
      if (LocalAccountData.needsDeletionCleanup(uid)) {
        try {
          await AccountDeletionController.instance.accept(uid);
        } catch (_) {
          return;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AccountDeletionController.instance,
    builder: (BuildContext context, Widget? child) {
      if (AccountDeletionController.instance.blocksAccount) {
        return const _AccountDeletionStatus();
      }
      return FutureBuilder<void>(
        future: _localSetup,
        builder: (BuildContext context, AsyncSnapshot<void> local) {
          if (local.connectionState != ConnectionState.done) {
            return _accountShell(const CollectorLoading(label: 'Loading…'));
          }
          if (local.hasError) {
            return _accountShell(
              Scaffold(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text('Could not open local account data.'),
                      const SizedBox(height: 16),
                      PrimaryButton(
                        onPressed: () => setState(() {
                          _localSetup = _initializeLocalAccounts();
                        }),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          if (!_authReady) {
            return _accountShell(
              const CollectorLoading(label: 'Loading account…'),
            );
          }
          final User? user = _user;
          if (user == null) {
            return _accountShell(
              CollectorSignInScreen(
                accountNotice: AccountDeletionController.instance.accepted
                    ? 'Deletion requested. Local account data has been removed.'
                    : null,
              ),
            );
          }
          return _DeletionAwareAccount(
            key: ValueKey<String>(user.uid),
            user: user,
          );
        },
      );
    },
  );
}

Widget _accountShell(Widget child) => ArcaneApp(
  builder: _systemBars,
  title: 'The Collector',
  theme: MyThemeData.themeData(ThemeMode.system),
  home: child,
);

class _AccountDeletionStatus extends StatelessWidget {
  const _AccountDeletionStatus();

  @override
  Widget build(BuildContext context) => _accountShell(
    Builder(
      builder: (BuildContext appContext) {
        final AccountDeletionController controller =
            AccountDeletionController.instance;
        return Scaffold(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (controller.stage == AccountDeletionStage.cleaning)
                      const CollectorLoading(label: 'Removing account data…')
                    else ...<Widget>[
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          controller.error ?? 'Account deletion is pending.',
                        ),
                      ),
                      const SizedBox(height: 20),
                      PrimaryButton(
                        onPressed: () async {
                          try {
                            if (controller.accepted) {
                              await controller.retry();
                            } else if (!await controller.resolveRemote() &&
                                appContext.mounted &&
                                FirebaseAuth.instance.currentUser?.uid ==
                                    controller.uid) {
                              await showAccountDeletionDialog(
                                appContext,
                                auth: FirebaseCollectorAuth.instance,
                                requestDeletion: controller.retry,
                              );
                            }
                          } catch (_) {}
                        },
                        child: Text(
                          controller.accepted
                              ? 'Retry cleanup'
                              : 'Check request',
                        ),
                      ),
                      if (!controller.accepted)
                        TextButton(
                          onPressed: () async {
                            try {
                              await FirebaseAuth.instance.signOut();
                              controller.leavePending();
                            } catch (_) {}
                          },
                          child: const Text('Sign Out'),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _DeletionAwareAccount extends StatefulWidget {
  const _DeletionAwareAccount({super.key, required this.user});
  final User user;

  @override
  State<_DeletionAwareAccount> createState() => _DeletionAwareAccountState();
}

class _DeletionAwareAccountState extends State<_DeletionAwareAccount> {
  late Future<bool> _ready = prepareAccount(widget.user.uid);
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _jobs;

  @override
  void initState() {
    super.initState();
    if (accountDeletionEnabled) {
      _jobs = FirebaseFirestore.instance
          .doc('accountDeletions/${widget.user.uid}')
          .snapshots()
          .listen(
            (DocumentSnapshot<Map<String, dynamic>> job) {
              if (!mounted ||
                  FirebaseAuth.instance.currentUser?.uid != widget.user.uid ||
                  !job.exists ||
                  AccountDeletionController.instance.stage ==
                      AccountDeletionStage.submitting) {
                return;
              }
              try {
                validateDeletionJob(job.data());
                unawaited(
                  AccountDeletionController.instance
                      .accept(widget.user.uid)
                      .catchError((Object _) {}),
                );
              } catch (_) {
                if (mounted) {
                  setState(() {
                    _ready = Future<bool>.value(false);
                  });
                }
              }
            },
            onError: (Object error) {
              if (mounted &&
                  FirebaseAuth.instance.currentUser?.uid == widget.user.uid) {
                setState(() {
                  _ready = Future<bool>.value(false);
                });
              }
            },
          );
    }
  }

  @override
  void dispose() {
    unawaited(_jobs?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _ready,
    builder: (BuildContext context, AsyncSnapshot<bool> ready) {
      if (ready.data == true && !ready.hasError) {
        return _AuthenticatedCollector(user: widget.user);
      }
      if (ready.connectionState != ConnectionState.done) {
        return _accountShell(const CollectorLoading(label: 'Loading account…'));
      }
      return _accountShell(
        Scaffold(
          child: Builder(
            builder: (BuildContext appContext) => Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      LocalAccountData.isDeleting(widget.user.uid)
                          ? 'Your deletion request is awaiting confirmation. Account changes are paused.'
                          : 'Could not load your account.',
                    ),
                    const SizedBox(height: 16),
                    PrimaryButton(
                      onPressed: () {
                        if (LocalAccountData.isDeleting(widget.user.uid)) {
                          showAccountDeletionDialog(
                            appContext,
                            auth: FirebaseCollectorAuth.instance,
                            requestDeletion: () => AccountDeletionController
                                .instance
                                .request(widget.user.uid),
                          );
                        } else {
                          setState(() {
                            _ready = prepareAccount(widget.user.uid);
                          });
                        }
                      },
                      child: const Text('Retry'),
                    ),
                    TextButton(
                      onPressed: () => SignOutManager.signOut(appContext),
                      child: const Text('Sign Out'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _AuthenticatedCollector extends StatefulWidget {
  final User user;
  const _AuthenticatedCollector({required this.user});
  @override
  State<_AuthenticatedCollector> createState() =>
      _AuthenticatedCollectorState();
}

class _AuthenticatedCollectorState extends State<_AuthenticatedCollector> {
  late Future<void> _setup = _ensureProfile();

  Future<void> _ensureProfile() async {
    LocalAccountData.requireWritable(widget.user.uid);
    final DocumentReference<AppUser> reference = Crud.user().collection.doc(
      widget.user.uid,
    );
    final DocumentSnapshot<AppUser> existing = await reference.get();
    if (existing.exists) {
      return;
    }
    await reference.firestore.runTransaction<void>((
      Transaction transaction,
    ) async {
      final DocumentSnapshot<AppUser> snapshot = await transaction.get(
        reference,
      );
      if (!snapshot.exists) {
        LocalAccountData.requireWritable(widget.user.uid);
        transaction.set(reference, AppUser());
      }
    });
  }

  Widget _accountStatus({
    required bool failed,
    ThemeMode mode = ThemeMode.system,
  }) {
    return ArcaneApp(
      builder: _systemBars,
      title: 'The Collector',
      theme: MyThemeData.themeData(mode),
      home: Builder(
        builder: (BuildContext appContext) => Scaffold(
          child: Center(
            child: failed
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text('Could not load your account.'),
                      const SizedBox(height: 12),
                      PrimaryButton(
                        onPressed: () => setState(() {
                          _setup = _ensureProfile();
                        }),
                        child: const Text('Retry'),
                      ),
                      TextButton(
                        onPressed: () => SignOutManager.signOut(appContext),
                        child: const Text('Sign Out'),
                      ),
                    ],
                  )
                : const CollectorLoading(label: 'Loading your collection…'),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _setup,
    builder: (BuildContext context, AsyncSnapshot<void> setup) {
      if (setup.connectionState != ConnectionState.done || setup.hasError) {
        return _accountStatus(failed: setup.hasError);
      }
      final User user = widget.user;
      return StreamBuilder<AppUser?>(
        stream: Crud.user().streamOrNull(user.uid),
        builder: (BuildContext context, AsyncSnapshot<AppUser?> profile) {
          if (!profile.hasData) {
            return _accountStatus(
              failed:
                  profile.hasError ||
                  profile.connectionState == ConnectionState.active ||
                  profile.connectionState == ConnectionState.done,
              mode: ThemeMode.dark,
            );
          }
          return StreamBuilder<AppUserRestricted?>(
            stream: Crud.userRestricted(user.uid).streamOrNull('perms'),
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<AppUserRestricted?> permissions,
                ) => Provider<AppUser?>.value(
                  value: profile.data,
                  child: Provider<AppUserRestricted?>.value(
                    value: permissions.data,
                    child: ArcaneApp(
                      builder: _systemBars,
                      key: ValueKey<String>(user.uid),
                      title: 'The Collector',
                      theme: MyThemeData.themeData(
                        profile.data!.theme ? ThemeMode.light : ThemeMode.dark,
                      ),
                      home: const CollectorHub(),
                      routes: <String, WidgetBuilder>{
                        '/login': (_) => const CollectorSignInScreen(),
                        '/home': (_) => const CollectorHub(),
                        '/collection': (_) => const CollectorHub(),
                        '/admin': (_) => const AdminHub(),
                      },
                    ),
                  ),
                ),
          );
        },
      );
    },
  );
}


class SignOutManager {
  static Future<void> signOut(
    BuildContext context, {
    CollectorAuth? auth,
  }) async {
    try {
      await (auth ?? FirebaseCollectorAuth.instance).signOut();
      if (context.mounted) {
        Navigator.of(context).popUntil((Route<Object?> route) => route.isFirst);
      }
    } catch (_) {
      if (context.mounted) {
        const TextToast('Could not finish signing out. Try again.')
            .open(context);
      }
    }
  }
}
