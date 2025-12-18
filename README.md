# MCP Emacs

Model Context Protocol (MCP) tooling for Emacs, now split into two dedicated modules:

- `packages/server`: the Node.js MCP server (`mcp-emacs-server` npm package)
- `packages/emacs`: the Emacs Lisp package (`mcp-emacs`) that exposes editor-side commands

Install the Emacs package inside your editor, then run the MCP server to make those operations available to Claude Desktop/Code.

## Features

### Tools

| Tool | Description |
| --- | --- |
| `get_buffer_content` | Get the content of the current Emacs buffer |
| `get_buffer_filename` | Get the filename associated with the current Emacs buffer |
| `get_selection` | Get the current selection (region) in Emacs |
| `open_file` | Open a file in the current Emacs window |
| `edit_file_region` | Replace text in a file by specifying start/end line & column coordinates (optionally save) |
| `insert_at_point` | Insert text at point or replace the current selection in the active buffer |
| `goto_line` | Jump to a specific line/column or navigate directly to a named function via imenu |
| `toggle_org_todo` | Toggle the TODO keyword (or set a specific state) on the current Org heading |
| `describe_flycheck_info_at_point` | Get flycheck diagnostics at cursor |
| `get_error_context` | Summarize contents of error-related buffers (*Messages*, *Warnings*, compilation logs) |

### Resources

| Resource | Description |
| --- | --- |
| `org-tasks://all` | All TODO items from org-mode agenda files with status, priority, scheduled/deadline dates |
| `buffer://messages` | Live contents of the Emacs `*Messages*` buffer |
| `buffer://warnings` | Live contents of the Emacs `*Warnings*` buffer |

## Prerequisites

- Node.js 20+
- Emacs with server mode running (`M-x server-start` or via your init file)
- `emacsclient` available in PATH
- The `mcp-emacs` Emacs package loaded (see below)

## Installation

### 1. Install the Emacs package

```elisp
(add-to-list 'load-path "/path/to/mcp-emacs/packages/emacs/lisp")
(require 'mcp-emacs)
(server-start)
```

You can also wire this directory up via `use-package`, `straight.el`, or your preferred package manager. The Emacs package lives entirely under `packages/emacs`.

### 2. Install/build the Node MCP server

```bash
cd packages/server
npm install
npm run build
```

This produces `packages/server/dist/index.js` plus the CLI wrapper `packages/server/bin/mcp-emacs.js`.

### Run via npx

Use the published package directly:

```bash
npx --yes mcp-emacs-server
```

The CLI entrypoint remains `mcp-emacs`; `npx` downloads the `mcp-emacs-server` package and runs that binary.

## Usage with Claude Desktop

Update `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS example):

```json
{
  "mcpServers": {
    "emacs": {
      "command": "node",
      "args": ["/path/to/mcp-emacs/packages/server/dist/index.js"]
    }
  }
}
```

## Usage with Claude Code

```json
{
  "emacs": {
    "command": "node",
    "args": ["/path/to/mcp-emacs/packages/server/dist/index.js"]
  }
}
```

## Development

```bash
cd packages/server
npm run build      # Single build
npm run watch      # Rebuild on change
npm test           # TypeScript unit tests
```

The Emacs package is plain Elisp; edit files under `packages/emacs/lisp` and load them into your Emacs session as usual.

## Architecture

- **TypeScript/Node.js**: MCP server implementation (`mcp-emacs-server`)
- **Emacs Lisp**: `mcp-emacs` package that implements the editor-side helpers
- **emacsclient**: Communication bridge (always via `--eval`)
- **STDIO transport**: Standard MCP communication channel

### Flow Diagram

![Architecture flow diagram](docs/architecture.png)

The source PlantUML definition lives in `docs/architecture.puml` if you need to edit or re-render the diagram.

## Requirements

The server still requires Emacs to already be running with server mode enabled. Add this to your init file if needed:

```elisp
(server-start)
```

Or run `M-x server-start` manually before launching the MCP server.
