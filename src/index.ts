#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { z } from "zod"
import { EmacsClient } from "./emacs-client.js"

const server = new McpServer(
  {
    name: "mcp-emacs",
    version: "0.1.0",
  },
  {
    capabilities: {
      tools: {},
      resources: {},
    },
  }
)

const emacs = new EmacsClient()

server.registerTool(
  "get_buffer_content",
  {
    description: "Get the content of the current Emacs buffer",
  },
  async () => {
    const content = emacs.getBufferContent()
    return {
      content: [
        {
          type: "text",
          text: content,
        },
      ],
    }
  }
)

server.registerTool(
  "get_buffer_filename",
  {
    description: "Get the filename associated with the current Emacs buffer",
  },
  async () => {
    const filename = emacs.getBufferFilename()
    if (filename === null) {
      return {
        content: [
          {
            type: "text",
            text: "Current buffer is not visiting a file",
          },
        ],
      }
    }
    return {
      content: [
        {
          type: "text",
          text: filename,
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
    const selection = emacs.getSelection()
    if (selection === null) {
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
          text: selection,
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
    emacs.openFile(args.path)
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
    const result = emacs.getFlycheckInfo()
    return {
      content: [
        {
          type: "text",
          text: result,
        },
      ],
    }
  }
)

server.registerTool(
  "get_error_context",
  {
    description: "Summarize recent error-related buffers such as *Messages*, *Warnings*, or compilation logs",
  },
  async () => {
    const info = emacs.getErrorContext()
    return {
      content: [
        {
          type: "text",
          text: info,
        },
      ],
    }
  }
)

server.registerResource(
  "org-tasks",
  "org-tasks://all",
  {
    description: "All TODO items from org-mode agenda files",
    mimeType: "text/plain",
  },
  async () => {
    const tasks = emacs.getOrgTasks()
    return {
      contents: [
        {
          uri: "org-tasks://all",
          mimeType: "text/plain",
          text: tasks,
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
