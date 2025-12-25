import type { EmacsClient } from "../emacs-client.js"
import { EmacsResource } from "./base-resource.js"

export class OrgTasksResource extends EmacsResource {
  readonly name         = "org-tasks"
  readonly uri          = "org-tasks://all"
  readonly description  = "All TODO items from org-mode agenda files"
  readonly mimeType     = "text/plain"

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  read() {
    return {
      contents: [
        {
          uri: this.uri,
          mimeType: "text/plain",
          text: this.emacs.callElispStringFunction("mcp-emacs-get-org-tasks")
        }
      ]
    }
  }
}
