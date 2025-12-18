import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class GetBufferContentTool extends EmacsTool {
  constructor(server: McpServer, emacs: EmacsClient) {
    super(server, emacs, {
      name: "get_buffer_content",
      metadata: {
        description: "Get the content of the current Emacs buffer",
      },
    })
  }

  protected handle(_args: unknown, _extra: unknown, _context: unknown): Record<string, unknown> {
    return {
      content: [
        {
          type: "text",
          text: this.callTextFunction("mcp-emacs-get-buffer-content")
        }
      ]
    }
  }
}
