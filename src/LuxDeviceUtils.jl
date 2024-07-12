module LuxDeviceUtils

using Adapt: Adapt
using ChainRulesCore: ChainRulesCore, NoTangent
using Functors: Functors, fmap, fleaves
using LuxCore: LuxCore
using Preferences: @delete_preferences!, @load_preference, @set_preferences!
using Random: AbstractRNG, Random

const CRC = ChainRulesCore

export gpu_backend!, supported_gpu_backends, reset_gpu_device!
export default_device_rng
export gpu_device, cpu_device
export LuxCPUDevice, LuxCUDADevice, LuxAMDGPUDevice, LuxMetalDevice, LuxoneAPIDevice
export get_device, get_device_type

abstract type AbstractLuxDevice <: Function end
abstract type AbstractLuxGPUDevice <: AbstractLuxDevice end

"""
    functional(x::AbstractLuxDevice) -> Bool
    functional(::Type{<:AbstractLuxDevice}) -> Bool

Checks if the device is functional. This is used to determine if the device can be used for
computation. Note that even if the backend is loaded (as checked via
[`LuxDeviceUtils.loaded`](@ref)), the device may not be functional.

Note that while this function is not exported, it is considered part of the public API.
"""
@inline functional(x) = false

Base.@deprecate __is_functional(x) functional(x)

"""
    loaded(x::AbstractLuxDevice) -> Bool
    loaded(::Type{<:AbstractLuxDevice}) -> Bool

Checks if the trigger package for the device is loaded. Trigger packages are as follows:

  - `LuxCUDA.jl` for NVIDIA CUDA Support.
  - `AMDGPU.jl` for AMD GPU ROCM Support.
  - `Metal.jl` for Apple Metal GPU Support.
  - `oneAPI.jl` for Intel oneAPI GPU Support.
"""
@inline loaded(x) = false

Base.@deprecate __is_loaded(x) loaded(x)

struct LuxCPUDevice <: AbstractLuxDevice end
@kwdef struct LuxCUDADevice{D} <: AbstractLuxGPUDevice
    device::D = nothing
end
@kwdef struct LuxAMDGPUDevice{D} <: AbstractLuxGPUDevice
    device::D = nothing
end
struct LuxMetalDevice <: AbstractLuxGPUDevice end
struct LuxoneAPIDevice <: AbstractLuxGPUDevice end

for dev in (LuxCPUDevice, LuxMetalDevice, LuxoneAPIDevice)
    msg = "`device_id` is not applicable for `$dev`."
    @eval begin
        _with_device(::Type{$dev}, ::Nothing) = $dev()
        function _with_device(::Type{$dev}, device_id)
            @warn $(msg) maxlog=1
            return $dev()
        end
    end
end

@inline functional(::Union{LuxCPUDevice, Type{<:LuxCPUDevice}}) = true
@inline loaded(::Union{LuxCPUDevice, Type{<:LuxCPUDevice}}) = true

for name in (:CPU, :CUDA, :AMDGPU, :Metal, :oneAPI)
    tpkg = name === :CPU ? "" : (name == :CUDA ? "Lux$(name)" : string(name))
    ldev = eval(Symbol(:Lux, name, :Device))
    @eval begin
        @inline _get_device_name(::Union{$ldev, Type{<:$ldev}}) = $(string(name))
        @inline _get_triggerpkg_name(::Union{$ldev, Type{<:$ldev}}) = $(tpkg)
    end
end

for T in (LuxCPUDevice, LuxCUDADevice{Nothing},
    LuxAMDGPUDevice{Nothing}, LuxMetalDevice, LuxoneAPIDevice)
    @eval @inline _get_device_id(::$(T)) = nothing
end

struct LuxDeviceSelectionException <: Exception end

function Base.showerror(io::IO, ::LuxDeviceSelectionException)
    return print(io, "LuxDeviceSelectionException(No functional GPU device found!!)")
end

# Order is important here
const GPU_DEVICES = (LuxCUDADevice, LuxAMDGPUDevice, LuxMetalDevice, LuxoneAPIDevice)

const GPU_DEVICE = Ref{Union{Nothing, AbstractLuxDevice}}(nothing)

