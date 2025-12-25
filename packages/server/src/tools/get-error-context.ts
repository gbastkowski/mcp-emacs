import type { EmacsClient } from "../emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class GetErrorContextTool extends EmacsTool {
  readonly name     = "get_error_context"
  readonly metadata = {
    description: "Summarize recent error-related buffers such as *Messages*, *Warnings*, or compilation logs"
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  handle(_args: unknown, _extra: unknown, _context: unknown) {
    const info = this.callTextFunction("mcp-emacs-get-error-context")
    return { content: [ { type: "text", text: info } ] }
  }
}
