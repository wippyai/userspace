local json = require("json")
local contract = require("contract")
local registry = require("registry")

-- Helper function to get implementation schema and validate options
local function validate_implementation_options(binding_id, provided_options, implementation_type)
    -- Get the registry entry for this implementation
    local entry, err = registry.get(binding_id)
    if not entry then
        return false, "Failed to get registry entry for " .. binding_id .. ": " .. (err or "unknown error")
    end

    -- Check if it has kb9_plugin metadata
    if not entry.meta or not entry.meta.kb9_plugin or not entry.meta.kb9_plugin.options_schema then
        return false, "Implementation " .. binding_id .. " does not have a valid options schema"
    end

    local schema = entry.meta.kb9_plugin.options_schema
    local required_fields = schema.required or {}

    -- If no required fields, validation passes
    if #required_fields == 0 then
        return true, nil
    end

    -- Check each required field
    local missing_fields = {}
    for _, field in ipairs(required_fields) do
        if not provided_options or not provided_options[field] or
           (type(provided_options[field]) == "string" and provided_options[field]:gsub("%s+", "") == "") then
            table.insert(missing_fields, field)
        end
    end

    if #missing_fields > 0 then
        local impl_name = entry.meta.kb9_plugin.name or binding_id
        return false, string.format(
            "%s (%s) requires the following options: %s. Missing: %s",
            impl_name,
            implementation_type,
            table.concat(required_fields, ", "),
            table.concat(missing_fields, ", ")
        ), {
            implementation = impl_name,
            binding_id = binding_id,
            required_fields = required_fields,
            missing_fields = missing_fields,
            provided_options = provided_options or {}
        }
    end

    return true, nil
end

local function handle(args)
    args = args or {}

    -- Validate required fields
    if not args.name or type(args.name) ~= "string" or args.name:gsub("%s+", "") == "" then
        return {
            success = false,
            error = "Name is required and must be a non-empty string"
        }
    end

    if not args.embedding_model or type(args.embedding_model) ~= "string" or args.embedding_model:gsub("%s+", "") == "" then
        return {
            success = false,
            error = "Embedding model is required and must be a non-empty string"
        }
    end

    if not args.embed_implementation or type(args.embed_implementation) ~= "string" then
        return {
            success = false,
            error = "Embed implementation binding ID is required"
        }
    end

    if not args.query_implementation or type(args.query_implementation) ~= "string" then
        return {
            success = false,
            error = "Query implementation binding ID is required"
        }
    end

    -- Validate embed implementation options
    local embed_valid, embed_error, embed_details = validate_implementation_options(
        args.embed_implementation,
        args.embed_options,
        "embed implementation"
    )
    if not embed_valid then
        return {
            success = false,
            error = embed_error,
            details = embed_details,
            validation_failed = "embed_options"
        }
    end

    -- Validate query implementation options
    local query_valid, query_error, query_details = validate_implementation_options(
        args.query_implementation,
        args.query_options,
        "query implementation"
    )
    if not query_valid then
        return {
            success = false,
            error = query_error,
            details = query_details,
            validation_failed = "query_options"
        }
    end

    -- Prepare configuration
    local config = {
        embed_contract = {
            binding_id = args.embed_implementation,
            options = args.embed_options or {}
        },
        query_contract = {
            binding_id = args.query_implementation,
            options = args.query_options or {}
        }
    }

    -- Prepare request for KB service
    local create_request = {
        name = args.name,
        description = args.description,
        embedding_model = args.embedding_model,
        config = config
    }

    -- Get KB service contract
    local kb_service_contract, contract_err = contract.get("userspace.kb9:kb_service_contract")
    if contract_err then
        return {
            success = false,
            error = "Failed to get KB service contract: " .. contract_err
        }
    end

    -- Open the service instance
    local kb_service, service_err = kb_service_contract:open()
    if service_err then
        return {
            success = false,
            error = "Failed to open KB service: " .. service_err
        }
    end

    -- Create the KB9 knowledge base
    local result, call_err = kb_service:create_kb9(create_request)
    if call_err then
        return {
            success = false,
            error = "Failed to create KB9: " .. call_err
        }
    end

    -- Check if the service returned an error
    if not result.success then
        return {
            success = false,
            error = result.error and result.error.message or "KB creation failed",
            details = result.error
        }
    end

    -- Return success with enhanced response
    return {
        success = true,
        component_id = result.component_id,
        name = result.name,
        description = result.description,
        embedding_model = args.embedding_model,
        configuration = {
            embed_implementation = args.embed_implementation,
            embed_options = args.embed_options or {},
            query_implementation = args.query_implementation,
            query_options = args.query_options or {}
        },
        created_at = result.created_at,
        initialization = result.initialization,
        message = "Successfully created KB9 knowledge base: " .. result.name
    }
end

return { handle = handle }