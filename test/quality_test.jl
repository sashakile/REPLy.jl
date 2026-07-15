using Test
using Aqua
using JET

@testset "Aqua" begin
    Aqua.test_all(REPLy;
        ambiguities = true,
        unbound_args = true,
        undefined_exports = true,
        # stale_deps disabled: Scratch is a [deps] used by deps/build.jl, not by
        # REPLy's source code, so Aqua flags it as stale. Available Aqua v0.8
        # does not support `ignore` kwarg to exclude it.
        stale_deps = false,
        deps_compat = true,
        piracies = true,
    )
end

@testset "JET" begin
    JET.test_package(REPLy; target_modules = (REPLy,))
end
