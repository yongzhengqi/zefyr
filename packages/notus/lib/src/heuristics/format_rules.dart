// Copyright (c) 2018, the Zefyr project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:quill_delta/quill_delta.dart';
import 'package:notus/notus.dart';

/// A heuristic rule for format (retain) operations.
abstract class FormatRule {
  /// Constant constructor allows subclasses to declare constant constructors.
  const FormatRule();

  /// Applies heuristic rule to a retain (format) operation on a [document] and
  /// returns resulting [Delta].
  Delta apply(Delta document, int index, int length, NotusAttribute attribute);
}

/// Produces Delta with line-level attributes applied strictly to
/// line-break characters.
class ResolveLineFormatRule extends FormatRule {
  const ResolveLineFormatRule() : super();

  @override
  Delta apply(Delta document, int index, int length, NotusAttribute attribute) {
    if (attribute.scope != NotusAttributeScope.line) return null;

    Delta result = new Delta()..retain(index);
    final iter = new DeltaIterator(document);
    iter.skip(index);

    // Apply line styles to all line-break characters within range of this
    // retain operation.
    int current = 0;
    while (current < length && iter.hasNext) {
      final op = iter.next(length - current);
      if (op.data.contains('\n')) {
        final delta = _applyAttribute(op.data, attribute);
        result = result.concat(delta);
      } else {
        result.retain(op.length);
      }
      current += op.length;
    }
    // And include extra line-break after retain
    while (iter.hasNext) {
      final op = iter.next();
      int lf = op.data.indexOf('\n');
      if (lf == -1) {
        result..retain(op.length);
        continue;
      }
      result..retain(lf)..retain(1, attribute.toJson());
      break;
    }
    return result;
  }

  Delta _applyAttribute(String text, NotusAttribute attribute) {
    final result = new Delta();
    int offset = 0;
    int lf = text.indexOf('\n');
    while (lf >= 0) {
      result..retain(lf - offset)..retain(1, attribute.toJson());
      offset = lf + 1;
      lf = text.indexOf('\n', offset);
    }
    // Retain any remaining characters in text
    result.retain(text.length - offset);
    return result;
  }
}

/// Produces Delta with inline-level attributes applied too all characters
/// except line-breaks.
class ResolveInlineFormatRule extends FormatRule {
  const ResolveInlineFormatRule();

  @override
  Delta apply(Delta document, int index, int length, NotusAttribute attribute) {
    if (attribute.scope != NotusAttributeScope.inline) return null;

    Delta result = new Delta()..retain(index);
    final iter = new DeltaIterator(document);
    iter.skip(index);

    // Apply inline styles to all non-line-break characters within range of this
    // retain operation.
    int current = 0;
    while (current < length && iter.hasNext) {
      final op = iter.next(length - current);
      int lf = op.data.indexOf('\n');
      if (lf != -1) {
        int pos = 0;
        while (lf != -1) {
          result..retain(lf - pos, attribute.toJson())..retain(1);
          pos = lf + 1;
          lf = op.data.indexOf('\n', pos);
        }
        if (pos < op.length) result.retain(op.length - pos, attribute.toJson());
      } else {
        result.retain(op.length, attribute.toJson());
      }
      current += op.length;
    }

    return result;
  }
}

/// Allows updating link format with collapsed selection.
class FormatLinkAtCaretPositionRule extends FormatRule {
  const FormatLinkAtCaretPositionRule();

  @override
  Delta apply(Delta document, int index, int length, NotusAttribute attribute) {
    if (attribute.key != NotusAttribute.link.key) return null;
    // If user selection is not collapsed we let it fallback to default rule
    // which simply applies the attribute to selected range.
    // This may still not be a bulletproof approach as selection can span
    // multiple lines or be a subset of existing link-formatted text.
    // So certain improvements can be made in the future to account for such
    // edge cases.
    if (length != 0) return null;

    Delta result = new Delta();
    final iter = new DeltaIterator(document);
    final before = iter.skip(index);
    final after = iter.next();
    int startIndex = index;
    int retain = 0;
    if (before != null && before.hasAttribute(attribute.key)) {
      startIndex -= before.length;
      retain = before.length;
    }
    if (after != null && after.hasAttribute(attribute.key)) {
      retain += after.length;
    }
    // There is no link-styled text around `index` position so it becomes a
    // no-op action.
    if (retain == 0) return null;

    result..retain(startIndex)..retain(retain, attribute.toJson());

    return result;
  }
}