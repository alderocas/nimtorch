import fragments/ffi/cpp as cpp
import sequtils

proc chunk*(self: Tensor; chunks, dim: int64): seq[Tensor] =
  assert(self.dim() > 0, "chunk expects at least a 1-dimensional tensor");
  assert(chunks > 0, "chunk expects `chunks` to be greater than 0, got: " & $chunks)
  
  let split_size = (self.size(dim) + chunks - 1) div chunks

  # We need to call split_with_sizes in the case where split_size and dimension size are 0, because
  # a call to split would discard the number of chunks (because we can have an arbitrary number of
  # 0-sized chunks adding up to 0).  So, call split_with_sizes with the correct number of chunks,
  # eventually we will do this for all cases.
  if split_size == 0 and self.size(dim) == 0:
    var split_sizes = newSeqWith(chunks.int, split_size)
    split_sizes[chunks.int - 1] = split_size - (split_size * chunks - self.size(dim))
    return self.split_with_sizes(split_sizes, dim)
  else:
    return self.split(split_size, dim)

proc contiguous*(self: Tensor): Tensor =
  #unpack(self, "self", 0)
  if self.is_contiguous():
    return self
  return self.clone()

proc infer_size(a, b: IntList): IntList =
  let
    dimsA = a.len
    dimsB = b.len
    ndim = max(dimsA, dimsB)

  result.setLen(ndim)

  for i in countdown(ndim - 1, 0):
    let
      offset = ndim - 1 - i
      dimA = dimsA - 1 - offset
      dimB = dimsB - 1 - offset
      sizeA = if dimA >= 0: a[dimA] else: 1
      sizeB = if dimB >= 0: b[dimB] else: 1

    assert(sizeA == sizeB or sizeA == 1 or sizeB == 1,
      fmt"The size of tensor a ({sizeA}) must match the size of tensor b ({sizeB}) at non-singleton dimension {i}")

    # 1s map to the other size (even 0).
    result[i] = if sizeA == 1: sizeB else: sizeA

proc toType(self: Tensor; t: TensorType; non_blocking: bool = false): Tensor =
  if self.getType() == t:
    return self
  return t.copy(self, non_blocking)

proc toType(self: Tensor; t: AScalarType; non_blocking: bool = false): Tensor =
  self.toType(self.getType().toScalarType(t).to(TensorType))

proc integer_upcast(self: Tensor; dtype: Option[AScalarType] = AScalarType.none): Tensor =
  let 
    scalarType = self.getType().scalarType().to(AScalarType)
    upcast_scalarType = if dtype.isSome: dtype.get else: (if scalarType.toCpp().isIntegralType().to(bool): ATkLong else: scalarType)
  return self.toType(upcast_scalarType)

proc sum(self: Tensor; dim: IntList; keepdim: bool; dtype: Option[AScalarType] = AScalarType.none): Tensor =
  sum_internal(integer_upcast(self, dtype), dim, keepdim)

# Sums `tensor` repeatedly to produce a tensor of shape `shape`.
# Precondition: is_expandable_to(shape, tensor.sizes()) must be true
proc sum_to(tensor: Tensor; shape: IntList): Tensor =
  if shape.len == 0:
    return tensor.sum()

  result = tensor
  while result.dim() > shape.len:
    result = result.sum([0], false)

  for i in 0 ..< result.dim():
    if shape[i] == 1 and result.sizes[i] > 1:
      result = result.sum([i], true)

proc mm*(self, mat2: Tensor): Tensor =
  if self.is_sparse:
    return mat2.getType().addmm(zeros[int]([], mat2.getType()), self, mat2, 0, 1)
  return mm_internal(self, mat2);

