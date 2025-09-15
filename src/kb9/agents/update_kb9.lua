local json = require("json")
local component = require("component")
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

    -- Validate required KB ID
    if not args.kb_id or type(args.kb_id) ~= "string" or args.kb_id:gsub("%s+", "") == "" then
        return {
            success = false,
            error = "KB ID is required and must be a non-empty string"
        }
    end

    -- Check if we have any updates to make
    local has_updates = args.embedding_model or args.embed_implementation or args.embed_options or
                       args.query_implementation or args.query_options

    if not has_updates then
        return {
            success = false,
            error = "At least one configuration field must be provided to update"
        }
    end

    -- Handle embedding model updates (currently not supported)
    if args.embedding_model then
        return {
            success = false,
            error = "Changing embedding model is not currently supported - this would require re-embedding all existing content",
            suggestion = "Create a new KB with the desired embedding model and migrate content manually"
        }
    end

    -- Validate embed implementation options if being updated
    if args.embed_implementation then
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
    end

    -- Validate query implementation options if being updated
    if args.query_implementation then
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
    end

    -- Validate that if options are provided without implementation, that's an error
    if args.embed_options and not args.embed_implementation then
        return {
            success = false,
            error = "embed_implementation is required when updating embed_options"
        }
    end

    if args.query_options and not args.query_implementation then
        return {
            success = false,
            error = "query_implementation is required when updating query_options"
        }
    end

    -- Open the KB9 component with write access
    local kb9_instance, open_err = component.open(args.kb_id, component.ACCESS.WRITE, "userspace.kb9:kb9_contract")
    if not kb9_instance then
        return {
            success = false,
            error = "Failed to open KB9 component: " .. (open_err or "unknown error"),
            details = {
                kb_id = args.kb_id,
                access_required = "WRITE",
                contract = "userspace.kb9:kb9_contract"
            }
        }
    end

    -- Build update configuration
    local update_config = {}

    -- Handle embed contract updates
    if args.embed_implementation then
        update_config.embed_contract = {
            binding_id = args.embed_implementation,
            options = args.embed_options or {}
        }
    end

    -- Handle query contract updates
    if args.query_implementation then
        update_config.query_contract = {
            binding_id = args.query_implementation,
            options = args.query_options or {}
        }
    end

    -- Perform the configuration update
    local result, update_err = kb9_instance:update_config(update_config)
    if update_err then
        return {
            success = false,
            error = "Failed to update KB9 configuration: " .. update_err,
            details = {
                kb_id = args.kb_id,
                update_config = update_config
            }
        }
    end

    -- Check if the service returned an error
    if not result.success then
        return {
            success = false,
            error = result.error and result.error.message or "Configuration update failed",
            details = result.error
        }
    end

    -- Return success response
    local response = {
        success = true,
        kb_id = args.kb_id,
        updated_fields = {},
        message = "Successfully updated KB9 configuration"
    }

    -- Track what was updated
    if update_config.embed_contract then
        response.updated_fields.embed_implementation = args.embed_implementation
        if args.embed_options then
            response.updated_fields.embed_options = args.embed_options
        end
    end

    if update_config.query_contract then
        response.updated_fields.query_implementation = args.query_implementation
        if args.query_options then
            response.updated_fields.query_options = args.query_options
        end
    end

    -- Include any additional result info
    if result.commands_sent then
        response.commands_sent = result.commands_sent
    end
    if result.acks_received then
        response.acks_received = result.acks_received
    end
    if result.errors then
        response.warnings = result.errors
    end

    return response
end

return { handle = handle }