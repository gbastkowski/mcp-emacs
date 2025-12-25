import type { EmacsClient } from "../emacs-client.js"
import { EmacsResource } from "./base-resource.js"

const MESSAGES_URI = "buffer://messages"

export class MessagesResource extends EmacsResource {
  readonly name         = "messages-buffer"
  readonly uri          = MESSAGES_URI
  readonly description  = "Live contents of the *Messages* buffer"
  readonly mimeType     = "text/plain"

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  read() {
    const text = this.emacs.getNamedBufferText("*Messages*")
    return {
      contents: [
        {
          uri: this.uri,
          mimeType: "text/plain",
          text
        }
      ]
    }
  }
}
