import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { EmacsClient } from "../emacs-client.js"
import { EmacsResource } from "./base-resource.js"

const MESSAGES_URI = "buffer://messages"

export class MessagesResource extends EmacsResource {
  constructor(server: McpServer, emacs: EmacsClient) {
    super(server, emacs, {
      name: "messages-buffer",
      uri: MESSAGES_URI,
      description: "Live contents of the *Messages* buffer",
      mimeType: "text/plain"
    })
  }

  protected read() {
    const text = this.emacs.getNamedBufferText("*Messages*")
    return {
      contents: [
        {
          uri: MESSAGES_URI,
          mimeType: "text/plain",
          text
        }
      ]
    }
  }
}
