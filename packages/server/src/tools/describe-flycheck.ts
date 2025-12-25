import type { EmacsClient } from "../emacs-client.js"
import      { EmacsTool   } from "./base-tool.js"

export class DescribeFlycheckInfoTool extends EmacsTool {
  public readonly name = "describe_flycheck_info_at_point"
  public readonly metadata = {
    description: "Get flycheck error/warning/info messages at the current cursor position"
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  protected handle(_args: unknown, _extra: unknown, _context: unknown) {
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
