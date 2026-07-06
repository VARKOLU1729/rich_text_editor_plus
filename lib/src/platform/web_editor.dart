import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../js/editor_html.dart';
import 'editor_platform.dart';

extension _WindowEval on web.Window {
  external JSAny? eval(String code);
}

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
        ..srcdoc = generateEditorHtml(widget.theme, channelId: _viewType).toJS as dynamic;

      // Wire up JS evaluation via the iframe's contentWindow
      widget.controller.evaluateJavascript = (String js) async {
        try {
          final contentWindow = _iframe?.contentWindow;
          if (contentWindow == null) return null;
          final result = contentWindow.eval(js);
          return result?.dartify()?.toString();
        } catch (e) {
          // eval may fail for void expressions; that's expected
          return null;
        }
      };

      // Allow callers to disable pointer events on the iframe so that Flutter
      // dialogs rendered on top of it can receive pointer events.
      widget.controller.setPointerEventsCallback((bool enable) {
        _iframe?.style.setProperty('pointer-events', enable ? 'auto' : 'none');
      });

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
    widget.controller.setPointerEventsCallback(null);
    _messageSubscription?.cancel();
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
