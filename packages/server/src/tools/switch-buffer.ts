import type { EmacsClient } from "../emacs-client.js"
import { z } from "zod"
import { EmacsTool } from "./base-tool.js"

const switchSchema = z.object({
  name: z.string().min(1).describe("Name of the buffer to switch to")
})

type SwitchArgs = z.infer<typeof switchSchema>

export class SwitchBufferTool extends EmacsTool {
  public readonly name = "switch_buffer"
  public readonly metadata = {
    description: "Switch to a named buffer in the current Emacs session",
    inputSchema: switchSchema
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  protected handle(args: unknown, _extra: unknown, _context: unknown) {
    const parsed: SwitchArgs = switchSchema.parse(args)
    const result = this.callTextFunction("mcp-emacs-switch-buffer", [parsed.name])
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
