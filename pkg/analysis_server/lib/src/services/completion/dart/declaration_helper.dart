// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/protocol_server.dart'
    show CompletionSuggestionKind;
import 'package:analysis_server/src/services/completion/dart/candidate_suggestion.dart';
import 'package:analysis_server/src/services/completion/dart/completion_manager.dart';
import 'package:analysis_server/src/services/completion/dart/suggestion_collector.dart';
import 'package:analysis_server/src/services/completion/dart/visibility_tracker.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

/// A helper class that produces candidate suggestions for all of the
/// declarations that are in scope at the completion location.
class DeclarationHelper {
  /// The regular expression used to detect an unused identifier (a sequence of
  /// one or more underscodes with no other characters).
  static final RegExp UnusedIdentifier = RegExp(r'^_+$');

  /// The completion request being processed.
  final DartCompletionRequest request;

  /// The suggestion collector to which suggestions will be added.
  final SuggestionCollector collector;

  /// The offset of the completion location.
  final int offset;

  /// The visibility tracker used to prevent suggesting elements that have been
  /// shadowed by local declarations.
  final VisibilityTracker visibilityTracker = VisibilityTracker();

  /// A flag indicating whether suggestions should be limited to only include
  /// those to which a value can be assigned: either a setter or a local
  /// variable.
  final bool mustBeAssignable;

  /// A flag indicating whether suggestions should be limited to only include
  /// valid constants.
  final bool mustBeConstant;

  /// A flag indicating whether suggestions should be limited to only include
  /// methods with a non-`void` return type.
  final bool mustBeNonVoid;

  /// A flag indicating whether suggestions should be limited to only include
  /// static members.
  final bool mustBeStatic;

  /// A flag indicating whether suggestions should be limited to only include
  /// types.
  final bool mustBeType;

  /// A flag indicating whether suggestions should be tear-offs rather than
  /// invocations where possible.
  final bool preferNonInvocation;

  /// The number of local variables that have already been suggested.
  int _variableDistance = 0;

  /// Initialize a newly created helper to add suggestions to the [collector]
  /// that are appropriate for the location at the [offset].
  ///
  /// The flags [mustBeAssignable], [mustBeConstant], [mustBeNonVoid],
  /// [mustBeStatic], and [mustBeType] are used to control which declarations
  /// are suggested. The flag [preferNonInvocation] is used to control what kind
  /// of suggestion is made for executable elements.
  DeclarationHelper({
    required this.request,
    required this.collector,
    required this.offset,
    required this.mustBeAssignable,
    required this.mustBeConstant,
    required this.mustBeNonVoid,
    required this.mustBeStatic,
    required this.mustBeType,
    required this.preferNonInvocation,
  });

  /// Return the suggestion kind that should be used for executable elements.
  CompletionSuggestionKind get _executableSuggestionKind => preferNonInvocation
      ? CompletionSuggestionKind.IDENTIFIER
      : CompletionSuggestionKind.INVOCATION;

  void addConstructorInvocations() {
    var library = request.libraryElement;
    _addConstructors(library);
    // TODO(brianwilkerson): Implement this.
    // _addImportedConstructors(library);
  }

  /// Add any fields that can be initialized in the initializer list of the
  /// given [constructor].
  void addFieldsForInitializers(ConstructorDeclaration constructor) {
    var containingElement = constructor.declaredElement?.enclosingElement;
    if (containingElement == null) {
      return;
    }

    var fieldsToSkip = <FieldElement>{};
    // Skip fields that are already initialized in the initializer list.
    for (var initializer in constructor.initializers) {
      if (initializer is ConstructorFieldInitializer) {
        var fieldElement = initializer.fieldName.staticElement;
        if (fieldElement is FieldElement) {
          fieldsToSkip.add(fieldElement);
        }
      }
    }
    // Skip fields that are already initialized in the parameter list.
    for (var parameter in constructor.parameters.parameters) {
      if (parameter is FieldFormalParameter) {
        var parameterElement = parameter.declaredElement;
        if (parameterElement is FieldFormalParameterElement) {
          var field = parameterElement.field;
          if (field != null) {
            fieldsToSkip.add(field);
          }
        }
      }
    }

    for (var field in containingElement.fields) {
      // Skip fields that are already initialized at their declaration.
      if (!fieldsToSkip.contains(field) && !field.hasInitializer) {
        _suggestField(field, containingElement);
      }
    }
  }

