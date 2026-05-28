# JET.jl static type-stability check.
#
# JET reports calls where a type cannot be inferred (returning `Any` past a
# point where it shouldn't), method-error candidates (typos, missing methods),
# and other inference-time anomalies.
#
# We don't enforce zero reports today — Tables.jl + Dict-of-Any pervade the
# codebase and produce inherently dynamic dispatches. We DO smoke-test that
# JET successfully runs on the package without crashing, and surface a count
# so a sudden spike in dynamic dispatches is visible in CI logs.
#
# When JET stabilizes around a fixed allowlist, this can become a hard
# regression gate (`@test isempty(JET.get_reports(...))`).

using SurrealDB
using Test

# JET dropped Julia 1.9 support in recent releases (StepExpr! ambiguity
# from JuliaInterpreter). Skip the type-stability check on the LTS
# matrix entry — current-stable still gets the gate.
@testset "JET package report (advisory)" begin
    if VERSION < v"1.10"
        @info "skip: JET requires Julia ≥ 1.10"
    else
        @eval using JET
        result = JET.report_package(SurrealDB; toplevel_logger=nothing)
        n = length(JET.get_reports(result))
        @info "JET reports" count=n
        @test n < 200
    end
end
