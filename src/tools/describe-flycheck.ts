import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class DescribeFlycheckInfoTool extends EmacsTool {
  constructor(server: McpServer, emacs: EmacsClient) {
    super(server, emacs, {
      name: "describe_flycheck_info_at_point",
      metadata: {
        description:
          "Get flycheck error/warning/info messages at the current cursor position",
      },
    })
  }

  protected handle(_args: unknown, _extra: unknown, _context: unknown) {
    const result = this.callTextFunction("mcp-emacs-get-flycheck-info")
    return { content: [ { type: "text", text: result } ] }
  }
}
