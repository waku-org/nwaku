## RequestBroker
## --------------------
## RequestBroker represents a proactive decoupling pattern, that
## allows defining request-response style interactions between modules without
## need for direct dependencies in between.
## Worth considering using it in a single provider, many requester scenario.
##
## Provides a declarative way to define an immutable value type together with a
## thread-local broker that can register asynchronous providers, dispatch typed
## requests and clear handlers. Each macro block defines one value type and the
## companion `<TypeName>Broker` along with the `setProvider`, `request`, and
## `clearProvider` helpers.
##
## Example:
## ```nim
## RequestBroker:
##   type Greeting = object
##     text*: string
##
##   ## Define the request and provider signature, that is enforced at compile time.
##   proc signature*(): Future[Result[Greeting, string]]
##
##   ## Also possible to define signature with arbitrary input arguments.
##   proc signature*(lang: string): Future[Result[Greeting, string]]
##
## ...
## Greeting.setProvider(
##   proc(): Future[Result[Greeting, string]] {.async.} =
##     ok(Greeting(text: "hello"))
## )
## let res = await Greeting.request()
## ```
## If no `signature` proc is declared, a zero-argument form is generated
## automatically, so the caller only needs to provide the type definition.

import std/[macros, strutils]
import chronos
import results

export results

proc errorFuture[T](message: string): Future[Result[T, string]] {.inline.} =
  ## Build a future that is already completed with an error result.
  let fut = newFuture[Result[T, string]]("request_broker.errorFuture")
  fut.complete(err(Result[T, string], message))
  fut

proc sanitizeIdentName(node: NimNode): string =
  var raw = $node
  result = newStringOfCap(raw.len)
  for ch in raw:
    case ch
    of 'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_':
      result.add(ch)
    else:
      result.add('_')

proc ensureFieldDef(node: NimNode) =
  if node.kind != nnkIdentDefs or node.len < 3:
    error("Expected field definition of the form `name: Type`", node)
  let typeSlot = node.len - 2
  if node[typeSlot].kind == nnkEmpty:
    error("Field `" & $node[0] & "` must declare a type", node)

proc exportIdentNode(node: NimNode): NimNode =
  case node.kind
  of nnkIdent:
    postfix(copyNimTree(node), "*")
  of nnkPostfix:
    node
  else:
    error("Unsupported identifier form in field definition", node)

proc baseTypeIdent(defName: NimNode): NimNode =
  case defName.kind
  of nnkIdent:
    defName
  of nnkAccQuoted:
    if defName.len != 1:
      error("Unsupported quoted identifier", defName)
    defName[0]
  of nnkPostfix:
    baseTypeIdent(defName[1])
  of nnkPragmaExpr:
    baseTypeIdent(defName[0])
  else:
    error("Unsupported type name in RequestBroker", defName)

proc isReturnTypeValid(returnType, typeIdent: NimNode): bool =
  ## Accept Future[Result[TypeIdent, string]] as the contract.
  if returnType.kind != nnkBracketExpr or returnType.len != 2:
    return false
  if returnType[0].kind != nnkIdent or not returnType[0].eqIdent("Future"):
    return false
  let inner = returnType[1]
  if inner.kind != nnkBracketExpr or inner.len != 3:
    return false
  if inner[0].kind != nnkIdent or not inner[0].eqIdent("Result"):
    return false
  if inner[1].kind != nnkIdent or not inner[1].eqIdent($typeIdent):
    return false
  inner[2].kind == nnkIdent and inner[2].eqIdent("string")

proc copyParam(def: NimNode): NimNode =
  ## Build a fresh IdentDefs node for proc type definitions.
  assert def.kind == nnkIdentDefs
  result = newTree(nnkIdentDefs, ident("input"), def[def.len - 2], newEmptyNode())

proc makeProcType(returnType: NimNode, params: seq[NimNode]): NimNode =
  var formal = newTree(nnkFormalParams)
  formal.add(returnType)
  for param in params:
    formal.add(param)
  let pragmas = newTree(nnkPragma, ident("gcsafe"))
  newTree(nnkProcTy, formal, pragmas)

