import 'package:dart_mappable/dart_mappable.dart';

part 'app_user.mapper.dart';

// We need to tell mappable what types this is a superclass of for it to work
@MappableClass()
class AppUser with AppUserMappable {
  String? id;
  bool theme;

  AppUser({
    this.theme = false,
  });

  void toggleTheme() {
    theme = !theme;
  }
}
