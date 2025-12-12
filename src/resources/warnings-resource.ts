import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { EmacsResource } from "./base-resource.js"

const WARNINGS_URI = "buffer://warnings"

export class WarningsResource extends EmacsResource {
  constructor(server: McpServer, emacs: EmacsClient) {
    super(server, emacs, {
      name: "warnings-buffer",
      uri: WARNINGS_URI,
      description: "Live contents of the *Warnings* buffer",
      mimeType: "text/plain"
    })
  }

  protected read() {
    const text = this.emacs.getNamedBufferText("*Warnings*")
    return {
      contents: [
        {
          uri: WARNINGS_URI,
          mimeType: "text/plain",
          text
        }
      ]
    }
  }
}