  /// Add any declarations that are visible at the completion location,
  /// given that the completion location is within the [node]. This includes
  /// local variables, local functions, parameters, members of the enclosing
  /// declaration, and top-level declarations in the enclosing library.
  void addLexicalDeclarations(AstNode node) {
    var containingMember =
        mustBeType ? _addLocalTypes(node) : _addLocalDeclarations(node);
    if (containingMember == null) {
      return;
    }
    AstNode? parent = containingMember.parent ?? containingMember;
    if (parent is ClassMember) {
      assert(node is CommentReference);
      parent = parent.parent;
    } else if (parent is CompilationUnit) {
      parent = containingMember;
    }
    if (parent is CompilationUnitMember) {
      _addMembersOf(parent, containingMember);
      parent = parent.parent;
    }
    if (parent is CompilationUnit) {
      var library = parent.declaredElement?.library;
      if (library != null) {
        _addTopLevelDeclarations(library);
        _addImportedDeclarations(library);
      }
    }
  }

  void addMembersOfType(DartType type) {
    // TODO(brianwilkerson): Implement this.
  }

  /// Add suggestions for any constructors that are declared within the
  /// [library].
  void _addConstructors(LibraryElement library) {
    for (var unit in library.units) {
      // Mixins don't have constructors, so we don't need to enumerate them.
      for (var element in unit.classes) {
        _suggestConstructors(element.constructors,
            allowNonFactory: !element.isAbstract);
      }
      for (var element in unit.enums) {
        _suggestEnum(element, null);
      }
      for (var element in unit.extensionTypes) {
        _suggestConstructors(element.constructors);
      }
      for (var element in unit.typeAliases) {
        _addConstructorsForAliasedElement(element);
      }
    }
  }

  /// Add suggestions for any constructors that are visible through type aliases
  /// declared within the [library].
  void _addConstructorsForAliasedElement(TypeAliasElement alias) {
    var aliasedElement = alias.aliasedElement;
    if (aliasedElement is ClassElement) {
      _suggestConstructors(aliasedElement.constructors,
          allowNonFactory: !aliasedElement.isAbstract);
    } else if (aliasedElement is ExtensionTypeElement) {
      _suggestConstructors(aliasedElement.constructors);
    } else if (aliasedElement is MixinElement) {
      _suggestConstructors(aliasedElement.constructors);
    }
  }

  /// Add suggestions for any top-level declarations that are visible within the
  /// [library].
  void _addImportedDeclarations(LibraryElement library) {
    // TODO(brianwilkerson): Implement this.
    // for (var importedLibrary in library.importedLibraries) {}
  }

