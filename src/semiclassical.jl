module semiclassical

import Base: ==
import ..bases, ..operators, ..operators_dense
import ..timeevolution: integrate, recast!, QO_CHECKS
import ..timeevolution.timeevolution_mcwf: jump
import LinearAlgebra: normalize!

using Random, LinearAlgebra
import OrdinaryDiffEq

# TODO: Remove imports
import DiffEqCallbacks, RecursiveArrayTools.copyat_or_push!
Base.@pure pure_inference(fout,T) = Core.Compiler.return_type(fout, T)

using ..bases, ..states, ..operators, ..operators_dense, ..timeevolution


const QuantumState{B} = Union{Ket{B}, DenseOperator{B,B}}
const DecayRates = Union{Nothing, Vector{Float64}, Matrix{Float64}}

"""
Semi-classical state.

It consists of a quantum part, which is either a `Ket` or a `DenseOperator` and
a classical part that is specified as a complex vector of arbitrary length.
"""
mutable struct State{B<:Basis,T<:QuantumState{B},C<:Vector{ComplexF64}}
    quantum::T
    classical::C
    function State(quantum::T, classical::C) where {B<:Basis,T<:QuantumState{B},C<:Vector{ComplexF64}}
        new{B,T,C}(quantum, classical)
    end
end

Base.length(state::State) = length(state.quantum) + length(state.classical)
Base.copy(state::State) = State(copy(state.quantum), copy(state.classical))
normalize!(state::State{B,T}) where {B,T<:Ket} = normalize!(state.quantum)

function ==(a::State, b::State)
    samebases(a.quantum, b.quantum) &&
    length(a.classical)==length(b.classical) &&
    (a.classical==b.classical) &&
    (a.quantum==b.quantum)
end

operators.expect(op, state::State) = expect(op, state.quantum)
operators.variance(op, state::State) = variance(op, state.quantum)
operators.ptrace(state::State, indices::Vector{Int}) = State(ptrace(state.quantum, indices), state.classical)

operators_dense.dm(x::State{B,T}) where {B<:Basis,T<:Ket{B}} = State(dm(x.quantum), x.classical)


"""
    semiclassical.schroedinger_dynamic(tspan, state0, fquantum, fclassical[; fout, ...])

Integrate time-dependent Schrödinger equation coupled to a classical system.

# Arguments
* `tspan`: Vector specifying the points of time for which the output should
        be displayed.
* `psi0`: Initial semi-classical state [`semiclassical.State`](@ref).
* `fquantum`: Function `f(t, psi, u) -> H` returning the time and or state
        dependent Hamiltonian.
* `fclassical`: Function `f(t, psi, u, du)` calculating the possibly time and
        state dependent derivative of the classical equations and storing it
        in the vector `du`.
* `fout=nothing`: If given, this function `fout(t, state)` is called every time
        an output should be displayed. ATTENTION: The given state is neither
        normalized nor permanent!
* `kwargs...`: Further arguments are passed on to the ode solver.
"""
function schroedinger_dynamic(tspan, state0::S, fquantum::Function, fclassical::Function;
                fout::Union{Function,Nothing}=nothing,
                kwargs...) where {B<:Basis,T<:Ket{B},S<:State{B,T}}
    tspan_ = convert(Vector{Float64}, tspan)
    dschroedinger_(t::Float64, state::S, dstate::S) = dschroedinger_dynamic(t, state, fquantum, fclassical, dstate)
    x0 = Vector{ComplexF64}(undef, length(state0))
    recast!(state0, x0)
    state = copy(state0)
    dstate = copy(state0)
    integrate(tspan_, dschroedinger_, x0, state, dstate, fout; kwargs...)
end

"""
    semiclassical.master_dynamic(tspan, state0, fquantum, fclassical; <keyword arguments>)

Integrate time-dependent master equation coupled to a classical system.

# Arguments
* `tspan`: Vector specifying the points of time for which output should
        be displayed.
* `rho0`: Initial semi-classical state [`semiclassical.State`](@ref).
* `fquantum`: Function `f(t, rho, u) -> (H, J, Jdagger)` returning the time
        and/or state dependent Hamiltonian and Jump operators.
* `fclassical`: Function `f(t, rho, u, du)` calculating the possibly time and
        state dependent derivative of the classical equations and storing it
        in the complex vector `du`.
* `fout=nothing`: If given, this function `fout(t, state)` is called every time
        an output should be displayed. ATTENTION: The given state is not
        permanent!
* `kwargs...`: Further arguments are passed on to the ode solver.
"""
function master_dynamic(tspan, state0::State{B,T}, fquantum, fclassical;
                rates::DecayRates=nothing,
                fout::Union{Function,Nothing}=nothing,
                tmp::T=copy(state0.quantum),
                kwargs...) where {B<:Basis,T<:DenseOperator{B,B}}
    tspan_ = convert(Vector{Float64}, tspan)
    function dmaster_(t::Float64, state::S, dstate::S) where {B<:Basis,T<:DenseOperator{B,B},S<:State{B,T}}
        dmaster_h_dynamic(t, state, fquantum, fclassical, rates, dstate, tmp)
    end
    x0 = Vector{ComplexF64}(undef, length(state0))
    recast!(state0, x0)
    state = copy(state0)
    dstate = copy(state0)
    integrate(tspan_, dmaster_, x0, state, dstate, fout; kwargs...)
