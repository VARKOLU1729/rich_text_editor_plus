import '../theme.dart';

/// Generates the full HTML document for the contenteditable editor.
///
/// Communication protocol:
///   Flutter → JS:  evaluateJavascript calling window.editorBridge.*
///   JS → Flutter:  window.flutter_channel.postMessage(JSON.stringify({...}))
///                   On web: window.parent.postMessage(...)
///
/// Message types FROM JS to Flutter:
///   { type: 'contentChanged', html: '...', plainText: '...' }
///   { type: 'selectionStyle', bold: bool, italic: bool, ... }
///   { type: 'ready' }
///   { type: 'focus' }
///   { type: 'blur' }
///   { type: 'linkRequest' }  (when user presses Ctrl+K)
///
/// Every message is stamped with `channelId` (the host's unique view id) so a host that hosts
/// multiple editors on the same window can route each message to the matching editor only.
String generateEditorHtml(RichEditorTheme theme, {String channelId = ''}) {
  final bgColor = _colorToCss(theme.editorBackground);
  final textColor = _colorToCss(theme.editorTextColor);
  final placeholderColor = _colorToCss(theme.placeholderColor);
  final fontFamily = theme.editorFontFamily;
  final fontSize = theme.editorFontSize;
  final lineHeight = theme.editorLineHeight;
  final paddingTop = theme.editorPadding.top;
  final paddingRight = theme.editorPadding.right;
  final paddingBottom = theme.editorPadding.bottom;
  final paddingLeft = theme.editorPadding.left;
  final placeholder = _escapeHtml(theme.placeholder ?? '');

  return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<style>
  * {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
  }

  html, body {
    height: 100%;
    width: 100%;
    overflow: hidden;
    background: $bgColor;
  }

  #editor {
    width: 100%;
    height: 100%;
    padding: ${paddingTop}px ${paddingRight}px ${paddingBottom}px ${paddingLeft}px;
    font-family: $fontFamily;
    font-size: ${fontSize}px;
    line-height: $lineHeight;
    color: $textColor;
    background: $bgColor;
    outline: none;
    overflow-y: auto;
    word-wrap: break-word;
    white-space: pre-wrap;
  }

  /* Slim scrollbar on the editor so long bodies show a scroll indicator on the right. */
  #editor::-webkit-scrollbar {
    width: 8px;
  }
  #editor::-webkit-scrollbar-thumb {
    background: rgba(0, 0, 0, 0.28);
    border-radius: 4px;
  }
  #editor::-webkit-scrollbar-track {
    background: transparent;
  }

  #editor:empty:before {
    content: attr(data-placeholder);
    color: $placeholderColor;
    pointer-events: none;
    display: block;
  }

  /* List styles */
  #editor ol, #editor ul {
    padding-left: 24px;
    margin: 4px 0;
  }

  #editor ol ol, #editor ul ul, #editor ol ul, #editor ul ol {
    margin: 2px 0;
  }

  #editor li {
    margin: 2px 0;
  }

  /* Link styles */
  #editor a {
    color: #1A73E8;
    text-decoration: underline;
    cursor: pointer;
  }

  /* Paragraph spacing */
  #editor p {
    margin: 0;
    min-height: 1em;
  }

  #editor p + p {
    margin-top: 0.4em;
  }

  /* Prevent pasted images from breaking layout */
  #editor img {
    max-width: 100%;
    height: auto;
  }
</style>
</head>
<body>
<div id="editor" contenteditable="true" data-placeholder="$placeholder" spellcheck="true"></div>

