## 0.1.5

* Fixed editor height: use `height: 100%` instead of `min-height: 100%` in CSS, and reset to `height: auto` alongside `minHeight: auto` when auto-resizing.

## 0.1.4

* Fixed web iframe pointer-events so Flutter dialogs (e.g. link dialog) correctly receive pointer events when shown on top of the editor.
* Added `disablePointerEvents()` and `enablePointerEvents()` methods to `RichEditorController` for manual control from custom link dialog callbacks.
* Renamed iOS podspec to `rich_text_editor_plus.podspec` to match the package name.

## 0.1.3

* Updated README with improved documentation.

## 0.1.0

* Initial release of `rich_text_editor_plus`.
* Rich text editor with native Flutter toolbar for Android, iOS, and Web.
* Supports bold, italic, underline, strikethrough, links, ordered/unordered nested lists, and alignment.
* HTML import/export via `RichTextEditorController`.
* Customizable toolbar via `ToolbarConfig`.
