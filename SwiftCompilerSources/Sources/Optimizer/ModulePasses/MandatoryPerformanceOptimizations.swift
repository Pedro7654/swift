//===--- MandatoryPerformanceOptimizations.swift --------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SIL

/// Performs mandatory optimizations for performance-annotated functions, and global
/// variable initializers that are required to be statically initialized.
///
/// Optimizations include:
/// * de-virtualization
/// * mandatory inlining
/// * generic specialization
/// * mandatory memory optimizations
/// * dead alloc elimination
/// * instruction simplification
///
/// The pass starts with performance-annotated functions / globals and transitively handles
/// called functions.
///
let mandatoryPerformanceOptimizations = ModulePass(name: "mandatory-performance-optimizations") {
  (moduleContext: ModulePassContext) in

  var worklist = FunctionWorklist()
  worklist.addAllPerformanceAnnotatedFunctions(of: moduleContext)
  worklist.addAllAnnotatedGlobalInitOnceFunctions(of: moduleContext)

  optimizeFunctionsTopDown(using: &worklist, moduleContext)
}

private func optimizeFunctionsTopDown(using worklist: inout FunctionWorklist,
                                      _ moduleContext: ModulePassContext) {
  while let f = worklist.pop() {
    moduleContext.transform(function: f) { context in
      if !context.loadFunction(function: f, loadCalleesRecursively: true) {
        return
      }
      optimize(function: f, context)
      worklist.add(calleesOf: f)
    }
  }
}

fileprivate struct PathFunctionTuple: Hashable {
  var path: SmallProjectionPath
  var function: Function
}

private func optimize(function: Function, _ context: FunctionPassContext) {
  var alreadyInlinedFunctions: Set<PathFunctionTuple> = Set()
  
  var changed = true
  while changed {
    changed = runSimplification(on: function, context, preserveDebugInfo: true) { instruction, simplifyCtxt in
      if let i = instruction as? OnoneSimplifyable {
        i.simplify(simplifyCtxt)
        if instruction.isDeleted {
          return
        }
      }
      switch instruction {
      case let apply as FullApplySite:
        inlineAndDevirtualize(apply: apply, alreadyInlinedFunctions: &alreadyInlinedFunctions, context, simplifyCtxt)
      default:
        break
      }
    }

    _ = context.specializeApplies(in: function, isMandatory: true)

    removeUnusedMetatypeInstructions(in: function, context)

    // If this is a just specialized function, try to optimize copy_addr, etc.
    changed = context.optimizeMemoryAccesses(in: function) || changed
    _ = context.eliminateDeadAllocations(in: function)
  }
}

private func inlineAndDevirtualize(apply: FullApplySite, alreadyInlinedFunctions: inout Set<PathFunctionTuple>,
                                   _ context: FunctionPassContext, _ simplifyCtxt: SimplifyContext) {
  if simplifyCtxt.tryDevirtualize(apply: apply, isMandatory: true) != nil {
    return
  }

  guard let callee = apply.referencedFunction else {
    return
  }

  if !context.loadFunction(function: callee, loadCalleesRecursively: true) {
    // We don't have the funcion body of the callee.
    return
  }

  if apply.canInline &&
     shouldInline(apply: apply, callee: callee, alreadyInlinedFunctions: &alreadyInlinedFunctions)
  {
    if apply.inliningCanInvalidateStackNesting  {
      simplifyCtxt.notifyInvalidatedStackNesting()
    }

    simplifyCtxt.inlineFunction(apply: apply, mandatoryInline: true)
  }
}

private func removeUnusedMetatypeInstructions(in function: Function, _ context: FunctionPassContext) {
  for inst in function.instructions {
    if let mt = inst as? MetatypeInst,
       mt.isTriviallyDeadIgnoringDebugUses {
      context.erase(instructionIncludingDebugUses: mt)
    }
  }
}

private func shouldInline(apply: FullApplySite, callee: Function, alreadyInlinedFunctions: inout Set<PathFunctionTuple>) -> Bool {
  if callee.isTransparent {
    return true
  }
  if apply is BeginApplyInst {
    // Avoid co-routines because they might allocate (their context).
    return true
  }
  if apply.parentFunction.isGlobalInitOnceFunction && callee.inlineStrategy == .always {
    // Some arithmetic operations, like integer conversions, are not transparent but `inline(__always)`.
    // Force inlining them in global initializers so that it's possible to statically initialize the global.
    return true
  }

  if apply.substitutionMap.isEmpty,
     let pathIntoGlobal = apply.resultIsUsedInGlobalInitialization(),
     alreadyInlinedFunctions.insert(PathFunctionTuple(path: pathIntoGlobal, function: callee)).inserted {
    return true
  }

  return false
}

private extension FullApplySite {
  func resultIsUsedInGlobalInitialization() -> SmallProjectionPath? {
    guard parentFunction.isGlobalInitOnceFunction,
          let global = parentFunction.getInitializedGlobal() else {
      return nil
    }

    switch numIndirectResultArguments {
    case 0:
      return singleDirectResult?.isStored(to: global)
    case 1:
      let resultAccessPath = arguments[0].accessPath
      switch resultAccessPath.base {
      case .global(let resultGlobal) where resultGlobal == global:
        return resultAccessPath.materializableProjectionPath
      case .stack(let allocStack) where resultAccessPath.projectionPath.isEmpty:
        return allocStack.getStoredValue(by: self)?.isStored(to: global)
      default:
        return nil
      }
    default:
      return nil
    }
  }
}

