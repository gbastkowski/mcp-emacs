import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class GetErrorContextTool extends EmacsTool {
  constructor(server: McpServer, emacs: EmacsClient) {
    super(server, emacs, {
      name: "get_error_context",
      metadata: {
        description:
          "Summarize recent error-related buffers such as *Messages*, *Warnings*, or compilation logs",
      },
    })
  }

  protected handle(_args: unknown, _extra: unknown, _context: unknown) {
    const info = this.callTextFunction("mcp-emacs-get-error-context")
    return { content: [ { type: "text", text: info } ] }
  }
}
