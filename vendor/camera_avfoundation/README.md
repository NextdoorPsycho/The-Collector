# camera\_avfoundation

The iOS implementation of [`camera`][1].

This local fork keeps maximum still-photo capture while limiting iOS 16 and later video buffers to a 1920-pixel edge during image streaming. Analysis delivery is capped at 10 FPS before pixels cross into Flutter; preview frames keep the camera's normal cadence. Buffer dimensions follow the active format and capture orientation. Stopping the image stream restores the default video dimensions.

## Usage

This package is [endorsed][2], which means you can simply use `camera`
normally. This package will be automatically included in your app when you do,
so you do not need to add it to your `pubspec.yaml`.

However, if you `import` this package to use any of its APIs directly, you
should add it to your `pubspec.yaml` as usual.

[1]: https://pub.dev/packages/camera
[2]: https://flutter.dev/to/endorsed-federated-plugin