private extension AllocStackInst {
  func getStoredValue(by storingInstruction: Instruction) -> Value? {
    // If the only use (beside `storingInstruction`) is a load, it's the value which is
    // stored by `storingInstruction`.
    var loadedValue: Value? = nil
    for use in self.uses {
      switch use.instruction {
      case is DeallocStackInst:
        break
      case let load as LoadInst:
        if loadedValue != nil {
          return nil
        }
        loadedValue = load
      default:
        if use.instruction != storingInstruction {
          return nil
        }
      }
    }
    return loadedValue
  }
}

private extension Value {
  /// Analyzes the def-use chain of an apply instruction, and looks for a single chain that leads to a store instruction
  /// that initializes a part of a global variable or the entire variable:
  ///
  /// Example:
  ///   %g = global_addr @global
  ///   ...
  ///   %f = function_ref @func
  ///   %apply = apply %f(...)
  ///   store %apply to %g   <--- is a store to the global trivially (the apply result is immediately going into a store)
  ///
  /// Example:
  ///   %apply = apply %f(...)
  ///   %apply2 = apply %f2(%apply)
  ///   store %apply2 to %g   <--- is a store to the global (the apply result has a single chain into the store)
  ///
  /// Example:
  ///   %a = apply %f(...)
  ///   %s = struct $MyStruct (%a, %b)
  ///   store %s to %g   <--- is a partial store to the global (returned SmallProjectionPath is MyStruct.s0)
  ///
  /// Example:
  ///   %a = apply %f(...)
  ///   %as = struct $AStruct (%other, %a)
  ///   %bs = struct $BStruct (%as, %bother)
  ///   store %bs to %g   <--- is a partial store to the global (returned SmallProjectionPath is MyStruct.s0.s1)
  ///
  /// Returns nil if we cannot find a singular def-use use chain (e.g. because a value has more than one user)
  /// leading to a store to the specified global variable.
  func isStored(to global: GlobalVariable) -> SmallProjectionPath? {
    var singleUseValue: any Value = self
    var path = SmallProjectionPath()
    while true {
      guard let use = singleUseValue.uses.singleRelevantUse else {
        return nil
      }
      
      switch use.instruction {
      case is StructInst:
        path = path.push(.structField, index: use.index)
        break
      case is TupleInst:
        path = path.push(.tupleField, index: use.index)
        break
      case let ei as EnumInst:
        path = path.push(.enumCase, index: ei.caseIndex)
        break
      case let si as StoreInst:
        let accessPath = si.destination.getAccessPath(fromInitialPath: path)
        switch accessPath.base {
        case .global(let storedGlobal) where storedGlobal == global:
          return accessPath.materializableProjectionPath
        default:
          return nil
        }
      case is PointerToAddressInst, is AddressToPointerInst, is BeginAccessInst:
        break
      default:
        return nil
      }

      guard let nextInstruction = use.instruction as? SingleValueInstruction else {
        return nil
      }

      singleUseValue = nextInstruction
    }
  }
}

private extension Function {
  /// Analyzes the global initializer function and returns global it initializes (from `alloc_global` instruction).
  func getInitializedGlobal() -> GlobalVariable? {
    for inst in self.entryBlock.instructions {
      switch inst {
      case let agi as AllocGlobalInst:
        return agi.global
      default:
        break
      }
    }

    return nil
  }
}

fileprivate struct FunctionWorklist {
  private(set) var functions = Array<Function>()
  private var pushedFunctions = Set<Function>()
  private var currentIndex = 0

  mutating func pop() -> Function? {
    if currentIndex < functions.count {
      let f = functions[currentIndex]
      currentIndex += 1
      return f
    }
    return nil
  }

  mutating func addAllPerformanceAnnotatedFunctions(of moduleContext: ModulePassContext) {
    for f in moduleContext.functions where f.performanceConstraints != .none {
      pushIfNotVisited(f)
    }
  }

  mutating func addAllAnnotatedGlobalInitOnceFunctions(of moduleContext: ModulePassContext) {
    for f in moduleContext.functions where f.isGlobalInitOnceFunction {
      if let global = f.getInitializedGlobal(),
         global.mustBeInitializedStatically {
        pushIfNotVisited(f)
      }
    }
  }

  mutating func add(calleesOf function: Function) {
    for inst in function.instructions {
      switch inst {
      case let apply as ApplySite:
        if let callee = apply.referencedFunction {
          pushIfNotVisited(callee)
        }
      case let bi as BuiltinInst:
        switch bi.id {
        case .Once, .OnceWithContext:
          if let fri = bi.operands[1].value as? FunctionRefInst {
            pushIfNotVisited(fri.referencedFunction)
          }
          break;
        default:
          break
        }
      default:
        break
      }
    }
  }

  mutating func pushIfNotVisited(_ element: Function) {
    if pushedFunctions.insert(element).inserted {
      functions.append(element)
    }
  }
}

private extension UseList {
  var singleRelevantUse: Operand? {
    var singleUse: Operand?
    for use in self {
      switch use.instruction {
      case is DebugValueInst,
           // The initializer value of a global can contain access instructions if it references another
           // global variable by address, e.g.
           //   var p = Point(x: 10, y: 20)
           //   let o = UnsafePointer(&p)
           // Therefore ignore the `end_access` use of a `begin_access`.
           is EndAccessInst:
        continue
      default:
        if singleUse != nil {
          return nil
        }
        singleUse = use
      }
    }
    return singleUse
  }
}
