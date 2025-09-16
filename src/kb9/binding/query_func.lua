local ctx = require("ctx")
local json = require("json")
local store = require("store")
local contract = require("contract")
local llm = require("llm")
local consts = require("consts")

local function handle(request_dto)
    local component_id, err = ctx.get("component_id")
    if err then
        return {
            success = false,
            items = {},
            count = 0
        }
    end

    if not request_dto or type(request_dto) ~= "table" then
        return {
            success = false,
            items = {},
            count = 0
        }
    end

    if not request_dto.query or type(request_dto.query) ~= "string" or request_dto.query == "" then
        return {
            success = false,
            items = {},
            count = 0
        }
    end

    local component, err = store.get_component(component_id)
    if err then
        return {
            success = false,
            items = {},
            count = 0
        }
    end

    local config = component.config
    if type(config) == "string" then
        local parsed_config, parse_err = json.decode(config)
        if not parse_err then
            config = parsed_config
        end
    end

    if not config or not config.embedding_model or not config.query_contract then
        return {
            success = false,
            error = "Component is not properly configured",
            items = {},
            count = 0
        }
    end

    local embed_response, err = llm.embed({ request_dto.query }, {
        model = config.embedding_model,
        dimensions = consts.VECTOR_DIMENSIONS
    })

    if err or not embed_response.result or #embed_response.result == 0 then
        return {
            success = false,
            error = err or "Failed to get embedding",
            items = {},
            count = 0
        }
    end

    local input_vector = embed_response.result[1]
    if not input_vector then
        return {
            success = false,
            items = {},
            count = 0
        }
    end

    local query_contract_def, err = contract.get("userspace.kb9:kb9_query_contract")
    if err then
        return {
            success = false,
            items = {},
            count = 0
        }
    end

    local query_instance, err = query_contract_def:open(
        config.query_contract.binding_id,
        { component_id = component_id }
    )
    if err then
        return {
            success = false,
            items = {},
            count = 0
        }
    end

    local merged_options = config.query_contract.options or {}
    if request_dto.options then
        for k, v in pairs(request_dto.options) do
            merged_options[k] = v
        end
    end

    local query_request = {
        query = request_dto.query,
        input_vector = input_vector,
        embedding_model = config.embedding_model,
        limit = request_dto.limit or 10,
        options = merged_options
    }

    local query_result, err = query_instance:query(query_request)
    if err then
        return {
            success = false,
            items = {},
            count = 0
        }
    end

    if not query_result.success then
        return {
            success = false,
            items = {},
            count = 0
        }
    end

    -- Transform to universal queryable format
    local universal_items = {}
    for _, item in ipairs(query_result.items or {}) do
        table.insert(universal_items, {
            id = item.id,
            content = item.content,
            meta = {
                similarity = item.similarity,
                node_type = item.node_type,
                path = item.path,
                parent_id = item.parent_id,
                content_type = item.content_type,
                created_at = item.created_at,
                updated_at = item.updated_at,
                metadata = item.metadata,
                vector_distance = item.vector_distance
            }
        })
    end

    return {
        success = true,
        items = universal_items,
        count = query_result.count or #universal_items
    }
end

return { handle = handle }
