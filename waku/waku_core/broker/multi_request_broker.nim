## MultiRequestBroker
## --------------------
## MultiRequestBroker represents a proactive decoupling pattern, that
## allows defining request-response style interactions between modules without
## need for direct dependencies in between.
## Worth considering using it for use cases where you need to collect data from multiple providers.
##
## Provides a declarative way to define an immutable value type together with a
## thread-local broker that can register multiple asynchronous providers, dispatch
## typed requests, and clear handlers. Each macro block defines one value type
## and the companion `<TypeName>Broker` along with the `setProvider`,
## `removeProvider`, `request`, and `clearProviders` helpers. Unlike
## `RequestBroker`, every call to `request` fan-outs to every registered
## provider and returns with collected responses. Return succeeds if all providers
## succeed, otherwise fails with an error.
##
## Example:
## ```nim
## MultiRequestBroker:
##   type Greeting = object
##     text*: string
##
##   ## Define the request and provider signature, that is enforced at compile time.
##   proc signature*(): Future[Result[Greeting, string]] {.async: (raises: []).}
##
##   ## Also possible to define signature with arbitrary input arguments.
##   proc signature*(lang: string): Future[Result[Greeting, string]] {.async: (raises: []).}
##
## ...
## let handle = Greeting.setProvider(
##   proc(): Future[Result[Greeting, string]] {.async: (raises: []).} =
##     ok(Greeting(text: "hello"))
## )
##
## let anotherHandle = Greeting.setProvider(
##  proc(): Future[Result[Greeting, string]] {.async: (raises: []).} =
##   ok(Greeting(text: "szia"))
## )
##
## let responses = (await Greeting.request()).valueOr(@[Greeting(text: "default")])
##
## echo responses.len
## Greeting.clearProviders()
## ```
## If no `signature` proc is declared, a zero-argument form is generated
## automatically, so the caller only needs to provide the type definition.

import std/[macros, strutils, tables, sugar]
import chronos
import results
import ./helper/broker_utils

export results

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
  newTree(nnkIdentDefs, ident("input"), def[def.len - 2], newEmptyNode())

proc makeProcType(returnType: NimNode, params: seq[NimNode]): NimNode =
  var formal = newTree(nnkFormalParams)
  formal.add(returnType)
  for param in params:
    formal.add(param)

  let pragmas = quote:
    {.async.}

  newTree(nnkProcTy, formal, pragmas)

