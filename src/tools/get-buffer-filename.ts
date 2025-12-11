import { EmacsTool } from "./base-tool.js"

export class GetBufferFilenameTool extends EmacsTool {
  protected name = "get_buffer_filename"
  protected metadata = {
    description: "Get the filename associated with the current Emacs buffer",
  }

  protected handle(
    _args: unknown,
    _extra: unknown,
    _context: unknown
  ) {
    const raw = this.emacs.callElispFunction("mcp-emacs-get-buffer-filename")
    if (raw === "nil") {
      return {
        content: [
          {
            type: "text",
            text: "Current buffer is not visiting a file",
          },
        ],
      }
    }

    const filename = this.emacs.parseElispString(raw)
    return {
      content: [
        {
          type: "text",
          text: filename,
        },
      ],
    }
  }
}
