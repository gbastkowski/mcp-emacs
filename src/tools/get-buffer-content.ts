import { EmacsTool } from "./base-tool.js"

export class GetBufferContentTool extends EmacsTool {
  protected name = "get_buffer_content"
  protected metadata = {
    description: "Get the content of the current Emacs buffer",
  }

  protected handle(
    _args: unknown,
    _extra: unknown,
    _context: unknown
  ): Record<string, unknown> {
    const content = this.callTextFunction("mcp-emacs-get-buffer-content")
    return {
      content: [
        {
          type: "text",
          text: content,
        },
      ],
    }
  }
}
