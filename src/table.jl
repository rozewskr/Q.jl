import TableTraits
using Serialization
using DataFrames
struct K_Table <: AbstractDataFrame
    a::Array{K_,0}
    function K_Table(x::K_)
        a = asarray(x)
        t = xt(x)
        if(t != XT)
            throw(ArgumentError("type mismatch: t=$t ≠ $XT"))
        end
        return new(a)
    end
    function K_Table(columns::Vector, colnames::Vector{Symbol})
        ncols = length(columns)
        x = K_new(colnames)
        y = K_new(columns)
        a = asarray(xT(xD(x, y)))
        new(a)
    end
    function K_Table(; kwargs...)
        x = ktn(KS, 0)
        y = ktn(KK, 0)
        rx, ry = map(Ref{K_}, [x, y])
        for (k, v) in kwargs
            x = js(rx, ss(k))
            y = jk(ry, K_new(v))
        end
        a = asarray(xT(xD(x, y)))
        new(a)
    end
end
K_Table(df::AbstractDataFrame) = K_Table(K_new(df))
function K_Table(::Type{T}, n::Integer) where {T <: NamedTuple}
    cols = fieldnames(T)
    x = K_new(cols)
    y = knk(length(cols), (ktn(ktypecode(S), n) for S in T.types)...)
    K_Table(xT(xD(x, y)))
end
kpointer(x::K_Table) = K_(pointer(x.a)-8)
valptr(x::K_Table, i) = unsafe_load(Ptr{K_}(xy(x.a[])+16), i)
colnames(x::K_Table) = K(r1(xx(x.a[])))
coldata(x::K_Table) = K(r1(xy(x.a[])))

Serialization.serialize(io::Serialization.AbstractSerializer, x::K_Table) =
    _serialize(io, x, typeof(x))

ncol(x::K_Table) = Int(xn(xx(x.a[])))
nrow(x::K_Table) = Int(xn(valptr(x, 1)))
index(x::K_Table) = DataFrames.Index(Array(colnames(x)))

function DataFrames.names!(x::K_Table, vals; allow_duplicates=true)
    u = DataFrames.make_unique(vals, allow_duplicates=allow_duplicates)
    kS(kK(x.a[])[1])[:] = map(ss, u)
    x
end

Base.getindex(x::K_Table, i::Integer) = K(r1(valptr(x, i)))
Base.getindex(x::K_Table, i::Integer, j::Integer) = x[j][i]
Base.getindex(x::K_Table, i::Symbol) = x[DataFrames.index(x)[i]]
function genkeymap(gd, cols)
    # currently we use Dict{Any,Int} because then field :keymap in GroupedDataFrame
    # has a concrete type which makes the access to it faster as we do not have a dynamic
    # dispatch when indexing into it. In the future an optimization of this approach
    # can be investigated (also taking compilation time into account).
    d = Dict{Any,Int}()
    gdidx = gd.idx
    sizehint!(d, length(gd.starts))
    for (i, s) in enumerate(gd.starts)
        d[getindex.(cols, gdidx[s])] = i
    end
    d
end

function Base.getproperty(gd::K_Table, f::Symbol)
    if f in (:idx, :starts, :ends)
        # Group indices are computed lazily the first time they are accessed
        # Do not lock when field is already initialized
        if getfield(gd, f) === nothing
            Threads.lock(gd.lazy_lock)
            if getfield(gd, f) === nothing # Do not lock when field is already initialized
                gd.idx, gd.starts, gd.ends = compute_indices(gd.groups, gd.ngroups)
            end
            Threads.unlock(gd.lazy_lock)
        end
        return getfield(gd, f)::Vector{Int}
    elseif f === :keymap
        # Keymap is computed lazily the first time it is accessed
        if getfield(gd, f) === nothing # Do not lock when field is already initialized
            Threads.lock(gd.lazy_lock)
            if getfield(gd, f) === nothing
                gd.keymap = genkeymap(gd, ntuple(i -> parent(gd)[!, gd.cols[i]], length(gd.cols)))
            end
            Threads.unlock(gd.lazy_lock)
        end
        return getfield(gd, f)::Dict{Any,Int}
    else
        return getfield(gd, f)
    end
end

## IterableTable protocol


# T is the type of the elements produced
# TS is a tuple type that stores the columns of the DataFrame
struct K_Table_Iter{T, TS}
    x::K_Table
    # This field hodls a tuple with the columns of the DataFrame.
    # Having a tuple of the columns here allows the iterator
    # functions to access the columns in a type stable way.
    columns::TS
end

TableTraits.isiterable(x::K_Table) = true
TableTraits.isiterabletable(x::K_Table) = true

function TableTraits.getiterator(x::K_Table)
    names = colnames(x)
    columns = coldata(x)
    col_exprs = Expr[]
    columns_tuple_type = :(Tuple{})
    for i in 1:length(columns)
        push!(col_exprs, Expr(:(::), Symbol(names[i]), eltype(columns[i])))
        push!(columns_tuple_type.args, typeof(columns[i]))
    end
    named_tuple_type = NamedTuples.make_tuple(col_exprs)
    iter_type_expr = :(K_Table_Iter{$named_tuple_type,$columns_tuple_type})
    iter_type = eval(iter_type_expr)
    iter_type(x, (columns...))
end

Base.length(iter::K_Table_Iter{T,TS}) where {T,TS} = size(iter.x,1)
Base.eltype(iter::K_Table_Iter{T,TS}) where {T,TS} = T

@generated function Base.iterate(iter::K_Table_Iter{T,TS}, state) where {T,TS}
    constructor_call = :($T())
    for i in 1:length(iter.types[2].types)
        push!(constructor_call.args, :(iter.columns[$i][state]))
    end
    :($constructor_call, state + 1)
end

function K_Table(source)
    iter = TableTraits.getiterator(source)
    _table(Base.iteratorsize(iter), iter)
end

_table(::Base.IsInfinite, iter) = error("infinite source")
_table(::Base.HasShape, iter) = _table_prealloc(iter)
_table(::Base.HasLength, iter) = _table_prealloc(iter)

function _table_prealloc(iter)
    x = K_Table(eltype(iter), length(iter))
    for (i, row) in enumerate(iter)
        for (j, v) in enumerate(row)
            x[j][i] = v
        end
    end
    x
end

function _raw_eltype(T)
    exprs = [Expr(:(::), n, eltype(t))
        for (n, t) in zip(fieldnames(T), T.types)]
    NamedTuples.make_tuple(exprs)
end

function _table(::Base.SizeUnknown, iter)
    x = K_Table(eltype(iter), 0)
    for row in iter
        for (i, v) in enumerate(row)
            Q.coldata(x)[i] = push!(x[i], row[i])
        end
    end
    x
end
