import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class GetSelectionTool extends EmacsTool {
  constructor(server: McpServer, emacs: EmacsClient) {
    super(server, emacs, {
      name: "get_selection",
      metadata: {
        description: "Get the current selection (region) in Emacs",
      },
    })
  }

  protected handle(_args: unknown, _extra: unknown, _context: unknown) {
    const raw = this.emacs.callElispFunction("mcp-emacs-get-selection")
    if (raw === "nil") {
      return { content: [ { type: "text", text: "No active selection" } ] }
    }

    const selection = this.emacs.parseElispString(raw)
    return { content: [ { type: "text", text: selection } ] }
  }
}