"""
    reset_gpu_device!()

Resets the selected GPU device. This is useful when automatic GPU selection needs to be
run again.
"""
@inline reset_gpu_device!() = (GPU_DEVICE[] = nothing)

"""
    supported_gpu_backends() -> Tuple{String, ...}

Return a tuple of supported GPU backends.

!!! warning

    This is not the list of functional backends on the system, but rather backends which
    `Lux.jl` supports.

!!! danger

    `Metal.jl` and `oneAPI.jl` support is **extremely** experimental and most things are not
    expected to work.
"""
@inline supported_gpu_backends() = map(_get_device_name, GPU_DEVICES)

"""
    gpu_device(device_id::Union{Nothing, Integer}=nothing;
        force_gpu_usage::Bool=false) -> AbstractLuxDevice()

Selects GPU device based on the following criteria:

 1. If `gpu_backend` preference is set and the backend is functional on the system, then
    that device is selected.
 2. Otherwise, an automatic selection algorithm is used. We go over possible device
    backends in the order specified by `supported_gpu_backends()` and select the first
    functional backend.
 3. If no GPU device is functional and  `force_gpu_usage` is `false`, then `cpu_device()` is
    invoked.
 4. If nothing works, an error is thrown.

## Arguments

  - `device_id::Union{Nothing, Integer}`: The device id to select. If `nothing`, then we return
    the last selected device or if none was selected then we run the autoselection and
    choose the current device using `CUDA.device()` or `AMDGPU.device()` or similar. If
    `Integer`, then we select the device with the given id. Note that this is `1`-indexed, in
    contrast to the `0`-indexed `CUDA.jl`. For example, `id = 4` corresponds to
    `CUDA.device!(3)`.

!!! warning

    `device_id` is only applicable for `CUDA` and `AMDGPU` backends. For `Metal`, `oneAPI`
    and `CPU` backends, `device_id` is ignored and a warning is printed.

## Keyword Arguments

  - `force_gpu_usage::Bool`: If `true`, then an error is thrown if no functional GPU
    device is found.
"""
function gpu_device(device_id::Union{Nothing, <:Integer}=nothing;
        force_gpu_usage::Bool=false)::AbstractLuxDevice
    device_id == 0 && throw(ArgumentError("`device_id` is 1-indexed."))

    if GPU_DEVICE[] !== nothing
        dev = GPU_DEVICE[]
        if device_id === nothing
            force_gpu_usage &&
                !(dev isa AbstractLuxGPUDevice) &&
                throw(LuxDeviceSelectionException())
            return dev
        else
            selected_device_id = _get_device_id(dev)
            selected_device_id !== nothing && selected_device_id == device_id && return dev
        end
    end

    device_type = _get_gpu_device(; force_gpu_usage)
    device = _with_device(device_type, device_id)
    GPU_DEVICE[] = device

    return device
end

function _get_gpu_device(; force_gpu_usage::Bool)
    backend = @load_preference("gpu_backend", nothing)

    # If backend set with preferences, use it
    if backend !== nothing
        allowed_backends = supported_gpu_backends()
        if backend ∉ allowed_backends
            @warn "`gpu_backend` preference is set to $backend, which is not a valid \
                    backend. Valid backends are $allowed_backends. Defaulting to automatic \
                    GPU Backend selection." maxlog=1
        else
            @debug "Using GPU backend set in preferences: $backend."
            idx = findfirst(isequal(backend), allowed_backends)
            device = GPU_DEVICES[idx]
            if !loaded(device)
                @warn "Trying to use backend: $(_get_device_name(device)) but the trigger \
                       package $(_get_triggerpkg_name(device)) is not loaded. Ignoring the \
                       Preferences backend!!! Please load the package and call this \
                       function again to respect the Preferences backend." maxlog=1
            else
                if functional(device)
                    @debug "Using GPU backend: $(_get_device_name(device))."
                    return device
                else
                    @warn "GPU backend: $(_get_device_name(device)) set via Preferences.jl \
                           is not functional. Defaulting to automatic GPU Backend \
                           selection." maxlog=1
                end
            end
        end
    end

    @debug "Running automatic GPU backend selection..."
    for device in GPU_DEVICES
        if loaded(device)
            @debug "Trying backend: $(_get_device_name(device))."
            if functional(device)
                @debug "Using GPU backend: $(_get_device_name(device))."
                return device
            end
            @debug "GPU backend: $(_get_device_name(device)) is not functional."
        else
            @debug "Trigger package for backend ($(_get_device_name(device))): \
                    $(_get_triggerpkg_name(device)) not loaded."
        end
    end

    if force_gpu_usage
        throw(LuxDeviceSelectionException())
    else
        @warn """No functional GPU backend found! Defaulting to CPU.

                 1. If no GPU is available, nothing needs to be done.
                 2. If GPU is available, load the corresponding trigger package.
                     a. `LuxCUDA.jl` for NVIDIA CUDA Support.
                     b. `AMDGPU.jl` for AMD GPU ROCM Support.
                     c. `Metal.jl` for Apple Metal GPU Support. (Experimental)
                     d. `oneAPI.jl` for Intel oneAPI GPU Support. (Experimental)""" maxlog=1
        return LuxCPUDevice
    end
