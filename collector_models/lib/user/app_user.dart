import 'package:dart_mappable/dart_mappable.dart';

part 'app_user.mapper.dart';

@MappableClass()
class AppUser with AppUserMappable {
  String? id;
  bool theme;
  bool showCommander;

  AppUser({this.theme = false, this.showCommander = false});

  void toggleTheme() {
    theme = !theme;
  }
}
