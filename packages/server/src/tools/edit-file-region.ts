

import type { EmacsClient } from "../emacs-client.js"
import      { z           } from "zod"
import      { EmacsTool   } from "./base-tool.js"

const positionSchema = z.object({
  line:   z.number().int().min(1).describe("1-based line number"),
  column: z.number().int().min(1).describe("1-based column number"),
})

const editSchema = z.object({
  path:   z.string().min(1).describe("Absolute path to the file being edited"),
  start:  positionSchema.describe("Start of the replacement region"),
  end:    positionSchema.describe("End of the replacement region"),
  text:   z.string().describe("Replacement text to insert within the range"),
  save:   z.boolean().default(false).describe("Save the buffer after applying the edit"),
})

type EditArgs = z.infer<typeof editSchema>

export class EditFileRegionTool extends EmacsTool {
  public readonly name = "edit_file_region"
  public readonly metadata = {
    description: "Edit a specific region in an Emacs buffer using line/column coordinates",
    inputSchema: editSchema
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  protected handle(args: unknown, _extra: unknown, _context: unknown): Record<string, unknown> {
    const parsed: EditArgs = editSchema.parse(args)
    this.ensureValidRange(parsed)
    const result = this.callTextFunction("mcp-emacs-edit-file-region", [
      parsed.path,
      parsed.start.line,
      parsed.start.column,
      parsed.end.line,
      parsed.end.column,
      parsed.text,
      parsed.save,
    ])

    return {
      content: [
        {
          type: "text",
          text: result,
        },
      ],
    }
  }

  private ensureValidRange({ start, end }: EditArgs): void {
    if (start.line > end.line) {
      throw new Error("Start line must be before or equal to end line")
    }
    if (start.line === end.line && start.column > end.column) {
      throw new Error("Start column must be before or equal to end column")
    }
  }
}
