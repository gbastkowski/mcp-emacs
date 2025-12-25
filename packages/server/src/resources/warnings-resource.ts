import type { EmacsClient } from "../emacs-client.js"
import { EmacsResource } from "./base-resource.js"

const WARNINGS_URI = "buffer://warnings"

export class WarningsResource extends EmacsResource {
  readonly name         = "warnings-buffer"
  readonly uri          = WARNINGS_URI
  readonly description  = "Live contents of the *Warnings* buffer"
  readonly mimeType     = "text/plain"

  constructor(emacs: EmacsClient) {
    super(emacs)
  }

  read() {
    const text = this.emacs.getNamedBufferText("*Warnings*")
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
