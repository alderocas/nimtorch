import os, strutils, macros, osproc, json, sequtils, streams, pegs, tables, strformat

# nim naming issues:
# if a name is a nim keyword, like "var", the name will be prefixed by "a", and so it will be "avar"
# underscores are replaced with "u_", "_" = "u_" or "_u"

const
  ofTensorTo = "proc $1*($4): $2 $7= $8self.tensor.dynamicCppCall(\"$3\"$5)$6"
  ofTypeTo = "proc $1*(ty: TensorType; $4): $2 $7= $8ty.dynamicCppCall(\"$3\"$5)$6"
  ofNamespaceTo = "proc $1*($4): $2 $7= $8dynamicCCall(\"at::$3\"$5)$6"
  
  backwardGrad = "#[ proc $1_bwd*(grad: Tensor; fwd_result: $2$3): $4 {.inline, noinit.} =$5 ]#"
  backwardGrads = "proc $1_bwd*(grads: TensorList; fwd_result: $2$3): $4 {.inline, noinit.} =$5"

static:
  doAssert(getenv("ATEN") != "", "Please add $ATEN variable installation path to the environment")

type
  ArgInfo = object
    originalName: string
    name: string
    nimType: string

  ProcInfo = object
    originalName: string
    originalAlternativeName: string
    name: string
    args: seq[ArgInfo]
    returns: seq[ArgInfo]
    argsStr: string
    nimReturnType: string
    kind: MethodOfKind
    expression: string

  MethodOfKind = enum
    Type, Tensor, Namespace

  InvalidReturnException = object of Exception

proc toNimType(typeName: string): string =
  case typeName
  of "Tensor", "BoolTensor", "IndexTensor", "IntegerTensor": return "Tensor"
  of "TensorOptions": return "TensorOptions"
  of "Storage": return "AStorage"
  of "TensorList": return "TensorList"
  of "int64_t": return "int64"
  of "bool": return "bool"
  of "real", "accreal": return "float"
  of "double": return "float64"
  of "Generator*", "Generator *", "Generator": return "pointer"
  of "IntList": return "IntList"
  of "void": return "void"
  of "void*": return "pointer"
  of "Scalar": return "float"
  of "std::array<bool,2>": return "StdArray[bool, 2]"
  of "std::array<bool,3>": return "StdArray[bool, 3]"
  of "std::array<bool,4>": return "StdArray[bool, 4]"
  of "ScalarType": return "AScalarType"
  of "std::string": return "StdString"
  of "Type": return "TensorType"
  of "SparseTensorRef": return "ASparseTensorRef"
  else: raise newException(InvalidReturnException, "Invalid return type '" & typeName & "'")

proc validate(name: string): string =
  const invalidNames = ["div", "var", "end", "result", "to", "from"]
  result = name
  if result.endsWith("_"):
    result &= "u"
  if result.startsWith("_"):
    result = "u" & result
  if invalidNames.contains(result):
    result = "a" & result
  result = result.replace("__", "_u_u")
  
var generatedProcs = newSeq[ProcInfo]()

# add some known procs we created in torch.nim, don't care about args
generatedProcs.add(ProcInfo(originalName: "maybe_multiply", name: "maybe_multiply", kind: Namespace, args: @[], returns: @[], nimReturnType: ""))
generatedProcs.add(ProcInfo(originalName: "mm_mat1_backward", name: "mm_mat1_backward", kind: Namespace, args: @[], returns: @[], nimReturnType: ""))
generatedProcs.add(ProcInfo(originalName: "mm_mat2_backward", name: "mm_mat2_backward",kind: Namespace, args: @[], returns: @[], nimReturnType: ""))
generatedProcs.add(ProcInfo(originalName: "pow_backward", name: "pow_backward",kind: Namespace, args: @[], returns: @[], nimReturnType: ""))
generatedProcs.add(ProcInfo(originalName: "pow_backward_self", name: "pow_backward_self",kind: Namespace, args: @[], returns: @[], nimReturnType: ""))
generatedProcs.add(ProcInfo(originalName: "pow_backward_exponent", name: "pow_backward_exponent",kind: Namespace, args: @[], returns: @[], nimReturnType: ""))
generatedProcs.add(ProcInfo(originalName: "atan2_backward", name: "atan2_backward",kind: Namespace, args: @[], returns: @[], nimReturnType: ""))
generatedProcs.add(ProcInfo(originalName: "split_backward", name: "split_backward",kind: Namespace, args: @[], returns: @[], nimReturnType: ""))
generatedProcs.add(ProcInfo(originalName: "split_with_sizes_backward", name: "split_with_sizes_backward",kind: Namespace, args: @[], returns: @[], nimReturnType: ""))
generatedProcs.add(ProcInfo(originalName: "sizes", name: "sizes", kind: Tensor, args: @[], returns: @[], nimReturnType: ""))
generatedProcs.add(ProcInfo(originalName: "strides", name: "strides", kind: Tensor, args: @[], returns: @[], nimReturnType: ""))
generatedProcs.add(ProcInfo(originalName: "type", name: "getType", kind: Tensor, args: @[], returns: @[], nimReturnType: ""))

