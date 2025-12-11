import { z } from "zod"
import { EmacsTool } from "./base-tool.js"

export class OpenFileTool extends EmacsTool {
  protected name = "open_file"
  protected metadata = {
    description: "Open a file in the current Emacs window",
    inputSchema: {
      path: z.string().describe("Absolute path to the file to open"),
    },
  }

  protected handle(
    args: unknown,
    _extra: unknown,
    _context: unknown
  ) {
    const { path } = args as { path: string }
    this.emacs.callElispFunction("mcp-emacs-open-file", [path])
    return {
      content: [
        {
          type: "text",
          text: `Opened file: ${path}`,
        },
      ],
    }
  }
}
