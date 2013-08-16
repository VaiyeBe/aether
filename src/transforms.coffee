esprima = require 'esprima'
S = esprima.Syntax

statements = [S.EmptyStatement, S.ExpressionStatement, S.BreakStatement, S.ContinueStatement, S.DebuggerStatement, S.DoWhileStatement, S.ForStatement, S.FunctionDeclaration, S.ClassDeclaration, S.IfStatement, S.ReturnStatement, S.SwitchStatement, S.ThrowStatement, S.TryStatement, S.VariableStatement, S.WhileStatement, S.WithStatement]

getLineNumberForNode = (node) ->
  # We ignore the first two wrapper lines
  parent = node
  while parent.type isnt S.Program
    parent = parent.parent
  fullSource = parent.source()
  line = -2
  for i in [0 ... node.range[0]]
    if fullSource[i] is '\n'
      ++line
  #console.log "getLineNumberFor", node, "of", fullSource, "is", line
  line

possiblyGeneratorifyAncestorFunction = (node) ->
  while node.type isnt S.FunctionExpression
    node = node.parent
  node.mustBecomeGeneratorFunction = true

# Now that it's normalized to this: https://github.com/nwinter/JS_WALA/blob/master/normalizer/doc/normalization.md
# ... we can basically just put a yield check in after every CallExpression except the outermost one if we are yielding conditionally.
module.exports.yieldConditionally = yieldConditionally = (node) ->
  grandparent = node.parent?.parent
  if node.type is S.CallExpression and grandparent?.type is S.ExpressionStatement
    grandparent.update "#{grandparent.source()} if (__global._shouldYield) { var __yieldValue = __global._shouldYield; __global._shouldYield = false; yield __yieldValue; }"
    grandparent.yields = true
    possiblyGeneratorifyAncestorFunction grandparent
  else if node.mustBecomeGeneratorFunction
    node.update node.source().replace /^function \(/, 'function* ('

module.exports.yieldAutomatically = yieldAutomatically = (node) ->
  # TODO: don't yield after things like 'use strict';
  # TODO: think about only doing this after some of the statements which have a different original range?
  if node.type in statements
    if node.parent?.type isnt S.Program
      node.update "#{node.source()} yield 'waiting...';"
      node.yields = true
      possiblyGeneratorifyAncestorFunction node
  else if node.mustBecomeGeneratorFunction
    node.update node.source().replace /^function \(/, 'function* ('

module.exports.validateReturns = validateReturns = (node) ->
  if node.type is S.ReturnStatement and not node.argument
    node.update "return this.validateReturn('#{@options.functionName}', null);"
  else if node.parent?.type is S.ReturnStatement
    node.update "this.validateReturn('#{@options.functionName}', (#{node.source()}))"

module.exports.addThis = addThis = (node) ->
  if node.type is S.VariableDeclarator
    @vars[node.id] = true
  else if node.type is S.CallExpression
    if node.callee.name and not @vars[node.callee.name] and not (@options.global[node.callee.name])
      node.update "this.#{node.source()}"

# TODO: this one should be replaced by generalized flow-control instrumentation
module.exports.gatherLineNumbers = gatherLineNumbers = (node) ->
  if node.type is S.ExpressionStatement
    lineNumber = getLineNumberForNode node
    exp = node.expression
    if exp.type is S.CallExpression
      # Quick hack to handle tracking line number for plan() method invocations
      if exp.callee.type is S.MemberExpression
        name = exp.callee.property.name
      else if exp.callee.type is S.Identifier
        name = exp.callee.name  # say() without this... (even though I added this)
      else if $?
        console.log "How is this CallExpression being handled?", node, node.source(), exp.callee, exp.callee.source()
      if @methodLineNumbers.length > lineNumber
        @methodLineNumbers[lineNumber].push name
      else
        console.log "More lines than we can actually handle:", lineNumber, name, "of", @methodLineNumbers.length, "lines"

module.exports.checkIncompleteMembers = checkIncompleteMembers = (node) ->
  if node.type is 'ExpressionStatement'
    lineNumber = Aether.getLineNumberForNode node, true
    exp = node.expression
    if exp.type is 'MemberExpression'
      # Handle missing parentheses, like in:  this.moveUp;
      if exp.property.name is "IncompleteThisReference"
        m = "this.what? (Check available spells below.)"
      else
        m = "#{exp.source()} has no effect."
        if exp.property.name in errors.commonMethods
          m += " It needs parentheses: #{exp.property.name}()"
      error = new Error m
      error.lineNumber = lineNumber + 2  # Reapply wrapper function offset
      #if $? then console.log node, node.source(), "going to error out!"
      throw error

module.exports.instrumentStatements = instrumentStatements = (node) ->
