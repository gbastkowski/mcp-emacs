import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class GetEnvVarsTool extends EmacsTool {
  constructor(server: McpServer, emacs: EmacsClient) {
    super(server, emacs, {
      name: "get_env_vars",
      metadata: {
        description: "List the environment variables currently visible to Emacs",
      },
    })
  }

  protected handle(_args: unknown, _extra: unknown, _context: unknown) {
    const vars = this.callTextFunction("mcp-emacs-get-env-vars")
    return { content: [ { type: "text", text: vars } ] }
  }
}
