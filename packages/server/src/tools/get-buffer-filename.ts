import type { EmacsClient } from "../emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class GetBufferFilenameTool extends EmacsTool {
  public readonly name = "get_buffer_filename"
  public readonly metadata = {
    description: "Get the filename associated with the current Emacs buffer"
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  protected handle(_args: unknown, _extra: unknown, _context: unknown) {
    const raw = this.emacs.callElispFunction("mcp-emacs-get-buffer-filename")
    if (raw === "nil") {
      return { content: [ { type: "text", text: "Current buffer is not visiting a file" } ] }
    }

    return {
      content: [
        {
          type: "text",
          text: this.emacs.parseElispString(raw)
        }
      ]
    }
  }
}
