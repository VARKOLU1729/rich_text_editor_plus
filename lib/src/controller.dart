import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'models/content.dart';
import 'models/selection_style.dart';

/// Callback type for content changes.
typedef ContentChangedCallback = void Function(EditorContent content);

/// Callback type for requesting a link dialog (triggered by Ctrl+K).
typedef LinkRequestCallback = void Function();

/// Controller for the Rich Text Editor.
///
/// Manages communication between the Flutter UI and the JS-based editor.
/// Maintains the current content and selection style state.
///
/// Usage:
/// ```dart
/// final controller = RichEditorController(
///   initialHtml: '<p>Hello <b>world</b></p>',
/// );
/// controller.execCommand('bold');
/// print(controller.getHtml());
/// ```
class RichEditorController extends ChangeNotifier {
  /// Current content of the editor.
  EditorContent _content = EditorContent.empty;
  EditorContent get content => _content;

  /// Current selection style at the cursor.
  SelectionStyle _selectionStyle = SelectionStyle.none;
  SelectionStyle get selectionStyle => _selectionStyle;

  /// Whether the editor has focus.
  bool _hasFocus = false;
  bool get hasFocus => _hasFocus;

  /// Whether the JS editor is ready.
  bool _isReady = false;
  bool get isReady => _isReady;

  /// Content height reported by JS (used for auto-height read-only viewer).
  double? _contentHeight;
  double? get contentHeight => _contentHeight;

  double? _caretTop;
  double? _caretBottom;

  /// Top and bottom of the line the caret is on, measured from the top of the document — the same
  /// origin as [contentHeight], so a host can use them against the height it sizes the editor to.
  ///
  /// Reported in auto-height mode only, where this editor has no scroll of its own and the host is
  /// the only thing that can bring the caret into view. Null until the first report.
  double? get caretTop => _caretTop;
  double? get caretBottom => _caretBottom;

  /// Callback for content changes.
  ContentChangedCallback? onContentChanged;

  /// Callback when Ctrl+K requests a link dialog.
  LinkRequestCallback? onLinkRequest;

  /// Called with the wheel delta when the editor is scrolled past its own scroll boundary, so a
  /// host scroll view can continue scrolling (scroll chaining across the web iframe boundary).
  void Function(double deltaY)? onOverscroll;

  /// Called with the wheel delta on EVERY wheel event over the editor (web), regardless of scroll
  /// position or direction — for hosts that want to react to any scroll (e.g. collapse a header on
  /// the first scroll).
  void Function(double deltaY)? onWheel;

  /// Called with a link's URL when it is tapped in a (read-only) body. The mobile
  /// WebView blocks in-editor navigation, so the host opens the URL externally
  /// (e.g. url_launcher). On web, links open natively so this is unused.
  void Function(String url)? onLinkTap;

  /// Internal: set by WebEditor on web to toggle the iframe's pointer-events.
  /// Pass null to unregister.
  void Function(bool enable)? _pointerEventsCallback;

  void setPointerEventsCallback(void Function(bool enable)? callback) {
    _pointerEventsCallback = callback;
  }

  /// Unregisters [callback], but only if it is still the registered one — a later editor sharing this
  /// controller may already have replaced it, and clearing that one would leave the live editor unable
  /// to release its iframe's pointer events.
  void clearPointerEventsCallback(void Function(bool enable) callback) {
    if (identical(_pointerEventsCallback, callback)) _pointerEventsCallback = null;
  }

  /// Disable pointer events on the editor iframe (call before showing a dialog on web).
  void disablePointerEvents() => _pointerEventsCallback?.call(false);

  /// Re-enable pointer events on the editor iframe (call after a dialog closes).
  void enablePointerEvents() => _pointerEventsCallback?.call(true);

  /// Queue of commands to execute once JS is ready.
  final List<String> _commandQueue = [];

  /// Millisecond timestamp of the last formatting toggle.
  ///
  /// Used by the guard window to determine whether incoming selectionStyle messages should
  /// be allowed to overwrite the optimistic formatting state set by the toggle.
  int _lastToggleTimestamp = 0;

  /// Guard window duration in milliseconds.
  ///
  /// Incoming selectionStyle messages that arrive within this window preserve the
  /// optimistic formatting fields set by the most recent toggle.
  static const int _toggleGuardMs = 200;

