module OptiMimi

using NLopt
using ForwardDiff
using MathProgBase
using Compat

import Mimi: Model, CertainScalarParameter, CertainArrayParameter, addparameter

export problem, solution, unaryobjective, objevals, setparameters, nameindexes

include("registerdiff.jl")
include("matrixconstraints.jl")
include("linproghouse.jl")

allverbose = false
objevals = 0

type OptimizationProblem
    model::Model
    components::Vector{Symbol}
    names::Vector{Symbol}
    opt::Opt
    constraints::Vector{Function}
end

type LinprogOptimizationProblem{T}
    model::Model
    components::Vector{Symbol}
    names::Vector{Symbol}
    objective::Function
    objectiveconstraints::Vector{Function}
    matrixconstraints::Vector{MatrixConstraintSet}
    exlowers::Vector{T}
    exuppers::Vector{T}
end

"""Returns (ii, len, isscalar) with the index of each symbol and its length."""
function nameindexes(model::Model, names::Vector{Symbol})
    ii = 1
    for name in names
        if isa(model.parameters[name], CertainScalarParameter)
            produce((ii, 1, true))
        elseif isa(model.parameters[name], CertainArrayParameter)
            produce((ii, length(model.parameters[name].values), false))
        else
            error("Unknown parameter type for " + string(name))
        end
        ii += 1
    end
end

"""Set parameters in a model."""
function setparameters(model::Model, components::Vector{Symbol}, names::Vector{Symbol}, xx::Vector)
    startindex = 1
    for (ii, len, isscalar) in @task nameindexes(model, names)
        if isscalar
            model.components[components[ii]].Parameters.(names[ii]) = xx[startindex]
        else
            shape = size(model.components[components[ii]].Parameters.(names[ii]))
            model.components[components[ii]].Parameters.(names[ii]) = reshape(collect(Number, xx[startindex:(startindex+len - 1)]), shape)
        end
        startindex += len
    end
end

"""Generate the form of objective function used by the optimization, taking parameters rather than a model."""
function unaryobjective(model::Model, components::Vector{Symbol}, names::Vector{Symbol}, objective::Function)
    function my_objective(xx::Vector)
        if allverbose
            println(xx)
        end

        global objevals
        objevals += 1

        setparameters(model, components, names, xx)
        run(model)
        objective(model)
    end

    my_objective
end

"""Create an NLopt-style objective function which does not use its grad argument."""
function gradfreeobjective(model::Model, components::Vector{Symbol}, names::Vector{Symbol}, objective::Function)
    myunaryobjective = unaryobjective(model, components, names, objective)
    function myobjective(xx::Vector, grad::Vector)
        myunaryobjective(xx)
    end

    myobjective
end

"""Create an NLopt-style objective function which computes an autodiff gradient."""
function autodiffobjective(model::Model, components::Vector{Symbol}, names::Vector{Symbol}, objective::Function)
    myunaryobjective = unaryobjective(model, components, names, objective)
    if VERSION < v"0.4.0-dev"
        # Slower: doesn't use cache
        function myobjective(xx::Vector, gradout::Vector)
            gradual = myunaryobjective(GraDual(xx))
            copy!(gradout, grad(gradual))
            value(gradual)
        end
    else
        function myobjective(xx::Vector, grad::Vector)
            out = GradientResult(xx)
            ForwardDiff.gradient!(out, myunaryobjective, xx)
            if any(isnan(ForwardDiff.gradient(out)))
                error("objective gradient is NaN")
            end
            copy!(grad, ForwardDiff.gradient(out))
            ForwardDiff.value(out)
        end
    end

    myobjective
end

"""Create a 0 point."""
function make0(model::Model, names::Vector{Symbol})
    initial = Float64[]
    for (ii, len, isscalar) in @task nameindexes(model, names)
        append!(initial, [0. for jj in 1:len])
    end

    initial
end


