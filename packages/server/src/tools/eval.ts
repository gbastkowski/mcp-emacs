import type { EmacsClient } from "../emacs-client.js"
import { z         } from "zod"
import { EmacsTool } from "./base-tool.js"

const evalSchema = z.object({
  expression: z
    .string()
    .min(1)
    .describe("Elisp expression to evaluate via emacsclient"),
})

type EvalArgs = z.infer<typeof evalSchema>

export class EvalTool extends EmacsTool {
  readonly name = "eval"
  readonly metadata = {
    description: "Evaluate an arbitrary Elisp expression through emacsclient",
    inputSchema: evalSchema
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  handle(args: unknown, _extra: unknown, _context: unknown) {
    const { expression }: EvalArgs = evalSchema.parse(args)
    const raw = this.emacs.evalInEmacs(expression)
    const text = this.emacs.parseElispString(raw)
    return { content: [ { type: "text", text } ] }
  }
}
