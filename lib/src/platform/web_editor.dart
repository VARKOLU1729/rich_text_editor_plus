import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../js/editor_html.dart';
import 'editor_platform.dart';

/// Web editor implementation using an iframe rendered via HtmlElementView.
///
/// More efficient than WebView on web since there's no WebView overhead —
/// it's a direct iframe in the browser.
class WebEditor extends EditorPlatform {
  const WebEditor({
    super.key,
    required super.controller,
    required super.theme,
    super.height,
  });

  @override
  State<WebEditor> createState() => _WebEditorState();
}

class _WebEditorState extends State<WebEditor> {
  late final String _viewType;
  web.HTMLIFrameElement? _iframe;
  StreamSubscription<web.MessageEvent>? _messageSubscription;

  // Pending Flutter -> iframe eval requests, keyed by id, awaiting their
  // '__execResult' reply (see _listenForMessages and editor_html.dart).
  final Map<int, Completer<String?>> _pendingExecs = {};
  int _nextExecId = 0;

  // The pointer-events toggle this editor registered on the controller, if any.
  void Function(bool enable)? _pointerEventsCallback;

  @override
  void initState() {
    super.initState();
    _viewType = 'rich-editor-${DateTime.now().millisecondsSinceEpoch}';
    _registerView();
    _listenForMessages();
  }

  void _registerView() {
    // ignore: undefined_prefixed_name
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      _iframe = web.HTMLIFrameElement()
        ..style.setProperty('border', 'none')
        ..style.setProperty('width', '100%')
        ..style.setProperty('height', '100%')
        // No allow-same-origin: this keeps the iframe on a unique opaque origin, so
        // rendered email/compose content can never reach the host app's cookies,
        // localStorage, or DOM even if a sanitizer gap let a script run. allow-popups
        // is kept so insertLink's target="_blank" links keep opening a new tab.
        ..setAttribute('sandbox', 'allow-scripts allow-popups')
        ..srcdoc = generateEditorHtml(widget.theme, channelId: _viewType).toJS as dynamic;

      // Wire up JS evaluation via postMessage. A sandboxed iframe without
      // allow-same-origin is cross-origin to the parent, so contentWindow.eval()
      // is no longer reachable — postMessage is the one channel the browser still
      // allows across that boundary. The code is still eval'd verbatim, just inside
      // the iframe's own realm (see the message listener in editor_html.dart), so
      // every editorBridge.* call behaves exactly as before. Requests are matched
      // to their reply by id since postMessage is async.
      widget.controller.evaluateJavascript = (String js) {
        final contentWindow = _iframe?.contentWindow;
        if (contentWindow == null) return Future.value(null);

        final id = _nextExecId++;
        final completer = Completer<String?>();
        _pendingExecs[id] = completer;
        contentWindow.postMessage(jsonEncode({'__exec': true, 'id': id, 'code': js}).toJS, '*'.toJS);
        // A dropped reply (e.g. the iframe is torn down mid-flight) must not hang the caller forever.
        return completer.future.timeout(const Duration(seconds: 5), onTimeout: () => null);
      };

      // Allow callers to disable pointer events on the iframe so that Flutter
      // dialogs rendered on top of it can receive pointer events. Kept in a field
      // so dispose() can hand back only its own callback (see dispose).
      _pointerEventsCallback = (bool enable) {
        _iframe?.style.setProperty('pointer-events', enable ? 'auto' : 'none');
      };
      widget.controller.setPointerEventsCallback(_pointerEventsCallback);

      return _iframe!;
    });
  }

  void _listenForMessages() {
    _messageSubscription = web.window.onMessage.listen((web.MessageEvent event) {
      try {
        final data = event.data.dartify();
        if (data is String) {
          final decoded = jsonDecode(data);
          // Only handle messages from THIS editor's own iframe. Every editor iframe postMessages to
          // the same window, so without this id check each controller would receive every other
          // editor's events (e.g. a read-only viewer's content leaking into an open compose editor).
          // channelId is stamped by generateEditorHtml with this view's unique id.
          if (decoded is Map && decoded.containsKey('type') && decoded['channelId'] == _viewType) {
            if (decoded['type'] == '__execResult') {
              final id = decoded['id'] as int?;
              final pending = id == null ? null : _pendingExecs.remove(id);
              pending?.complete(decoded['result']?.toString());
              return;
            }
            widget.controller.handleMessage(data);
          }
        }
      } catch (_) {
        // Ignore non-JSON messages from other sources
      }
    });
  }

  @override
  void dispose() {
    // Only hand back our own toggle: when a controller is passed from one editor to another, the new
    // editor registers before this one is disposed, and clearing unconditionally would leave the live
    // editor unable to release its iframe's pointer events for a dialog rendered above it.
    final void Function(bool enable)? callback = _pointerEventsCallback;
    if (callback != null) widget.controller.clearPointerEventsCallback(callback);
    _messageSubscription?.cancel();
    for (final completer in _pendingExecs.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _pendingExecs.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final height = widget.controller.contentHeight ?? widget.height ?? 300;
        return SizedBox(
          height: height,
          child: HtmlElementView(viewType: _viewType),
        );
      },
    );
  }
}
