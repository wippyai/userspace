# userspace/webscout

Web research tools for AI agents.

## Tools

- **GoogleSearch** - Search the web via Google Custom Search API
- **ReadPage** - Fetch and extract clean text content from web pages
- **FetchAllLinks** - Extract all unique links from a web page

## Trait

Add the `web_researcher` trait to any agent to give it full web research capabilities:

```yaml
traits:
  - id: userspace.webscout.traits:web_researcher
```

## Configuration

Set the following environment variables for Google Search:

- `userspace.webscout:google_search_api_key` - Google Custom Search API key
- `userspace.webscout:google_search_engine_id` - Google Custom Search Engine ID (cx)

ReadPage and FetchAllLinks work without any API keys.
