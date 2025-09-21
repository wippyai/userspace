# Dataflow Flow Builder SDK - Complete Specification

## Overview

The Flow Builder SDK provides a fluent interface for composing dataflows as **acyclic graphs**. Iteration exists only as **encapsulated sub-graphs** via `:cycle()` nodes. The same surface works for AI and non-AI workloads.

**Core Principles:**
- **Acyclic Graph**: Forward-only routing with explicit success/error edges
- **Input-First**: `:with_input()` establishes data flow direction
- **Transform Auto-Application**: `:transform()` applies to the next node only
- **Explicit Routing**: `:to()` for success, `:error_to()` for errors
- **Conditional Logic**: `:when()` conditions apply to preceding routing method
- **Optional Naming**: `:as()` only when nodes need references
- **Template Reuse**: `:use()` inlines templates, `flow.template()` defines them

## Core API

```lua
local flow = require("userspace.dataflow.flow")

flow.create()
    :with_input(data)           -- Input-first semantics
    :transform(expr)            -- Lua expression (auto-applies to next node)
    :[operation](config)        -- Functions, agents, templates, etc.
    :as(node_name)             -- Optional node naming  
    :to(target_name)           -- Output routing to named nodes
    :error_to(target_name)     -- Error routing to named nodes
    :when(condition)           -- Conditional routing (applies to preceding route)
    :run()                     -- Context-aware execution

flow.template()                -- Creates reusable template definitions
    :[operations]...           -- Template operations
```

## Transform Operations

**Transform**: `:transform(expr)` evaluates a single **expression** (supporting Lua operations, table construction, and field access) and passes its result as the input to the **next** node.

```lua
-- Simple field access
:transform("input.content")

-- Lua table construction with output shape
:transform("{ s = input.sentiment, e = input.entities, sum = input.summary }")
-- Output: { s = sentiment_result, e = entities_result, sum = summary_result }

-- Complex Lua operations
:transform("{ items = input.data, count = #input.data, valid = input.status == 'ok' }")
-- Output: { items = array, count = number, valid = boolean }

-- Conditional logic
:transform("input.quality > 0.8 and input.result or 'needs_review'")
-- Output: string (either input.result or "needs_review")

-- Nested field access
:transform("input.metadata.title or 'Untitled'")
-- Output: string
```

## Node Types and Outputs

### Function Nodes

**Input**: Any data type
**Output**: Whatever the function returns

```lua
flow.create()
    :with_input("Hello world")
    :func("myapp.text:uppercase")
    :run()
-- Function output: "HELLO WORLD"

-- With control commands
flow.create()
    :with_input(data)
    :func("myapp.process:with_commands")
    :run()
-- If function returns: { result = "processed", _control = { commands = [...] } }
-- Node output: child node results (commands executed, outputs collected)
-- If no commands: "processed"
```

### Agent Nodes

**Input**: String prompt or structured data
**Output**: Agent's final result

```lua
flow.create()
    :with_input("Analyze this data")
    :agent("myapp.agents:analyzer", {
        arena = { 
            prompt = "You are an expert analyst...",
            max_iterations = 10,
            tool_calling = "auto"
        }
    })
    :run()
-- Agent output examples:
-- With exit tool: { answer = "Analysis complete", confidence = 0.9 }
-- Without exit tool: "Final analysis result"
-- On failure: { success = false, error = "Analysis failed" }
```

### Cycle Nodes

**Input**: Any data type
**Output**: Result from final iteration

```lua
-- Function-based cycle
flow.create()
    :with_input("draft content")
    :cycle({
        func_id = "myapp.improve:content",
        continue_condition = "state.quality < 0.9 and iteration < 5",
        max_iterations = 5,
        initial_state = { quality = 0.3 }
    })
    :run()
-- If function returns: { result = "improved content", state = { quality = 0.92 } }
-- Cycle output: "improved content"

-- Template-based cycle
flow.create()
    :with_input(data)
    :cycle({
        template = flow.template()
            :func("myapp.step:analyze")
            :func("myapp.step:improve"),
        continue_condition = "state.score < 0.8",
        max_iterations = 3
    })
    :run()
-- Template output collected from leaf nodes
-- Single leaf: direct result
-- Multiple leaves: array of results
```

### Parallel Expressions

**Input**: Any data type (same input goes to all branches)
**Output**: Structured object with all branch results

