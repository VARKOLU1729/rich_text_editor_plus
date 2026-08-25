import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../js/editor_html.dart';
import 'editor_platform.dart';

/// Mobile (Android/iOS) editor implementation using webview_flutter.
class MobileEditor extends EditorPlatform {
  const MobileEditor({
    super.key,
    required super.controller,
    required super.theme,
    super.height,
  });

  @override
  State<MobileEditor> createState() => _MobileEditorState();
}

class _MobileEditorState extends State<MobileEditor> {
  late final WebViewController _webViewController;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  void _initWebView() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(widget.theme.editorBackground)
      ..addJavaScriptChannel(
        'flutter_channel',
        onMessageReceived: (JavaScriptMessage message) {
          widget.controller.handleMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          // Keep the editor's own WebView on its document; hand real links to the
          // host (onLinkTap) to open externally instead of navigating in place.
          // Keep the editor's own WebView on its document; hand real links to the
          // host (onLinkTap) to open externally instead of navigating in place.
          onNavigationRequest: (NavigationRequest request) {
            if (request.url.startsWith('data:') || request.url == 'about:blank') {
              return NavigationDecision.navigate;
            }
            widget.controller.onLinkTap?.call(request.url);
            return NavigationDecision.prevent;
          },
        ),
      );

    // Claim the controller's JS channel now, not once this WebView finishes loading. A controller
    // handed from one editor to another still points at the editor that is going away, and its
    // 'ready' — which is what re-applies the content — would be evaluated against that dead WebView,
    // leaving this one showing an empty document. Commands sent before the page loads are queued by
    // the controller, so claiming it early costs nothing.
    widget.controller.evaluateJavascript = (String js) async {
      try {
        final result = await _webViewController.runJavaScriptReturningResult(js);
        return result.toString();
      } catch (e) {
        debugPrint('JS eval error: $e');
        return null;
      }
    };

    // Load the editor HTML as a data URI
    final html = generateEditorHtml(widget.theme);
    final dataUri = Uri.dataFromString(
      html,
      mimeType: 'text/html',
      encoding: Encoding.getByName('utf-8'),
    ).toString();
    _webViewController.loadRequest(Uri.parse(dataUri));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final height = widget.controller.contentHeight ?? widget.height ?? 300;
        return SizedBox(
          height: height,
          child: WebViewWidget(controller: _webViewController),
        );
      },
    );
  }
}
