import 'package:arcane/arcane.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collector_models/user/app_user.dart';
import 'package:collector_models/user/app_user_restricted.dart';
import 'package:flutter/services.dart' show TextInputAction;
import 'package:provider/provider.dart';
import 'package:the_collector/pages/collection/collection_decks.dart';
import 'package:the_collector/theme/collector_brand.dart';
import 'package:the_collector/utils/crud.dart';

typedef AdminUserPageLoader = Future<List<AppUser>> Function({
  required String prefix,
  required int limit,
  String? after,
});

class AdminUsers extends StatefulWidget {
  const AdminUsers({
    super.key,
    this.loadUsers,
    this.permissionStore,
    this.currentUserId,
  });
  final AdminUserPageLoader? loadUsers;
  final CollectionStore<AppUserRestricted> Function(String)? permissionStore;
  final String? currentUserId;
  @override
  State<AdminUsers> createState() => _AdminUsersState();
}

class _AdminUsersState extends State<AdminUsers> {
  static const int _pageSize = 50;
  Future<List<AppUser>>? _users;
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<String?> _cursors = <String?>[null];
  String _query = '';
  int _page = 0;
  AppUser? _selected;
  bool _wasAllowed = false;

  Future<List<AppUser>> _load() async {
    final String? cursor = _cursors[_page];
    if (widget.loadUsers != null) {
      return widget.loadUsers!(
        prefix: _query,
        after: cursor,
        limit: _pageSize + 1,
      );
    }
    Query<AppUser> query = Crud.user().collection.orderBy(FieldPath.documentId);
    if (_query.isNotEmpty) {
      query = query.startAt(<Object>[_query]).endAt(<Object>['$_query\uf8ff']);
    }
    if (cursor != null) query = query.startAfter(<Object>[cursor]);
    final QuerySnapshot<AppUser> snapshot = await query
        .limit(_pageSize + 1)
        .get();
    return snapshot.docs
        .map((QueryDocumentSnapshot<AppUser> document) => document.data())
        .toList();
  }