  /// Add suggestions for any local declarations that are visible at the
  /// completion location, given that the completion location is within the
  /// [node].
  ///
  /// This includes local variables, local functions, parameters, and type
  /// parameters defined on local functions.
  ///
  /// Return the member containing the local declarations that were added, or
  /// `null` if there is an error such as the AST being malformed or we
  /// encountered an AST structure that isn't handled correctly.
  ///
  /// The returned member can be either a [ClassMember] or a
  /// [CompilationUnitMember].
  AstNode? _addLocalDeclarations(AstNode node) {
    AstNode? previousNode;
    AstNode? currentNode = node;
    while (currentNode != null) {
      switch (currentNode) {
        case Block():
          _visitStatements(currentNode.statements, previousNode);
        case CatchClause():
          _visitCatchClause(currentNode);
        case CommentReference():
          return _visitCommentReference(currentNode);
        case ConstructorDeclaration():
          _visitParameterList(currentNode.parameters);
          return currentNode;
        case DeclaredVariablePattern():
          _visitDeclaredVariablePattern(currentNode);
        case FieldDeclaration():
          return currentNode;
        case ForElement(forLoopParts: var parts):
          if (parts != previousNode) {
            _visitForLoopParts(parts);
          }
        case ForStatement(forLoopParts: var parts):
          if (parts != previousNode) {
            _visitForLoopParts(parts);
          }
        case ForPartsWithDeclarations(:var variables):
          if (variables != previousNode) {
            _visitForLoopParts(currentNode);
          }
        case FunctionDeclaration(:var parent):
          if (parent is! FunctionDeclarationStatement) {
            return currentNode;
          }
        case FunctionDeclarationStatement():
          var functionElement = currentNode.functionDeclaration.declaredElement;
          if (functionElement != null) {
            _suggestFunction(functionElement);
          }
        case FunctionExpression():
          _visitParameterList(currentNode.parameters);
          _visitTypeParameterList(currentNode.typeParameters);
        case IfElement():
          _visitIfElement(currentNode);
        case IfStatement():
          _visitIfStatement(currentNode);
        case MethodDeclaration():
          _visitParameterList(currentNode.parameters);
          _visitTypeParameterList(currentNode.typeParameters);
          return currentNode;
        case SwitchCase():
          _visitStatements(currentNode.statements, previousNode);
        case SwitchDefault():
          _visitStatements(currentNode.statements, previousNode);
        case SwitchExpressionCase():
          _visitSwitchExpressionCase(currentNode);
        case SwitchPatternCase():
          _visitSwitchPatternCase(currentNode, previousNode);
        case VariableDeclarationList():
          _visitVariableDeclarationList(currentNode, previousNode);
        case CompilationUnit():
        case CompilationUnitMember():
          return currentNode;
      }
      previousNode = currentNode;
      currentNode = currentNode.parent;
    }
    return currentNode;
  }

  /// Add suggestions for any local types that are visible at the completion
  /// location, given that the completion location is within the [node].
  ///
  /// This includes only type parameters.
  ///
  /// Return the member containing the local declarations that were added, or
  /// `null` if there is an error such as the AST being malformed or we
  /// encountered an AST structure that isn't handled correctly.
  ///
  /// The returned member can be either a [ClassMember] or a
  /// [CompilationUnitMember].
  AstNode? _addLocalTypes(AstNode node) {
    AstNode? currentNode = node;
    while (currentNode != null) {
      switch (currentNode) {
        case CommentReference():
          return currentNode;
        case ConstructorDeclaration():
          _visitParameterList(currentNode.parameters);
          return currentNode;
        case FieldDeclaration():
          return currentNode;
        case FunctionDeclaration(:var parent):
          if (parent is! FunctionDeclarationStatement) {
            return currentNode;
          }
        case FunctionExpression():
          _visitTypeParameterList(currentNode.typeParameters);
        case GenericFunctionType():
          _visitTypeParameterList(currentNode.typeParameters);
        case MethodDeclaration():
          _visitTypeParameterList(currentNode.typeParameters);
          return currentNode;
        case CompilationUnit():
        case CompilationUnitMember():
          return currentNode;
      }
      currentNode = currentNode.parent;
    }
    return currentNode;
  }

  /// Add suggestions for the [members] of the [containingElement].
  void _addMembers(Element containingElement, NodeList<ClassMember> members) {
    for (var member in members) {
      switch (member) {
        case ConstructorDeclaration():
          // Constructors are suggested when the enclosing class is suggested.
          break;
        case FieldDeclaration():
          if (mustBeStatic && !member.isStatic) {
            continue;
          }
          for (var field in member.fields.variables) {
            var declaredElement = field.declaredElement;
            if (declaredElement is FieldElement) {
              _suggestField(declaredElement, containingElement);
            }
          }
        case MethodDeclaration():
          if (mustBeStatic && !member.isStatic) {
            continue;
          }
          var declaredElement = member.declaredElement;
          if (declaredElement is MethodElement) {
            _suggestMethod(declaredElement, containingElement);
          } else if (declaredElement is PropertyAccessorElement) {
            _suggestProperty(declaredElement, containingElement);
          }
      }
    }
  }

