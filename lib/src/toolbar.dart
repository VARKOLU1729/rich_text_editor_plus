import 'package:flutter/material.dart';

import 'controller.dart';
import 'models/selection_style.dart';
import 'theme.dart';
import 'toolbar_config.dart';

/// A customizable toolbar for the rich text editor.
///
/// Listens to the [RichEditorController] to highlight active formatting
/// and dispatches formatting commands on button tap.
class RichEditorToolbar extends StatelessWidget {
  final RichEditorController controller;
  final RichEditorTheme theme;
  final ToolbarConfig config;

  /// Optional custom link dialog builder.
  /// If null, a default Material dialog is used.
  /// Return null from the callback to cancel.
  /// When editing an existing link, its display text is available via
  /// `controller.selectionStyle.linkText`.
  final Future<LinkDialogResult?> Function(BuildContext context, String? currentUrl)? onLinkDialog;

  const RichEditorToolbar({
    super.key,
    required this.controller,
    required this.theme,
    this.config = ToolbarConfig.standard,
    this.onLinkDialog,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final style = controller.selectionStyle;
        return Container(
          height: theme.toolbarHeight,
          decoration: BoxDecoration(
            color: theme.toolbarColor,
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: _buildButtons(context, style),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildButtons(BuildContext context, SelectionStyle style) {
    final buttons = <Widget>[];
    ToolbarAction? lastAction;

    for (final action in config.actions) {
      // Add a visual separator between different groups
      if (lastAction != null && _shouldAddSeparator(lastAction, action)) {
        buttons.add(_buildSeparator());
      }

      buttons.add(
        _ToolbarButton(
          icon: getToolbarActionIcon(action),
          tooltip: getToolbarActionTooltip(action),
          isActive: _isActionActive(action, style),
          iconColor: theme.toolbarIconColor,
          activeColor: theme.activeIconColor,
          activeBackground: theme.activeBackgroundColor,
          iconSize: theme.toolbarIconSize,
          spacing: theme.toolbarSpacing,
          onPressed: () => _handleAction(context, action),
        ),
      );

      lastAction = action;
    }

    return buttons;
  }

  Widget _buildSeparator() {
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: theme.dividerColor,
    );
  }

  bool _shouldAddSeparator(ToolbarAction prev, ToolbarAction current) {
    return _getGroup(prev) != _getGroup(current);
  }

  /// Assign each action to a group index for separator logic.
  int _getGroup(ToolbarAction action) {
    switch (action) {
      case ToolbarAction.undo:
      case ToolbarAction.redo:
        return 0;
      case ToolbarAction.bold:
      case ToolbarAction.italic:
      case ToolbarAction.underline:
      case ToolbarAction.strikethrough:
        return 1;
      case ToolbarAction.link:
        return 2;
      case ToolbarAction.orderedList:
      case ToolbarAction.unorderedList:
      case ToolbarAction.indent:
      case ToolbarAction.outdent:
        return 3;
      case ToolbarAction.alignLeft:
      case ToolbarAction.alignCenter:
      case ToolbarAction.alignRight:
      case ToolbarAction.alignJustify:
        return 4;
      case ToolbarAction.clearFormatting:
        return 5;
    }
  }

  /// Check if a toolbar action is currently active based on selection style.
  bool _isActionActive(ToolbarAction action, SelectionStyle style) {
    switch (action) {
      case ToolbarAction.bold:
        return style.isBold;
      case ToolbarAction.italic:
        return style.isItalic;
      case ToolbarAction.underline:
        return style.isUnderline;
      case ToolbarAction.strikethrough:
        return style.isStrikethrough;
      case ToolbarAction.orderedList:
        return style.isOrderedList;
      case ToolbarAction.unorderedList:
        return style.isUnorderedList;
      case ToolbarAction.alignLeft:
        return style.alignment == 'left';
      case ToolbarAction.alignCenter:
        return style.alignment == 'center';
      case ToolbarAction.alignRight:
        return style.alignment == 'right';
      case ToolbarAction.alignJustify:
        return style.alignment == 'justify';
      case ToolbarAction.link:
        return style.hasLink;
      default:
        return false;
    }
  }

  void _handleAction(BuildContext context, ToolbarAction action) async {
    if (action == ToolbarAction.link) {
      await _handleLinkAction(context);
      return;
    }
    controller.handleToolbarAction(action.name);
  }

  Future<void> _handleLinkAction(BuildContext context) async {
    final currentUrl = controller.selectionStyle.linkUrl;

    controller.disablePointerEvents();
    LinkDialogResult? result;
    try {
      if (onLinkDialog != null) {
        result = await onLinkDialog!(context, currentUrl);
      } else {
        result = await _showDefaultLinkDialog(context, currentUrl);
      }
    } finally {
      controller.enablePointerEvents();
    }

    if (result == null) return;

    if (result.shouldRemove) {
      controller.removeLink();
    } else if (result.url != null && result.url!.isNotEmpty) {
      controller.insertLink(result.url!, result.text);
    }
  }

  /// Built-in Material link dialog.
  Future<LinkDialogResult?> _showDefaultLinkDialog(BuildContext context, String? currentUrl) async {
    final urlController = TextEditingController(text: currentUrl ?? '');
    final textController = TextEditingController(text: currentUrl != null ? (controller.selectionStyle.linkText ?? '') : '');

    return showDialog<LinkDialogResult>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(currentUrl != null ? 'Edit Link' : 'Insert Link'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  hintText: 'https://example.com',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: textController,
                decoration: const InputDecoration(
                  labelText: 'Text (optional)',
                  hintText: 'Display text',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            if (currentUrl != null)
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(
                  LinkDialogResult(shouldRemove: true),
                ),
                child: const Text('Remove Link', style: TextStyle(color: Colors.red)),
              ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(
                LinkDialogResult(
                  url: urlController.text,
                  text: textController.text.isNotEmpty ? textController.text : null,
                ),
              ),
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );
  }
}

/// Result from a link insertion/edit dialog.
class LinkDialogResult {
  final String? url;
  final String? text;
  final bool shouldRemove;

  LinkDialogResult({this.url, this.text, this.shouldRemove = false});
}

/// A single toolbar icon button with active/inactive state.
class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isActive;
  final Color iconColor;
  final Color activeColor;
  final Color? activeBackground;
  final double iconSize;
  final double spacing;
  final VoidCallback onPressed;

  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.iconColor,
    required this.activeColor,
    this.activeBackground,
    required this.iconSize,
    required this.spacing,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: spacing),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: isActive ? (activeBackground ?? activeColor.withValues(alpha: 0.1)) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                icon,
                size: iconSize,
                color: isActive ? activeColor : iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