```lua
flow.create()
    :with_input(document)
    :parallel({
        sentiment = "myapp.analyze:sentiment",
        entities = "myapp.extract:entities",
        summary = "myapp.summarize:content"
    })
    :run()
-- Parallel output: 
-- {
--   sentiment = { score = 0.8, label = "positive" },
--   entities = ["person", "organization"],
--   summary = "Document summary text"
-- }

-- With transform to reshape
flow.create()
    :with_input(document)
    :parallel({
        sentiment = "myapp.analyze:sentiment",
        entities = "myapp.extract:entities"
    })
    :transform("{ s = input.sentiment, e = input.entities, count = #input.entities }")
    :func("myapp.process:combined")
    :run()
-- Transform output: { s = sentiment_data, e = entities_array, count = 3 }
```

### Map-Reduce Nodes

**Input**: Object with array field specified by `source_array_key`
**Output**: Depends on `reduction_extract` and `reduction_steps`

```lua
flow.create()
    :with_input({ documents = [doc1, doc2, doc3] })
    :map_reduce({
        source_array_key = "documents",
        template = templates.processor,
        item_steps = flow.step
            :map("myapp.extract:metadata")
            :filter("myapp.filter:quality"),
        reduction_steps = flow.step
            :aggregate("myapp.combine:all"),
        reduction_extract = "successes"
    })
    :run()
-- Without reduction: 
-- {
--   successes = [
--     { iteration = 1, item = doc1, result = processed1 },
--     { iteration = 2, item = doc2, result = processed2 }
--   ],
--   failures = [...],
--   total_iterations = 3,
--   success_count = 2,
--   failure_count = 1
-- }

-- With reduction_extract = "successes":
-- [processed1, processed2]  // Just the results

-- With reduction_steps:
-- Whatever the final aggregate function returns
```

### State Nodes (Internal)

**Input**: Multiple inputs from different sources
**Output**: Structured collection of inputs

```lua
-- Internal state node (created by parallel compilation)
-- Input keys: { "sentiment_branch" = result1, "entities_branch" = result2 }
-- Output: { sentiment_branch = result1, entities_branch = result2 }
-- Or with key mapping: { sentiment = result1, entities = result2 }
```

### Template Usage

**Input**: Any data type
**Output**: Output from template's leaf nodes

```lua
local preprocessor = flow.template()
    :func("myapp.text:clean")
    :func("myapp.text:tokenize")

flow.create()
    :with_input("raw text")
    :use(preprocessor)
    :run()
-- Template output: result from "myapp.text:tokenize" (the leaf node)

-- Multi-leaf template
local analyzer = flow.template()
    :func("myapp.text:clean")
    :parallel({
        sentiment = "myapp.analyze:sentiment",
        entities = "myapp.extract:entities"
    })

flow.create()
    :with_input("text")
    :use(analyzer)
    :run()
-- Template output: { sentiment = result1, entities = result2 } (from parallel)
```

## Transform Examples with Output Shapes

```lua
-- Reshape parallel results
:parallel({
    sentiment = "myapp.analyze:sentiment",
    entities = "myapp.extract:entities",
    summary = "myapp.summarize:content"
})
:transform("{ 
    analysis = { sentiment = input.sentiment.score, entities = input.entities.list },
    confidence = (input.sentiment.confidence + input.entities.confidence) / 2,
    summary = input.summary.text
}")
-- Transform input: { sentiment = {...}, entities = {...}, summary = {...} }
-- Transform output: { analysis = {...}, confidence = 0.85, summary = "text" }

-- Extract and restructure
:func("myapp.process:data")
:transform("{ 
    result = input.processed_data,
    metadata = { timestamp = input.created_at, quality = input.score },
    items = input.items and #input.items or 0
}")
-- Transform input: { processed_data = "result", created_at = 123456, score = 0.9, items = [...] }
-- Transform output: { result = "result", metadata = {...}, items = 3 }

-- Conditional extraction
:func("myapp.validate:content")
:transform("input.valid and input.data or { error = 'validation failed' }")
-- Transform input: { valid = true, data = "content" }
-- Transform output: "content"
-- OR if valid = false: { error = "validation failed" }

-- Array operations (if expr system supports)
:func("myapp.extract:items")
:transform("{ processed = input.items, count = #input.items, first = input.items[1] }")
-- Transform input: { items = ["a", "b", "c"] }
-- Transform output: { processed = ["a", "b", "c"], count = 3, first = "a" }
```

## Routing and Conditional Flow

