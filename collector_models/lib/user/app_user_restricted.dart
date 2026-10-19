import 'package:dart_mappable/dart_mappable.dart';

part 'app_user_restricted.mapper.dart';

@MappableClass()
class AppUserRestricted with AppUserRestrictedMappable {
  String? id;
  bool admin;

  AppUserRestricted({this.admin = false});
}
