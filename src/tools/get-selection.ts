import { EmacsTool } from "./base-tool.js"

export class GetSelectionTool extends EmacsTool {
  protected name = "get_selection"
  protected metadata = {
    description: "Get the current selection (region) in Emacs",
  }

  protected handle(
    _args: unknown,
    _extra: unknown,
    _context: unknown
  ) {
    const raw = this.emacs.callElispFunction("mcp-emacs-get-selection")
    if (raw === "nil") {
      return {
        content: [
          {
            type: "text",
            text: "No active selection",
          },
        ],
      }
    }

    const selection = this.emacs.parseElispString(raw)
    return {
      content: [
        {
          type: "text",
          text: selection,
        },
      ],
    }
  }
}
