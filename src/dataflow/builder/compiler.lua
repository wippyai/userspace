local json = require("json")
local uuid = require("uuid")
local consts = require("consts")

local compiler = {}

-- Flow operation types
compiler.OP_TYPES = {
    WITH_INPUT = "with_input",
    TRANSFORM = "transform",
    FUNC = "func",
    AGENT = "agent",
    CYCLE = "cycle",
    PARALLEL = "parallel",
    MAP_REDUCE = "map_reduce",
    USE = "use",
    AS = "as",
    TO = "to",
    ERROR_TO = "error_to",
    WHEN = "when"
}

-- Internal graph representation
local FlowGraph = {}
local flow_graph_mt = { __index = FlowGraph }

function FlowGraph.new()
    return setmetatable({
        operations = {},          -- Sequential operations as added
        nodes = {},              -- node_id -> node_definition
        node_order = {},         -- Array to maintain creation order
        edges = {},              -- node_id -> {targets = {}, error_targets = {}}
        references = {},         -- name -> node_id mapping
        input_data = nil,        -- Initial input
        current_transform = nil, -- Pending transform for next node
        last_node_id = nil,     -- Last created node for chaining
        pending_routes = {},     -- Routes waiting for target resolution
        has_explicit_routing = false, -- Whether explicit routing has been used
        session_parent_id = nil  -- Parent node ID from session context
    }, flow_graph_mt)
end

function FlowGraph:add_operation(op_type, config)
    table.insert(self.operations, {
        type = op_type,
        config = config or {}
    })
    return self, nil
end

function FlowGraph:create_node(node_type, config, metadata)
    local node_id = uuid.v7()

    self.nodes[node_id] = {
        node_id = node_id,
        node_type = node_type,
        config = config or {},
        metadata = metadata or {},
        status = consts.STATUS.PENDING
    }

    -- Track node creation order
    table.insert(self.node_order, node_id)

    self.edges[node_id] = {
        targets = {},
        error_targets = {}
    }

    -- Auto-chain sequential nodes unless explicit routing is used
    if not self.has_explicit_routing and self.last_node_id then
        -- Create automatic routing from last node to this node
        table.insert(self.edges[self.last_node_id].targets, {
            target_node_id = node_id,
            condition = nil
        })
    end

    self.last_node_id = node_id
    return node_id, nil
end