block declarations:
  var output = newFileStream("torch/declarations.nim", fmWrite)

  output.writeLine "# Automatically generated, to update run again the generator from the torch root path"
  output.writeLine "# nim c -r torch/generator.nim\n"

  # convert from yaml to json to load at compile time, using python3 for now
  let
    declYaml = getenv("ATEN") & "/share/ATen/Declarations.yaml"
    # NimYAML is not active anymore and anyway we most likely have all those modules if we built ATen anyway!
    cmd = "python3 -c 'import json, sys, yaml ; " & # needs python3
      "stream = open(\"" & declYaml & "\", \"r\") ; " & # replace open with file for python2.. maybe
      "y=yaml.safe_load(stream) ; " & 
      "print(json.dumps(y))'"
    (declJson, exitCode) = execCmdEx(cmd)

  doAssert(exitCode == 0, "Failed to convert Declarations.yaml to JSON, failed with output: " & declJson)
  
  var rootNode = parseJson(declJson)
  
  for node in rootNode:
    if not node.hasKey("name"):
      continue
      
    let name = node["name"].getStr()

    # Skip deprecated procs
    var deprecated = false
    if node.hasKey("deprecated") and node["deprecated"].getBool():
      deprecated = true
      continue

    # Disable out-procs for now
    # TODO: Do we need these for some optimization?
    if name.contains("_out"):
      continue

    # # TODO: Skip inplace procs until we know how to handle their graph properly/know if we can optimize them otherwise
    # if node.hasKey("inplace") and node["inplace"].getBool():
    #   continue

    var
      originalAlternativeName: string
      validName = name

    # NN function with no _forward/_backward suffix don't have cimpls. They call the _forward function and discard any buffer returns
    # See https://github.com/pytorch/pytorch/blob/dccd0f2de69396de99f45cf6792c684b5a095c49/aten/src/ATen/function_wrapper.py#L822
    if node.hasKey("mode") and node["mode"].getStr() == "NN":
      if validName.contains("_forward"):
        originalAlternativeName = name.replace("_forward", "")
        validName = originalAlternativeName
      elif not validName.contains("_backward"):
        continue # Skip alternative desclaration

    validName = validName.validate()

    assert(node.hasKey("method_of"))
    var methodKind: set[MethodOfKind]
    for ofNode in node["method_of"]:
      case ofNode.getStr()
      of "Tensor": methodKind.incl Tensor
      of "Type": methodKind.incl Type
      of "namespace": methodKind.incl Namespace
      
    proc validateArguments(arguments: openarray[JsonNode]): bool =
      result = arguments.all do (x: JsonNode) -> bool:
        assert(x.hasKey("dynamic_type"))
        let dynType = x["dynamic_type"].getStr()
        return 
          dynType == "Tensor" or
          dynType == "BoolTensor" or
          dynType == "IndexTensor" or
          dynType == "IntegerTensor" or
          dynType == "TensorList" or
          dynType == "int64_t" or 
          dynType == "bool" or
          dynType == "real" or
          dynType == "double" or
          dynType == "Generator*" or dynType == "Generator *" or
          dynType == "IntList" or
          dynType == "accreal" or
          dynType == "Scalar" or
          dynType == "TensorOptions" or
          dynType == "Storage" or
          dynType == "ScalarType" or
          dynType == "std::string" or
          dynType == "std::array<bool,2>" or
          dynType == "std::array<bool,3>" or
          dynType == "std::array<bool,4>" or
          dynType == "Type" or
          dynType == "SparseTensorRef"

      if not result:
        echo "Skipping method with invalid argument/s: ", name, " arguments: ", arguments
          
    template fillArgumentDefaults: untyped =
      if arguments[i].hasKey("default"):
        let defaultNode = arguments[i]["default"]
        case defaultNode.kind
        of JInt, JBool:
          # easy case, no need to transform
          case nimType
          of "IntList": defaultStr = " = @[" & $arguments[i]["default"] & "]"
          else: defaultStr = " = " & $arguments[i]["default"]
        of JString:
          let stringValue = arguments[i]["default"].getStr()
          case stringValue
          of "nullptr": defaultStr = " = nil"
        else:
          # skipping defaults, might cause integration issues tho
          discard
          
    proc procFormatString(kind: MethodOfKind): string =
      case kind:
        of Type: return ofTypeTo
        of Tensor: return ofTensorTo
        of Namespace: return ofNamespaceTo

    proc generateProc(kind: MethodOfKind; arguments: seq[JsonNode]) =

      # Find the self-parameter
      var
        hasSelf = false
        selfPosition = 0
      
      for i, arg in arguments:
        assert(arg.hasKey("name") and arg.hasKey("dynamic_type"))
        if arg["name"].getStr() == "self" and arg["dynamic_type"].getStr() == "Tensor":
          hasSelf = true
          selfPosition = i
          break

      # Tensor procs need a self parameter
      if kind == Tensor and not hasSelf:
        echo "Skipping method of Tensor without self Tensor: ", name, " ", arguments
        return
      
      if not validateArguments(arguments):
        return

      var procInfo = ProcInfo(originalName: name, originalAlternativeName: originalAlternativeName, name: validName, args: @[], returns: @[], kind: kind)
      
      var argsStr1 = ""
      var argsStr2 = ""
      for i, arg in arguments:
        var
          nimType = toNimType(arguments[i]["dynamic_type"].getStr())
          argName = arguments[i]["name"].getStr()
          originalName = argName
          defaultStr = ""

        argName = argName.validate()
        
        fillArgumentDefaults()
        
        var prefix = if i == 0: "" else: ", "
        argsStr1 &= prefix & "$1: $2$3" % [argName, nimType, defaultStr]

        # For tensor procs we don't add `self` parameter to the native call
        if kind != Tensor or argName != "self":
          if nimType == "Tensor":
            argsStr2 &= ", $1.tensor" % [argName]
          else:
            argsStr2 &= ", $1" % [argName]

        var argInfo = ArgInfo(originalName: originalName, name: argName, nimType: nimType)
        if kind == Tensor and argName == "self":
          procInfo.args.insert(argInfo, 0)
        else:  
          procInfo.args.add(argInfo)

      var pragmasStr = ""
      if deprecated:
        pragmasStr = "{.deprecated, inline, noinit.} "
      else:
        pragmasStr = "{.inline, noinit.} "
      
      var convertStr, preCode: string

      try:
        if not node.hasKey("returns") or node["returns"].len == 0:
          raise newException(InvalidReturnException, "Method has no returns") # should not happen by design
          
        elif node["returns"].len == 1:
          procInfo.nimReturnType = toNimType(node["returns"][0]["dynamic_type"].getStr())
          convertStr = ".to(" & procInfo.nimReturnType & ")"

          if procInfo.nimReturnType == "Tensor":
            convertStr = ".to(ATensor).newTensor()"
            preCode = "" #&= "\n  result = newTensor "

          procInfo.returns.add(ArgInfo(originalName: "", name: "", nimType: procInfo.nimReturnType))
          
        elif node["returns"].len > 1: # tuple, a bit ugly tho
          var
            tupleStr1 = ""
            tupleStr2 = ""
            resultStr = ""
          
          let returnsHigh = node["returns"].len - 1
          for i in 0 .. returnsHigh:
            var
              res = node["returns"][i]["dynamic_type"].getStr()
              returnName = node["returns"][i]["name"].getStr()
            
            # Need to
            # turn any grad_input into self because of:
            # https://github.com/pytorch/pytorch/blob/e26d584445a80a548485097bfbef1f67bba5f771/aten/src/ATen/nn_parse.py#L356
            # addume grad_ is to be cut cos of
            # https://github.com/pytorch/pytorch/blob/e26d584445a80a548485097bfbef1f67bba5f771/aten/src/ATen/nn_parse.py#L356
            if returnName == "grad_input":
              returnName = "self"
            elif returnName.startsWith("grad_"):
              returnName = returnName["grad_".len..^1]
            
            var
              originalReturnName = returnName
              outputType = res.toNimType
              toType = if outputType == "Tensor": "ATensor" else: outputType

            returnName = returnName.validate()

            procInfo.returns.add(ArgInfo(originalName: originalReturnName, name: returnName, nimType: outputType))

            tupleStr1 &= returnName & ": " & outputType
            tupleStr2 &= toType

            if i != returnsHigh:
              tupleStr1 &= ", "
              tupleStr2 &= ", "

          convertStr = ".to(StdTuple" & $(returnsHigh + 1) & "[" & tupleStr2 & "]).toNimTuple().newTensors()"
          procInfo.nimReturnType = "tuple[" & tupleStr1 & "]"
         
        else:
          raise newException(InvalidReturnException, "Not implemented returns length")

        case kind:
          of Tensor:
            procInfo.argsStr = "self: Tensor" & argsStr1
            procInfo.expression = fmt"self.dynamicCppCall(""{procInfo.originalName}""{argsStr2}){convertStr}"
          of Type:
            procInfo.argsStr = "ty: TensorType; " & argsStr1
            procInfo.expression = fmt"ty.dynamicCppCall(""{procInfo.originalName}""{argsStr2}){convertStr}"
          of Namespace:
            procInfo.argsStr = argsStr1
            procInfo.expression = fmt"dynamicCCall(""at::{procInfo.originalName}""{argsStr2}){convertStr}"

        output.writeLine(procInfo.kind.procFormatString % [procInfo.name, procInfo.nimReturnType, procInfo.originalName, argsStr1, argsStr2, convertStr, pragmasStr, preCode])
        generatedProcs.add(procInfo)

      except InvalidReturnException:
        echo "Skipping method with invalid results: ", name, " type: ", node["returns"][0]["dynamic_type"].getStr()
        echo getCurrentExceptionMsg()
    
    assert(node.hasKey("arguments"))
    let arguments = toSeq(node["arguments"])

    # Always generate the type proc
    if methodKind.contains(Type):
      generateProc(Type, arguments)

    # Generate only the tensor or the namespace proc.
    # In nim the call syntax is unified
    if methodKind.contains(Tensor):
      generateProc(Tensor, arguments) 
    elif methodKind.contains(Namespace):
      generateProc(Namespace, arguments)
      
  output.flush()
  output.close()