macro MultiRequestBroker*(body: untyped): untyped =
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
          error("Only one object type may be declared inside MultiRequestBroker", def)
        typeIdent = baseTypeIdent(def[0])
        let recList = rhs[2]
        if recList.kind != nnkRecList:
          error("MultiRequestBroker object must declare a standard field list", rhs)
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
              "MultiRequestBroker object definition only supports simple field declarations",
              field,
            )
        objectDef = newTree(
          nnkObjectTy, copyNimTree(rhs[0]), copyNimTree(rhs[1]), exportedRecList
        )
  if typeIdent.isNil:
    error("MultiRequestBroker body must declare exactly one object type", body)

  when defined(requestBrokerDebug):
    echo "MultiRequestBroker generating type: ", $typeIdent

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let sanitized = sanitizeIdentName(typeIdent)
  let tableSym = bindSym"Table"
  let initTableSym = bindSym"initTable"
  let uint64Ident = ident("uint64")
  let providerKindIdent = ident(sanitized & "ProviderKind")
  let providerHandleIdent = ident(sanitized & "ProviderHandle")
  let exportedProviderHandleIdent = postfix(copyNimTree(providerHandleIdent), "*")
  let zeroKindIdent = ident("pk" & sanitized & "NoArgs")
  let argKindIdent = ident("pk" & sanitized & "WithArgs")
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
      error("Unsupported statement inside MultiRequestBroker definition", stmt)

  if zeroArgSig.isNil and argSig.isNil:
    zeroArgSig = newEmptyNode()
    zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
    zeroArgFieldName = ident("providerNoArgs")

  var typeSection = newTree(nnkTypeSection)
  typeSection.add(newTree(nnkTypeDef, exportedTypeIdent, newEmptyNode(), objectDef))

  var kindEnum = newTree(nnkEnumTy, newEmptyNode())
  if not zeroArgSig.isNil:
    kindEnum.add(zeroKindIdent)
  if not argSig.isNil:
    kindEnum.add(argKindIdent)
  typeSection.add(newTree(nnkTypeDef, providerKindIdent, newEmptyNode(), kindEnum))

  var handleRecList = newTree(nnkRecList)
  handleRecList.add(newTree(nnkIdentDefs, ident("id"), uint64Ident, newEmptyNode()))
  handleRecList.add(
    newTree(nnkIdentDefs, ident("kind"), providerKindIdent, newEmptyNode())
  )
  typeSection.add(
    newTree(
      nnkTypeDef,
      exportedProviderHandleIdent,
      newEmptyNode(),
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), handleRecList),
    )
  )

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
      newTree(
        nnkIdentDefs,
        zeroArgFieldName,
        newTree(nnkBracketExpr, tableSym, uint64Ident, zeroArgProviderName),
        newEmptyNode(),
      )
    )
  if not argSig.isNil:
    brokerRecList.add(
      newTree(
        nnkIdentDefs,
        argFieldName,
        newTree(nnkBracketExpr, tableSym, uint64Ident, argProviderName),
        newEmptyNode(),
      )
    )
  brokerRecList.add(newTree(nnkIdentDefs, ident("nextId"), uint64Ident, newEmptyNode()))
  let brokerTypeIdent = ident(sanitizeIdentName(typeIdent) & "Broker")
  let brokerTypeDef = newTree(
    nnkTypeDef,
    postfix(brokerTypeIdent, "*"),
    newEmptyNode(),
    newTree(
      nnkRefTy, newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), brokerRecList)
    ),
  )
  typeSection.add(brokerTypeDef)
  result = newStmtList()
  result.add(typeSection)

  let globalVarIdent = ident("g" & sanitizeIdentName(typeIdent) & "Broker")
  let accessProcIdent = ident("access" & sanitizeIdentName(typeIdent) & "Broker")
  var initStatements = newStmtList()
  if not zeroArgSig.isNil:
    initStatements.add(
      quote do:
        `globalVarIdent`.`zeroArgFieldName` =
          `initTableSym`[`uint64Ident`, `zeroArgProviderName`]()
    )
  if not argSig.isNil:
    initStatements.add(
      quote do:
        `globalVarIdent`.`argFieldName` =
          `initTableSym`[`uint64Ident`, `argProviderName`]()
    )
  result.add(
    quote do:
      var `globalVarIdent` {.threadvar.}: `brokerTypeIdent`

      proc `accessProcIdent`(): `brokerTypeIdent` =
        if `globalVarIdent`.isNil:
          new(`globalVarIdent`)
          `globalVarIdent`.nextId = 1'u64
          `initStatements`
        `globalVarIdent`

      proc broker*(_: typedesc[`typeIdent`]): `brokerTypeIdent` =
        `accessProcIdent`()

  )

  var clearBody = newStmtList()
  if not zeroArgSig.isNil:
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `zeroArgProviderName`
        ): Result[`providerHandleIdent`, string] =
          if handler.isNil():
            return err("Provider handler must be provided")
          let broker = `accessProcIdent`()
          if broker.nextId == 0'u64:
            broker.nextId = 1'u64
          for existingId, existing in broker.`zeroArgFieldName`.pairs:
            if existing == handler:
              return ok(`providerHandleIdent`(id: existingId, kind: `zeroKindIdent`))
          let newId = broker.nextId
          inc broker.nextId
          broker.`zeroArgFieldName`[newId] = handler
          ok(`providerHandleIdent`(id: newId, kind: `zeroKindIdent`))

    )
    clearBody.add(
      quote do:
        let broker = `accessProcIdent`()
        if not broker.isNil and broker.`zeroArgFieldName`.len > 0:
          broker.`zeroArgFieldName`.clear()
    )
    result.add(
      quote do:
        proc request*(
            _: typedesc[`typeIdent`]
        ): Future[Result[seq[`typeIdent`], string]] {.async: (raises: []), gcsafe.} =
          var aggregated: seq[`typeIdent`] = @[]
          let providers = `accessProcIdent`().`zeroArgFieldName`
          if providers.len == 0:
            return ok(aggregated)
          # var providersFut: seq[Future[Result[`typeIdent`, string]]] = collect:
          var providersFut = collect(newSeq):
            for provider in providers.values:
              if provider.isNil:
                continue
              provider()

          let catchable = catch:
            await allFinished(providersFut)

          catchable.isOkOr:
            return err("Some provider(s) failed:" & error.msg)

          for fut in catchable.get():
            if fut.failed():
              return err("Some provider(s) failed:" & fut.error.msg)
            elif fut.finished():
              if fut.value().isOk:
                aggregated.add(fut.value().get())
              else:
                return err("Some provider(s) failed:" & fut.value().error)

          ok(aggregated)

    )
  if not argSig.isNil:
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `argProviderName`
        ): Result[`providerHandleIdent`, string] =
          if handler.isNil():
            return err("Provider handler must be provided")
          let broker = `accessProcIdent`()
          if broker.nextId == 0'u64:
            broker.nextId = 1'u64
          for existingId, existing in broker.`argFieldName`.pairs:
            if existing == handler:
              return ok(`providerHandleIdent`(id: existingId, kind: `argKindIdent`))
          let newId = broker.nextId
          inc broker.nextId
          broker.`argFieldName`[newId] = handler
          ok(`providerHandleIdent`(id: newId, kind: `argKindIdent`))

    )
    clearBody.add(
      quote do:
        let broker = `accessProcIdent`()
        if not broker.isNil and broker.`argFieldName`.len > 0:
          broker.`argFieldName`.clear()
    )
    result.add(
      quote do:
        proc request*(
            _: typedesc[`typeIdent`], input: `argTypeNode`
        ): Future[Result[seq[`typeIdent`], string]] {.async: (raises: []), gcsafe.} =
          var aggregated: seq[`typeIdent`] = @[]
          let providers = `accessProcIdent`().`argFieldName`
          if providers.len == 0:
            return ok(aggregated)
          var providersFut = collect(newSeq):
            for provider in providers.values:
              if provider.isNil:
                continue
              provider(input)

          let catchable = catch:
            await allFinished(providersFut)

          catchable.isOkOr:
            return err("Some provider(s) failed:" & error.msg)

          for fut in catchable.get():
            if fut.failed():
              return err("Some provider(s) failed:" & fut.error.msg)
            elif fut.finished():
              if fut.value().isOk:
                aggregated.add(fut.value().get())
              else:
                return err("Some provider(s) failed:" & fut.value().error)

          ok(aggregated)

    )

  result.add(
    quote do:
      proc clearProviders*(_: typedesc[`typeIdent`]) =
        `clearBody`
        let broker = `accessProcIdent`()
        if not broker.isNil:
          broker.nextId = 1'u64

  )

  let removeHandleSym = genSym(nskParam, "handle")
  let removeBrokerSym = genSym(nskLet, "broker")
  var removeBody = newStmtList()
  removeBody.add(
    quote do:
      if `removeHandleSym`.id == 0'u64:
        return
      let `removeBrokerSym` = `accessProcIdent`()
      if `removeBrokerSym`.isNil:
        return
  )
  if not zeroArgSig.isNil:
    removeBody.add(
      quote do:
        if `removeHandleSym`.kind == `zeroKindIdent`:
          `removeBrokerSym`.`zeroArgFieldName`.del(`removeHandleSym`.id)
          return
    )
  if not argSig.isNil:
    removeBody.add(
      quote do:
        if `removeHandleSym`.kind == `argKindIdent`:
          `removeBrokerSym`.`argFieldName`.del(`removeHandleSym`.id)
          return
    )
  removeBody.add(
    quote do:
      discard
  )
  result.add(
    quote do:
      proc removeProvider*(
          _: typedesc[`typeIdent`], `removeHandleSym`: `providerHandleIdent`
      ) =
        `removeBody`

  )

  when defined(requestBrokerDebug):
    echo result.repr
