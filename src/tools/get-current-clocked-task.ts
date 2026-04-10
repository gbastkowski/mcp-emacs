import type { EmacsClient } from "../utils/emacs-client.js"
import { EmacsTool } from "./base-tool.js"

export class GetCurrentClockedTaskTool extends EmacsTool {
  readonly name = "get_current_clocked_task"
  readonly metadata = {
    description: "Get the Org task currently clocked in"
  }

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  handle(_args: unknown, _extra: unknown, _context: unknown) {
    const raw = this.emacs.callElispFunction("mcp-emacs-get-current-clocked-task")
    if (raw === "nil") { return { content: [ { type: "text", text: "No task is currently clocked in" } ] } }

    const task = this.emacs.parseElispString(raw)
    return { content: [ { type: "text", text: task } ] }
  }
}
