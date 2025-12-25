import type { EmacsClient } from "../emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class SaveBufferTool extends EmacsTool {
  public readonly name = "save_buffer"
  public readonly metadata = {
    description: "Save the current buffer if it is visiting a file"
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  protected handle(_args: unknown, _extra: unknown, _context: unknown) {
    return {
      content: [
        {
          type: "text",
          text: this.callTextFunction("mcp-emacs-save-buffer")
        }
      ]
    }
  }
}
