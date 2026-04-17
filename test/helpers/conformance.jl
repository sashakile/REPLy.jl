function assert_conformance(msgs::Vector{Dict}, request_id::String)
    @test !isempty(msgs)
    @test all(get(msg, "id", nothing) == request_id for msg in msgs)

    done_indexes = findall(msg -> haskey(msg, "status") && ("done" in msg["status"]), msgs)
    @test length(done_indexes) == 1
    done_index = only(done_indexes)
    @test done_index == length(msgs)

    out_indexes = findall(msg -> haskey(msg, "out"), msgs)
    stderr_chunk_indexes = findall(msg -> haskey(msg, "err") && !haskey(msg, "status"), msgs)
    value_indexes = findall(msg -> haskey(msg, "value"), msgs)

    if !isempty(value_indexes)
        @test maximum(value_indexes) < done_index
    end

    if !isempty(out_indexes) && !isempty(value_indexes)
        @test maximum(out_indexes) < minimum(value_indexes)
    end

    if !isempty(stderr_chunk_indexes) && !isempty(value_indexes)
        @test maximum(stderr_chunk_indexes) < minimum(value_indexes)
    end

    for (index, msg) in pairs(msgs)
        key_strings = String.(collect(keys(msg)))
        @test all(!occursin("_", key) for key in key_strings)

        if haskey(msg, "err") && !haskey(msg, "status")
            @test index < done_index
        end

        if haskey(msg, "status") && ("error" in msg["status"])
            @test haskey(msg, "err")
        end
    end
end
