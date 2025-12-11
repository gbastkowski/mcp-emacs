import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class DiagnoseEmacsTool extends EmacsTool {
  constructor(server: McpServer, emacs: EmacsClient) {
    super(server, emacs, {
      name: "diagnose_emacs",
      metadata: {
        description:
          "Collect diagnostic information about the running Emacs, including exec-path and LSP clients",
      },
    })
  }

  protected handle(_args: unknown, _extra: unknown, _context: unknown) {
    const report = this.callTextFunction("mcp-emacs-diagnose")
    return { content: [ { type: "text", text: report } ] }
  }
}
