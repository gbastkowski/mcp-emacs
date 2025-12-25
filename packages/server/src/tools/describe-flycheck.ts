import type { EmacsClient } from "../emacs-client.js"
import      { EmacsTool   } from "./base-tool.js"

export class DescribeFlycheckInfoTool extends EmacsTool {
  readonly name = "describe_flycheck_info_at_point"
  readonly metadata = {
    description: "Get flycheck error/warning/info messages at the current cursor position"
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  handle(_args: unknown, _extra: unknown, _context: unknown) {
    return {
      content: [
        {
          type: "text",
          text: this.callTextFunction("mcp-emacs-get-flycheck-info")
        }
      ]
    }
  }
}
