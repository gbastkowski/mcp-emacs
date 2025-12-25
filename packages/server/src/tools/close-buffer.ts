import type { EmacsClient } from "../emacs-client.js"
import { z } from "zod"
import { EmacsTool } from "./base-tool.js"

const closeSchema = z.object({
  save: z.boolean().default(false).describe("Save the buffer before closing")
})

type CloseArgs = z.infer<typeof closeSchema>

export class CloseBufferTool extends EmacsTool {
  public readonly name = "close_buffer"
  public readonly metadata = {
    description: "Close the current buffer, optionally saving it first",
    inputSchema: closeSchema
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  protected handle(args: unknown, _extra: unknown, _context: unknown) {
    const parsed: CloseArgs = closeSchema.parse(args ?? {})
    const result = this.callTextFunction("mcp-emacs-close-buffer", [parsed.save])
    return {
      content: [
        {
          type: "text",
          text: result
        }
      ]
    }
  }
}
