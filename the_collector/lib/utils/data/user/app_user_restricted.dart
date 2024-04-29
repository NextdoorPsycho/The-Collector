import 'package:dart_mappable/dart_mappable.dart';

part 'app_user_restricted.mapper.dart';

// We need to tell mappable what types this is a superclass of for it to work
@MappableClass()
class AppUserRestricted with AppUserRestrictedMappable {
  String? id;
  bool admin;

  AppUserRestricted({
    this.admin = false,
  });
}