  /// Function to evaluate JavaScript. Set by the platform editor widget as soon as it has a
  /// WebView/iframe to run JS in. Assigning it drains any commands queued while there was none.
  ///
  /// A new editor claiming the channel also puts the controller back to not-ready: readiness belongs
  /// to a document, and the incoming editor's has not loaded yet. Without that, a controller handed
  /// between editors carries `_isReady` over from the old one and every command sent before the new
  /// document announces itself is evaluated against a page that cannot run it — silently lost
  /// instead of queued.
  Future<String?> Function(String js)? _evaluateJavascript;
  Future<String?> Function(String js)? get evaluateJavascript => _evaluateJavascript;
  set evaluateJavascript(Future<String?> Function(String js)? fn) {
    final bool isNewChannel = fn != null && !identical(fn, _evaluateJavascript);
    _evaluateJavascript = fn;
    if (isNewChannel) _isReady = false;
    _flushIfReady();
  }

  /// Runs any queued commands once the editor is ready AND a JS executor exists.
  /// Iterates a copy so commands re-queued mid-flush can't corrupt the iteration.
  void _flushIfReady() {
    if (!_isReady || _evaluateJavascript == null) return;
    final List<String> pending = List<String>.from(_commandQueue);
    _commandQueue.clear();
    for (final js in pending) {
      _evaluateJavascript!(js);
    }
  }

  /// Optional initial HTML content to load when the editor is ready.
  String? initialHtml;

  /// Whether the editor is read-only (non-editable).
  bool readOnly;

  /// Whether the editable editor is in auto-height mode — see [setAutoHeight].
  ///
  /// Persisted on the controller, like [readOnly] and [initialHtml], so it can be re-applied to a
  /// fresh editor: a controller can outlive the editor widget it drives (a compose surface that moves
  /// between two hosts, a minimise/restore, …) and every new editor starts in the default
  /// fixed-height mode.
  bool autoHeight;

  RichEditorController({this.initialHtml, this.readOnly = false, this.autoHeight = false});

  // -----------------------------------------------------------------------
  // Handle messages from JS
  // -----------------------------------------------------------------------

  /// Process a message received from the JS editor bridge.
  void handleMessage(String messageJson) {
    try {
      final data = jsonDecode(messageJson) as Map<String, dynamic>;
      final type = data['type'] as String?;

      switch (type) {
        case 'contentChanged':
          _content = EditorContent(
            html: data['html'] as String? ?? '',
            plainText: data['plainText'] as String? ?? '',
          );
          onContentChanged?.call(_content);
          notifyListeners();
          break;

        case 'selectionStyle':
          final now = DateTime.now().millisecondsSinceEpoch;
          final guarded = now - _lastToggleTimestamp < _toggleGuardMs;
          if (guarded) {
            // Guard window is active: preserve the optimistic formatting values set by the
            // last toggle. Only non-formatting fields (alignment, lists, linkUrl) are updated
            // from JS, as those are not affected by the browser queryCommandState bug.
            _selectionStyle = SelectionStyle(
              isBold: _selectionStyle.isBold,
              isItalic: _selectionStyle.isItalic,
              isUnderline: _selectionStyle.isUnderline,
              isStrikethrough: _selectionStyle.isStrikethrough,
              isOrderedList: data['orderedList'] == true,
              isUnorderedList: data['unorderedList'] == true,
              linkUrl: data['linkUrl'] as String?,
              linkText: data['linkText'] as String?,
              alignment: (data['alignment'] as String?) ?? 'left',
            );
          } else {
            _selectionStyle = SelectionStyle.fromJson(data);
          }
          notifyListeners();
          break;

        case 'toolbarToggle':
          // Keyboard shortcut (Ctrl+B/I/U) rerouted from JS so the optimistic
          // update and guard window apply, matching the toolbar button path.
          final action = data['action'] as String?;
          if (action != null) handleToolbarAction(action);
          break;

        case 'ready':
          _isReady = true;
          if (initialHtml != null && initialHtml!.isNotEmpty) {
            _executeJs("window.editorBridge.setHtml(${jsonEncode(initialHtml)})");
          }
          if (readOnly) {
            _executeJs("window.editorBridge.setReadOnly(true)");
          }
          // Re-assert auto-height on every editor that becomes ready, not just the one that was
          // live when setAutoHeight() was called. Without this, a host that swaps editors under the
          // same controller silently loses the setting: _isReady is still true from the previous
          // editor, so the setAutoHeight() the new host sends on mount is executed against the old,
          // dying iframe instead of being queued for the new one — which then keeps its own inner
          // scroll and never reports a height.
          if (autoHeight) {
            _executeJs("window.editorBridge.setAutoHeight(true)");
          }
          // Flush queued commands — safe against the mobile race where 'ready'
          // arrives before evaluateJavascript is wired (the setter re-flushes then).
          _flushIfReady();
          notifyListeners();
          break;

        case 'heightChanged':
          _contentHeight = (data['height'] as num?)?.toDouble();
          notifyListeners();
          break;

        case 'caretMoved':
          final double? caretTop = (data['top'] as num?)?.toDouble();
          final double? caretBottom = (data['bottom'] as num?)?.toDouble();
          if (caretTop == null || caretBottom == null) break;
          // Every keystroke and every arrow key reports, and most land on the same line — a host that
          // scrolls to the caret would otherwise be asked to do it again for no movement.
          if (caretTop == _caretTop && caretBottom == _caretBottom) break;
          _caretTop = caretTop;
          _caretBottom = caretBottom;
          notifyListeners();
          break;

        case 'focus':
          _hasFocus = true;
          notifyListeners();
          break;

        case 'blur':
          _hasFocus = false;
          notifyListeners();
          break;

        case 'linkRequest':
          onLinkRequest?.call();
          break;

        case 'overscroll':
          onOverscroll?.call((data['deltaY'] as num?)?.toDouble() ?? 0);
          break;

        case 'wheel':
          onWheel?.call((data['deltaY'] as num?)?.toDouble() ?? 0);
          break;

        default:
          debugPrint('RichEditorController: unknown message type: $type');
      }
    } catch (e) {
      debugPrint('RichEditorController: error handling message: $e');
    }
  }