  /// Add suggestions for any members of the [parent].
  ///
  /// The [containingMember] is the member within the [parent] in which
  /// completion was requested.
  void _addMembersOf(CompilationUnitMember parent, AstNode containingMember) {
    switch (parent) {
      case ClassDeclaration():
        var classElement = parent.declaredElement;
        if (classElement != null) {
          if (!mustBeType) {
            _addMembers(classElement, parent.members);
          }
          _suggestTypeParameters(classElement.typeParameters);
        }
      case EnumDeclaration():
        var enumElement = parent.declaredElement;
        if (enumElement != null) {
          if (!mustBeType) {
            _addMembers(enumElement, parent.members);
          }
          _suggestTypeParameters(enumElement.typeParameters);
        }
      case ExtensionDeclaration():
        var extensionElement = parent.declaredElement;
        if (extensionElement != null) {
          if (!mustBeType) {
            _addMembers(extensionElement, parent.members);
          }
          _suggestTypeParameters(extensionElement.typeParameters);
        }
      case ExtensionTypeDeclaration():
        var extensionTypeElement = parent.declaredElement;
        if (extensionTypeElement != null) {
          if (!mustBeType) {
            _addMembers(extensionTypeElement, parent.members);
          }
          _suggestTypeParameters(extensionTypeElement.typeParameters);
        }
      case MixinDeclaration():
        var mixinElement = parent.declaredElement;
        if (mixinElement != null) {
          if (!mustBeType) {
            _addMembers(mixinElement, parent.members);
          }
          _suggestTypeParameters(mixinElement.typeParameters);
        }
      case ClassTypeAlias():
        var aliasElement = parent.declaredElement;
        if (aliasElement != null) {
          _suggestTypeParameters(aliasElement.typeParameters);
        }
      case FunctionTypeAlias():
        var aliasElement = parent.declaredElement;
        if (aliasElement != null) {
          _suggestTypeParameters(aliasElement.typeParameters);
        }
      case GenericTypeAlias():
        var aliasElement = parent.declaredElement;
        if (aliasElement is TypeAliasElement) {
          _suggestTypeParameters(aliasElement.typeParameters);
        }
    }
  }

  /// Add suggestions for any top-level declarations that are visible within the
  /// [library].
  void _addTopLevelDeclarations(LibraryElement library) {
    for (var unit in library.units) {
      for (var element in unit.classes) {
        _suggestClass(element, null);
      }
      for (var element in unit.enums) {
        _suggestEnum(element, null);
      }
      // TODO(brianwilkerson): This should suggest extensions that have static
      //  members. We appear to not have any tests for this case.
      for (var element in unit.extensionTypes) {
        _suggestExtensionType(element, null);
      }
      for (var element in unit.mixins) {
        _suggestMixin(element, null);
      }
      for (var element in unit.typeAliases) {
        _suggestTypeAlias(element, null);
      }
      if (!mustBeType) {
        for (var element in unit.accessors) {
          if (!element.isSynthetic) {
            if (element.isGetter || element.correspondingGetter == null) {
              _suggestTopLevelProperty(element, null);
            }
          }
        }
        for (var element in unit.extensions) {
          if (element.name != null) {
            _suggestExtension(element, null);
          }
        }
        for (var element in unit.functions) {
          _suggestTopLevelFunction(element, null);
        }
        for (var element in unit.topLevelVariables) {
          if (!element.isSynthetic) {
            _suggestTopLevelVariable(element, null);
          }
        }
      }
    }
  }

  /// Return `true` if the [identifier] is composed of one or more underscore
  /// characters and nothing else.
  bool _isUnused(String identifier) => UnusedIdentifier.hasMatch(identifier);

  /// Add a suggestion for the class represented by the [element]. The [prefix]
  /// is the prefix by which the element is imported.
  void _suggestClass(ClassElement element, String? prefix) {
    if (visibilityTracker.isVisible(element)) {
      var suggestion = ClassSuggestion(prefix, element);
      collector.addSuggestion(suggestion);
      if (!mustBeType) {
        _suggestStaticFields(element.fields);
        _suggestConstructors(element.constructors,
            allowNonFactory: !element.isAbstract);
      }
    }
  }

