#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { EmacsClient } from "./emacs-client.js"
import { registerTools } from "./tools/index.js"

const server = new McpServer(
  {
    name: "mcp-emacs",
    version: "0.2.0",
  },
  {
    capabilities: {
      tools: {},
      resources: {},
    },
  }
)

const emacs = new EmacsClient()

registerTools(server, emacs)

server.registerResource(
  "org-tasks",
  "org-tasks://all",
  {
    description: "All TODO items from org-mode agenda files",
    mimeType: "text/plain",
  },
  async () => {
    const tasks = emacs.callElispStringFunction("mcp-emacs-get-org-tasks")
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
