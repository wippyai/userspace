# Dataflow Flow Builder SDK - Specification

## Overview

Flow Builder SDK provides a fluent interface for composing acyclic dataflows. Iteration exists only as encapsulated subgraphs via cycle nodes.

**Core Principles:**
- **Acyclic Graph**: Forward-only routing with explicit edges
- **Input-First**: `:with_input()` establishes flow direction
- **Transform-on-Route**: Transforms apply at routing points
- **Explicit Routing**: `:to()` for success, `:error_to()` for errors
- **Terminal Nodes**: `@success` and `@fail` for explicit workflow completion
- **Conditional Logic**: `:when()` applies to preceding route
- **Optional Naming**: `:as()` only when references needed
- **Template Reuse**: `:use()` inlines, `flow.template()` defines

## Core API

```lua
local flow = require("userspace.dataflow.flow")

flow.create()
    :with_title(title)
    :with_metadata(metadata)
    :with_input(data)
    :[operation](config)
    :as(name)
    :to(target, input_key, transform)
    :error_to(target, input_key, transform)
    :when(condition)
    :run()  -- or :start()

flow.template()
    :[operations]...
```

## Workflow Configuration

### Title
```lua
flow.create()
    :with_title("Data Processing Pipeline")
    :with_input(data)
    :func("process")
    :run()
```

Sets the workflow title. If not provided, defaults to "Flow Builder Workflow".

### Metadata
```lua
flow.create()
    :with_title("Analytics Job")
    :with_metadata({
        project = "analytics",
        version = "1.0",
        owner = "data-team",
        priority = "high"
    })
    :with_input(data)
    :func("process")
    :run()
```

Sets custom workflow metadata. Metadata is merged with default fields (`title`, `created_by`).

## Execution Modes

### Synchronous Execution (`:run()`)
```lua
local result, err = flow.create()
    :with_title("Sync Job")
    :with_input(data)
    :func("process")
    :run()

if err then
    print("Error:", err)
    return
end

print("Result:", result)
```

**Behavior:**
- Blocks until workflow completes
- Returns workflow output data on success: `data, nil`
- Returns error on failure: `nil, error_message`
- Cannot be used in nested contexts (inside cycles/map-reduce)

### Asynchronous Execution (`:start()`)
```lua
local dataflow_id, err = flow.create()
    :with_title("Background Job")
    :with_input(data)
    :func("process")
    :start()

if err then
    print("Failed to start:", err)
    return
end

print("Started workflow:", dataflow_id)
-- Workflow runs in background
```

**Behavior:**
- Returns immediately with workflow ID
- Workflow runs in background
- Returns dataflow_id on success: `dataflow_id, nil`
- Returns error if startup fails: `nil, error_message`
- Cannot be used in nested contexts

**Checking status and getting results:**
```lua
local client = require("client")
local c = client.new()

-- Check status
local status, err = c:get_status(dataflow_id)

-- Get outputs when complete
local outputs, err = c:output(dataflow_id)
```

## Routing

### Automatic Sequential
Without explicit `:to()`, outputs auto-chain to next node. Using `:to()` disables auto-chain for that node only.

### Terminal Nodes
Explicit workflow completion:

```lua
:func("process")
    :to("@success")              -- Terminates workflow successfully
    :error_to("@fail")            -- Terminates workflow with error

:func("validate")
    :to("process"):when("output.valid")
    :error_to("@fail"):when("!output.valid")
```

In nested contexts (cycles, map-reduce templates), terminal routes create `NODE_OUTPUT` instead of `WORKFLOW_OUTPUT`, properly returning to parent.

### Input Key Routing
```lua
:func("router")
    :to("nodeA", "primary")
    :to("nodeB", "fallback")

:func("source1"):to("processor", "data_a")
:func("source2"):to("processor", "data_b")
```

### Conditional
```lua
:func("analyzer")
    :to("high"):when("output.score > 0.8")
    :to("medium"):when("output.score > 0.5")
    :to("low")
    :error_to("failed")
```