macro RequestBroker*(body: untyped): untyped =
  when defined(requestBrokerDebug):
    echo body.treeRepr
  var typeIdent: NimNode = nil
  var objectDef: NimNode = nil
  for stmt in body:
    if stmt.kind == nnkTypeSection:
      for def in stmt:
        if def.kind != nnkTypeDef:
          continue
        let rhs = def[2]
        if rhs.kind != nnkObjectTy:
          continue
        if not typeIdent.isNil:
          error("Only one object type may be declared inside RequestBroker", def)
        typeIdent = baseTypeIdent(def[0])
        let recList = rhs[2]
        if recList.kind != nnkRecList:
          error("RequestBroker object must declare a standard field list", rhs)
        var exportedRecList = newTree(nnkRecList)
        for field in recList:
          case field.kind
          of nnkIdentDefs:
            ensureFieldDef(field)
            var cloned = copyNimTree(field)
            for i in 0 ..< cloned.len - 2:
              cloned[i] = exportIdentNode(cloned[i])
            exportedRecList.add(cloned)
          of nnkEmpty:
            discard
          else:
            error(
              "RequestBroker object definition only supports simple field declarations",
              field,
            )
        objectDef = newTree(
          nnkObjectTy, copyNimTree(rhs[0]), copyNimTree(rhs[1]), exportedRecList
        )
  if typeIdent.isNil:
    error("RequestBroker body must declare exactly one object type", body)

  when defined(requestBrokerDebug):
    echo "RequestBroker generating type: ", $typeIdent

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let typeNameLit = newLit(sanitizeIdentName(typeIdent))
  var zeroArgSig: NimNode = nil
  var zeroArgProviderName: NimNode = nil
  var zeroArgFieldName: NimNode = nil
  var argSig: NimNode = nil
  var argParam: NimNode = nil
  var argProviderName: NimNode = nil
  var argFieldName: NimNode = nil
  var argTypeNode: NimNode = nil

  for stmt in body:
    case stmt.kind
    of nnkProcDef:
      let procName = stmt[0]
      let procNameIdent =
        case procName.kind
        of nnkIdent:
          procName
        of nnkPostfix:
          procName[1]
        else:
          procName
      let procNameStr = $procNameIdent
      if not procNameStr.startsWith("signature"):
        error("Signature proc names must start with `signature`", procName)
      let params = stmt.params
      if params.len == 0:
        error("Signature must declare a return type", stmt)
      let returnType = params[0]
      if not isReturnTypeValid(returnType, typeIdent):
        error(
          "Signature must return Future[Result[`" & $typeIdent & "`, string]]", stmt
        )
      let paramCount = params.len - 1
      if paramCount == 0:
        if zeroArgSig != nil:
          error("Only one zero-argument signature is allowed", stmt)
        zeroArgSig = stmt
        zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
        zeroArgFieldName = ident("providerNoArgs")
      elif paramCount == 1:
        if argSig != nil:
          error("Only one argument-based signature is allowed", stmt)
        let paramTypeNode = params[1][params[1].len - 2]
        if paramTypeNode.kind == nnkEmpty:
          error("Signature parameter must declare a type", params[1])
        argSig = stmt
        argParam = copyParam(params[1])
        argTypeNode = copyNimTree(paramTypeNode)
        argProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderWithArgs")
        argFieldName = ident("providerWithArgs")
      else:
        error("Signatures may define at most one parameter", stmt)
    of nnkTypeSection, nnkEmpty:
      discard
    else:
      error("Unsupported statement inside RequestBroker definition", stmt)

  if zeroArgSig.isNil and argSig.isNil:
    zeroArgSig = newEmptyNode()
    zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
    zeroArgFieldName = ident("providerNoArgs")

  var typeSection = newTree(nnkTypeSection)
  typeSection.add(newTree(nnkTypeDef, exportedTypeIdent, newEmptyNode(), objectDef))

  let returnType = quote:
    Future[Result[`typeIdent`, string]]

  if not zeroArgSig.isNil:
    let procType = makeProcType(returnType, @[])
    typeSection.add(newTree(nnkTypeDef, zeroArgProviderName, newEmptyNode(), procType))
  if not argSig.isNil:
    let procType = makeProcType(returnType, @[argParam])
    typeSection.add(newTree(nnkTypeDef, argProviderName, newEmptyNode(), procType))

  var brokerRecList = newTree(nnkRecList)
  if not zeroArgSig.isNil:
    brokerRecList.add(
      newTree(nnkIdentDefs, zeroArgFieldName, zeroArgProviderName, newEmptyNode())
    )
  if not argSig.isNil:
    brokerRecList.add(
      newTree(nnkIdentDefs, argFieldName, argProviderName, newEmptyNode())
    )
  let brokerTypeIdent = ident(sanitizeIdentName(typeIdent) & "Broker")
  let brokerTypeDef = newTree(
    nnkTypeDef,
    postfix(brokerTypeIdent, "*"),
    newEmptyNode(),
    newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), brokerRecList),
  )
  typeSection.add(brokerTypeDef)
  result = newStmtList()
  result.add(typeSection)

  let globalVarIdent = ident("g" & sanitizeIdentName(typeIdent) & "Broker")
  let accessProcIdent = ident("access" & sanitizeIdentName(typeIdent) & "Broker")
  result.add(
    quote do:
      var `globalVarIdent` {.threadvar.}: `brokerTypeIdent`

      proc `accessProcIdent`(): var `brokerTypeIdent` =
        `globalVarIdent`

      proc broker*(_: typedesc[`typeIdent`]): var `brokerTypeIdent` =
        `accessProcIdent`()

  )

  var clearBody = newStmtList()
  if not zeroArgSig.isNil:
    result.add(
      quote do:
        proc setProvider*(_: typedesc[`typeIdent`], handler: `zeroArgProviderName`) =
          `accessProcIdent`().`zeroArgFieldName` = handler

    )
    clearBody.add(
      quote do:
        `accessProcIdent`().`zeroArgFieldName` = nil
    )
    result.add(
      quote do:
        proc request*(_: typedesc[`typeIdent`]): Future[Result[`typeIdent`, string]] =
          let provider = `accessProcIdent`().`zeroArgFieldName`
          if provider.isNil:
            return errorFuture[`typeIdent`](
              "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered"
            )
          provider()

    )
  if not argSig.isNil:
    result.add(
      quote do:
        proc setProvider*(_: typedesc[`typeIdent`], handler: `argProviderName`) =
          `accessProcIdent`().`argFieldName` = handler

    )
    clearBody.add(
      quote do:
        `accessProcIdent`().`argFieldName` = nil
    )
    result.add(
      quote do:
        proc request*(
            _: typedesc[`typeIdent`], input: `argTypeNode`
        ): Future[Result[`typeIdent`, string]] =
          let provider = `accessProcIdent`().`argFieldName`
          if provider.isNil:
            return errorFuture[`typeIdent`](
              "RequestBroker(" & `typeNameLit` &
                "): no provider registered for input signature"
            )
          provider(input)

    )

  result.add(
    quote do:
      proc clearProvider*(_: typedesc[`typeIdent`]) =
        `clearBody`

  )

  when defined(requestBrokerDebug):
    echo result.repr
