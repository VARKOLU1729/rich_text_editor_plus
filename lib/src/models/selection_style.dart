/// Represents the formatting state at the current cursor position or selection.
///
/// Updated every time the selection changes inside the editor.
class SelectionStyle {
  final bool isBold;
  final bool isItalic;
  final bool isUnderline;
  final bool isStrikethrough;
  final bool isOrderedList;
  final bool isUnorderedList;
  final String? linkUrl;

  /// Display text of the link at the current selection, if any.
  final String? linkText;
  final String alignment; // 'left', 'center', 'right', 'justify'

  const SelectionStyle({
    this.isBold = false,
    this.isItalic = false,
    this.isUnderline = false,
    this.isStrikethrough = false,
    this.isOrderedList = false,
    this.isUnorderedList = false,
    this.linkUrl,
    this.linkText,
    this.alignment = 'left',
  });

  /// Whether a link is active at the current selection.
  bool get hasLink => linkUrl != null && linkUrl!.isNotEmpty;

  /// Returns a copy of this style with the given fields replaced.
  ///
  /// Used by the controller for optimistic updates — flips a single field without manually copying every field.
  SelectionStyle copyWith({
    bool? isBold,
    bool? isItalic,
    bool? isUnderline,
    bool? isStrikethrough,
    bool? isOrderedList,
    bool? isUnorderedList,
    String? linkUrl,
    String? linkText,
    String? alignment,
  }) {
    return SelectionStyle(
      isBold: isBold ?? this.isBold,
      isItalic: isItalic ?? this.isItalic,
      isUnderline: isUnderline ?? this.isUnderline,
      isStrikethrough: isStrikethrough ?? this.isStrikethrough,
      isOrderedList: isOrderedList ?? this.isOrderedList,
      isUnorderedList: isUnorderedList ?? this.isUnorderedList,
      linkUrl: linkUrl ?? this.linkUrl,
      linkText: linkText ?? this.linkText,
      alignment: alignment ?? this.alignment,
    );
  }

  /// Default empty style.
  static const SelectionStyle none = SelectionStyle();

  /// Parse from a JSON map sent by the JS bridge.
  factory SelectionStyle.fromJson(Map<String, dynamic> json) {
    return SelectionStyle(
      isBold: json['bold'] == true,
      isItalic: json['italic'] == true,
      isUnderline: json['underline'] == true,
      isStrikethrough: json['strikethrough'] == true,
      isOrderedList: json['orderedList'] == true,
      isUnorderedList: json['unorderedList'] == true,
      linkUrl: json['linkUrl'] as String?,
      linkText: json['linkText'] as String?,
      alignment: (json['alignment'] as String?) ?? 'left',
    );
  }

  @override
  String toString() {
    final active = <String>[];
    if (isBold) active.add('bold');
    if (isItalic) active.add('italic');
    if (isUnderline) active.add('underline');
    if (isStrikethrough) active.add('strikethrough');
    if (isOrderedList) active.add('OL');
    if (isUnorderedList) active.add('UL');
    if (hasLink) active.add('link:$linkUrl');
    active.add('align:$alignment');
    return 'SelectionStyle(${active.join(', ')})';
  }
}
