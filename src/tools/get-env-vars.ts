import { EmacsTool } from "./base-tool.js"

export class GetEnvVarsTool extends EmacsTool {
  protected name = "get_env_vars"
  protected metadata = {
    description: "List the environment variables currently visible to Emacs",
  }

  protected handle(
    _args: unknown,
    _extra: unknown,
    _context: unknown
  ) {
    const vars = this.callTextFunction("mcp-emacs-get-env-vars")
    return {
      content: [
        {
          type: "text",
          text: vars,
        },
      ],
    }
  }
}