  // -----------------------------------------------------------------------
  // Public API: Commands to JS
  // -----------------------------------------------------------------------

  /// Execute a formatting command (bold, italic, insertOrderedList, etc.).
  void execCommand(String command, [String? value]) {
    if (value != null) {
      _executeJs("window.editorBridge.execCommand('$command', ${jsonEncode(value)})");
    } else {
      _executeJs("window.editorBridge.execCommand('$command')");
    }
  }

  /// Set the editor's HTML content, replacing everything.
  void setHtml(String html) {
    _executeJs("window.editorBridge.setHtml(${jsonEncode(html)})");
  }

  /// Get the current HTML content (cached, synchronous).
  String getHtml() => _content.html;

  /// Get the current HTML content directly from JS (async, most up-to-date).
  Future<String> getHtmlAsync() async {
    final result = await _executeJsWithResult("window.editorBridge.getHtml()");
    return result ?? _content.html;
  }

  /// Get the current plain text content (cached, synchronous).
  String getPlainText() => _content.plainText;

  /// Get the current plain text content directly from JS (async).
  Future<String> getPlainTextAsync() async {
    final result = await _executeJsWithResult("window.editorBridge.getPlainText()");
    return result ?? _content.plainText;
  }

  /// Insert a link. If text is selected, wraps it. Otherwise inserts new linked text.
  void insertLink(String url, [String? text]) {
    if (text != null) {
      _executeJs("window.editorBridge.insertLink(${jsonEncode(url)}, ${jsonEncode(text)})");
    } else {
      _executeJs("window.editorBridge.insertLink(${jsonEncode(url)})");
    }
  }

  /// Remove the link at the current cursor position.
  void removeLink() {
    _executeJs("window.editorBridge.removeLink()");
  }

  /// Insert HTML at the current cursor position.
  void insertHtml(String html) {
    _executeJs("window.editorBridge.insertHtml(${jsonEncode(html)})");
  }

  /// Set text alignment for the current block.
  void setAlignment(String alignment) {
    _executeJs("window.editorBridge.setAlignment(${jsonEncode(alignment)})");
  }

  /// Clear all content and reset all formatting state.
  ///
  /// Resetting [_lastToggleTimestamp] ensures no guard window is active after a clear,
  /// so the toolbar reflects the blank-editor state immediately.
  void clear() {
    _executeJs("window.editorBridge.clear()");
    _selectionStyle = SelectionStyle.none;
    _lastToggleTimestamp = 0;
    notifyListeners();
  }

  /// Focus the editor.
  void focus() {
    _executeJs("window.editorBridge.focus()");
  }

  /// Blur the editor.
  void blur() {
    _executeJs("window.editorBridge.blur()");
  }

  /// Toggle read-only mode at runtime.
  void setReadOnly(bool value) {
    readOnly = value;
    _executeJs("window.editorBridge.setReadOnly(${value ? 'true' : 'false'})");
  }

