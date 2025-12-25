import type { EmacsClient } from "../emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class GetBufferContentTool extends EmacsTool {
  public readonly name = "get_buffer_content"
  public readonly metadata = {
    description: "Get the content of the current Emacs buffer"
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
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
