# MCP Emacs

Model Context Protocol (MCP) server for Emacs integration.
Provides tools to interact with Emacs from Claude Desktop/Code.

## Features

- **get_buffer_content**: Get the content of the current Emacs buffer
- **get_selection**: Get the current selection (region) in Emacs
- **open_file**: Open a file in the current Emacs window

## Prerequisites

- Node.js 20+
- Emacs with server mode running (`M-x server-start` or in your init file)
- `emacsclient` available in PATH

## Installation

```bash
npm install
npm run build
```

## Usage with Claude Desktop

Add to your Claude Desktop config (`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS):

```json
{
  "mcpServers": {
    "emacs": {
      "command": "node",
      "args": ["/path/to/mcp-emacs/dist/index.js"]
    }
  }
}
```

## Usage with Claude Code

Add to your Claude Code MCP settings:

```json
{
  "emacs": {
    "command": "node",
    "args": ["/path/to/mcp-emacs/dist/index.js"]
  }
}
```

## Development

```bash
# Build
npm run build

# Watch mode
npm run watch
```

## Architecture

- **TypeScript/Node.js**: MCP server implementation
- **emacsclient**: Communication with Emacs via `--eval`
- **STDIO transport**: Standard MCP communication protocol

## Requirements

The server requires Emacs to be running with server mode enabled.
Add this to your Emacs init file:

```elisp
(server-start)
```

Or manually start the server with `M-x server-start`.