<script>
(function() {
  'use strict';

  var editor = document.getElementById('editor');
  var isComposing = false;
  var debounceTimer = null;

  // -----------------------------------------------------------------------
  // Communication: send messages to Flutter
  // -----------------------------------------------------------------------
  function sendToFlutter(data) {
    // Stamp the source editor id. On web every editor iframe postMessages to the SAME parent
    // window, so the host must be able to tell which editor a message came from — otherwise
    // each controller would process every other editor's events (cross-talk).
    data.channelId = '$channelId';
    var msg = JSON.stringify(data);
    try {
      // Mobile WebView channel (Android/iOS)
      if (window.flutter_channel && window.flutter_channel.postMessage) {
        window.flutter_channel.postMessage(msg);
        return;
      }
      // Web platform: postMessage to parent frame
      if (window.parent && window.parent !== window) {
        window.parent.postMessage(msg, '*');
        return;
      }
      // Fallback: custom event
      window.dispatchEvent(new CustomEvent('editorMessage', { detail: msg }));
    } catch (e) {
      console.error('sendToFlutter error:', e);
    }
  }

  // -----------------------------------------------------------------------
  // Content reporting
  // -----------------------------------------------------------------------
  function reportContent() {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(function() {
      sendToFlutter({
        type: 'contentChanged',
        html: isEditorEffectivelyEmpty() ? '' : editor.innerHTML,
        plainText: getPlainText()
      });
    }, 50);
  }

  function getPlainText() {
    return domToPlainText(editor).replace(/\\n{3,}/g, '\\n\\n').trim();
  }

  function domToPlainText(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      return node.textContent;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return '';

    var tag = node.tagName.toLowerCase();
    var result = '';

    // Handle list items with bullet/number prefix
    if (tag === 'li') {
      var parent = node.parentElement;
      var prefix = '';
      if (parent && parent.tagName.toLowerCase() === 'ol') {
        var index = Array.from(parent.children).indexOf(node) + 1;
        prefix = index + '. ';
      } else {
        prefix = '\\u2022 ';
      }
      // Calculate nesting depth for indentation
      var depth = 0;
      var p = node.parentElement;
      while (p && p !== editor) {
        if (p.tagName.toLowerCase() === 'ol' || p.tagName.toLowerCase() === 'ul') {
          depth++;
        }
        p = p.parentElement;
      }
      var indent = '  '.repeat(Math.max(0, depth - 1));
      var childText = '';
      for (var i = 0; i < node.childNodes.length; i++) {
        childText += domToPlainText(node.childNodes[i]);
      }
      var lines = childText.split('\\n');
      result = indent + prefix + lines[0];
      for (var j = 1; j < lines.length; j++) {
        result += '\\n' + lines[j];
      }
      result += '\\n';
      return result;
    }

    // Block-level elements get line breaks
    var isBlock = ['p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
                   'blockquote', 'pre', 'ol', 'ul', 'table', 'hr'].indexOf(tag) >= 0;

    for (var k = 0; k < node.childNodes.length; k++) {
      result += domToPlainText(node.childNodes[k]);
    }

    if (tag === 'br') return '\\n';
    if (isBlock && result.length > 0) {
      if (tag !== 'ol' && tag !== 'ul') {
        if (!result.endsWith('\\n')) result += '\\n';
      }
    }

    return result;
  }

  // -----------------------------------------------------------------------
  // All inline formatting tags
  // -----------------------------------------------------------------------
  var ALL_FORMAT_TAGS = ['b', 'strong', 'i', 'em', 'u', 's', 'strike', 'del'];

  var TAG_MAP = {
    bold: ['b', 'strong'],
    italic: ['i', 'em'],
    underline: ['u'],
    strikethrough: ['s', 'strike', 'del']
  };

  // True when there is no content between the given range's start and the end of el.
  function isCaretAtEndOfElement(range, el) {
    var endRange = document.createRange();
    endRange.setStart(range.startContainer, range.startOffset);
    endRange.setEndAfter(el);
    return endRange.toString() === '';
  }

  // True when the element has no rendered text and no embedded media.
  function isEffectivelyEmptyNode(el) {
    if (!el || el.nodeType !== Node.ELEMENT_NODE) return false;
    if (el.textContent.length > 0) return false;
    return !el.querySelector('img, video, audio, iframe, hr, table');
  }

  // True when the editor has no rendered text and no embedded media.
  function isEditorEffectivelyEmpty() {
    if (editor.innerText.replace(/[\\s\\u200B]/g, '').length > 0) return false;
    return !editor.querySelector('img, video, audio, iframe, hr, table');
  }

  // -----------------------------------------------------------------------
  // Break caret out of only the specific formatting tags being toggled off,
  // while keeping the caret inside any other active format tags.
  //
  // Problem with escaping ALL tags: if you have <b><i><u><s>|</s></u></i></b>
  // and toggle bold off, the caret lands outside everything. Then toggling italic
  // off sees queryCommandState('italic')=false and ADDS italic back instead of
  // removing it — the opposite of what the user wants.
  //
  // Fix: escape only the tag(s) matching the toggled command. Collect all other
  // format tags encountered on the way up (the ones to preserve) and re-wrap the
  // new caret position in them using a zero-width-space anchor.
  // -----------------------------------------------------------------------
  function breakOutOfSpecificFormattingTag(command) {
    var formatKeyByCommand = { bold: 'bold', italic: 'italic', underline: 'underline', strikeThrough: 'strikethrough' };
    var formatKey = formatKeyByCommand[command];
    if (!formatKey) return false;

    var tagsToEscape = TAG_MAP[formatKey]; // e.g. ['b','strong'] for bold

    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || !sel.isCollapsed) return false;

    var range = sel.getRangeAt(0);
    var startContainer = range.startContainer;
    var startOffset = range.startOffset;

    // Only act when caret is at the end of its text node.
    if (startContainer.nodeType === Node.TEXT_NODE && startOffset !== startContainer.length) {
      return false;
    }

    // Walk up collecting: the outermost tag-to-escape and all other format tags
    // encountered between the caret and that outermost tag (innermost listed first).
    var outermostToEscape = null;
    var tagsToPreserve = []; // other format tags inside outermostToEscape, innermost first

    var walker = startContainer.nodeType === Node.TEXT_NODE ? startContainer.parentNode : startContainer;
    while (walker && walker !== editor) {
      if (walker.nodeType === Node.ELEMENT_NODE) {
        var tag = walker.tagName.toLowerCase();
        if (ALL_FORMAT_TAGS.indexOf(tag) >= 0) {
          if (!isCaretAtEndOfElement(range, walker)) break;
          if (tagsToEscape.indexOf(tag) >= 0) {
            outermostToEscape = walker;
            // tagsToPreserve collected so far are all inside outermostToEscape — keep them
          } else {
            tagsToPreserve.push(tag);
          }
        }
      }
      walker = walker.parentNode;
    }

    if (!outermostToEscape) return false;

    var parentOfOutermost = outermostToEscape.parentNode;
    var indexInParent = Array.prototype.indexOf.call(parentOfOutermost.childNodes, outermostToEscape);

    // Move caret to just after the escaped tag.
    range.setStartAfter(outermostToEscape);
    range.collapse(true);
    sel.removeAllRanges();
    sel.addRange(range);

    // Re-wrap caret in the preserved formats so the user stays inside them.
    // tagsToPreserve is innermost-first, so build wrappers from inside out.
    if (tagsToPreserve.length > 0) {
      var zwsp = document.createTextNode('\u200B');
      var currentEl = zwsp;
      for (var i = 0; i < tagsToPreserve.length; i++) {
        var wrapper = document.createElement(tagsToPreserve[i]);
        wrapper.appendChild(currentEl);
        currentEl = wrapper;
      }
      range.insertNode(currentEl);
      range.setStart(zwsp, zwsp.length);
      range.collapse(true);
      sel.removeAllRanges();
      sel.addRange(range);
    }

    // Remove the escaped tag if it is now empty.
    if (isEffectivelyEmptyNode(outermostToEscape)) {
      parentOfOutermost.removeChild(outermostToEscape);
      range.setStart(parentOfOutermost, indexInParent);
      range.collapse(true);
      sel.removeAllRanges();
      sel.addRange(range);
    }

    return true;
  }

  // -----------------------------------------------------------------------
  // Selection style reporting
  // -----------------------------------------------------------------------
  function reportSelectionStyle() {
    var linkUrl = null;
    var sel = window.getSelection();
    if (sel && sel.rangeCount > 0) {
      var node = sel.anchorNode;
      while (node && node !== editor) {
        if (node.nodeType === Node.ELEMENT_NODE && node.tagName.toLowerCase() === 'a') {
          linkUrl = node.getAttribute('href');
          break;
        }
        node = node.parentNode;
      }
    }

    var alignment = 'left';
    if (sel && sel.rangeCount > 0) {
      var block = sel.anchorNode;
      while (block && block !== editor) {
        if (block.nodeType === Node.ELEMENT_NODE) {
          var ta = block.style.textAlign || window.getComputedStyle(block).textAlign;
          if (ta === 'center' || ta === 'right' || ta === 'justify') {
            alignment = ta;
            break;
          }
          var align = block.getAttribute('align');
          if (align) {
            alignment = align;
            break;
          }
        }
        block = block.parentNode;
      }
    }

    sendToFlutter({
      type: 'selectionStyle',
      bold: document.queryCommandState('bold'),
      italic: document.queryCommandState('italic'),
      underline: document.queryCommandState('underline'),
      strikethrough: document.queryCommandState('strikeThrough'),
      orderedList: document.queryCommandState('insertOrderedList'),
      unorderedList: document.queryCommandState('insertUnorderedList'),
      linkUrl: linkUrl,
      alignment: alignment
    });
  }

  // -----------------------------------------------------------------------
  // Bridge API: called from Flutter via evaluateJavascript
  // -----------------------------------------------------------------------
  window.editorBridge = {

    execCommand: function(command, value) {
      editor.focus();

      var formatKeyByCommand = { bold: 'bold', italic: 'italic', underline: 'underline', strikeThrough: 'strikethrough' };
      var formatKey = formatKeyByCommand[command];
      var sel = window.getSelection();
      var isCollapsed = sel && sel.isCollapsed;

      if (formatKey && isCollapsed && document.queryCommandState(command)) {
        // Escape only the tag(s) for this specific command, preserving all other
        // active format tags. See breakOutOfSpecificFormattingTag for full explanation.
        var brokeOut = breakOutOfSpecificFormattingTag(command);
        if (!brokeOut) {
          // No matching formatting ancestor found — fall back to native toggle.
          document.execCommand(command, false, value || null);
        } else if (document.queryCommandState(command)) {
          // Sticky state still lagging after relocation — force it off once more.
          document.execCommand(command, false, null);
        }
      } else {
        document.execCommand(command, false, value || null);
      }

      reportContent();
      reportSelectionStyle();
    },

    insertLink: function(url, text) {
      editor.focus();
      var sel = window.getSelection();
      if (sel.toString().length > 0) {
        document.execCommand('createLink', false, url);
      } else if (text) {
        var a = document.createElement('a');
        a.href = url;
        a.textContent = text;
        a.target = '_blank';
        var range = sel.getRangeAt(0);
        range.insertNode(a);
        range.setStartAfter(a);
        range.collapse(true);
        sel.removeAllRanges();
        sel.addRange(range);
      } else {
        document.execCommand('createLink', false, url);
      }
      reportContent();
      reportSelectionStyle();
    },

    removeLink: function() {
      editor.focus();
      document.execCommand('unlink', false, null);
      reportContent();
      reportSelectionStyle();
    },

    setHtml: function(html) {
      editor.innerHTML = html;
      reportContent();
      setTimeout(reportHeight, 100);
    },

    getHtml: function() {
      return isEditorEffectivelyEmpty() ? '' : editor.innerHTML;
    },

    getPlainText: function() {
      return getPlainText();
    },

    insertHtml: function(html) {
      editor.focus();
      document.execCommand('insertHTML', false, html);
      reportContent();
    },

    clear: function() {
      editor.innerHTML = '';
      reportContent();
    },

    focus: function() {
      editor.focus();
    },

    blur: function() {
      editor.blur();
    },

    setAlignment: function(alignment) {
      editor.focus();
      switch (alignment) {
        case 'left':
          document.execCommand('justifyLeft', false, null);
          break;
        case 'center':
          document.execCommand('justifyCenter', false, null);
          break;
        case 'right':
          document.execCommand('justifyRight', false, null);
          break;
        case 'justify':
          document.execCommand('justifyFull', false, null);
          break;
      }
      reportContent();
      reportSelectionStyle();
    },

    isEmpty: function() {
      var text = editor.innerText.trim();
      return text.length === 0 || text === '\\n';
    },

    // No-op kept for backwards compatibility with controller.dart callers.
    setEnforcement: function(state) {},

    setReadOnly: function(readOnly) {
      editor.contentEditable = readOnly ? 'false' : 'true';
      editor.style.cursor = readOnly ? 'default' : 'text';
      editor.style.userSelect = readOnly ? 'text' : 'auto';
      editor.style.webkitUserSelect = readOnly ? 'text' : 'auto';
      if (readOnly) {
        // Let content expand naturally so scrollHeight reflects actual height.
        document.documentElement.style.height = 'auto';
        document.documentElement.style.overflow = 'visible';
        document.body.style.height = 'auto';
        document.body.style.overflow = 'visible';
        editor.style.overflowY = 'visible';
        editor.style.height = 'auto';
        editor.style.minHeight = 'auto';
        setTimeout(fitReadOnlyWidth, 100);
        // Re-fit / re-measure as images finish loading (plus a later safety net):
        // late signature images change width and height, so refit to the viewport
        // width and re-report the resulting height. This also avoids the read-only
        // iframe overflowing (which would show its own extra scrollbar).
        var roImgs = editor.querySelectorAll('img');
        for (var ri = 0; ri < roImgs.length; ri++) {
          if (!roImgs[ri].complete) {
            roImgs[ri].addEventListener('load', fitReadOnlyWidth);
            roImgs[ri].addEventListener('error', fitReadOnlyWidth);
          }
        }
        setTimeout(fitReadOnlyWidth, 600);
      }
    }
  };

  // -----------------------------------------------------------------------
  // Height reporting (used for auto-height read-only viewer)
  // -----------------------------------------------------------------------
  function reportHeight() {
    sendToFlutter({ type: 'heightChanged', height: document.body.scrollHeight });
  }

  // Read-only fit-to-width: wide content (e.g. a 500px signature table) would
  // overflow a narrow mobile viewport. Scale the whole body down with CSS zoom so
  // it fits the width — like Gmail's mobile "fit to width" — instead of needing an
  // awkward horizontal scroll. zoom (unlike transform) shrinks layout height too,
  // so the reported height stays correct. Only ever shrinks (min with 1), so it is
  // a no-op when the content already fits (e.g. desktop web).
  function fitReadOnlyWidth() {
    document.body.style.zoom = '1';
    var viewWidth = document.documentElement.clientWidth || window.innerWidth || 0;
    var contentWidth = document.body.scrollWidth;
    if (viewWidth > 0 && contentWidth > viewWidth) {
      document.body.style.zoom = String(viewWidth / contentWidth);
    }
    // Report the rendered (zoom-applied) height so the host sizes the iframe right.
    sendToFlutter({ type: 'heightChanged', height: Math.ceil(document.body.getBoundingClientRect().height) });
  }

  // Rewrite Gmail image-proxy srcs (…googleusercontent.com/…#<original>) back to
  // the embedded original URL so pasted Gmail signatures render in the editor
  // instead of showing broken proxied images. Proxy srcs without a '#<url>'
  // fragment (e.g. Gmail's private mail-sig photos) have no public source and are
  // left as-is.
  function unwrapProxiedImages() {
    var imgs = editor.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      var src = imgs[i].getAttribute('src') || '';
      if (src.indexOf('googleusercontent.com') === -1) continue;
      var hashIdx = src.indexOf('#http');
      if (hashIdx !== -1) {
        imgs[i].setAttribute('src', src.substring(hashIdx + 1));
      }
    }
  }

  // -----------------------------------------------------------------------
  // Event listeners
  // -----------------------------------------------------------------------

  editor.addEventListener('input', function() {
    if (!isComposing) {
      reportContent();
    }
  });

  editor.addEventListener('compositionstart', function() {
    isComposing = true;
  });

  editor.addEventListener('compositionend', function() {
    isComposing = false;
    reportContent();
  });

  document.addEventListener('selectionchange', function() {
    reportSelectionStyle();
  });

  editor.addEventListener('focus', function() {
    sendToFlutter({ type: 'focus' });
  });

  editor.addEventListener('blur', function() {
    sendToFlutter({ type: 'blur' });
    reportContent();
  });

  // Scroll chaining: when the editor cannot scroll further in the wheel direction (or has no
  // scrollable overflow at all), forward the delta to the Flutter host so an enclosing scroll
  // view can continue. A web iframe otherwise swallows the wheel at its boundary and never
  // bubbles it to the parent document.
  editor.addEventListener('wheel', function(e) {
    // Fire on EVERY wheel so a host can react to any scroll immediately (e.g. collapse a header on
    // first scroll, in either direction) — independent of the editor's own scroll position.
    sendToFlutter({ type: 'wheel', deltaY: e.deltaY });
    // Additionally, at the scroll boundary (or when there's no scrollable overflow) forward the delta
    // so an enclosing scroll view can continue (scroll chaining across the iframe boundary).
    var atTop = editor.scrollTop <= 0;
    var atBottom = editor.scrollTop + editor.clientHeight >= editor.scrollHeight - 1;
    var noScroll = editor.scrollHeight <= editor.clientHeight;
    if (noScroll || (e.deltaY < 0 && atTop) || (e.deltaY > 0 && atBottom)) {
      sendToFlutter({ type: 'overscroll', deltaY: e.deltaY });
    }
  });

  // Paste: let the browser handle it natively, then unwrap any Gmail image-proxy
  // srcs and report changes.
  editor.addEventListener('paste', function(e) {
    setTimeout(function() {
      unwrapProxiedImages();
      reportContent();
      reportSelectionStyle();
    }, 50);
  });

  // Keyboard shortcuts
  editor.addEventListener('keydown', function(e) {
    if ((e.ctrlKey || e.metaKey) && !e.shiftKey) {
      switch (e.key.toLowerCase()) {
        case 'b':
          e.preventDefault();
          sendToFlutter({ type: 'toolbarToggle', action: 'bold' });
          break;
        case 'i':
          e.preventDefault();
          sendToFlutter({ type: 'toolbarToggle', action: 'italic' });
          break;
        case 'u':
          e.preventDefault();
          sendToFlutter({ type: 'toolbarToggle', action: 'underline' });
          break;
        case 'k':
          e.preventDefault();
          sendToFlutter({ type: 'linkRequest' });
          break;
      }
    }
  });

  // Signal ready
  sendToFlutter({ type: 'ready' });

})();
</script>
</body>
</html>
''';
}

/// Convert a Flutter Color to a CSS color string.
String _colorToCss(dynamic color) {
  try {
    final int value = (color as dynamic).value;
    final int r = (value >> 16) & 0xFF;
    final int g = (value >> 8) & 0xFF;
    final int b = value & 0xFF;
    final double a = ((value >> 24) & 0xFF) / 255.0;
    if (a < 1.0) {
      return 'rgba($r, $g, $b, ${a.toStringAsFixed(2)})';
    }
    return '#${r.toRadixString(16).padLeft(2, '0')}${g.toRadixString(16).padLeft(2, '0')}${b.toRadixString(16).padLeft(2, '0')}';
  } catch (_) {
    return '#000000';
  }
}

/// Escape HTML special characters in a string.
String _escapeHtml(String text) {
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');
}
