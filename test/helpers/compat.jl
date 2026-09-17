# Cross-version test helpers.
#
# Julia 1.11 added Base.isexecutable; on 1.10 it does not exist, so provide a
# plain-function fallback (defined in Main, where the test files run) that the
# build tests use to check launcher permissions. Guarded so 1.11+ keeps using
# the Base definition rather than shadowing it.

if !isdefined(Base, :isexecutable)
    function isexecutable(path::AbstractString)
        try
            isfile(path) && (stat(path).mode & 0o111) != 0
        catch
            false
        end
    end
end