  void _searchUsers() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _query = _search.text.trim();
      _page = 0;
      _cursors
        ..clear()
        ..add(null);
      _users = _load();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _showPage(int page, {String? cursor}) {
    setState(() {
      if (page == _cursors.length) _cursors.add(cursor);
      _page = page;
      _users = _load();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _close() => Align(
    alignment: Alignment.centerRight,
    child: SizedBox.square(
      dimension: 44,
      child: IconButton(
        icon: const Icon(Icons.x, semanticLabel: 'Close administration'),
        variance: ButtonVariance.ghost,
        onPressed: () => Navigator.pop(context),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final bool allowed = context.watch<AppUserRestricted?>()?.admin ?? false;
    if (!allowed) {
      _wasAllowed = false;
      _users = null;
      _selected = null;
    } else if (!_wasAllowed) {
      _wasAllowed = true;
      _page = 0;
      _cursors
        ..clear()
        ..add(null);
      _users = _load();
    }
    final AppUser? selected = _selected;
    return Scaffold(
      headers: <Widget>[if (Navigator.canPop(context)) _close()],
      child: !allowed
          ? const Center(child: Text('Administrator access is required.'))
          : selected != null
          ? _AdminUserDetails(
              key: ValueKey<String>(selected.id!),
              user: selected,
              ownAccount: selected.id == (widget.currentUserId ?? u),
              permissions: (widget.permissionStore ?? Crud.userRestricted)(
                selected.id!,
              ),
              onDone: () => setState(() => _selected = null),
            )
          : CustomScrollView(
              controller: _scroll,
              slivers: <Widget>[
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _search,
                            semanticLabel: 'User ID prefix',
                            placeholder: const ExcludeSemantics(
                              child: Text('User ID prefix'),
                            ),
                            textInputAction: TextInputAction.search,
                            onSubmitted: (_) => _searchUsers(),
                            features: const <InputFeature>[
                              InputFeature.clear(
                                icon: Icon(
                                  LucideIcons.x,
                                  semanticLabel: 'Clear user search',
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        SecondaryButton(
                          onPressed: _searchUsers,
                          child: const Text('Search'),
                        ),
                      ],
                    ),
                  ),
                ),
                FutureBuilder<List<AppUser>>(
                  future: _users,
                  builder:
                      (
                        BuildContext context,
                        AsyncSnapshot<List<AppUser>> snapshot,
                      ) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const SliverToBoxAdapter(
                            child: CollectorLoading(label: 'Loading users…'),
                          );
                        }
                        if (snapshot.hasError) {
                          return SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  const Text('Could not load users.'),
                                  SecondaryButton(
                                    onPressed: () => setState(() {
                                      _users = _load();
                                    }),
                                    child: const Text('Retry'),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }
                        final List<AppUser> documents = snapshot.data!;
                        final List<AppUser> users = documents
                            .take(_pageSize)
                            .toList();
                        return SliverMainAxisGroup(
                          slivers: <Widget>[
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Wrap(
                                  spacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: <Widget>[
                                    if (_page > 0)
                                      TextButton(
                                        onPressed: () => _showPage(_page - 1),
                                        child: const Text('Previous page'),
                                      ),
                                    Text(
                                      users.isEmpty
                                          ? 'No matching users.'
                                          : '${_page * _pageSize + 1}–${_page * _pageSize + users.length}',
                                    ),
                                    if (documents.length > _pageSize)
                                      TextButton(
                                        onPressed: () => _showPage(
                                          _page + 1,
                                          cursor: users.last.id,
                                        ),
                                        child: const Text('Next page'),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              sliver: SliverList.builder(
                                itemCount: users.length,
                                itemBuilder: (BuildContext context, int index) {
                                  final AppUser user = users[index];
                                  return Container(
                                    decoration: BoxDecoration(
                                      border: Border(
                                        bottom: BorderSide(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .border,
                                        ),
                                      ),
                                    ),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minHeight: 52,
                                      ),
                                      child: Tile(
                                        title: Text(user.id!),
                                        trailing: const Icon(
                                          Icons.caret_right,
                                          size: 16,
                                        ),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                        onPressed: () =>
                                            setState(() => _selected = user),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        );
                      },
                ),
              ],
            ),
    );
  }
}

class _AdminUserDetails extends StatefulWidget {
  const _AdminUserDetails({
    super.key,
    required this.user,
    required this.permissions,
    required this.ownAccount,
    required this.onDone,
  });
  final AppUser user;
  final CollectionStore<AppUserRestricted> permissions;
  final bool ownAccount;
  final VoidCallback onDone;
  @override
  State<_AdminUserDetails> createState() => _AdminUserDetailsState();
}

class _AdminUserDetailsState extends State<_AdminUserDetails> {
  late final Stream<AppUserRestricted?> _permissions = widget.permissions
      .streamOrNull('perms');
  bool _busy = false;
  bool _confirming = false;
  String? _error;

  Future<void> _confirmAdmin(bool value) async {
    if (_busy || _confirming || widget.ownAccount) return;
    setState(() => _confirming = true);
    try {
      await DialogConfirm(
        title: value
            ? 'Grant administrator access?'
            : 'Remove administrator access?',
        description: widget.user.id!,
        confirmText: value ? 'Grant access' : 'Remove access',
        onConfirm: () => _setAdmin(value),
      ).open(context);
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  Future<void> _setAdmin(bool value) async {
    if (!mounted ||
        _busy ||
        widget.ownAccount ||
        !(context.read<AppUserRestricted?>()?.admin ?? false)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.permissions.set('perms', AppUserRestricted(admin: value));
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not update this permission. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: <Widget>[
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: _busy ? null : widget.onDone,
          child: const Text('Users'),
        ),
      ),
      SelectableText(
        widget.user.id!,
        style: Theme.of(context).typography.large,
      ),
      if (widget.ownAccount) ...<Widget>[
        const SizedBox(height: 8),
        const Text('Your account'),
      ],
      const SizedBox(height: 16),
      StreamBuilder<AppUserRestricted?>(
        stream: _permissions,
        builder:
            (BuildContext context, AsyncSnapshot<AppUserRestricted?> snapshot) {
              final bool canChange =
                  !_busy &&
                  !_confirming &&
                  !widget.ownAccount &&
                  snapshot.connectionState != ConnectionState.waiting &&
                  !snapshot.hasError;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  MergeSemantics(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 52),
                      child: Tile(
                        title: const Text('Administrator access'),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                        ),
                        onPressed: canChange
                            ? () => _confirmAdmin(
                                !(snapshot.data?.admin ?? false),
                              )
                            : null,
                        trailing: Switch(
                          value: snapshot.data?.admin ?? false,
                          onChanged: canChange ? _confirmAdmin : null,
                        ),
                      ),
                    ),
                  ),
                  if (snapshot.hasError)
                    const Text('Could not load permissions.')
                  else if (snapshot.connectionState == ConnectionState.waiting)
                    const CollectorLoading(label: 'Loading permissions…'),
                  if (_error != null)
                    Semantics(liveRegion: true, child: Text(_error!)),
                ],
              );
            },
      ),
    ],
  );
}
