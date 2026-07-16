using Test
using Aqua
using JET

@testset "Aqua" begin
    Aqua.test_all(REPLy;
        ambiguities = true,
        unbound_args = true,
        undefined_exports = true,
        # persistent_tasks disabled: REPLy is a path-based dependency (not registered)
        # so the precompilation wrapper can't properly test it. Also, transitive deps
        # like Revise/JET create persistent tasks that block precompilation.
        persistent_tasks = false,
        stale_deps = false,
        deps_compat = true,
        piracies = true,
    )
end

@testset "JET" begin
    JET.test_package(REPLy; target_modules = (REPLy,))
end