### Transform on Routes
Apply transforms when routing:

```lua
:func("source")
    :to("target"):transform("output.data.field")
    :to("other"):transform('{"extracted": output.value}')
    :error_to("@fail"):transform("error.message")
```

Workflow input routing with transforms:

```lua
flow.create()
    :with_input({prompt = "task", data = [1,2,3]})
    :to("agent"):transform("input.prompt")
    :to("processor"):transform("input.data")
```

**Transform context variables:**
- For data routes from nodes: `output` (node's output)
- For error routes: `error` (error object)
- For workflow input routes: `input` (workflow input data)

## Expressions

Transform and condition expressions use the `expr` module.

**Transform context:**
- `output`: Previous node output (for `:to()`)
- `error`: Error object (for `:error_to()`)
- `input`: Workflow input (for routing from `:with_input()`)

**Condition context:**
- `output`: Node output (for `:to().when()`)
- `error`: Error object (for `:error_to().when()`)

**Operators:** `+`, `-`, `*`, `/`, `%`, `**`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `!`, `?:`

**Functions:** `contains()`, `startsWith()`, `endsWith()`, `upper()`, `lower()`, `trim()`, `filter()`, `map()`, `all()`, `any()`, `len()`, `first()`, `last()`, `max()`, `min()`, `abs()`, `ceil()`, `floor()`, `round()`, `sqrt()`, `pow()`

**Features:** Optional chaining `?.`, null coalescing `??`, array access `[0]`

## Node Configuration

### Input Transform
Nodes can declare `input_transform` to transform inputs on read:

```lua
:func("processor", {
    inputs = {required = ["data", "context"]},
    input_transform = {
        processed_data = "inputs.data.items",
        ctx_summary = "inputs.context.summary"
    }
})
```

Single expression transforms all inputs:
```lua
:func("processor", {
    input_transform = "input.nested.value"
})
```

Multi-key transform creates named variables for function access.

## Node Types

### Function
```lua
:func("namespace:func_id", {
    inputs = {required = ["key1", "key2"]},
    context = {key = value},
    input_transform = "input.data" or {k1 = "expr1", k2 = "expr2"},
    metadata = {title = "Custom"}
})
```

Functions can return `{_control = {commands = [...]}}` to spawn child graphs.

### Agent
```lua
:agent("namespace:agent_id", {
    inputs = {required = ["input1"]},
    model = "custom-model",
    input_transform = {field = "inputs.input1.data"},
    arena = {
        prompt = "System prompt",
        max_iterations = 10,
        min_iterations = 1,
        tool_calling = "auto",
        exit_schema = {...},
        tools = [...],
        context = {...}
    },
    show_tool_calls = true,
    metadata = {title = "Agent"}
})
```

**Reserved input keys:**
- `agent_id`: Overrides configured agent (must be string)
- `context`: Extracted and merged into agent's execution context (must be table, not included in XML-formatted inputs)
- `model`: Dynamic model overwrite (must be string)

**Tool calling modes:**
- `auto`: Optional tools, exit on text response or exit tool
- `any`: Must call tool (requires exit_schema for exit tool)
- `none`: No tools (cannot have exit_schema)

**Exit tool:** Automatically generated as `finish` when exit_schema provided

**Multiple inputs formatted as XML:**
```xml
<input key="task">Process this</input>
<input key="data">Sample data</input>
```

**Defaults:**
- `max_iterations`: 32
- `min_iterations`: 1
- `tool_calling`: "auto"
- `show_tool_calls`: true

### Cycle

Cycles iterate work until completion. Choose **either** `func_id` **or** `template` (not both).

**With function:**
```lua
:cycle({
    func_id = "namespace:cycle_func",
    max_iterations = 5,
    initial_state = {quality = 0.3},
    inputs = {required = ["data"]},
    input_transform = "input.nested",
    context = {key = value}
})
```

**With template:**
```lua
:cycle({
    template = flow.template()
        :func("namespace:step1")
        :func("namespace:step2")
        :func("namespace:collector"),
    max_iterations = 3,
    initial_state = {score = 0}
})
```

**Cycle function receives:**
```lua
{
    iteration = 1,
    input = original_input,
    state = {...},
    last_result = {...}
}
```

**Cycle function must return:**
```lua
{
    state = {...},
    result = {...},
    continue = bool,
    _control = {
        commands = {...}
    },
    _metadata = {...}
}
```

**Template cycle requirement:**
When using `template`, the template's **leaf node** must return the cycle structure. Template roots receive the cycle context `{iteration, input, state, last_result}` as their input.

**Continuation logic:**
1. If return value has `continue` field, use that value
2. Otherwise, continue if `state` changed from previous iteration
3. Always stop at `max_iterations` and return the final iteration's `result`

**Defaults:**
- `max_iterations`: 100
- `initial_state`: {}

### Map-Reduce
```lua
:map_reduce({
    source_array_key = "items",
    iteration_input_key = "default",
    batch_size = 4,
    failure_strategy = "collect_errors",
    inputs = {required = ["items", "config"]},
    input_transform = {arr = "inputs.items", cfg = "inputs.config"},
    template = flow.template()
        :func("namespace:process"),
    item_steps = {
        {type = "map", func_id = "namespace:transform"},
        {type = "filter", func_id = "namespace:keep"}
    },
    reduction_extract = "successes",
    reduction_steps = {
        {type = "map", func_id = "namespace:transform"},
        {type = "filter", func_id = "namespace:keep"},
        {type = "group", key_func_id = "namespace:key"},
        {type = "reduce_groups", func_id = "namespace:reduce"},
        {type = "aggregate", func_id = "namespace:combine"},
        {type = "flatten", func_id = "namespace:flatten"}
    }
})
```

**Without reduction:**
```lua
{
    successes = {{iteration, item, result}, ...},
    failures = {{iteration, item, error}, ...},
    total_iterations = N,
    success_count = N,
    failure_count = N
}
```

**With `reduction_extract = "successes"`:** `[result1, result2, ...]`

**Item pipeline steps:**
- `map`: Transform each result
- `filter`: Keep/reject results (returning nil removes item)

**Reduction pipeline steps:**
- `map`: Transform array items
- `filter`: Keep array items
- `group`: Group array by key into object
- `reduce_groups`: Reduce each group
- `aggregate`: Combine data into single result
- `flatten`: Custom flattening logic

**Pipeline data type flow:**
- Extract: `array`
- After `group`: `grouped_object`
- After `reduce_groups`: `object`
- After `aggregate`/`flatten`: `any`

**Validation:** `map`, `filter`, `group` require array input. Use `aggregate` for object inputs.

**Defaults:**
- `batch_size`: 1
- `iteration_input_key`: "default"
- `failure_strategy`: "fail_fast"

### Join
```lua
:join({
    inputs = {required = ["source1", "source2"]},
    input_transform = {data = "inputs.source1", ctx = "inputs.source2"},
    metadata = {title = "Merge Data"}
})
```

Join collects and merges multiple inputs into a single output. The output structure depends on the inputs received:

**Single input or single default key:**
```lua
:func("source"):to("merger", "default")
:join():as("merger")
-- Output: <content from source>
```

**Multiple named inputs:**
```lua
:func("source1"):to("merger", "data")
:func("source2"):to("merger", "config")
:join():as("merger")
-- Output: {data = <from source1>, config = <from source2>}
```

**Mixed default and named inputs:**
```lua
:func("source1"):to("merger", "default")
:func("source2"):to("merger", "config")
:join():as("merger")
-- Output: {default = <from source1>, config = <from source2>}
```

Join waits for all required inputs before proceeding. Use `input_transform` to reshape the merged data.

### Template Usage
```lua
local preprocessor = flow.template()
    :func("namespace:clean")
    :func("namespace:tokenize")

flow.create()
    :with_input(data)
    :use(preprocessor)
    :run()
```

## Complete Examples

### Sequential Pipeline with Title
```lua
local result, err = flow.create()
    :with_title("Document Processing")
    :with_input(doc)
    :func("namespace:clean")
    :func("namespace:analyze")
    :func("namespace:summarize")
    :run()

if err then
    print("Pipeline failed:", err)
else
    print("Summary:", result)
end
```

### Async Execution with Status Polling
```lua
local client = require("client")

-- Start workflow
local dataflow_id, err = flow.create()
    :with_title("Background Analytics")
    :with_metadata({
        project = "analytics",
        priority = "low"
    })
    :with_input(large_dataset)
    :func("namespace:process")
    :start()

if err then
    return nil, err
end

print("Started:", dataflow_id)

-- Poll for completion
local c = client.new()
while true do
    local status = c:get_status(dataflow_id)
    if status == "completed" or status == "failed" then
        break
    end
    time.sleep(2000)
end

-- Get results
local outputs, err = c:output(dataflow_id)
```

### Terminal Routing with Error Details
```lua
local result, err = flow.create()
    :with_title("Validation Pipeline")
    :with_input(data)
    :func("namespace:validate")
        :to("process"):when("output.valid")
        :error_to("@fail")
    :func("namespace:process"):as("process")
        :to("@success")
        :error_to("@fail")
    :run()

if err then
    print("Validation failed:", err)
end
```

### Transform on Routes
```lua
flow.create()
    :with_title("Multi-Path Processing")
    :with_input({prompt = "task", context = {...}})
    :to("agent"):transform("input.prompt")
    :to("logger"):transform("input.context")
    
    :agent("namespace:agent"):as("agent")
        :to("processor"):transform("output.result.data")
        :error_to("@fail"):transform("error.message")
    
    :func("namespace:processor"):as("processor")
        :to("@success")
    
    :func("namespace:logger"):as("logger")
    :run()
```

### Conditional Routing with Transforms
```lua
flow.create()
    :with_title("Conditional Router")
    :with_input(data)
    :func("namespace:classify")
        :to("@success"):when("output.type == 'simple'"):transform("output.data")
        :to("complex"):when("output.type == 'complex'"):transform("output")
        :error_to("@fail"):transform('{"code": "CLASSIFICATION_FAILED", "details": error}')
    
    :func("namespace:complex"):as("complex")
        :to("@success")
        :error_to("@fail")
    :run()
```

### Input Transform in Node Config
```lua
flow.create()
    :with_title("Transform Pipeline")
    :with_input({prompt = "x", data = "y", context = "z"})
    :to("fetch", "ctx")
    :to("processor", "original")
    
    :func("namespace:fetch"):as("fetch")
        :to("processor", "fetched")
    
    :func("namespace:processor", {
        inputs = {required = ["original", "fetched", "ctx"]},
        input_transform = {
            task = "inputs.original.prompt",
            data = "inputs.fetched.results",
            context = "inputs.ctx"
        }
    })
    :as("processor")
    :to("@success")
    :run()
```

### Join Pattern for Parallel Processing
```lua
flow.create()
    :with_title("Parallel Analysis")
    :with_input({document = "..."})
    :to("analyze", "doc")
    :to("extract", "doc")
    
    :func("namespace:analyze"):as("analyze")
        :to("merger", "analysis")
    
    :func("namespace:extract"):as("extract")
        :to("merger", "entities")
    
    :join({
        inputs = {required = ["analysis", "entities"]},
        input_transform = {
            summary = "inputs.analysis.summary",
            entities = "inputs.entities.list"
        }
    })
    :as("merger")
    :to("@success")
    :run()
```

### Cycle with Terminal Routing in Template
```lua
flow.create()
    :with_title("QA Cycle")
    :with_input({task = "Complex task"})
    :cycle({
        func_id = "namespace:qa_cycle",
        max_iterations = 4,
        initial_state = {feedback_history = {}}
    })
    :to("@success")
    :error_to("@fail")
    :run()

function qa_cycle(cycle_context)
    if cycle_context.last_result and cycle_context.last_result.approved then
        return {
            state = cycle_context.state,
            result = cycle_context.last_result,
            continue = false
        }
    end
    
    return flow.create()
        :with_input({
            task = cycle_context.state.task or cycle_context.input.task,
            feedback = cycle_context.state.feedback_history
        })
        :to("worker", "work_input")
        :to("qa", "context")
        
        :agent("namespace:worker", {
            inputs = {required = {"work_input"}},
            arena = {prompt = "Do work", exit_schema = {...}}
        })
        :as("worker")
        :to("qa", "work")
        :error_to("@fail")
        
        :agent("namespace:qa", {
            inputs = {required = {"work", "context"}},
            arena = {prompt = "Review work", exit_schema = {...}}
        })
        :as("qa")
        :to("collector")
        :error_to("@fail")
        
        :func("namespace:collector", {
            inputs = {required = ["work", "assessment", "context"]}
        })
        :as("collector")
        :run()
end

function collector(inputs)
    local feedback_history = inputs.context.feedback or {}
    if not inputs.assessment.approved then
        table.insert(feedback_history, inputs.assessment.feedback)
    end
    
    return {
        state = {
            task = inputs.context.task,
            feedback_history = feedback_history
        },
        result = {
            work = inputs.work.work,
            approved = inputs.assessment.approved
        },
        continue = not inputs.assessment.approved
    }
end
```

### Map-Reduce with Terminal Routing
```lua
flow.create()
    :with_title("Batch Processing")
    :with_input({items = [...]})
    :map_reduce({
        source_array_key = "items",
        batch_size = 4,
        template = flow.template()
            :func("namespace:process")
            :to("@success")
            :error_to("@fail"),
        reduction_extract = "successes"
    })
    :to("@success")
    :error_to("@fail"):transform("error.message")
    :run()
```

### Async with Metadata Tracking
```lua
local dataflow_id, err = flow.create()
    :with_title("Long Running Import")
    :with_metadata({
        import_source = "s3://bucket/data",
        started_by = "admin",
        batch_id = "2024Q1",
        priority = "high"
    })
    :with_input({source = "s3://bucket/data"})
    :func("namespace:import")
    :func("namespace:validate")
    :func("namespace:load")
    :start()

if err then
    print("Failed to start import:", err)
    return
end

print("Import job started:", dataflow_id)
-- Job runs in background
```

## Validation Rules

- `:as(name)` names must be unique
- All `:to()` and `:error_to()` targets must exist (except `@success`, `@fail`)
- Graph must be acyclic
- `:cycle()` needs `func_id` OR `template` (not both)
- `:map_reduce()` requires `source_array_key`
- `:when()` only follows `:to()` or `:error_to()`
- Map-reduce pipelines: validate data type compatibility
- Always return `flow()...:run()` from functions
- Terminal routes (`@success`, `@fail`) automatically adapt to context (top-level vs nested)
- `:start()` cannot be used in nested contexts (cycles, map-reduce)
- `:with_title()` requires non-empty string
- `:with_metadata()` requires table

## Error Handling

Both `:run()` and `:start()` follow standard Lua error conventions:

**Success:**
- `:run()` → `data, nil`
- `:start()` → `dataflow_id, nil`

**Failure:**
- `:run()` → `nil, error_message`
- `:start()` → `nil, error_message`

**Error types:**
- Compilation errors: "Compilation failed: ..."
- Client errors: "Failed to create dataflow client: ..."
- Workflow creation errors: "Failed to create workflow: ..."
- Execution errors (run): "Failed to execute workflow: ..."
- Startup errors (start): "Failed to start workflow: ..."
- Workflow failures (run): Returns workflow error message directly