function FlowGraph:create_template_nodes(template, parent_node_id)
    if not template or not template.operations then
        return {}
    end

    local template_node_ids = {}
    local last_template_node_id = nil

    for _, op in ipairs(template.operations) do
        if op.type == compiler.OP_TYPES.FUNC then
            local template_node_id = uuid.v7()

            local config = {
                func_id = op.config.func_id,
                context = op.config.context
            }

            -- Chain template nodes: connect previous to current
            if last_template_node_id then
                config.data_targets = config.data_targets or {}
                table.insert(config.data_targets, {
                    data_type = consts.DATA_TYPE.NODE_INPUT,
                    node_id = template_node_id,
                    key = "default"
                })

                -- Update previous node's config to route to this node
                if not self.nodes[last_template_node_id].config.data_targets then
                    self.nodes[last_template_node_id].config.data_targets = {}
                end
                table.insert(self.nodes[last_template_node_id].config.data_targets, {
                    data_type = consts.DATA_TYPE.NODE_INPUT,
                    node_id = template_node_id,
                    key = "default"
                })
            end

            local metadata = op.config.metadata or {}

            -- Add to main nodes table
            self.nodes[template_node_id] = {
                node_id = template_node_id,
                node_type = "userspace.dataflow.node.func:node",
                config = config,
                metadata = metadata,
                status = consts.STATUS.TEMPLATE,
                parent_node_id = parent_node_id
            }

            -- Initialize edges
            self.edges[template_node_id] = {
                targets = {},
                error_targets = {}
            }

            table.insert(self.node_order, template_node_id)
            table.insert(template_node_ids, template_node_id)
            last_template_node_id = template_node_id

        elseif op.type == compiler.OP_TYPES.AGENT then
            local template_node_id = uuid.v7()

            local config = {
                agent = op.config.agent_id,
                arena = op.config.arena,
                inputs = op.config.inputs,
                show_tool_calls = op.config.show_tool_calls
            }

            -- Chain template nodes: connect previous to current
            if last_template_node_id then
                -- Update previous node's config to route to this node
                if not self.nodes[last_template_node_id].config.data_targets then
                    self.nodes[last_template_node_id].config.data_targets = {}
                end
                table.insert(self.nodes[last_template_node_id].config.data_targets, {
                    data_type = consts.DATA_TYPE.NODE_INPUT,
                    node_id = template_node_id,
                    key = "default"
                })
            end

            local metadata = op.config.metadata or {}

            -- Add to main nodes table
            self.nodes[template_node_id] = {
                node_id = template_node_id,
                node_type = "userspace.dataflow.node.agent:node",
                config = config,
                metadata = metadata,
                status = consts.STATUS.TEMPLATE,
                parent_node_id = parent_node_id
            }

            -- Initialize edges
            self.edges[template_node_id] = {
                targets = {},
                error_targets = {}
            }

            table.insert(self.node_order, template_node_id)
            table.insert(template_node_ids, template_node_id)
            last_template_node_id = template_node_id

        elseif op.type == compiler.OP_TYPES.PARALLEL then
            local template_node_id = uuid.v7()

            -- Create state collection node as template
            self.nodes[template_node_id] = {
                node_id = template_node_id,
                node_type = "userspace.dataflow.node.state:state",
                config = {},
                metadata = { title = "Parallel State Collection", parallel_collection = true },
                status = consts.STATUS.TEMPLATE,
                parent_node_id = parent_node_id
            }

            -- Initialize edges
            self.edges[template_node_id] = {
                targets = {},
                error_targets = {}
            }

            table.insert(self.node_order, template_node_id)
            table.insert(template_node_ids, template_node_id)

            -- Create parallel branch nodes as templates
            for branch_key, branch_func_id in pairs(op.config.branches) do
                local branch_node_id = uuid.v7()

                self.nodes[branch_node_id] = {
                    node_id = branch_node_id,
                    node_type = "userspace.dataflow.node.func:node",
                    config = {
                        func_id = branch_func_id,
                        data_targets = {
                            {
                                data_type = consts.DATA_TYPE.NODE_INPUT,
                                node_id = template_node_id,
                                key = branch_key
                            }
                        }
                    },
                    metadata = { title = "Parallel Branch: " .. branch_key, parallel_branch = branch_key },
                    status = consts.STATUS.TEMPLATE,
                    parent_node_id = parent_node_id
                }

                -- Initialize edges
                self.edges[branch_node_id] = {
                    targets = {},
                    error_targets = {}
                }

                table.insert(self.node_order, branch_node_id)
                table.insert(template_node_ids, branch_node_id)
            end

            last_template_node_id = template_node_id
        end
    end

    -- CRITICAL: Route final template node output back to parent for map-reduce collection
    if last_template_node_id then
        if not self.nodes[last_template_node_id].config.data_targets then
            self.nodes[last_template_node_id].config.data_targets = {}
        end
        table.insert(self.nodes[last_template_node_id].config.data_targets, {
            data_type = consts.DATA_TYPE.NODE_OUTPUT,
            node_id = parent_node_id,
            key = "iteration_result"
        })
    end

    return template_node_ids
end

function FlowGraph:add_reference(name, node_id)
    if self.references[name] then
        return nil, "Duplicate node name: " .. name
    end
    self.references[name] = node_id
    return true, nil
end

function FlowGraph:resolve_reference(name)
    local node_id = self.references[name]
    if not node_id then
        return nil, "Undefined node reference: " .. name
    end
    return node_id, nil
end

function FlowGraph:add_edge(from_node_id, to_node_id, condition, is_error)
    local edge_list = is_error and self.edges[from_node_id].error_targets or self.edges[from_node_id].targets
    table.insert(edge_list, {
        target_node_id = to_node_id,
        condition = condition
    })
    return true, nil
end

