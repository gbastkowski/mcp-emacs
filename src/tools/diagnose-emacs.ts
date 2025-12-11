import { EmacsTool } from "./base-tool.js"

export class DiagnoseEmacsTool extends EmacsTool {
  protected name = "diagnose_emacs"
  protected metadata = {
    description:
      "Collect diagnostic information about the running Emacs, including exec-path and LSP clients",
  }

  protected handle(
    _args: unknown,
    _extra: unknown,
    _context: unknown
  ) {
    const report = this.callTextFunction("mcp-emacs-diagnose")
    return {
      content: [
        {
          type: "text",
          text: report,
        },
      ],
    }
  }
}
