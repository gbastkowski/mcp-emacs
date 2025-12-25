#!/usr/bin/env node

import { McpServer            } from "@modelcontextprotocol/sdk/server/mcp.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { EmacsClient          } from "./emacs-client.js"
import { registerTools        } from "./tools/index.js"
import { registerResources    } from "./resources/index.js"

const server = new McpServer(
  {
    name: "mcp-emacs",
    version: "0.3.0"
  },
  {
    capabilities: {
      tools: {},
      resources: {}
    }
  }
)

const emacs = new EmacsClient()

registerTools(server, emacs)
registerResources(server, emacs)

async function main() {
  await server.connect(new StdioServerTransport())
  console.error("Emacs MCP server running on stdio")
}

main().catch((error) => {
  console.error("Fatal error:", error)
  process.exit(1)
})