function FlowGraph:detect_cycles()
    local visited = {}
    local rec_stack = {}

    local function dfs(node_id, path)
        if rec_stack[node_id] then
            local cycle_start = nil
            for i, id in ipairs(path) do
                if id == node_id then
                    cycle_start = i
                    break
                end
            end

            if cycle_start then
                local cycle = {}
                for i = cycle_start, #path do
                    table.insert(cycle, path[i])
                end
                table.insert(cycle, node_id)
                return true, "Cycle detected: " .. table.concat(cycle, " -> ")
            end
            return true, "Cycle detected at node: " .. node_id
        end

        if visited[node_id] then
            return false, nil
        end

        visited[node_id] = true
        rec_stack[node_id] = true
        table.insert(path, node_id)

        local edges = self.edges[node_id]
        if edges then
            for _, edge in ipairs(edges.targets) do
                local has_cycle, cycle_desc = dfs(edge.target_node_id, path)
                if has_cycle then
                    return true, cycle_desc
                end
            end
            for _, edge in ipairs(edges.error_targets) do
                local has_cycle, cycle_desc = dfs(edge.target_node_id, path)
                if has_cycle then
                    return true, cycle_desc
                end
            end
        end

        rec_stack[node_id] = false
        table.remove(path)
        return false, nil
    end

    for node_id, _ in pairs(self.nodes) do
        if not visited[node_id] then
            local has_cycle, cycle_desc = dfs(node_id, {})
            if has_cycle then
                return true, cycle_desc
            end
        end
    end

    return false, nil
end