end

function master_dynamic(tspan, state0::State{B,T}, fquantum, fclassical; kwargs...) where {B<:Basis,T<:Ket{B}}
    master_dynamic(tspan, dm(state0), fquantum, fclassical; kwargs...)
end

"""
    semiclassical.mcwf_dynamic(tspan, psi0, fquantum, fclassical, fjump_classical; <keyword arguments>)

Calculate MCWF trajectories coupled to a classical system.

# Arguments
* `tspan`: Vector specifying the points of time for which output should
        be displayed.
* `rho0`: Initial semi-classical state [`semiclassical.State`](@ref).
* `fquantum`: Function `f(t, rho, u) -> (H, J, Jdagger)` returning the time
        and/or state dependent Hamiltonian and Jump operators.
* `fclassical`: Function `f(t, rho, u, du)` calculating the possibly time and
        state dependent derivative of the classical equations and storing it
        in the complex vector `du`.
* `fjump_classical`: Function `f(t, rho, u, i)` making a classical jump when a
        quantum jump of the i-th jump operator occurs.

* `fout=nothing`: If given, this function `fout(t, state)` is called every time
        an output should be displayed. ATTENTION: The given state is not
        permanent!
* `kwargs...`: Further arguments are passed on to the ode solver.
"""
function mcwf_dynamic(tspan, psi0::State{B,T}, fquantum, fclassical, fjump_classical;
                seed=rand(UInt),
                rates::DecayRates=nothing,
                fout::Union{Function,Nothing}=nothing,
                kwargs...) where {B<:Basis,T<:Ket{B}}
    tspan_ = convert(Vector{Float64}, tspan)
    tmp=copy(psi0.quantum)
    function dmcwf_(t::Float64, psi::S, dpsi::S) where {B<:Basis,T<:Ket{B},S<:State{B,T}}
        dmcwf_h_dynamic(t, psi, fquantum, fclassical, rates, dpsi, tmp)
    end
    j_(rng, t::Float64, psi, psi_new) = jump_dynamic(rng, t, psi, fquantum, fclassical, fjump_classical, psi_new, rates)
    x0 = Vector{ComplexF64}(undef, length(psi0))
    recast!(psi0, x0)
    psi = copy(psi0)
    dpsi = copy(psi0)
    integrate_mcwf(dmcwf_, j_, tspan_, psi, seed, fout; kwargs...)
end

function recast!(state::State{B,T,C}, x::C) where {B<:Basis,T<:QuantumState{B},C<:Vector{ComplexF64}}
    N = length(state.quantum)
    copyto!(x, 1, state.quantum.data, 1, N)
    copyto!(x, N+1, state.classical, 1, length(state.classical))
    x
end

function recast!(x::C, state::State{B,T,C}) where {B<:Basis,T<:QuantumState{B},C<:Vector{ComplexF64}}
    N = length(state.quantum)
    copyto!(state.quantum.data, 1, x, 1, N)
    copyto!(state.classical, 1, x, N+1, length(state.classical))
end

function dschroedinger_dynamic(t::Float64, state::State{B,T}, fquantum::Function,
            fclassical::Function, dstate::State{B,T}) where {B<:Basis,T<:Ket{B}}
    fquantum_(t, psi) = fquantum(t, state.quantum, state.classical)
    timeevolution.timeevolution_schroedinger.dschroedinger_dynamic(t, state.quantum, fquantum_, dstate.quantum)
    fclassical(t, state.quantum, state.classical, dstate.classical)
end

function dmaster_h_dynamic(t::Float64, state::State{B,T}, fquantum::Function,
            fclassical::Function, rates::DecayRates, dstate::State{B,T}, tmp::T) where {B<:Basis,T<:DenseOperator{B,B}}
    fquantum_(t, rho) = fquantum(t, state.quantum, state.classical)
    timeevolution.timeevolution_master.dmaster_h_dynamic(t, state.quantum, fquantum_, rates, dstate.quantum, tmp)
    fclassical(t, state.quantum, state.classical, dstate.classical)
end

function dmcwf_h_dynamic(t::Float64, psi::T, fquantum::Function, fclassical::Function, rates::DecayRates,
                    dpsi::T, tmp::K) where {T,K}
    fquantum_(t, rho) = fquantum(t, psi.quantum, psi.classical)
    timeevolution.timeevolution_mcwf.dmcwf_h_dynamic(t, psi.quantum, fquantum_, rates, dpsi.quantum, tmp)
    fclassical(t, psi.quantum, psi.classical, dpsi.classical)
