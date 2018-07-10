// Copyright (c) 2018, the Zefyr project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';

import 'package:quill_delta/quill_delta.dart';

import 'document/attributes.dart';
import 'document/block.dart';
import 'document/leaf.dart';
import 'document/line.dart';
import 'document/node.dart';
import 'embed.dart';
import 'heuristics.dart';

/// Source of a [NotusChange].
enum ChangeSource {
  /// Change originated from a local action. Typically triggered by user.
  local,

  /// Change originated from a remote action.
  remote,
}

/// Represents a change in a [NotusDocument].
class NotusChange {
  NotusChange(this.before, this.change, this.source);

  /// Document state before [change].
  final Delta before;

  /// Change delta applied to the document.
  final Delta change;

  /// The source of this change.
  final ChangeSource source;
}

/// A rich text document.
class NotusDocument {
  /// Creates new empty Notus document.
  NotusDocument()
      : _heuristics = NotusHeuristics.fallback,
        _delta = new Delta()..insert('\n') {
    _loadDocument(_delta);
  }

  NotusDocument.fromJson(dynamic data)
      : _heuristics = NotusHeuristics.fallback,
        _delta = Delta.fromJson(data) {
    _loadDocument(_delta);
  }

  NotusDocument.fromDelta(Delta delta)
      : assert(delta != null),
        _heuristics = NotusHeuristics.fallback,
        _delta = delta {
    _loadDocument(_delta);
  }

  final NotusHeuristics _heuristics;

  /// The root node of this document tree.
  RootNode get root => _root;
  final RootNode _root = new RootNode();

  /// Length of this document.
  int get length => _root.length;

  /// Stream of [NotusChange]s applied to this document.
  Stream<NotusChange> get changes => _controller.stream;

  final StreamController<NotusChange> _controller =
      new StreamController.broadcast();

  /// Returns contents of this document as [Delta].
  Delta toDelta() => new Delta.from(_delta);
  Delta _delta;

  /// Returns plain text representation of this document.
  String toPlainText() => _delta.toList().map((op) => op.data).join();

  dynamic toJson() {
    return _delta.toJson();
  }

  /// Returns `true` if this document and associated stream of [changes]
  /// is closed.
  ///
  /// Modifying a closed document is not allowed.
  bool get isClosed => _controller.isClosed;

  /// Closes [changes] stream.
  void close() {
    _controller.close();
  }

  /// Inserts [value] in this document at specified [index]. Value must be a
  /// [String] or an instance of [NotusEmbed].
  ///
  /// This method applies heuristic rules before modifying this document and
  /// produces a [NotusChange] with source set to [ChangeSource.local].
  ///
  /// Returns an instance of [Delta] actually composed into this document.
  Delta insert(int index, dynamic value) {
    assert(index >= 0);
    assert(value is String || value is NotusEmbed,
        'Value must be a string or a NotusEmbed.');
    Delta change;
    if (value is String) {
      assert(value.isNotEmpty);
      value = _sanitizeString(value);
      if (value.isEmpty) return new Delta();
      change = _heuristics.applyInsertRules(this, index, value);
    } else {
      NotusEmbed embed = value;
      change = _heuristics.applyEmbedRules(this, index, embed.attribute);
    }
    compose(change, ChangeSource.local);
    return change;
  }

  /// Deletes [length] of characters from this document starting at [index].
  ///
  /// This method applies heuristic rules before modifying this document and
  /// produces a [NotusChange] with source set to [ChangeSource.local].
  ///
  /// Returns an instance of [Delta] actually composed into this document.
  Delta delete(int index, int length) {
    assert(index >= 0 && length > 0);
    // TODO: need a heuristic rule to ensure last line-break.
    final change = _heuristics.applyDeleteRules(this, index, length);
    // Delete rules are allowed to prevent the edit so it may be empty.
    if (change.isNotEmpty) {
      compose(change, ChangeSource.local);
    }
    return change;
  }

  /// Replaces [length] of characters starting at [index] with [value]. Value
  /// must be a [String] or an instance of [NotusEmbed].
  ///
  /// This method applies heuristic rules before modifying this document and
  /// produces a [NotusChange] with source set to [ChangeSource.local].
  ///
  /// Returns an instance of [Delta] actually composed into this document.
  Delta replace(int index, int length, dynamic value) {
    assert(index >= 0 && (value.isNotEmpty || length > 0),
        'With index $index, length $length and text "$value"');
    assert(value is String || value is NotusEmbed,
        'Value must be a string or a NotusEmbed.');

    final hasInsert =
        (value is NotusEmbed || (value is String && value.isNotEmpty));
    Delta delta = new Delta();

    // We have to compose before applying delete rules
    // Otherwise delete would be operating on stale document snapshot.
    if (hasInsert) {
      delta = insert(index, value);
      index = delta.transformPosition(index);
    }

    if (length > 0) {
      final deleteDelta = delete(index, length);
      delta = delta.compose(deleteDelta);
    }
    return delta;
  }