end

"""
    gpu_backend!() = gpu_backend!("")
    gpu_backend!(backend) = gpu_backend!(string(backend))
    gpu_backend!(backend::AbstractLuxGPUDevice)
    gpu_backend!(backend::String)

Creates a `LocalPreferences.toml` file with the desired GPU backend.

If `backend == ""`, then the `gpu_backend` preference is deleted. Otherwise, `backend` is
validated to be one of the possible backends and the preference is set to `backend`.

If a new backend is successfully set, then the Julia session must be restarted for the
change to take effect.
"""
gpu_backend!(backend) = gpu_backend!(string(backend))
gpu_backend!(backend::AbstractLuxGPUDevice) = gpu_backend!(_get_device_name(backend))
gpu_backend!() = gpu_backend!("")
function gpu_backend!(backend::String)
    if backend == ""
        @delete_preferences!("gpu_backend")
        @info "Deleted the local preference for `gpu_backend`. Restart Julia to use the \
               new backend."
        return
    end

    allowed_backends = supported_gpu_backends()

    set_backend = @load_preference("gpu_backend", nothing)
    if set_backend == backend
        @info "GPU backend is already set to $backend. No action is required."
        return
    end

    if backend ∉ allowed_backends
        throw(ArgumentError("Invalid backend: $backend. Valid backends are $allowed_backends."))
    end

    @set_preferences!("gpu_backend"=>backend)
    @info "GPU backend has been set to $backend. Restart Julia to use the new backend."
    return
end

"""
    cpu_device() -> LuxCPUDevice()

Return a `LuxCPUDevice` object which can be used to transfer data to CPU.
"""
@inline cpu_device() = LuxCPUDevice()

"""
    default_device_rng(::AbstractLuxDevice)

Returns the default RNG for the device. This can be used to directly generate parameters
and states on the device using
[WeightInitializers.jl](https://github.com/LuxDL/WeightInitializers.jl).
"""
function default_device_rng(D::AbstractLuxDevice)
    return error("""`default_device_rng` not implemented for `$(typeof(D))`. This is \
           either because:

           1. The default RNG for this device is not known / officially provided.
           2. The trigger package for the device ($(_get_device_name(D)).jl) is not loaded.
           """)
end
default_device_rng(::LuxCPUDevice) = Random.default_rng()

# Dispatches for Different Data Structures
# Abstract Array / Tuples / NamedTuples have special fast paths to facilitate type stability
# For all other types we rely on fmap which means we lose type stability.
# For Lux, typically models only has these 3 datastructures so we should be mostly fine.
for (dev) in (:CPU, :CUDA, :AMDGPU, :Metal, :oneAPI)
    ldev = Symbol("Lux$(dev)Device")
    @eval begin
        function (D::$(ldev))(x::AbstractArray{T}) where {T}
            fn = Base.Fix1(Adapt.adapt, D)
            return isbitstype(T) || __special_aos(x) ? fn(x) : map(D, x)
        end
        (D::$(ldev))(x::Tuple) = map(D, x)
        (D::$(ldev))(x::NamedTuple{F}) where {F} = NamedTuple{F}(D(values(x)))
        function (D::$(ldev))(x)
            Functors.isleaf(x) && return Adapt.adapt(D, x)
            return fmap(D, x)
        end
        function (::$(ldev))(NN::LuxCore.AbstractExplicitLayer)
            @warn "Lux layers are stateless and hence don't participate in device \
                   transfers. Apply this function on the parameters and states generated \
                   using `Lux.setup`."
            return NN
        end
    end
