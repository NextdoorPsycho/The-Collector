# Arcane compatibility patch

Source: [ArcaneArts/arcane](https://github.com/ArcaneArts/arcane/tree/b7f6df7423293292f9e1b3ed2e5bc475d61d98bb), upstream version 6.5.14, commit `b7f6df7423293292f9e1b3ed2e5bc475d61d98bb`.

This copy derives from the upstream runtime and retains its fonts, shaders, and license. It requires Flutter 3.47 and Dart 3.13. Compatibility changes include:

- Replace removed icon subclasses with plain `IconData`. Keep Phosphor glyph codes and font. Map Ionic aliases to the matching names in Ionicons 0.2.3, whose glyph codes changed.
- Remove `flutter_phosphor_icons`, which subclasses Flutter's final `IconData`. Its font and MIT license are in `fonts/`.
- Allow Font Awesome Flutter 11.
- Calculate the liquid-glass SDF normal with central differences. SkSL runtime shaders do not support `dFdx` or `dFdy`. Refraction and lighting still use the same normal.
- Use the current Markdown parser with Arcane table borders, wrapping links, and full quote surfaces. Preserve math and selectable monospace code.
- Remove the unused `CodeSnippet` component and its syntax-highlighting dependency. This also removes the native clipboard plugin chain.

The Collector restores visible bottom navigation labels and selected tab semantics in `IconTab`. Navigation measures scaled labels and wraps tabs into additional rows when needed. Scaffold reserves the footer's actual height and retains keyboard traversal order.

`Selector` uses `SelectPopup` to install the selection handle required by the current option buttons. This restores selection in collection filters, deck sections, and printing review.

Buttons keep a minimum 44×44 touch area on iOS, Android, and viewports narrower than 600 pixels. Existing larger buttons and desktop density are preserved.

Focus rings use 65% opacity so the app's black and white rings remain visible against filled inputs.
Outlined controls use the theme's border color for their complete perimeter while keeping the original fill.

Scaffold consumes system safe-area insets around the complete layout. Headers, body content, footers, and nested panes stay clear of notches and the home indicator without adding those insets twice.

Dialog actions wrap on narrow screens and at larger text sizes. Text-entry dialogs dispose their controllers and focus nodes.

`TextField.semanticLabel` keeps the editable field named after text is entered. Clear controls merge their icon labels with button semantics while remaining separate from the editable field.

Replace this copy with the published Arcane package once upstream supports the current Flutter SDK. Preserve `LICENSE` and `fonts/PHOSPHOR_LICENSE` when distributing these assets.

The runtime dependencies now use Cached Network Image 4.0.4, Skeletonizer 3, Country Flags 4.1.2, Dotted Border 3.1, and Measure Size 5.0.2. Skeleton loading keeps Arcane's pulse colors and explicit app brightness through `effectResolver`. Phone flags retain their image geometry through `ImageTheme`. `DashedBorderSignal.shape` uses Arcane's `DashedBorderShape` and the four public dotted-border option classes; the removed upstream `BorderType` API is not retained. Measured quilts reject a missing child. Image provider call sites need no API changes.