  /// Add a suggestion for the constructor represented by the [element]. The
  /// [prefix] is the prefix by which the class is imported.
  void _suggestConstructor(ConstructorElement element, String? prefix) {
    if (mustBeAssignable || (mustBeConstant && !element.isConst)) {
      return;
    }
    var suggestion = ConstructorSuggestion(prefix, element);
    collector.addSuggestion(suggestion);
  }

  /// Suggest each of the [constructors].
  void _suggestConstructors(List<ConstructorElement> constructors,
      {bool allowNonFactory = true}) {
    if (mustBeAssignable) {
      return;
    }
    for (var constructor in constructors) {
      if (allowNonFactory || constructor.isFactory) {
        _suggestConstructor(constructor, null);
      }
    }
  }

  /// Add a suggestion for the enum represented by the [element]. The [prefix]
  /// is the prefix by which the element is imported.
  void _suggestEnum(EnumElement element, String? prefix) {
    if (visibilityTracker.isVisible(element)) {
      var suggestion = EnumSuggestion(prefix, element);
      collector.addSuggestion(suggestion);
      if (!mustBeType) {
        _suggestStaticFields(element.fields);
        _suggestConstructors(element.constructors);
      }
    }
  }

  /// Add a suggestion for the extension represented by the [element]. The
  /// [prefix] is the prefix by which the element is imported.
  void _suggestExtension(ExtensionElement element, String? prefix) {
    if (visibilityTracker.isVisible(element)) {
      var suggestion = ExtensionSuggestion(prefix, element);
      collector.addSuggestion(suggestion);

      _suggestStaticFields(element.fields);
    }
  }

  /// Add a suggestion for the extension type represented by the [element]. The
  /// [prefix] is the prefix by which the element is imported.
  void _suggestExtensionType(ExtensionTypeElement element, String? prefix) {
    if (visibilityTracker.isVisible(element)) {
      var suggestion = ExtensionTypeSuggestion(prefix, element);
      collector.addSuggestion(suggestion);
      if (!mustBeType) {
        _suggestStaticFields(element.fields);
        _suggestConstructors(element.constructors);
      }
    }
  }

  /// Add a suggestion for the field represented by the [element] contained
  /// in the [containingElement].
  void _suggestField(FieldElement element, Element containingElement) {
    if (visibilityTracker.isVisible(element)) {
      if ((mustBeAssignable && element.setter == null) ||
          (mustBeConstant && !element.isConst)) {
        return;
      }
      var suggestion = FieldSuggestion(element,
          (containingElement is ClassElement) ? containingElement : null);
      collector.addSuggestion(suggestion);
    }
  }

  /// Add a suggestion for the local function represented by the [element].
  void _suggestFunction(ExecutableElement element) {
    if (element is FunctionElement && visibilityTracker.isVisible(element)) {
      if (mustBeAssignable ||
          mustBeConstant ||
          (mustBeNonVoid && element.returnType is VoidType)) {
        return;
      }
      var suggestion =
          LocalFunctionSuggestion(_executableSuggestionKind, element);
      collector.addSuggestion(suggestion);
    }
  }

  /// Add a suggestion for the method represented by the [element] contained
  /// in the [containingElement].
  void _suggestMethod(MethodElement element, Element containingElement) {
    if (visibilityTracker.isVisible(element)) {
      if (mustBeAssignable ||
          mustBeConstant ||
          (mustBeNonVoid && element.returnType is VoidType)) {
        return;
      }
      var suggestion = MethodSuggestion(_executableSuggestionKind, element,
          (containingElement is ClassElement) ? containingElement : null);
      collector.addSuggestion(suggestion);
    }
  }

  /// Add a suggestion for the mixin represented by the [element]. The [prefix]
  /// is the prefix by which the element is imported.
  void _suggestMixin(MixinElement element, String? prefix) {
    if (visibilityTracker.isVisible(element)) {
      var suggestion = MixinSuggestion(prefix, element);
      collector.addSuggestion(suggestion);
      if (!mustBeType) {
        _suggestStaticFields(element.fields);
      }
    }
  }