"""Setup an optimization problem."""
function problem{T<:Real}(model::Model, components::Vector{Symbol}, names::Vector{Symbol}, lowers::Vector{T}, uppers::Vector{T}, objective::Function; constraints::Vector{Function}=Function[], algorithm::Symbol=:LN_COBYLA_OR_LD_MMA)
    my_lowers = T[]
    my_uppers = T[]

    ## Replace with eachname
    totalvars = 0
    for (ii, len, isscalar) in @task nameindexes(model, names)
        append!(my_lowers, [lowers[ii] for jj in 1:len])
        append!(my_uppers, [uppers[ii] for jj in 1:len])
        totalvars += len
    end

    if algorithm == :GUROBI_LINPROG
        # Make no changes to objective!
    elseif model.numberType == Number
        if algorithm == :LN_COBYLA_OR_LD_MMA
            algorithm = :LD_MMA
        end
        if string(algorithm)[2] == 'N'
            warn("Model is autodifferentiable, but optimizing using a derivative-free algorithm.")
            myobjective = gradfreeobjective(model, components, names, objective)
        else
            println("Using AutoDiff objective.")
            myobjective = autodiffobjective(model, components, names, objective)
        end
    else
        if algorithm == :LN_COBYLA_OR_LD_MMA
            algorithm = :LN_COBYLA
        elseif string(algorithm)[2] == 'D'
            warn("Model is non-differentiable, but requested a gradient algorithm; instead using LN_COBYLA.")
            algorithm = :LN_COBYLA
        end

        myobjective = gradfreeobjective(model, components, names, objective)
    end

    if algorithm == :GUROBI_LINPROG
        LinprogOptimizationProblem(model, components, names, objective, constraints, MatrixConstraintSet[], my_lowers, my_uppers)
    else
        opt = Opt(algorithm, totalvars)
        lower_bounds!(opt, my_lowers)
        upper_bounds!(opt, my_uppers)
        xtol_rel!(opt, minimum(1e-6 * (uppers - lowers)))

        max_objective!(opt, myobjective)

        for constraint in constraints
            let this_constraint = constraint
                function my_constraint(xx::Vector, grad::Vector)
                    setparameters(model, components, names, xx)
                    this_constraint(model)
                end

                inequality_constraint!(opt, my_constraint)
            end
        end

        OptimizationProblem(model, components, names, opt, constraints)
    end
end

"""Solve an optimization problem."""
function solution(optprob::OptimizationProblem, generator::Function; maxiter=Inf, verbose=false)
    global allverbose
    allverbose = verbose

    if verbose
        println("Selecting an initial point.")
    end

    attempts = 0
    initial = []
    valid = false
    while attempts < maxiter
        initial = generator()

        setparameters(optprob.model, optprob.components, optprob.names, initial)

        valid = true
        for constraint in optprob.constraints
            if constraint(optprob.model) >= 0
                valid = false
                break
            end
        end

        if valid
            break
        end

        attempts += 1
        if attempts % 1000 == 0
            println("Could not find initial point after $attempts attempts.")
        end
    end

    if !valid
        throw(DomainError("Could not find a valid initial value."))
    end

    if verbose
        println("Optimizing...")
    end
    (minf,minx,ret) = optimize(optprob.opt, initial)

    (minf, minx)
end

"""Setup an optimization problem."""
function problem{T<:Real}(model::Model, components::Vector{Symbol}, names::Vector{Symbol}, lowers::Vector{T}, uppers::Vector{T}, objective::Function, objectiveconstraints::Vector{Function}, matrixconstraints::Vector{MatrixConstraintSet})
    my_lowers = T[]
    my_uppers = T[]

    ## Replace with eachname
    totalvars = 0
    for (ii, len, isscalar) in @task nameindexes(model, names)
        append!(my_lowers, [lowers[ii] for jj in 1:len])
        append!(my_uppers, [uppers[ii] for jj in 1:len])
        totalvars += len
    end

    LinprogOptimizationProblem(model, components, names, objective, objectiveconstraints, matrixconstraints, my_lowers, my_uppers)
end

"""Solve an optimization problem."""
function solution(optprob::LinprogOptimizationProblem, verbose=false)
    global allverbose
    allverbose = verbose

    initial = make0(optprob.model, optprob.names)

    if verbose
        println("Optimizing...")
    end

    if optprob.model.numberType == Number
        myobjective = unaryobjective(optprob.model, optprob.components, optprob.names, optprob.objective)
        f, b, A = lpconstraints(optprob.model, optprob.components, optprob.names, myobjective, objectiveconstraints)
    else
        f, b, A = lpconstraints(optprob.model, optprob.components, optprob.names, optprob.objective, optprob.objectiveconstraints)
    end

    f, b, A = combineconstraints(f, b, A, optprob.model, optprob.components, optprob.names, optprob.matrixconstraints)
    exlowers, exuppers = combinelimits(optprob.exlowers, optprob.exuppers, optprob.model, optprob.components, optprob.names, optprob.matrixconstraints)

    # Use -f, because linprog *minimizes* objective
    @time sol = linprog(-f, A, '<', b, optprob.exlowers, optprob.exuppers)

    sol.sol
end

end # module
