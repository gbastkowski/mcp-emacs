import type { EmacsClient } from "../emacs-client.js"
import { z } from "zod"
import { EmacsTool } from "./base-tool.js"

const gotoSchema = z
  .object({
    line:   z.number().int().min(1).describe("1-based line number to jump to").optional(),
    column: z.number().int().min(1).describe("1-based column to position the cursor at").optional(),
    functionName: z
      .string()
      .min(1)
      .describe("Function or symbol name to jump to (via imenu)")
      .optional(),
  })
  .refine((data) => data.line !== undefined || data.functionName !== undefined, {
    message: "Provide either line or functionName",
    path: ["line"],
  })

type GotoArgs = z.infer<typeof gotoSchema>

export class GotoLineTool extends EmacsTool {
  readonly name = "goto_line"
  readonly metadata = {
    description: "Jump to a specific line/column or function name in the current buffer",
    inputSchema: gotoSchema
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  handle(args: unknown, _extra: unknown, _context: unknown) {
    const parsed: GotoArgs = gotoSchema.parse(args)
    const result = this.callTextFunction("mcp-emacs-goto-location", [
      parsed.line ?? null,
      parsed.column ?? null,
      parsed.functionName ?? null,
    ])

    return { content: [ { type: "text", text: result } ] }
  }
}