```lua
-- Route based on output structure
flow.create()
    :with_input(data)
    :func("myapp.analyze:quality")
        :to("high_quality"):when("output.score > 0.8")
        :to("medium_quality"):when("output.score > 0.5") 
        :to("low_quality")  -- Unconditional fallback
        :error_to("analysis_failed")
    :func("myapp.process:high"):as("high_quality")
    :func("myapp.process:medium"):as("medium_quality")
    :func("myapp.process:low"):as("low_quality")
    :func("myapp.error:analysis"):as("analysis_failed")
    :run()
-- Routing conditions access the output object from myapp.analyze:quality
```

## Error Handling and Output

```lua
-- Error routing
flow.create()
    :with_input(risky_data)
    :func("myapp.process:risky")
        :to("success_handler")
        :error_to("error_handler"):when("error.retryable")
        :error_to("fatal_handler")  -- All other errors
    :func("myapp.output:success"):as("success_handler")
    :func("myapp.retry:process"):as("error_handler") 
    :func("myapp.error:fatal"):as("fatal_handler")
    :run()
-- Error routing conditions access the error object
```

## Validation Constraints

**Authoring-time validation ensures:**
- `:as(name)` names must be unique within a flow
- All `:to()` and `:error_to()` targets must reference valid node names
- Graph must be acyclic (no backward edges)
- Each `:transform()` applies to exactly one subsequent node
- `:cycle()` must specify exactly one of `func_id` OR `template`
- `:map_reduce()` requires `source_array_key`
- `:when()` conditions can only follow `:to()` or `:error_to()`

## Context-Aware Execution

The same flow code works in all execution contexts:

```lua
-- Session tool - executes like standalone
function session_handler(params)
    return flow.create()
        :with_input(params.data)
        :agent("myapp.agents:processor")
        :run()  -- Creates workflow, executes, returns result
end

-- Standalone - executes complete workflow  
function standalone_processor(data)
    return flow.create()
        :with_input(data)
        :func("myapp.process:data")
        :run()  -- Creates workflow, executes, returns result
end

-- Inside workflow (cycle iteration, function with control commands) - returns control commands
function cycle_iteration(cycle_data)
    return flow.create()
        :with_input(cycle_data.state)
        :agent("myapp.agents:improver")
        :run()  -- Returns { _control = { commands = {...} } }
end
```

## Complete Example with Output Flow

```lua
local templates = {
    preprocessor = flow.template()
        :func("myapp.text:extract")      -- Output: extracted text
        :func("myapp.text:clean"),       -- Output: cleaned text
        
    analyzer = flow.template()
        :use(templates.preprocessor)      -- Output: cleaned text
        :parallel({                      -- Output: { sentiment = {...}, entities = {...} }
            sentiment = "myapp.analyze:sentiment",
            entities = "myapp.extract:entities"
        })
}

function create_analysis_pipeline(documents)
    return flow.create()
        :with_input({ documents = documents })
        
        -- Map-reduce preprocessing
        :map_reduce({
            source_array_key = "documents",
            template = templates.preprocessor,
            reduction_extract = "successes"  -- Output: [cleaned_text1, cleaned_text2, ...]
        })
        
        -- Transform for analysis
        :transform("{ content = input, metadata = { count = #input } }")
        -- Transform output: { content = [...], metadata = { count = 3 } }
        
        -- Analysis with conditional routing
        :use(templates.analyzer)
        -- Template output: { sentiment = {...}, entities = {...} }
        
        :func("myapp.combine:analysis")
            :to("high_confidence"):when("output.confidence > 0.8")
            :to("medium_confidence"):when("output.confidence > 0.5")
            :to("low_confidence")
            :error_to("analysis_failed")
            
        :func("myapp.output:high"):as("high_confidence")
        :func("myapp.output:medium"):as("medium_confidence") 
        :func("myapp.output:low"):as("low_confidence")
        :func("myapp.error:analysis"):as("analysis_failed")
        
        :run()
end
```

## Implementation Notes

- **Parallel compilation**: Creates internal state nodes for result collection
- **Template inlining**: Templates are expanded into individual nodes at build time
- **Expression evaluation**: Uses existing expr system for transforms and conditions
- **Routing compilation**: `:to()` and `:error_to()` compile to `data_targets` and `error_targets` configs
- **Context detection**: Same flow builder works for sessions, standalone execution, and cycle iterations
- **Output routing**: All node outputs route through standard `data_targets`/`error_targets` mechanisms
- **Transform application**: Transform expressions receive the previous node's output as `input`