block derivatives: # we still need to implement some of the procs in pytorch's 'tools/autograd/templates/Functions.cpp'
  var output = newFileStream("torch/derivatives.nim", fmWrite)

  output.writeLine "# Automatically generated, to update run again the generator from the torch root path"
  output.writeLine "# nim c -r torch/generator.nim\n"
  output.writeLine "import math"
  output.writeLine "import ../torch"
  output.writeLine "import autograd_helpers\n"
  output.writeLine "const M_PI = math.PI\n"

  # convert from yaml to json to load at compile time, using python3 for now
  let
    derYaml = getenv("ATEN") & "/share/derivatives.yaml"
    # NimYAML is not active anymore and anyway we most likely have all those modules if we built ATen anyway!
    cmd = "python3 -c 'import json, sys, yaml ; " & # needs python3
      "stream = open(\"" & derYaml & "\", \"r\") ; " & # replace open with file for python2.. maybe
      "y=yaml.safe_load(stream) ; " & 
      "print(json.dumps(y))'"
    (derJson, exitCode) = execCmdEx(cmd)
    
  let namePeg = peg"""
    full <- dot? {Name} func
    Name <- (validChars)+
    validChars <- \ident
    dot <- '.'
    func <- '(' @ ')'
    """
  let nameArgsPeg = peg"""
    full <- {Name} func
    Name <- (validChars)*
    validChars <- \ident
    func <- '(' {@} ')'
    """

  let argsPegs = peg"""
    full <- argFull+ argDelim argFull+ / argFull+
    separator <- ','
    ws <- \s
    argDelim <- ws? '*' ws? separator?
    argFull <- ws? arg ws? separator?
    arg <- {validChars} ws+ {validChars}
    validChars <- \ident
    """

  # generate replacements for calls from ATen/pytorch to nim 
  var replacements = newSeq[tuple[pattern: Peg, repl: string]]()
  for p in generatedProcs:
    case p.kind
    of Tensor: replacements.add((peg("'.' '" & p.originalName & "' '('"), "." & p.name & "("))
    of Namespace: replacements.add((peg("!'.' '" & p.originalName & "' '('"), p.name & "("))
    else: discard
  
  let callPeg = peg"','? \s? \ident+"

  doAssert(exitCode == 0, "Failed to convert derivatives.yaml to JSON, failed with output: " & derJson)

  var rootNode = parseJson(derJson)

  for node in rootNode:
    if not node.hasKey("name"):
      continue
    
    var
      name = ""
      info: ProcInfo
    
    let nameFull = node["name"].getStr()
    if nameFull =~ namePeg:
      name = matches[0]

    assert(name != "", nameFull)

    var candidates = generatedProcs.filter do (x: ProcInfo) -> bool: x.originalName == name
    if candidates.len == 0:
      echo "Ignoring not found declaration: ", name
      continue
    elif candidates.len == 1:
      info = candidates[0]
    else:
      var nameMatches: array[0..10, string]
      if nameFull.match(nameArgsPeg, nameMatches):
        let argsStr = nameMatches[1]
        var args = argsStr.split(peg"',' \s?")

        # remove *, its the delimiter for optional args...
        let wildcardIndex = args.find("*")
        if wildcardIndex != -1:
          args.del(wildcardIndex)
        
        block findCandidate:
          for candidate in candidates:
            # echo nameFull, " | ", candidate
            block checkArgs:
              var hasWildcard = false
              if candidate.args.len == args.len:
                for i in 0..candidate.args.high:
                  let
                    argB = args[i].split(peg"\s+")[0].toNimType
                    argA = candidate.args[i].nimType
                  
                  if argA != argB:
                    break checkArgs
                
                # echo "Accepted ", nameFull
                info = candidate
                break findCandidate

    # at this point we know of which Declarations.yaml proc we are talking about

    # build backward proc itself
    var
      resTuple = "tuple["
      body = "\n"
      argsStr = ""
      argsText: string
      resultText: string
      hasError = false

      head: string
      bodyText: string
  
    argsText = info.argsStr
    # for i, arg in info.args:
    #   argsStr &= ", " & arg.name & ": " & arg.nimType
    #   if i > 0: argsText &= ", "
    #   argsText &= arg.name & ": " & arg.nimType

    resultText = info.nimReturnType
    # case info.returns.len:
    #   of 0: discard
    #   of 1: resultText = info.returns[0].nimType
    #   else:
    #     resultText = "tuple["
    #     for i, arg in info.returns:
    #       if i > 0: argsText &= ", "
    #       resultText &= arg.name & ": " & arg.nimType
    #     resultText &= "]"

    bodyText &= fmt"  result: {info.expression}" & "\n"

    block generateProc:
      var nodeIndex = 0
      for k, v in node:
        let vStr = v.getStr().replace("at::", "") # also remove any at::prefix
        if k == "name" or vStr.startsWith("not_implemented"):
          continue

        var names = newSeq[tuple[name: string; index: int]]()

        # k can be multi like: "self, weight, bias", this is likely a tuple
        if k.contains(peg"',' \s?"):
          var index = 0
          for n in k.split(peg"',' \s?"):
            names.add((n, index))
            inc index
        else:
          names.add((k, -1))

        # must keep track of final calls, to recycle them (specially if final result was a tuple)
        var
          calls = initTable[string, string]()
          addedInputMask = false
          generatedTrainingAssert = false
        
        for name in names:
          var
            argName = info.args.filter do (x: ArgInfo) -> bool: x.originalName == name.name
            prefix = if nodeIndex == 0: "" else: ", "
          
          if argName.len == 0:
            echo "A needed arg was not found: ", name
            hasError = true
            break generateProc
          
          resTuple &= prefix & argName[0].name & ": " & argName[0].nimType

          var
            nimLikeStr = vStr
          
          # make sure we got all procs we need nim side
          var neededProcs = nimLikeStr.findAll(namePeg)
          for neededProc in neededProcs:
            if neededProc =~ namePeg: # go thru again to filter out not matched stuff
              let hasProc = generatedProcs.any do (x: ProcInfo) -> bool:
                # we assume Type ONLY procs are not used/needed in derivatives.. this might be wrong
                (x.kind == Tensor or x.kind == Namespace) and (x.originalName == matches[0] or x.originalAlternativeName == matches[0])
              
              if not hasProc:
                echo "A needed proc was not found: ", neededProc
                hasError = true
                break generateProc
            
          # fix all pytorch to nim namings
          nimLikeStr = nimLikeStr.parallelReplace(replacements)

          # fix fwd_result namings
          nimLikeStr = nimLikeStr.replacef(peg"{[^_]} 'result' {\d}", "$1fwd_result[$2]")
          nimLikeStr = nimLikeStr.replacef(peg"^'result' {\d}", "fwd_result[$1]")
          nimLikeStr = nimLikeStr.replacef(peg"{[^_]} 'result' {!\ident}", "$1fwd_result$2")
          nimLikeStr = nimLikeStr.replacef(peg"^'result' {!\ident}", "fwd_result$1")

          nimLikeStr = nimLikeStr.replacef(peg"{[^_]} 'output' {!\ident}", "$1fwd_result$2")
          nimLikeStr = nimLikeStr.replacef(peg"^'output' {!\ident}", "fwd_result$1")

          # replace any fwd result tuple names with proper prefix if necessary
          if info.returns.len > 1:
            for retArg in info.returns:
              nimLikeStr = nimLikeStr.replacef(peg("{[^_]} '" & retArg.originalName & "' {!\\ident}"), "$1fwd_result." & retArg.name & "$2")

          # some gradient have grad_input_mask, find and add it
          if not addedInputMask and nimLikeStr.contains(peg"{[^_]} 'grad_input_mask' {!\ident}"):
            argsStr &= ", grad_input_mask: StdArray"
            addedInputMask = true

          # some gradients are multiple
          if nimLikeStr.contains(peg"'grads[' \d ']'") or nimLikeStr.contains(peg"'grads'"):
            # TODO
            echo "Ignoring multi grad proc: ", info.name
            hasError = true
            break generateProc

          # replace int lists {} to our @[]
          nimLikeStr = nimLikeStr.replacef(peg"'{' {@} '}'", "@[$1]")

          # sometimes we have "training ?" pattern
          if nimLikeStr.contains(peg"^ 'training ?'"):
            nimLikeStr = nimLikeStr.replace(peg"^ 'training ?'", "")
            if not generatedTrainingAssert:
              body &= "  if not training:\n    raiseAssert(\"CuDNN cannot be used to compute backward in evaluation mode\")\n"
              generatedTrainingAssert = true

          var valueName = argName[0].name & "_result"
          
          # make sure we actually call only once
          if calls.contains(nimLikeStr):
            valueName = calls[nimLikeStr]
          else:
            body &= "  let " & valueName & " = " & nimLikeStr & "\n"
          
          calls.add(nimLikeStr, valueName)

          if name.index == -1:
            body &= "  result." & argName[0].name & " = " & valueName & "\n"
          else:
            body &= "  result." & argName[0].name & " = " & valueName & "[" & $name.index & "]\n"

          bodyText &= fmt"  {argName[0].name}: {nimLikeStr}" & "\n"

          inc nodeIndex
      
    resTuple &= "]"

    if resTuple == "tuple[]" or body == "\n" or hasError:
      echo "Ignoring derivative (not implemented or error): ", name
      continue

    let procStr = backwardGrad % [info.name, info.nimReturnType, argsStr, resTuple, body]
    output.writeLine procStr

    output.writeLine(fmt"autograd {info.name}({argsText}) -> {resultText}:" & "\n" & fmt"{bodyText}")

  output.flush()
  output.close()