end

function jump_dynamic(rng, t::Float64, psi::T, fquantum::Function, fclassical::Function, fjump_classical::Function, psi_new::T, rates::DecayRates) where T<:State
    result = fquantum(t, psi.quantum, psi.classical)
    QO_CHECKS[] && @assert 3 <= length(result) <= 4
    J = result[2]
    if length(result) == 3
        rates_ = rates
    else
        rates_ = result[4]
    end
    i = jump(rng, t, psi.quantum, J, psi_new.quantum, rates_)
    fjump_classical(t, psi_new.quantum, psi.classical, i)
    psi_new.classical .= psi.classical
end

function integrate_mcwf(dmcwf::Function, jumpfun::Function, tspan,
                        psi0::T, seed, fout::Function;
                        display_beforeevent=false, display_afterevent=false,
                        #TODO: Remove kwargs
                        save_everystep=false, callback=nothing,
                        alg=OrdinaryDiffEq.DP5(),
                        kwargs...) where {B<:Basis,T<:State}

    tmp = copy(psi0)
    psi_tmp = copy(psi0)
    x0 = [psi0.quantum.data; psi0.classical]
    rng = MersenneTwister(convert(UInt, seed))
    jumpnorm = Ref(rand(rng))
    n = length(psi0.quantum)
    djumpnorm(x::Vector{ComplexF64}, t::Float64, integrator) = norm(x[1:n])^2 - (1-jumpnorm[])

    if !display_beforeevent && !display_afterevent
        function dojump(integrator)
            x = integrator.u
            recast!(x, psi_tmp)
            t = integrator.t
            jumpfun(rng, t, psi_tmp, tmp)
            recast!(tmp, x)
            jumpnorm[] = rand(rng)
        end
        cb = OrdinaryDiffEq.ContinuousCallback(djumpnorm,dojump,
                         save_positions = (display_beforeevent,display_afterevent))


        timeevolution.integrate(float(tspan), dmcwf, x0,
                    copy(psi0), copy(psi0), fout;
                    callback = cb,
                    kwargs...)
    else
        # Temporary workaround until proper tooling for saving
        # TODO: Replace by proper call to timeevolution.integrate
        function fout_(x::Vector{ComplexF64}, t::Float64, integrator)
            recast!(x, state)
            fout(t, state)
        end

        state = copy(psi0)
        dstate = copy(psi0)
        out_type = pure_inference(fout, Tuple{eltype(tspan),typeof(state)})
        out = DiffEqCallbacks.SavedValues(Float64,out_type)
        scb = DiffEqCallbacks.SavingCallback(fout_,out,saveat=tspan,
                                             save_everystep=save_everystep,
                                             save_start = false)

        function dojump_display(integrator)
            x = integrator.u
            t = integrator.t

            affect! = scb.affect!
            if display_beforeevent
                affect!.saveiter += 1
                copyat_or_push!(affect!.saved_values.t, affect!.saveiter, integrator.t)
                copyat_or_push!(affect!.saved_values.saveval, affect!.saveiter,
                    affect!.save_func(integrator.u, integrator.t, integrator),Val{false})
            end

            recast!(x, psi_tmp)
            jumpfun(rng, t, psi_tmp, tmp)
            recast!(tmp, x)

            if display_afterevent
                affect!.saveiter += 1
                copyat_or_push!(affect!.saved_values.t, affect!.saveiter, integrator.t)
                copyat_or_push!(affect!.saved_values.saveval, affect!.saveiter,
                    affect!.save_func(integrator.u, integrator.t, integrator),Val{false})
            end
            jumpnorm[] = rand(rng)
        end

        cb = OrdinaryDiffEq.ContinuousCallback(djumpnorm,dojump_display,
                         save_positions = (false,false))
        full_cb = OrdinaryDiffEq.CallbackSet(callback,cb,scb)

        function df_(dx::Vector{ComplexF64}, x::Vector{ComplexF64}, p, t)
            recast!(x, state)
            recast!(dx, dstate)
            dmcwf(t, state, dstate)
            recast!(dstate, dx)
        end

        prob = OrdinaryDiffEq.ODEProblem{true}(df_, x0,(tspan[1],tspan[end]))

        sol = OrdinaryDiffEq.solve(
                    prob,
                    alg;
                    reltol = 1.0e-6,
                    abstol = 1.0e-8,
                    save_everystep = false, save_start = false,
                    save_end = false,
                    callback=full_cb, kwargs...)
        return out.t, out.saveval
    end
end

function integrate_mcwf(dmcwf::Function, jumpfun::Function, tspan,
                        psi0::T, seed, fout::Nothing;
                        kwargs...) where {T<:State}
    function fout_(t::Float64, x::T)
        psi = copy(x)
        normalize!(psi)
        return psi
    end
    integrate_mcwf(dmcwf, jumpfun, tspan, psi0, seed, fout_; kwargs...)
end

end # module
