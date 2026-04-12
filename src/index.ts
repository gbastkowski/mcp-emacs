#!/usr/bin/env node

import { McpServer            } from "@modelcontextprotocol/sdk/server/mcp.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { EmacsClient          } from "./utils/emacs-client.js"
import { registerTools        } from "./tools/index.js"
import { registerResources    } from "./resources/index.js"
import { parseCliOptions      } from "./utils/cli-options.js"

const server = new McpServer(
  {
    name: "mcp-emacs",
    version: "0.4.0"
  },
  {
    capabilities: {
      tools: {},
      resources: {}
    }
  }
)

let cliOptions
try {
  cliOptions = parseCliOptions(process.argv.slice(2))
} catch (error) {
  console.error(String(error))
  process.exit(1)
}

const emacs = new EmacsClient({ executable: cliOptions.emacsclientExecutable })

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
