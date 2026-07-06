## 0.1.6

* Added `RichTextEditor.onOverscroll` — on web, the editor forwards the wheel delta to the host when it is scrolled past its own boundary (or has no scrollable overflow), so an enclosing scroll view can continue. Fixes the case where a web iframe swallows wheel events and an enclosing scrollable can't scroll while the pointer is over the editor. Purely additive and opt-in.
* Added `RichTextEditor.onWheel` — on web, fires the wheel delta on every wheel event over the editor, regardless of scroll position or direction. Complements `onOverscroll` (boundary-only) for hosts that want to react to any scroll immediately (e.g. collapse a header on the first scroll). Purely additive.
* Fixed cross-talk between multiple editors on web. Each editor iframe postMessages to the same parent window, so previously every `RichEditorController` received every other editor's events (e.g. a read-only viewer's content leaking into an open compose editor). Each message is now stamped with the host view's unique `channelId`, and the web host only handles messages from its own iframe. Purely additive; mobile (per-WebView channel) is unaffected.

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
