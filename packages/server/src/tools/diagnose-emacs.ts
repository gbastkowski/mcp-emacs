import type { EmacsClient } from "../emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class DiagnoseEmacsTool extends EmacsTool {
  readonly name = "diagnose_emacs"
  readonly metadata = {
    description: "Collect diagnostic information about the running Emacs, including exec-path and LSP clients"
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  handle(_args: unknown, _extra: unknown, _context: unknown) {
    return {
      content: [
        {
          type: "text",
          text: this.callTextFunction("mcp-emacs-diagnose")
        }
      ]
    }
  }
}
