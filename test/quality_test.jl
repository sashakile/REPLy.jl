using Test
using Aqua
using JET

@testset "Aqua" begin
    Aqua.test_all(REPLy;
        ambiguities = true,
        unbound_args = true,
        undefined_exports = true,
        stale_deps = true,
        deps_compat = true,
        piracies = true,
    )
end

@testset "JET" begin
    JET.test_package(REPLy; target_modules = (REPLy,))
end