  /// Formats portion of this document with specified [attribute].
  ///
  /// Applies heuristic rules before modifying this document and
  /// produces a [NotusChange] with source set to [ChangeSource.local].
  ///
  /// Returns an instance of [Delta] actually composed into this document.
  /// The returned [Delta] may be empty in which case this document remains
  /// unchanged and no [NotusChange] is published to [changes] stream.
  Delta format(int index, int length, NotusAttribute attribute) {
    assert(index >= 0 && length >= 0 && attribute != null);
    Delta change;
    if (attribute is EmbedAttribute) {
      assert(length == 1);
      change = _heuristics.applyEmbedRules(this, index, attribute);
    } else {
      change = _heuristics.applyFormatRules(this, index, length, attribute);
    }
    if (change.isNotEmpty) {
      compose(change, ChangeSource.local);
    }
    return change;
  }

  /// Returns style of specified text range.
  ///
  /// Only attributes applied to all characters within this range are
  /// included in the result. Inline and block level attributes are
  /// handled separately, e.g.:
  ///
  /// - block attribute X is included in the result only if it exists for
  ///   every line within this range (partially included lines are counted).
  /// - inline attribute X is included in the result only if it exists
  ///   for every character within this range (line-break characters excluded).
  NotusStyle collectStyle(int index, int length) {
    var result = lookupLine(index);
    LineNode line = result.node;
    return line.collectStyle(result.offset, length);
  }

  /// Returns [LineNode] located at specified character [offset].
  LookupResult lookupLine(int offset) {
    // TODO: prevent user from moving caret after last line-break.
    var result = _root.lookup(offset, inclusive: true);
    if (result.node is LineNode) return result;
    BlockNode block = result.node;
    return block.lookup(result.offset, inclusive: true);
  }

  /// Composes [change] into this document.
  ///
  /// Use this method with caution as it does not apply heuristic rules to the
  /// [change].
  ///
  /// It is callers responsibility to ensure that the [change] conforms to
  /// the document model semantics and can be composed with the current state
  /// of this document.
  ///
  /// In case the [change] is invalid, behavior of this method is unspecified.
  void compose(Delta change, ChangeSource source) {
    _checkMutable();
    change.trim();
    assert(change.isNotEmpty);

    int offset = 0;
    final before = toDelta();
    for (final Operation op in change.toList()) {
      final attributes =
          op.attributes != null ? NotusStyle.fromJson(op.attributes) : null;
      if (op.isInsert) {
        _root.insert(offset, op.data, attributes);
      } else if (op.isDelete) {
        _root.delete(offset, op.length);
      } else if (op.attributes != null) {
        _root.retain(offset, op.length, attributes);
      }
      if (!op.isDelete) offset += op.length;
    }
    _delta = _delta.compose(change);

    if (_delta != _root.toDelta()) {
      throw new StateError('Compose produced inconsistent results. '
          'This is likely due to a bug in the library.');
    }
    _controller.add(new NotusChange(before, change, source));
  }

  //
  // Overridden members
  //
  @override
  String toString() => _root.toString();

  //
  // Private members
  //

  void _checkMutable() {
    assert(!_controller.isClosed,
        'Cannot modify Notus document after it was closed.');
  }

  String _sanitizeString(String value) {
    if (value.contains(EmbedNode.kPlainTextPlaceholder)) {
      return value.replaceAll(EmbedNode.kPlainTextPlaceholder, '');
    } else {
      return value;
    }
  }

  /// Loads [document] delta into this document.
  void _loadDocument(Delta doc) {
    assert(doc.last.data.endsWith('\n'),
        'Invalid document delta. Document delta must always end with a line-break.');
    int offset = 0;
    for (final Operation op in doc.toList()) {
      final style =
          op.attributes != null ? NotusStyle.fromJson(op.attributes) : null;
      if (op.isInsert) {
        _root.insert(offset, op.data, style);
      } else {
        throw new ArgumentError.value(doc,
            "Document Delta can only contain insert operations but ${op.key} found.");
      }
      offset += op.length;
    }
    // Must remove last line if it's empty and with no styles.
    // TODO: find a way for DocumentRoot to not create extra line when composing initial delta.
    Node node = _root.last;
    if (node is LineNode &&
        node.parent is! BlockNode &&
        node.style.isEmpty &&
        _root.childCount > 1) {
      _root.remove(node);
    }
  }
}