proc matmul*(tensor1, tensor2: Tensor): Tensor =
  let
    dim_tensor1 = tensor1.dim()
    dim_tensor2 = tensor2.dim()

  if dim_tensor1 == 1 and dim_tensor2 == 1:
    return tensor1.dot(tensor2)
  elif dim_tensor1 == 2 and dim_tensor2 == 1:
    return tensor1.mv(tensor2)
  elif dim_tensor1 == 1 and dim_tensor2 == 2:
    return tensor1.unsqueeze(0).mm(tensor2).squeeze_inplace(0)
  elif dim_tensor1 == 2 and dim_tensor2 == 2:
    return tensor1.mm(tensor2)
  elif dim_tensor1 >= 3 and (dim_tensor2 == 1 or dim_tensor2 == 2):
    # optimization: use mm instead of bmm by folding tensor1's batch into
    # its leading matrix dimension.
    let
      t2 = if dim_tensor2 == 1: tensor2.unsqueeze(-1) else: tensor2
      size1 = tensor1.sizes()
      size2 = t2.sizes()
    var output_size = size1
    if dim_tensor2 > 1:
      output_size.add(size2[dim_tensor2 - 1])

    # fold the batch into the first dimension
    let t1 = tensor1.contiguous().view([-1, size1[size1.len - 1]])
    return unsafe_view_internal(t1.mm(t2), output_size)

  elif (dim_tensor1 >= 1 and dim_tensor2 >= 1) and (dim_tensor1 >= 3 or dim_tensor2 >= 3):
    # We are multiplying b1 x n x m1 by x2 x m2 x p (where b1 can be a list);
    # we track m1 vs m2 separately even though they must match for nicer error messages
    let
      n = if dim_tensor1 > 1: tensor1.size(-2) else: 1
      m1 = tensor1.size(-1)
      batch_tensor1 = tensor1.sizes[0 ..< max(dim_tensor1 - 2, 0)]
      m2 = if dim_tensor2 > 1: tensor2.size(-2) else: 1
      p = tensor2.size(-1)
      batch_tensor2 = tensor2.sizes[0 ..< max(dim_tensor2 - 2, 0)]

    # expand the batch portion (i.e. cut off matrix dimensions and expand rest)
    let
      expand_batch_portion = infer_size(batch_tensor1, batch_tensor2)
      tensor1_expand_size = expand_batch_portion & n.int & m1.int
      tensor2_expand_size = expand_batch_portion & m2.int & p.int

      expand_batch_product = expand_batch_portion.foldl(a * b)
      tensor1_bmm_view = @[expand_batch_product, n.int, m1.int]
      tensor2_bmm_view = @[expand_batch_product, m2.int, p.int]

    # flatten expanded batches
    let
      tensor1_expanded = tensor1.expand(tensor1_expand_size).contiguous().view(tensor1_bmm_view)
      tensor2_expanded = tensor2.expand(tensor2_expand_size).contiguous().view(tensor2_bmm_view)

    # reshape batches back into result
    var output_shape = expand_batch_portion;
    if dim_tensor1 > 1: output_shape.add(n.int)
    if dim_tensor2 > 1: output_shape.add(p.int)

    return unsafe_view_internal(tensor1_expanded.bmm(tensor2_expanded), output_shape)

  raise newException(ValueError, fmt"both arguments to matmul need to be at least 1D, but they are {dim_tensor1}D and {dim_tensor2}D")

# TODO: Workaround for int instead of IntList
proc sum(self: Tensor; dim: int): Tensor =
  self.sum(@[dim])

proc maybe_multiply*(a: Tensor; b: SomeNumber): Tensor {.inline, noinit.} =
  if b.float == 1.0:
    return a
  else:
    return a * b

proc mm_mat1_backward*(grad, mat2: Tensor; sizes, strides: IntList; alpha: float): Tensor {.inline, noinit.} =
  if strides[0] == 1 and strides[1] == sizes[0]:
    return torch.maybe_multiply(mat2.mm(grad.t()).t(), alpha)
  else:
    return torch.maybe_multiply(grad.mm(mat2.t()), alpha)

proc mm_mat2_backward*(grad, mat1: Tensor; sizes, strides: IntList; alpha: float): Tensor {.inline, noinit.} =
  if strides[0] == 1 and strides[1] == sizes[0]:
    return torch.maybe_multiply(grad.t().mm(mat1).t(), alpha)
  else:
    return torch.maybe_multiply(mat1.t().mm(grad), alpha)

proc pow_backward*(grad, self: Tensor; exponent: float): Tensor {.inline, noinit.} =
  if exponent == 0.0:
    return torch.zeros_like(self)
  else:
    return grad * exponent * self.pow(exponent - 1)

proc pow_backward_self*(grad, self, exponent: Tensor): Tensor {.inline, noinit.} =
  var l: IntList
  return torch.where(exponent == 0.0, torch.zeros(l, grad.getType()), grad * exponent * torch.pow(self, exponent - 1))

proc pow_backward_exponent*(grad, self, exponent: Tensor): Tensor {.inline, noinit.} =
  return grad * torch.pow(self, exponent) * self.log()