  /// Toggle editable auto-height mode at runtime.
  ///
  /// When [value] is true the editor grows to fit its content and reports its
  /// height (via `heightChanged`), so a parent scroll view can scroll through
  /// the whole body. When false it reverts to a fixed height with its own inner
  /// scroll, and the stale [contentHeight] (and caret) is dropped so the next build falls
  /// back to the host-provided height.
  void setAutoHeight(bool value) {
    // Remembered so a later editor can pick it up on its own 'ready' — see handleMessage.
    autoHeight = value;
    _executeJs("window.editorBridge.setAutoHeight(${value ? 'true' : 'false'})");
    // Cleared WITHOUT notifying, deliberately. Hosts switch auto-height off while tearing down (the
    // usual reason being that they are handing this controller to another editor), and a notification
    // dispatched from a dispose() reaches listeners whose elements are mid-unmount — asking them to
    // rebuild while the widget tree is locked, which throws. Nothing is lost: whichever editor renders
    // next reads the cleared value on its first build.
    if (!value) {
      _contentHeight = null;
      _caretTop = null;
      _caretBottom = null;
    }
  }

  // -----------------------------------------------------------------------
  // Toolbar action dispatch
  // -----------------------------------------------------------------------

  /// Shared logic for bold / italic / underline / strikethrough toolbar toggles.
  ///
  /// Applies an optimistic flip to [_selectionStyle], starts the guard window, tells JS
  /// to enforce the new value at the cursor (Layer 3), then executes the browser command.
  void _toggleFormatting(String property, String command) {
    _selectionStyle = switch (property) {
      'bold' => _selectionStyle.copyWith(isBold: !_selectionStyle.isBold),
      'italic' => _selectionStyle.copyWith(isItalic: !_selectionStyle.isItalic),
      'underline' => _selectionStyle.copyWith(isUnderline: !_selectionStyle.isUnderline),
      'strikethrough' => _selectionStyle.copyWith(isStrikethrough: !_selectionStyle.isStrikethrough),
      _ => _selectionStyle,
    };
    final desiredValue = switch (property) {
      'bold' => _selectionStyle.isBold,
      'italic' => _selectionStyle.isItalic,
      'underline' => _selectionStyle.isUnderline,
      'strikethrough' => _selectionStyle.isStrikethrough,
      _ => false,
    };
    _lastToggleTimestamp = DateTime.now().millisecondsSinceEpoch;
    _executeJs("window.editorBridge.setEnforcement(${jsonEncode({property: desiredValue})})");
    execCommand(command);
    notifyListeners();
  }

  /// Handle a toolbar action by name. Maps action names to JS commands.
  void handleToolbarAction(String action) {
    switch (action) {
      case 'bold':
        _toggleFormatting('bold', 'bold');
        break;
      case 'italic':
        _toggleFormatting('italic', 'italic');
        break;
      case 'underline':
        _toggleFormatting('underline', 'underline');
        break;
      case 'strikethrough':
        _toggleFormatting('strikethrough', 'strikeThrough');
        break;
      case 'orderedList':
        execCommand('insertOrderedList');
        break;
      case 'unorderedList':
        execCommand('insertUnorderedList');
        break;
      case 'indent':
        execCommand('indent');
        break;
      case 'outdent':
        execCommand('outdent');
        break;
      case 'alignLeft':
        setAlignment('left');
        break;
      case 'alignCenter':
        setAlignment('center');
        break;
      case 'alignRight':
        setAlignment('right');
        break;
      case 'alignJustify':
        setAlignment('justify');
        break;
      case 'undo':
        execCommand('undo');
        break;
      case 'redo':
        execCommand('redo');
        break;
      case 'clearFormatting':
        execCommand('removeFormat');
        break;
      case 'link':
        onLinkRequest?.call();
        break;
      default:
        debugPrint('RichEditorController: unknown action: $action');
    }
  }

  // -----------------------------------------------------------------------
  // Internal
  // -----------------------------------------------------------------------

  void _executeJs(String js) {
    if (_isReady && _evaluateJavascript != null) {
      _evaluateJavascript!(js);
    } else {
      _commandQueue.add(js);
    }
  }

  Future<String?> _executeJsWithResult(String js) async {
    if (_evaluateJavascript != null) {
      return _evaluateJavascript!(js);
    }
    return null;
  }

  @override
  void dispose() {
    _commandQueue.clear();
    super.dispose();
  }
}