  /// Add a suggestion for the parameter represented by the [element].
  void _suggestParameter(ParameterElement element) {
    if (visibilityTracker.isVisible(element)) {
      if (mustBeConstant || _isUnused(element.name)) {
        return;
      }
      var suggestion = FormalParameterSuggestion(element);
      collector.addSuggestion(suggestion);
    }
  }

  /// Add a suggestion for the getter or setter represented by the [element]
  /// contained in the [containingElement].
  void _suggestProperty(
      PropertyAccessorElement element, Element containingElement) {
    if (visibilityTracker.isVisible(element)) {
      if ((mustBeAssignable &&
              element.isGetter &&
              element.correspondingSetter == null) ||
          mustBeConstant ||
          (mustBeNonVoid && element.returnType is VoidType)) {
        return;
      }
      var suggestion = PropertyAccessSuggestion(element,
          (containingElement is ClassElement) ? containingElement : null);
      collector.addSuggestion(suggestion);
    }
  }

  /// Add a suggestion for the enum constant represented by the [element].
  /// The [prefix] is the prefix by which the element is imported.
  void _suggestStaticField(FieldElement element, String? prefix) {
    if (!element.isStatic ||
        (mustBeAssignable && !(element.isFinal || element.isConst)) ||
        (mustBeConstant && !element.isConst)) {
      return;
    }
    final contextType = request.contextType;
    if (contextType != null &&
        request.libraryElement.typeSystem
            .isSubtypeOf(element.type, contextType)) {
      if (element.isEnumConstant) {
        var suggestion = EnumConstantSuggestion(prefix, element);
        collector.addSuggestion(suggestion);
      } else {
        var suggestion = StaticFieldSuggestion(prefix, element);
        collector.addSuggestion(suggestion);
      }
    }
  }

  /// Suggest each of the static fields in the list of [fields].
  void _suggestStaticFields(List<FieldElement> fields) {
    for (var field in fields) {
      _suggestStaticField(field, null);
    }
  }

  /// Add a suggestion for the function represented by the [element]. The
  /// [prefix] is the prefix by which the element is imported.
  void _suggestTopLevelFunction(FunctionElement element, String? prefix) {
    if (visibilityTracker.isVisible(element)) {
      if (mustBeAssignable ||
          mustBeConstant ||
          (mustBeNonVoid && element.returnType is VoidType)) {
        return;
      }
      var suggestion = TopLevelFunctionSuggestion(
          prefix, element, _executableSuggestionKind);
      collector.addSuggestion(suggestion);
    }
  }

  /// Add a suggestion for the getter or setter represented by the [element].
  /// The [prefix] is the prefix by which the element is imported.
  void _suggestTopLevelProperty(
      PropertyAccessorElement element, String? prefix) {
    if (visibilityTracker.isVisible(element)) {
      if ((mustBeAssignable &&
              element.isGetter &&
              element.correspondingSetter == null) ||
          mustBeConstant ||
          (mustBeNonVoid && element.returnType is VoidType)) {
        return;
      }
      var suggestion = TopLevelPropertyAccessSuggestion(prefix, element);
      collector.addSuggestion(suggestion);
    }
  }

  /// Add a suggestion for the getter or setter represented by the [element].
  /// The [prefix] is the prefix by which the element is imported.
  void _suggestTopLevelVariable(
      TopLevelVariableElement element, String? prefix) {
    if (visibilityTracker.isVisible(element)) {
      if ((mustBeAssignable && element.setter == null) ||
          mustBeConstant && !element.isConst) {
        return;
      }
      var suggestion = TopLevelVariableSuggestion(prefix, element);
      collector.addSuggestion(suggestion);
    }
  }

  /// Add a suggestion for the type alias represented by the [element]. The
  /// [prefix] is the prefix by which the element is imported.
  void _suggestTypeAlias(TypeAliasElement element, String? prefix) {
    if (visibilityTracker.isVisible(element)) {
      var suggestion = TypeAliasSuggestion(prefix, element);
      collector.addSuggestion(suggestion);
      if (!mustBeType) {
        _addConstructorsForAliasedElement(element);
      }
    }
  }