proc atan2_backward*(grad, self, other: Tensor; outputMask: StdArray[bool, 2]): (Tensor, Tensor) {.inline, noinit.} =
  let recip = (self * self + other * other).reciprocal()
  if output_mask[0]:
    result[0] = grad * other * recip
  if output_mask[1]:
    result[1] = grad * -self * recip

proc maybe_wrap_dim(dim, size: int64): int {.inline.} =
  return dynamicCCall("at::maybe_wrap_dim", dim, size).to(int)

proc split_with_sizes_backward*(grads: openarray[Tensor]; split_sizes: openarray[SomeInteger]; dim: int64; sizes: IntList; tensorType: TensorType): Tensor {.noinit.} =
  let ndim = maybe_wrap_dim(dim, sizes.len())
  var allDefinedList: TensorList
  for i in 0..grads.high:
    let grad = grads[i]
    if grad.is_defined():
      allDefinedList.add(grad)
    else:
      let length = split_sizes[i]
      var grad_size = sizes 
      grad_size[dim.int] = length.int
      allDefinedList.add(torch.zeros(grad_size, tensorType))
  result = torch.cat(allDefinedList, ndim)

proc split_backward*(grads: openarray[Tensor]; split_size, dim: int64; sizes: IntList; tensorType: TensorType): Tensor {.noinit.} =
  let
    ndim = maybe_wrap_dim(dim, sizes.len())
    dim_size = sizes[ndim]
    num_splits = grads.len
  var split_sizes = newSeqWith(num_splits, split_size.int)
  split_sizes[num_splits - 1] = split_size.int - (split_size.int * num_splits - dim_size)
  result = split_with_sizes_backward(grads, split_sizes, ndim, sizes, tensorType)

proc unsqueeze_to(self: Tensor; sizes: openarray[SomeInteger]): Tensor =
  result = self
  for dim, size in sizes:
    if size == 1:
      result = result.unsqueeze(dim.int64)

proc unsqueeze_to(self: Tensor; dim: int64; sizes: openarray[SomeInteger]): Tensor =
  let dim = maybe_wrap_dim(dim.int, sizes.len)
  # in NumPy it's not an error to unsqueeze a scalar, but we still need to avoided
  # unsqueezing in the backward.
  if sizes.len > 0 and sizes[dim.int] == 1:
    return self.unsqueeze(dim.int64)
  return self

proc dim_list_to_bitset(dims: openarray[SomeInteger]; ndims: int64; wrap_scalar: bool = true): set[0..63] =
  assert(ndims <= 64, "only tensors with up to 64 dims are supported")
  for i in 0 ..< dims.len:
    let dim = maybe_wrap_dim(dims[i].int, ndims.int)
    assert(dim in result, "dim " & $dim & " appears multiple times in the list of dims")
    result.incl(dim)

proc sum_backward(grad: Tensor; sizes: openarray[SomeInteger]; dims: openarray[SomeInteger]; keepdim: bool): Tensor =
  if not keepdim and sizes.len > 0:
    if dims.len == 1:
      return grad.unsqueeze(dims[0]).expand(sizes)
    else:
      let dims_to_unsqueeze = dim_list_to_bitset(dims, sizes.len)
      result = grad
      for i in 0 ..< sizes.len:
        if i in dims_to_unsqueeze:
          result = result.unsqueeze(i)
      result = result.expand(sizes)
  else:
    return grad.expand(sizes)

proc legacy_cat_wrap_dim(dim: int; tensor_sizes: seq[seq[int]]): int =
  for sizes in tensor_sizes:
    if sizes.len != 1 or sizes[0] != 0:
      return maybe_wrap_dim(dim, sizes.len);
  return dim

proc cat_tensors_backward(grad: Tensor; sizes: seq[seq[int]]; dim: int64): TensorList =
  let dim = legacy_cat_wrap_dim(dim.int, sizes)
  result.setLen(sizes.len)
  var accumulate = 0

  for i, shape in sizes:
    # If input was empty tensor, gradInput should be empty tensor.
    if shape.len == 1 and shape[0] == 0:
      result[i] = zeros([0], grad.options())
      continue

    let size = shape[dim]
    accumulate += size
    result[i] = grad.narrow(dim, (accumulate - size).int64, size.int64)

proc to_args_sizes(tensors: openarray[Tensor]): seq[seq[int]] =
  result.setLen(tensors.len)
  for i, tensor in tensors:
    result[i] = tensor.sizes()