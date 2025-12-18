import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { EmacsResource } from "./base-resource.js"

export class OrgTasksResource extends EmacsResource {
  constructor(server: McpServer, emacs: EmacsClient) {
    super(server, emacs, {
      name: "org-tasks",
      uri: "org-tasks://all",
      description: "All TODO items from org-mode agenda files",
      mimeType: "text/plain"
    })
  }

  protected read() {
    const tasks = this.emacs.callElispStringFunction("mcp-emacs-get-org-tasks")
    return {
      contents: [
        {
          uri: "org-tasks://all",
          mimeType: "text/plain",
          text: tasks
        }
      ]
    }
  }
}