  /// Add a suggestion for the type parameter represented by the [element].
  void _suggestTypeParameter(TypeParameterElement element) {
    if (visibilityTracker.isVisible(element)) {
      var suggestion = TypeParameterSuggestion(element);
      collector.addSuggestion(suggestion);
    }
  }

  /// Suggest each of the [typeParameters].
  void _suggestTypeParameters(List<TypeParameterElement> typeParameters) {
    for (var parameter in typeParameters) {
      _suggestTypeParameter(parameter);
    }
  }

  /// Add a suggestion for the local variable represented by the [element].
  void _suggestVariable(LocalVariableElement element) {
    if (visibilityTracker.isVisible(element)) {
      if (mustBeConstant && !element.isConst) {
        return;
      }
      var suggestion = LocalVariableSuggestion(element, _variableDistance++);
      collector.addSuggestion(suggestion);
    }
  }

  void _visitCatchClause(CatchClause node) {
    var exceptionElement = node.exceptionParameter?.declaredElement;
    if (exceptionElement != null) {
      _suggestVariable(exceptionElement);
    }

    var stackTraceElement = node.stackTraceParameter?.declaredElement;
    if (stackTraceElement != null) {
      _suggestVariable(stackTraceElement);
    }
  }

  AstNode? _visitCommentReference(CommentReference node) {
    var comment = node.parent;
    var member = comment?.parent;
    switch (member) {
      case ConstructorDeclaration():
        _visitParameterList(member.parameters);
      case FunctionDeclaration():
        var functionExpression = member.functionExpression;
        _visitParameterList(functionExpression.parameters);
        _visitTypeParameterList(functionExpression.typeParameters);
      case FunctionExpression():
        _visitParameterList(member.parameters);
        _visitTypeParameterList(member.typeParameters);
      case MethodDeclaration():
        _visitParameterList(member.parameters);
        _visitTypeParameterList(member.typeParameters);
    }
    return comment;
  }

  void _visitDeclaredVariablePattern(DeclaredVariablePattern pattern) {
    var declaredElement = pattern.declaredElement;
    if (declaredElement != null) {
      _suggestVariable(declaredElement);
    }
  }

  void _visitForLoopParts(ForLoopParts node) {
    if (node is ForEachPartsWithDeclaration) {
      var declaredElement = node.loopVariable.declaredElement;
      if (declaredElement != null) {
        _suggestVariable(declaredElement);
      }
    } else if (node is ForPartsWithDeclarations) {
      var variables = node.variables;
      for (var variable in variables.variables) {
        var declaredElement = variable.declaredElement;
        if (declaredElement is LocalVariableElement) {
          _suggestVariable(declaredElement);
        }
      }
    }
  }

  void _visitIfElement(IfElement node) {
    var elseKeyword = node.elseKeyword;
    if (elseKeyword == null || offset < elseKeyword.offset) {
      var pattern = node.caseClause?.guardedPattern.pattern;
      if (pattern != null) {
        _visitPattern(pattern);
      }
    }
  }

  void _visitIfStatement(IfStatement node) {
    var elseKeyword = node.elseKeyword;
    if (elseKeyword == null || offset < elseKeyword.offset) {
      var pattern = node.caseClause?.guardedPattern.pattern;
      if (pattern != null) {
        _visitPattern(pattern);
      }
    }
  }

  void _visitParameterList(FormalParameterList? parameterList) {
    if (parameterList != null) {
      for (var param in parameterList.parameters) {
        var declaredElement = param.declaredElement;
        if (declaredElement != null) {
          _suggestParameter(declaredElement);
        }
      }
    }
  }