end

@inline __special_aos(x::AbstractArray) = false

const GET_DEVICE_ADMONITIONS = """
!!! note

    Trigger Packages must be loaded for this to return the correct device.

!!! warning

    RNG types currently don't participate in device determination. We will remove this
    restriction in the future.
"""

# Query Device from Array
"""
    get_device(x) -> dev::AbstractLuxDevice | Exception | nothing

If all arrays (on the leaves of the structure) are on the same device, we return that
device. Otherwise, we throw an error. If the object is device agnostic, we return `nothing`.

$(GET_DEVICE_ADMONITIONS)

See also [`get_device_type`](@ref) for a faster alternative that can be used for dispatch
based on device type.
"""
function get_device end

"""
    get_device_type(x) -> Type{<:AbstractLuxDevice} | Exception | Type{Nothing}

Similar to [`get_device`](@ref) but returns the type of the device instead of the device
itself. This value is often a compile time constant and is recommended to be used instead
of [`get_device`](@ref) where ever defining dispatches based on the device type.

$(GET_DEVICE_ADMONITIONS)
"""
function get_device_type end

for op in (:get_device, :get_device_type)
    _op = Symbol("_", op)
    cpu_ret_val = op == :get_device ? LuxCPUDevice() : LuxCPUDevice
    @eval begin
        function $(op)(x)
            hasmethod($(_op), Tuple{typeof(x)}) && return $(_op)(x)
            return mapreduce($(_op), __combine_devices, fleaves(x))
        end

        CRC.@non_differentiable $op(::Any)

        function $(_op)(x::AbstractArray{T}) where {T}
            __recursible_array_eltype(T) && return mapreduce($(_op), __combine_devices, x)
            if hasmethod(parent, Tuple{typeof(x)})
                parent_x = parent(x)
                parent_x === x && return $(cpu_ret_val)
                return $(_op)(parent_x)
            end
            return $(cpu_ret_val)
        end

        function $(_op)(x::Union{Tuple, NamedTuple})
            length(x) == 0 && return $(op == :get_device ? nothing : Nothing)
            return mapreduce($(_op), __combine_devices, values(x))
        end
    end

    for T in (Number, AbstractRNG, Val, Symbol, String)
        @eval $(_op)(::$(T)) = $(op == :get_device ? nothing : Nothing)
    end
end

__recursible_array_eltype(::Type{T}) where {T} = !isbitstype(T) && !(T <: Number)

__combine_devices(::Nothing, ::Nothing) = nothing
__combine_devices(::Type{Nothing}, ::Type{Nothing}) = nothing
__combine_devices(::Nothing, dev::AbstractLuxDevice) = dev
__combine_devices(::Type{Nothing}, ::Type{T}) where {T <: AbstractLuxDevice} = T
__combine_devices(dev::AbstractLuxDevice, ::Nothing) = dev
__combine_devices(::Type{T}, ::Type{Nothing}) where {T <: AbstractLuxDevice} = T
function __combine_devices(dev1::AbstractLuxDevice, dev2::AbstractLuxDevice)
    dev1 == dev2 && return dev1
    throw(ArgumentError("Objects are on different devices: $(dev1) and $(dev2)."))
end
__combine_devices(::Type{T}, ::Type{T}) where {T <: AbstractLuxDevice} = T
function __combine_devices(
        ::Type{T1}, ::Type{T2}) where {T1 <: AbstractLuxDevice, T2 <: AbstractLuxDevice}
    throw(ArgumentError("Objects are on devices with different types: $(T1) and $(T2)."))
end

