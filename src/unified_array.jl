export CuUnifiedArray, CuUnifiedVector, CuUnifiedMatrix, CuUnifiedVecOrMat

mutable struct CuUnifiedArray{T,N} <: AbstractGPUArray{T,N}
  buf::Mem.UnifiedBuffer
  baseptr::CuPtr{T}
  dims::Dims{N}
  ctx::CuContext
  offset::Int

  function CuUnifiedArray{T,N}(::UndefInitializer, dims::Dims{N}) where {T,N}
    Base.allocatedinline(T) || error("CuArray only supports element types that are stored inline")
    maxsize = prod(dims) * sizeof(T)
    bufsize = if Base.isbitsunion(T)
      # type tag array past the data
      maxsize + prod(dims)
    else
      maxsize
    end
    buf = alloc(Mem.Unified, bufsize)
    ptr = convert(CuPtr{T}, buf)
    obj = new{T,N}(buf, ptr, dims, context(), 0)
    finalizer(t -> free(t.buf), obj)
  end

  # increase ref count using `alias` when creating from an existing buffer.
  function CuUnifiedArray{T,N}(buf::Mem.UnifiedBuffer, dims::Dims{N}, offset::Int) where {T,N}
    alias(buf)
    ptr = convert(CuPtr{T}, buf)
    Base.allocatedinline(T) || error("CuArray only supports element types that are stored inline")
    obj = new{T,N}(buf, ptr, dims, context(), offset)
    finalizer(t -> free(t.buf), obj)
  end
end

## convenience constructors
CuUnifiedVector{T} = CuUnifiedArray{T,1}
CuUnifiedMatrix{T} = CuUnifiedArray{T,2}
CuUnifiedVecOrMat{T} = Union{CuUnifiedVector{T},CuUnifiedMatrix{T}}

# type and dimensionality specified, accepting dims as series of Ints
CuUnifiedArray{T,N}(::UndefInitializer, dims::Integer...) where {T,N} = CuUnifiedArray{T,N}(undef, dims)

# type but not dimensionality specified
CuUnifiedArray{T}(::UndefInitializer, dims::Dims{N}) where {T,N} = CuUnifiedArray{T,N}(undef, dims)

CuUnifiedArray{T}(::UndefInitializer, dims::Integer...) where {T} = CuUnifiedArray{T}(undef, convert(Tuple{Vararg{Int}}, dims))

CuUnifiedArray{T}(buf::Mem.UnifiedBuffer, dims::Integer...) where {T} = CuUnifiedArray{T}(buf, convert(Tuple{Vararg{Int}}, dims))

# empty vector constructor
CuUnifiedArray{T,1}() where {T} = CuUnifiedArray{T,1}(undef, 0)

## array interface

Base.elsize(::Type{<:CuUnifiedArray{T}}) where {T} = sizeof(T)

Base.size(x::CuUnifiedArray) = x.dims
Base.sizeof(x::CuUnifiedArray) = Base.elsize(x) * length(x)

## alias detection

Base.dataids(A::CuUnifiedArray) = (UInt(A.baseptr),)

Base.unaliascopy(A::CuUnifiedArray) = copy(A)

function Base.mightalias(A::CuUnifiedArray, B::CuUnifiedArray)
  rA = pointer(A):pointer(A)+sizeof(A)
  rB = pointer(B):pointer(B)+sizeof(B)
  return first(rA) <= first(rB) < last(rA) || first(rB) <= first(rA) < last(rB)
end

Base.pointer(x::CuUnifiedArray) = x.baseptr + x.offset

Base.similar(a::CuUnifiedArray{T,N}) where {T,N} = CuUnifiedArray{T,N}(undef, size(a))
Base.similar(a::CuUnifiedArray{T}, dims::Base.Dims{N}) where {T,N} = CuUnifiedArray{T,N}(undef, dims)
Base.similar(a::CuUnifiedArray, ::Type{T}, dims::Base.Dims{N}) where {T,N} = CuUnifiedArray{T,N}(undef, dims)

function Base.copy(a::CuUnifiedArray{T,N}) where {T,N}
  b = similar(a)
  @inbounds copyto!(b, a)
end

## interop with other arrays
@inline function CuUnifiedArray{T,N}(xs::AbstractArray{<:Any,N}) where {T,N}
  A = CuUnifiedArray{T,N}(undef, size(xs))
  copyto!(A, convert(Array{T}, xs))
  return A
end

# underspecified constructors
CuUnifiedArray{T}(xs::AbstractArray{S,N}) where {T,N,S} = CuUnifiedArray{T,N}(xs)
(::Type{CuUnifiedArray{T,N} where T})(x::AbstractArray{S,N}) where {S,N} = CuUnifiedArray{S,N}(x)
CuUnifiedArray(A::AbstractArray{T,N}) where {T,N} = CuUnifiedArray{T,N}(A)

# idempotency
CuUnifiedArray{T,N}(xs::CuUnifiedArray{T,N}) where {T,N} = xs

## conversions
Base.convert(::Type{T}, x::T) where T <: CuUnifiedArray = x

## interop with C libraries

Base.unsafe_convert(::Type{Ptr{T}}, x::CuUnifiedArray{T}) where {T} =
  throw(ArgumentError("cannot take the CPU address of a $(typeof(x))"))

Base.unsafe_convert(::Type{CuPtr{T}}, x::CuUnifiedArray{T}) where {T} =
  convert(CuPtr{T}, x.baseptr)

## interop with device arrays

function Base.unsafe_convert(::Type{CuDeviceArray{T,N,AS.Global}}, a::CuUnifiedArray{T,N}) where {T,N}
  CuDeviceArray{T,N,AS.Global}(size(a), reinterpret(LLVMPtr{T,AS.Global}, pointer(a)))
end

## interop with CPU arrays

typetagdata(a::CuUnifiedArray, i=1) =
  # buf.bytesize is total buffer size not accounting for the space allocated for typetags.
  # subtract the prod(dims) to get proper offset to copy typetag info
  convert(CuPtr{UInt8}, a.baseptr + a.buf.bytesize - prod(a.dims)) + a.offset÷Base.elsize(a) + i - 1


# We don't convert isbits types in `adapt`, since they are already
# considered GPU-compatible.

Adapt.adapt_storage(::Type{CuUnifiedArray}, xs::AT) where {AT<:AbstractArray} =
  isbitstype(AT) ? xs : convert(CuUnifiedArray, xs)

# if an element type is specified, convert to it
Adapt.adapt_storage(::Type{<:CuUnifiedArray{T}}, xs::AT) where {T, AT<:AbstractArray} =
  isbitstype(AT) ? xs : convert(CuUnifiedArray{T}, xs)

# optimize reshape to return a CuUnifiedArray

function Base.reshape(a::CuUnifiedArray{T,M}, dims::NTuple{N,Int}) where {T,N,M}
  if prod(dims) != length(a)
      throw(DimensionMismatch("new dimensions $(dims) must be consistent with array size $(size(a))"))
  end
  if N == M && dims == size(a)
      return a
  end
  b = CuUnifiedArray{T,N}(a.buf, dims, a.offset)
  return b
end

@inline function unsafe_contiguous_view(a::CuUnifiedArray{T}, I::NTuple{N,Base.ViewIndex}, dims::NTuple{M,Integer}) where {T,N,M}
    offset = Base.compute_offset1(a, 1, I) * sizeof(T)
    b = CuUnifiedArray{T,M}(a.buf, dims, offset)
    return b
end
