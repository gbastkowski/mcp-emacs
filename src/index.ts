#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { execSync } from "child_process"
import { z } from "zod"

const server = new McpServer(
  {
    name: "mcp-emacs",
    version: "0.1.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
)

function evalInEmacs(elisp: string): string {
  try {
    const result = execSync(`emacsclient --eval '${elisp}'`, {
      encoding: "utf-8",
      timeout: 5000,
    })
    return result.trim()
  } catch (error) {
    throw new Error(`Failed to communicate with Emacs: ${error}`)
  }
}

server.registerTool(
  "get_buffer_content",
  {
    description: "Get the content of the current Emacs buffer",
  },
  async () => {
    const content = evalInEmacs(
      "(with-current-buffer (window-buffer (frame-selected-window (selected-frame))) (buffer-substring-no-properties (point-min) (point-max)))"
    )
    return {
      content: [
        {
          type: "text",
          text: content.slice(1, -1), // Remove surrounding quotes
        },
      ],
    }
  }
)

server.registerTool(
  "get_selection",
  {
    description: "Get the current selection (region) in Emacs",
  },
  async () => {
    const selection = evalInEmacs(
      "(with-current-buffer (window-buffer (frame-selected-window (selected-frame))) (if (use-region-p) (buffer-substring-no-properties (region-beginning) (region-end)) nil))"
    )
    if (selection === "nil") {
      return {
        content: [
          {
            type: "text",
            text: "No active selection",
          },
        ],
      }
    }
    return {
      content: [
        {
          type: "text",
          text: selection.slice(1, -1), // Remove surrounding quotes
        },
      ],
    }
  }
)

server.registerTool(
  "open_file",
  {
    description: "Open a file in the current Emacs window",
    inputSchema: {
      path: z.string().describe("Absolute path to the file to open"),
    },
  },
  async (args) => {
    evalInEmacs(`(find-file "${args.path}")`)
    return {
      content: [
        {
          type: "text",
          text: `Opened file: ${args.path}`,
        },
      ],
    }
  }
)

server.registerTool(
  "describe_flycheck_info_at_point",
  {
    description:
      "Get flycheck error/warning/info messages at the current cursor position",
  },
  async () => {
    const result = evalInEmacs(
      `(with-current-buffer (window-buffer (frame-selected-window (selected-frame)))
         (if (bound-and-true-p flycheck-mode)
             (let ((errors (flycheck-overlay-errors-at (point))))
               (if errors
                   (mapconcat
                    (lambda (err)
                      (format "%s: %s [%s]"
                              (flycheck-error-level err)
                              (flycheck-error-message err)
                              (flycheck-error-checker err)))
                    errors
                    "\\n")
                 "No flycheck messages at point"))
           "Flycheck mode not active"))`
    )
    return {
      content: [
        {
          type: "text",
          text: result.slice(1, -1), // Remove surrounding quotes
        },
      ],
    }
  }
)

async function main() {
  const transport = new StdioServerTransport()
  await server.connect(transport)
  console.error("Emacs MCP server running on stdio")
}

main().catch((error) => {
  console.error("Fatal error:", error)
  process.exit(1)
})