# Set the device
const SET_DEVICE_DOCS = """
Set the device for the given type. This is a no-op for `LuxCPUDevice`. For `LuxCUDADevice`
and `LuxAMDGPUDevice`, it prints a warning if the corresponding trigger package is not
loaded.

Currently, `LuxMetalDevice` and `LuxoneAPIDevice` doesn't support setting the device.
"""

const SET_DEVICE_DANGER = """
!!! danger

    This specific function should be considered experimental at this point and is currently
    provided to support distributed training in Lux. As such please use
    `Lux.DistributedUtils` instead of using this function.
"""

"""
    set_device!(T::Type{<:AbstractLuxDevice}, dev_or_id)

$SET_DEVICE_DOCS

## Arguments

  - `T::Type{<:AbstractLuxDevice}`: The device type to set.
  - `dev_or_id`: Can be the device from the corresponding package. For example for CUDA it
    can be a `CuDevice`. If it is an integer, it is the device id to set. This is
    `1`-indexed.

$SET_DEVICE_DANGER
"""
function set_device!(::Type{T}, dev_or_id) where {T <: AbstractLuxDevice}
    T === LuxCUDADevice &&
        @warn "`CUDA.jl` hasn't been loaded. Ignoring the device setting."
    T === LuxAMDGPUDevice &&
        @warn "`AMDGPU.jl` hasn't been loaded. Ignoring the device setting."
    T === LuxMetalDevice &&
        @warn "Support for Multi Device Metal hasn't been implemented yet. Ignoring the device setting."
    T === LuxoneAPIDevice &&
        @warn "Support for Multi Device oneAPI hasn't been implemented yet. Ignoring the device setting."
    T === LuxCPUDevice &&
        @warn "Setting device for `LuxCPUDevice` doesn't make sense. Ignoring the device setting."
    return
end

"""
    set_device!(T::Type{<:AbstractLuxDevice}, ::Nothing, rank::Integer)

$SET_DEVICE_DOCS

## Arguments

  - `T::Type{<:AbstractLuxDevice}`: The device type to set.
  - `rank::Integer`: Local Rank of the process. This is applicable for distributed training and
    must be `0`-indexed.

$SET_DEVICE_DANGER
"""
function set_device!(::Type{T}, ::Nothing, rank::Integer) where {T <: AbstractLuxDevice}
    return set_device!(T, rank)
end

# Adapt Interface
# In older versions we had corresponding Adapt functions, rn we directly dispatch on the
# device type.
for name in (:CPU, :CUDA, :AMDGPU, :Metal, :oneAPI)
    dev = Symbol(:Lux, name, :Device)
    adaptor = Symbol(:Lux, name, :Adaptor)
    @eval Base.@deprecate $(adaptor) $(dev) true
end

Adapt.adapt_storage(::LuxCPUDevice, x::AbstractArray) = Adapt.adapt(Array, x)
Adapt.adapt_storage(::LuxCPUDevice, rng::AbstractRNG) = rng

for T in (LuxAMDGPUDevice, LuxCUDADevice, LuxMetalDevice, LuxoneAPIDevice)
    @eval begin
        function Adapt.adapt_storage(to::$(T), ::Random.TaskLocalRNG)
            return default_device_rng(to)
        end
        Adapt.adapt_storage(::$(T), rng::AbstractRNG) = rng
    end
end

Adapt.adapt_storage(::LuxCPUDevice, x::AbstractRange) = x
# Prevent Ambiguity
for T in (LuxAMDGPUDevice, LuxAMDGPUDevice{Nothing}, LuxCUDADevice,
    LuxCUDADevice{Nothing}, LuxMetalDevice, LuxoneAPIDevice)
    @eval Adapt.adapt_storage(to::$(T), x::AbstractRange) = Adapt.adapt(to, collect(x))
end

# Chain Rules Core
function CRC.rrule(::typeof(Adapt.adapt_storage), to::AbstractLuxDevice, x::AbstractArray)
    ∇adapt_storage = let x = x
        Δ -> (NoTangent(), NoTangent(), (get_device(x))(Δ))
    end
    return Adapt.adapt_storage(to, x), ∇adapt_storage
end

end
