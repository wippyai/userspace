local mcp_client = require("mcp_client")
local json = require("json")
local time = require("time")
local ctx = require("ctx")

local function execute(base_prompt, context)
    -- Get required context
    local server_id = ctx.get("server_id")
    if not server_id then
        return {
            prompt = base_prompt .. "\n\nMCP integration failed: server_id required in context"
        }
    end

    -- Get optional context with defaults
    local integration_mode = ctx.get("integration_mode") or "individual_tools"
    local tool_prefix = ctx.get("tool_prefix") or ""
    local tool_name = ctx.get("tool_name") or "mcp_tools"
    local selected_tools = ctx.get("selected_tools") -- Array of tool names to include

    -- Connect to MCP server and get tools with schemas
    local client, connect_err = mcp_client.connect(server_id :: string)
    if connect_err then
        return {
            prompt = base_prompt .. "\n\nMCP integration failed: " .. connect_err
        }
    end

    local tools, tools_err = mcp_client.get_tools(client)
    mcp_client.close(client)

    if tools_err then
        return {
            prompt = base_prompt .. "\n\nMCP tool discovery failed: " .. tools_err
        }
    end

    if not tools or #tools == 0 then
        return {
            prompt = base_prompt .. "\n\nMCP server '" .. server_id .. "' has no available tools"
        }
    end

    -- Filter tools if selected_tools is specified
    local filtered_tools = {}
    if selected_tools and #selected_tools > 0 then
        local selected_set = {}
        for _, tool_name in ipairs(selected_tools) do
            selected_set[tool_name] = true
        end

        for _, tool in ipairs(tools) do
            if selected_set[tool.name] then
                table.insert(filtered_tools, tool)
            end
        end

        if #filtered_tools == 0 then
            return {
                prompt = base_prompt .. "\n\nNo matching tools found for selection: " .. table.concat(selected_tools, ", ")
            }
        end
    else
        filtered_tools = tools
    end

    local result_tools = {}
    local tool_descriptions = {}

    if integration_mode == "individual_tools" then
        -- Create single sophisticated tool with REAL MCP schemas per tool
        for _, tool in ipairs(filtered_tools) do
            table.insert(tool_descriptions, "- " .. tool.name .. ": " .. (tool.description or "No description"))
        end

        -- Build schema with real MCP tool schemas
        local tool_enum = {}
        local tool_schemas = {}
        for _, tool in ipairs(filtered_tools) do
            table.insert(tool_enum, tool.name)
            if tool.inputSchema then
                tool_schemas[tool.name] = tool.inputSchema
            end
        end

        table.insert(result_tools, {
            id = "userspace.mcp.traits:individual_tools_caller",
            alias = tool_name,
            description = "Call any MCP tool on server '" .. server_id .. "' with real schema validation",
            context = {
                server_id = server_id,
                tool_schemas = tool_schemas -- Pass real schemas for validation
            },
            schema = {
                type = "object",
                properties = {
                    tool_name = {
                        type = "string",
                        description = "Name of the MCP tool to call",
                        enum = tool_enum
                    },
                    parameters = {
                        type = "object",
                        description = "Parameters matching the selected tool's schema",
                        additionalProperties = true -- Will be validated against real schema in handler
                    }
                },
                required = {"tool_name"}
            }
        })

        local prompt_addition = string.format(
            "\n\nYou have access to MCP server '%s' through the %s tool (individual tools with real schemas). Available tools:\n%s",
            server_id,
            tool_name,
            table.concat(tool_descriptions, "\n")
        )

        return {
            prompt = base_prompt .. prompt_addition,
            tools = result_tools
        }

    elseif integration_mode == "command_caller" then
        -- Create individual command-pattern tools with FLEXIBLE schemas (tool pre-bound in context)
        local schema_documentation = {}

        for _, tool in ipairs(filtered_tools) do
            local tool_alias = tool_prefix .. tool.name

            table.insert(result_tools, {
                id = "userspace.mcp.traits:command_caller",
                alias = tool_alias,
                description = tool.description or ("MCP command tool: " .. tool.name),
                context = {
                    server_id = server_id,
                    tool_name = tool.name -- Tool is pre-bound in context
                },
                schema = {
                    type = "object",
                    properties = {
                        parameters = {
                            type = "object",
                            description = "Parameters for " .. tool.name .. " (flexible schema - tool pre-bound)",
                            additionalProperties = true -- Flexible since tool is pre-bound
                        }
                    }
                }
            })

            -- Enhanced tool documentation for command_caller mode
            local tool_doc = string.format("## %s\n**Function:** %s\n**Description:** %s",
                tool_alias,
                tool.name,
                tool.description or "No description available")

            -- Add schema information if available
            if tool.inputSchema then
                local schema_str = json.encode(tool.inputSchema)
                tool_doc = tool_doc .. "\n**Expected Parameters:**\n```json\n" .. schema_str .. "\n```"
            end

            table.insert(schema_documentation, tool_doc)
            table.insert(tool_descriptions, "- " .. tool_alias .. ": " .. (tool.description or "No description"))
        end

        local prompt_addition = string.format(
            "\n\nYou have access to %d command-pattern tools from MCP server '%s':\n%s\n\n## Tool Documentation\n\n%s",
            #filtered_tools,
            server_id,
            table.concat(tool_descriptions, "\n"),
            table.concat(schema_documentation, "\n\n")
        )

        return {
            prompt = base_prompt .. prompt_addition,
            tools = result_tools
        }

    elseif integration_mode == "unified_tool" then
        -- Create single unified tool using app.mcp:call_tool (legacy mode)
        local available_tools = {}
        for _, tool in ipairs(filtered_tools) do
            table.insert(available_tools, {
                name = tool.name,
                description = tool.description
            })
            table.insert(tool_descriptions, "- " .. tool.name .. ": " .. (tool.description or "No description"))
        end

        table.insert(result_tools, {
            id = "app.mcp:call_tool",
            alias = tool_name,
            description = "Call any tool on MCP server '" .. server_id .. "'",
            context = {
                server_id = server_id,
                available_tools = available_tools
            },
            schema = {
                type = "object",
                properties = {
                    tool_name = {
                        type = "string",
                        description = "Name of the MCP tool to call",
                        enum = (function()
                            local tool_names = {}
                            for _, tool in ipairs(filtered_tools) do
                                table.insert(tool_names, tool.name)
                            end
                            return tool_names
                        end)()
                    },
                    parameters = {
                        type = "object",
                        description = "Parameters to pass to the MCP tool",
                        additionalProperties = true
                    }
                },
                required = {"tool_name"}
            }
        })

        local prompt_addition = string.format(
            "\n\nYou have access to MCP server '%s' through the %s tool (unified legacy mode). Available tools:\n%s",
            server_id,
            tool_name,
            table.concat(tool_descriptions, "\n")
        )

        return {
            prompt = base_prompt .. prompt_addition,
            tools = result_tools
        }

    else
        return {
            prompt = base_prompt .. "\n\nUnknown integration_mode: " .. integration_mode .. ". Supported modes: individual_tools, command_caller, unified_tool"
        }
    end
end

return { execute = execute }