-- Build graph from operations
function compiler.build_graph(operations, session_context)
    if not operations or #operations == 0 then
        return nil, "No operations provided"
    end

    local graph = FlowGraph.new()

    -- Set session parent if we're in a session context
    if session_context and session_context.node_id then
        graph.session_parent_id = session_context.node_id
    end

    for _, op in ipairs(operations) do
        if op.type == compiler.OP_TYPES.WITH_INPUT then
            graph.input_data = op.config.data

        elseif op.type == compiler.OP_TYPES.TRANSFORM then
            graph.current_transform = op.config.expression

        elseif op.type == compiler.OP_TYPES.FUNC then
            local config = {
                func_id = op.config.func_id,
                context = op.config.context
            }

            -- Apply pending transform
            if graph.current_transform then
                config.input_transform = graph.current_transform
                graph.current_transform = nil
            end

            local node_id, err = graph:create_node("userspace.dataflow.node.func:node", config, op.config.metadata)
            if err then
                return nil, err
            end

        elseif op.type == compiler.OP_TYPES.AGENT then
            local config = {
                agent = op.config.agent_id,
                arena = op.config.arena,
                inputs = op.config.inputs,
                show_tool_calls = op.config.show_tool_calls
            }

            -- Apply pending transform
            if graph.current_transform then
                config.input_transform = graph.current_transform
                graph.current_transform = nil
            end

            local node_id, err = graph:create_node("userspace.dataflow.node.agent:node", config, op.config.metadata)
            if err then
                return nil, err
            end

        elseif op.type == compiler.OP_TYPES.CYCLE then
            local config = {
                func_id = op.config.func_id,
                continue_condition = op.config.continue_condition,
                max_iterations = op.config.max_iterations,
                initial_state = op.config.initial_state,
                context = op.config.context
            }

            -- Apply pending transform
            if graph.current_transform then
                config.input_transform = graph.current_transform
                graph.current_transform = nil
            end

            local node_id, err = graph:create_node("userspace.dataflow.node.cycle:cycle", config, op.config.metadata)
            if err then
                return nil, err
            end

            -- Create template nodes if template is provided
            if op.config.template then
                graph:create_template_nodes(op.config.template, node_id)
            end

        elseif op.type == compiler.OP_TYPES.PARALLEL then
            -- Create parallel execution with state collection
            local parallel_branches = op.config.branches
            local state_node_id, err = graph:create_node("userspace.dataflow.node.state:state", {}, {
                title = "Parallel State Collection",
                parallel_collection = true
            })
            if err then
                return nil, err
            end

            -- Apply pending transform to state node
            if graph.current_transform then
                graph.nodes[state_node_id].config.input_transform = graph.current_transform
                graph.current_transform = nil
            end

            local branch_nodes = {}
            for branch_key, branch_func_id in pairs(parallel_branches) do
                local branch_node_id, branch_err = graph:create_node("userspace.dataflow.node.func:node", {
                    func_id = branch_func_id,
                    data_targets = {
                        {
                            data_type = consts.DATA_TYPE.NODE_INPUT,
                            node_id = state_node_id,
                            key = branch_key
                        }
                    }
                }, {
                    title = "Parallel Branch: " .. branch_key,
                    parallel_branch = branch_key
                })
                if branch_err then
                    return nil, branch_err
                end
                branch_nodes[branch_key] = branch_node_id
            end

            -- Set last node to state collection node
            graph.last_node_id = state_node_id

        elseif op.type == compiler.OP_TYPES.MAP_REDUCE then
            local config = {
                source_array_key = op.config.source_array_key,
                iteration_input_key = op.config.iteration_input_key,
                batch_size = op.config.batch_size,
                failure_strategy = op.config.failure_strategy,
                item_steps = op.config.item_steps,
                reduction_extract = op.config.reduction_extract,
                reduction_steps = op.config.reduction_steps
            }

            -- Apply pending transform
            if graph.current_transform then
                config.input_transform = graph.current_transform
                graph.current_transform = nil
            end

            local node_id, err = graph:create_node("userspace.dataflow.node.map_reduce:map_reduce", config, op.config.metadata)
            if err then
                return nil, err
            end

            -- Create template nodes if template is provided
            if op.config.template then
                graph:create_template_nodes(op.config.template, node_id)
            end

        elseif op.type == compiler.OP_TYPES.USE then
            -- For now, inline template operations (simplified)
            if op.config.operations then
                for _, template_op in ipairs(op.config.operations) do
                    table.insert(graph.operations, template_op)
                end
            end

        elseif op.type == compiler.OP_TYPES.AS then
            if not graph.last_node_id then
                return nil, "Cannot name node: no previous node to name"
            end
            local success, err = graph:add_reference(op.config.name, graph.last_node_id)
            if err then
                return nil, err
            end

        elseif op.type == compiler.OP_TYPES.TO then
            if not graph.last_node_id then
                return nil, "Cannot add route: no source node"
            end
            -- Stop auto-chaining when explicit routing is used
            graph.has_explicit_routing = true
            table.insert(graph.pending_routes, {
                from_node_id = graph.last_node_id,
                target_name = op.config.target,
                is_error = false,
                condition = nil -- Will be set by pending conditions
            })

        elseif op.type == compiler.OP_TYPES.ERROR_TO then
            if not graph.last_node_id then
                return nil, "Cannot add error route: no source node"
            end
            -- Stop auto-chaining when explicit routing is used
            graph.has_explicit_routing = true
            table.insert(graph.pending_routes, {
                from_node_id = graph.last_node_id,
                target_name = op.config.target,
                is_error = true,
                condition = nil -- Will be set by pending conditions
            })

        elseif op.type == compiler.OP_TYPES.WHEN then
            if #graph.pending_routes == 0 then
                return nil, "Cannot add condition: no preceding route"
            end
            -- Apply condition to the last route
            graph.pending_routes[#graph.pending_routes].condition = op.config.condition
        end

        local success, err = graph:add_operation(op.type, op.config)
        if err then
            return nil, err
        end
    end

    -- Resolve all pending routes
    for _, route in ipairs(graph.pending_routes) do
        local target_node_id, resolve_err = graph:resolve_reference(route.target_name)
        if resolve_err then
            return nil, resolve_err
        end
        local success, edge_err = graph:add_edge(route.from_node_id, target_node_id, route.condition, route.is_error)
        if edge_err then
            return nil, edge_err
        end
    end

    -- Validate graph is acyclic
    local has_cycles, cycle_desc = graph:detect_cycles()
    if has_cycles then
        return nil, "Flow contains cycles: " .. cycle_desc
    end

    return graph, nil
end

-- Find nodes with no incoming edges and no parent
function compiler.find_root_nodes(graph)
    local nodes_with_incoming = {}

    for _, edges in pairs(graph.edges) do
        for _, edge in ipairs(edges.targets) do
            nodes_with_incoming[edge.target_node_id] = true
        end
        for _, edge in ipairs(edges.error_targets) do
            nodes_with_incoming[edge.target_node_id] = true
        end
    end

    local roots = {}
    for node_id, node_def in pairs(graph.nodes) do
        -- Root nodes have no incoming edges and no parent_node_id
        if not nodes_with_incoming[node_id] and not node_def.parent_node_id then
            table.insert(roots, node_id)
        end
    end

    return roots, nil
end

-- Find leaf nodes (no outgoing edges)
function compiler.find_leaf_nodes(graph)
    local leaves = {}

    for node_id, edges in pairs(graph.edges) do
        if #edges.targets == 0 and #edges.error_targets == 0 then
            table.insert(leaves, node_id)
        end
    end

    return leaves, nil
end

-- Compile graph to commands
function compiler.compile_to_commands(graph)
    if not graph then
        return nil, "Graph is required"
    end

    local commands = {}
    local input_data_id = nil

    -- Create input data if provided
    if graph.input_data then
        input_data_id = uuid.v7()
        table.insert(commands, {
            type = consts.COMMAND_TYPES.CREATE_DATA,
            payload = {
                data_id = input_data_id,
                data_type = consts.DATA_TYPE.WORKFLOW_INPUT,
                content = graph.input_data,
                content_type = type(graph.input_data) == "table" and consts.CONTENT_TYPE.JSON or consts.CONTENT_TYPE.TEXT
            }
        })
    end

    -- Find leaf nodes for default output routing
    local leaf_nodes, leaf_err = compiler.find_leaf_nodes(graph)
    if leaf_err then
        return nil, leaf_err
    end

    -- Create all nodes in creation order
    for _, node_id in ipairs(graph.node_order) do
        local node_def = graph.nodes[node_id]
        local config = {}

        -- Copy node config
        for k, v in pairs(node_def.config) do
            config[k] = v
        end

        -- Add routing configuration
        local edges = graph.edges[node_id]
        local has_explicit_routes = (#edges.targets > 0 or #edges.error_targets > 0)

        if has_explicit_routes then
            -- Node has explicit routing
            config.data_targets = {}
            config.error_targets = {}

            for _, edge in ipairs(edges.targets) do
                table.insert(config.data_targets, {
                    data_type = consts.DATA_TYPE.NODE_INPUT,
                    node_id = edge.target_node_id,
                    key = "default",
                    condition = edge.condition
                })
            end

            for _, edge in ipairs(edges.error_targets) do
                table.insert(config.error_targets, {
                    data_type = consts.DATA_TYPE.NODE_INPUT,
                    node_id = edge.target_node_id,
                    key = "default",
                    condition = edge.condition
                })
            end
        else
            -- Check if this is a leaf node and not a template
            local is_leaf = false
            local is_template = node_def.status == consts.STATUS.TEMPLATE

            for _, leaf_id in ipairs(leaf_nodes) do
                if leaf_id == node_id then
                    is_leaf = true
                    break
                end
            end

            if is_leaf and not is_template then
                -- Leaf node: route to workflow output
                config.data_targets = {
                    {
                        data_type = consts.DATA_TYPE.WORKFLOW_OUTPUT,
                        key = "result",
                        content_type = consts.CONTENT_TYPE.JSON
                    }
                }
            end
        end

        -- Create node command
        local node_payload = {
            node_id = node_id,
            node_type = node_def.node_type,
            status = node_def.status,
            config = config,
            metadata = node_def.metadata
        }

        -- Add parent_node_id if this is a template node
        if node_def.parent_node_id then
            node_payload.parent_node_id = node_def.parent_node_id
        -- Or if we're in a session and this is a root node
        elseif graph.session_parent_id and not node_def.parent_node_id then
            -- Root nodes get the session parent
            local is_root = true
            for _, other_node_def in pairs(graph.nodes) do
                if other_node_def.parent_node_id then
                    is_root = false
                    break
                end
            end
            if is_root then
                node_payload.parent_node_id = graph.session_parent_id
            end
        end

        table.insert(commands, {
            type = consts.COMMAND_TYPES.CREATE_NODE,
            payload = node_payload
        })
    end

    -- Create input routing to root nodes only
    if input_data_id then
        local root_nodes, roots_err = compiler.find_root_nodes(graph)
        if roots_err then
            return nil, roots_err
        end

        for _, node_id in ipairs(root_nodes) do
            table.insert(commands, {
                type = consts.COMMAND_TYPES.CREATE_DATA,
                payload = {
                    data_id = uuid.v7(),
                    data_type = consts.DATA_TYPE.NODE_INPUT,
                    node_id = node_id,
                    key = input_data_id,
                    content = "",
                    content_type = "dataflow/reference"
                }
            })
        end
    end

    return commands, nil
end

-- Main compilation function
function compiler.compile(operations, session_context)
    if not operations or #operations == 0 then
        return nil, "No operations to compile"
    end

    local graph, graph_err = compiler.build_graph(operations, session_context)
    if graph_err then
        return nil, graph_err
    end

    local commands, commands_err = compiler.compile_to_commands(graph)
    if commands_err then
        return nil, commands_err
    end

    return {
        commands = commands,
        graph = graph
    }, nil
end

return compiler