  void _visitPattern(DartPattern pattern) {
    switch (pattern) {
      case CastPattern(:var pattern):
        _visitPattern(pattern);
      case DeclaredVariablePattern():
        _visitDeclaredVariablePattern(pattern);
      case ListPattern():
        for (var element in pattern.elements) {
          if (element is DartPattern) {
            _visitPattern(element);
          } else if (element is RestPatternElement) {
            var elementPattern = element.pattern;
            if (elementPattern != null) {
              _visitPattern(elementPattern);
            }
          }
        }
      case LogicalAndPattern():
        _visitPattern(pattern.leftOperand);
        _visitPattern(pattern.rightOperand);
      case LogicalOrPattern():
        _visitPattern(pattern.leftOperand);
        _visitPattern(pattern.rightOperand);
      case MapPattern():
        for (var element in pattern.elements) {
          if (element is MapPatternEntry) {
            _visitPattern(element.value);
          } else if (element is RestPatternElement) {
            var elementPattern = element.pattern;
            if (elementPattern != null) {
              _visitPattern(elementPattern);
            }
          }
        }
      case NullAssertPattern():
        _visitPattern(pattern.pattern);
      case NullCheckPattern():
        _visitPattern(pattern.pattern);
      case ObjectPattern():
        for (var field in pattern.fields) {
          _visitPattern(field.pattern);
        }
      case ParenthesizedPattern():
        _visitPattern(pattern.pattern);
      case RecordPattern():
        for (var field in pattern.fields) {
          _visitPattern(field.pattern);
        }
      case _:
      // Do nothing
    }
  }

  void _visitStatements(NodeList<Statement> statements, AstNode? child) {
    // Visit the statements in reverse order so that shadowing declarations are
    // found before the declarations they shadow.
    for (var i = statements.length - 1; i >= 0; i--) {
      var statement = statements[i];
      if (statement == child) {
        // Skip the child that was passed in because we will have already
        // visited it and don't want to suggest declared variables twice.
        continue;
      }
      // TODO(brianwilkerson): I think we need to compare to the end of the
      //  statement for variable declarations and the offset for functions.
      if (statement.offset < offset) {
        if (statement is VariableDeclarationStatement) {
          var variables = statement.variables;
          for (var variable in variables.variables) {
            if (variable.end < offset) {
              var declaredElement = variable.declaredElement;
              if (declaredElement is LocalVariableElement) {
                _suggestVariable(declaredElement);
              }
            }
          }
        } else if (statement is FunctionDeclarationStatement) {
          var declaration = statement.functionDeclaration;
          if (declaration.offset < offset) {
            var name = declaration.name.lexeme;
            if (name.isNotEmpty) {
              var declaredElement = declaration.declaredElement;
              if (declaredElement != null) {
                _suggestFunction(declaredElement);
              }
            }
          }
        } else if (statement is PatternVariableDeclarationStatement) {
          var declaration = statement.declaration;
          if (declaration.end < offset) {
            _visitPattern(declaration.pattern);
          }
        }
      }
    }
  }

  void _visitSwitchExpressionCase(SwitchExpressionCase node) {
    if (offset >= node.arrow.end) {
      _visitPattern(node.guardedPattern.pattern);
    }
  }

  void _visitSwitchPatternCase(SwitchPatternCase node, AstNode? child) {
    if (offset >= node.colon.end) {
      _visitStatements(node.statements, child);
      _visitPattern(node.guardedPattern.pattern);
      var parent = node.parent;
      if (parent is SwitchStatement) {
        var members = parent.members;
        var index = members.indexOf(node) - 1;
        while (index >= 0) {
          var member = members[index];
          if (member is SwitchPatternCase && member.statements.isEmpty) {
            _visitPattern(member.guardedPattern.pattern);
          } else {
            break;
          }
          index--;
        }
      }
    }
  }

  void _visitTypeParameterList(TypeParameterList? typeParameters) {
    if (typeParameters != null) {
      for (var typeParameter in typeParameters.typeParameters) {
        var element = typeParameter.declaredElement;
        if (element != null) {
          _suggestTypeParameter(element);
        }
      }
    }
  }

  void _visitVariableDeclarationList(
      VariableDeclarationList node, AstNode? child) {
    var variables = node.variables;
    if (child is VariableDeclaration) {
      var index = variables.indexOf(child);
      for (var i = index - 1; i >= 0; i--) {
        var element = variables[i].declaredElement;
        if (element is LocalVariableElement) {
          _suggestVariable(element);
        }
      }
    }
  }
}
