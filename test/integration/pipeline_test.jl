@testset "integration: tracer bullet pipeline" begin
    request = Dict(
        "op" => "eval",
        "id" => "integration-1",
        "code" => "println(\"hello\"); 1 + 1",
    )

    handler = REPLy.build_handler()
    msgs = handler(request)

    assert_conformance(msgs, request["id"])
    @test any(get(msg, "value", nothing) == "2" for msg in msgs)
end
