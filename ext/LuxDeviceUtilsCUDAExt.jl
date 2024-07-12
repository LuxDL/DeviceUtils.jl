module LuxDeviceUtilsCUDAExt

using Adapt: Adapt
using CUDA: CUDA
using CUDA.CUSPARSE: AbstractCuSparseMatrix, AbstractCuSparseVector
using LuxDeviceUtils: LuxDeviceUtils, LuxCUDADevice, LuxCPUDevice
using Random: Random

function LuxDeviceUtils._with_device(::Type{LuxCUDADevice}, id::Integer)
    id > length(CUDA.devices()) &&
        throw(ArgumentError("id = $id > length(CUDA.devices()) = $(length(CUDA.devices()))"))
    old_dev = CUDA.device()
    CUDA.device!(id - 1)
    device = LuxCUDADevice(CUDA.device())
    CUDA.device!(old_dev)
    return device
end

function LuxDeviceUtils._with_device(::Type{LuxCUDADevice}, ::Nothing)
    return LuxCUDADevice(nothing)
end

LuxDeviceUtils._get_device_id(dev::LuxCUDADevice) = CUDA.deviceid(dev.device) + 1

# Default RNG
LuxDeviceUtils.default_device_rng(::LuxCUDADevice) = CUDA.default_rng()

# Query Device from Array
function LuxDeviceUtils._get_device(x::CUDA.AnyCuArray)
    parent_x = parent(x)
    parent_x === x && return LuxCUDADevice(CUDA.device(x))
    return LuxDeviceUtils.get_device(parent_x)
end
function LuxDeviceUtils._get_device(x::CUDA.CUSPARSE.AbstractCuSparseArray)
    return LuxCUDADevice(CUDA.device(x.nzVal))
end

function LuxDeviceUtils._get_device_type(::Union{
        <:CUDA.AnyCuArray, <:CUDA.CUSPARSE.AbstractCuSparseArray})
    return LuxCUDADevice
end

# Set Device
function LuxDeviceUtils.set_device!(::Type{LuxCUDADevice}, dev::CUDA.CuDevice)
    return CUDA.device!(dev)
end
function LuxDeviceUtils.set_device!(::Type{LuxCUDADevice}, id::Integer)
    return LuxDeviceUtils.set_device!(LuxCUDADevice, collect(CUDA.devices())[id])
end
function LuxDeviceUtils.set_device!(::Type{LuxCUDADevice}, ::Nothing, rank::Integer)
    id = mod1(rank + 1, length(CUDA.devices()))
    return LuxDeviceUtils.set_device!(LuxCUDADevice, id)
end

# Device Transfer
Adapt.adapt_storage(::LuxCUDADevice{Nothing}, x::AbstractArray) = CUDA.cu(x)
function Adapt.adapt_storage(to::LuxCUDADevice, x::AbstractArray)
    old_dev = CUDA.device()  # remember the current device
    dev = LuxDeviceUtils.get_device(x)
    if !(dev isa LuxCUDADevice)
        CUDA.device!(to.device)
        x_new = CUDA.cu(x)
        CUDA.device!(old_dev)
        return x_new
    elseif dev.device == to.device
        return x
    else
        CUDA.device!(to.device)
        x_new = copy(x)
        CUDA.device!(old_dev)
        return x_new
    end
end

Adapt.adapt_storage(::LuxCPUDevice, rng::CUDA.RNG) = Random.default_rng()

# Defining as extensions seems to case precompilation errors
@static if isdefined(CUDA.CUSPARSE, :SparseArrays)
    function Adapt.adapt_storage(::LuxCPUDevice, x::AbstractCuSparseMatrix)
        return CUDA.CUSPARSE.SparseArrays.SparseMatrixCSC(x)
    end
    function Adapt.adapt_storage(::LuxCPUDevice, x::AbstractCuSparseVector)
        return CUDA.CUSPARSE.SparseArrays.SparseVector(x)
    end
else
    @warn "CUDA.CUSPARSE seems to have removed SparseArrays as a dependency. Please open \
           an issue in LuxDeviceUtils.jl repository."
end

end
