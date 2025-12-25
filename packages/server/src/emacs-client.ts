import { execFileSync } from "child_process"

export class EmacsClient {
  private timeout: number
  private initialized: boolean

  constructor(timeout: number = 5000) {
    this.timeout = timeout
    this.initialized = false
  }

  /**
   * Evaluate an arbitrary Elisp function via `emacsclient --eval` and return the raw string result.
   * Accepts basic JavaScript primitives as arguments and handles quoting/escaping for Emacs.
   */
  callElispFunction(functionName: string, args: Array<string | number | boolean | null> = []): string {
    const formattedArgs = args.map((arg) => this.formatElispArg(arg)).join(" ")
    return this.evalInEmacs(`(${functionName}${formattedArgs ? " " + formattedArgs : ""})`)
  }

  /**
   * Convert the string returned by Emacs into a plain JavaScript string.
   * Emacs wraps strings in quotes and escapes characters; this removes those artifacts.
   */
  parseElispString(str: string): string {
    if (str.length < 2) return str
    const firstChar = str[0]
    const lastChar = str[str.length - 1]
    if (firstChar !== '"' || lastChar !== '"') {
      return str
    }

    const body = str.slice(1, -1)
    let result = ""
    for (let i = 0; i < body.length; ) {
      const char = body[i]
      if (char !== "\\") {
        result += char
        i += 1
        continue
      }

      if (i === body.length - 1) {
        result += "\\"
        break
      }

      const next = body[i + 1]
      i += 2
      switch (next) {
        case "\\": result += "\\"; break
        case '"':  result += '"';  break
        case "n":  result += "\n"; break
        case "r":  result += "\r"; break
        case "t":  result += "\t"; break
        case "b":  result += "\b"; break
        case "f":  result += "\f"; break
        case "v":  result += "\v"; break
        case "x": {
          const hexMatch = body.slice(i).match(/^[0-9a-fA-F]{1,2}/)
          if (hexMatch) {
            result += String.fromCharCode(parseInt(hexMatch[0], 16))
            i += hexMatch[0].length
          } else result += "x"
          break
        }
        case "u": {
          const unicodeMatch = body.slice(i).match(/^[0-9a-fA-F]{4}/)
          if (unicodeMatch) {
            result += String.fromCharCode(parseInt(unicodeMatch[0], 16))
            i += unicodeMatch[0].length
          } else result += "u"
          break
        }
        default: {
          if (/[0-7]/.test(next)) {
            let octalDigits = next
            let consumed = 1
            while (
              consumed < 3 &&
              i < body.length &&
              /[0-7]/.test(body[i])
            ) {
              octalDigits += body[i]
              i += 1
              consumed++
            }
            result += String.fromCharCode(parseInt(octalDigits, 8))
          } else result += next
        }
      }
    }

    return result
  }

  /**
   * Convenience helper that both evaluates an Elisp function and strips the surrounding quotes.
   */
  callElispStringFunction(functionName: string, args: Array<string | number | boolean | null> = []): string {
    const raw = this.callElispFunction(functionName, args)
    return this.parseElispString(raw)
  }

  /**
   * Fetch the text contents of an arbitrary Emacs buffer, used by resource readers.
   */
  getNamedBufferText(bufferName: string): string {
    return this.callElispStringFunction("mcp-emacs-get-buffer-text", [bufferName])
  }

  public evalInEmacs(elisp: string): string {
    this.ensureInitialized()
    return this.runEval(elisp)
  }

  private ensureInitialized(): void {
    if (this.initialized) return
    try {
      this.runEval("(require 'mcp-emacs)")
      this.initialized = true
    } catch (error) {
      throw new Error(
        "Failed to load the mcp-emacs Emacs package. Add it to your Emacs load-path and ensure it can be required. " +
          `Original error: ${error}`
      )
    }
  }

  private runEval(elisp: string): string {
    try {
      const result = execFileSync(
        "emacsclient",
        ["--eval", elisp],
        {
          encoding: "utf-8",
          timeout: this.timeout
        }
      )
      return result.trim()
    } catch (error) {
      throw new Error(`Failed to communicate with Emacs: ${error}`)
    }
  }

  private escapeElispString(value: string): string {
    return value
      .replace(/\\/g, "\\\\")
      .replace(/"/g, '\\"')
      .replace(/\n/g, "\\n")
      .replace(/\r/g, "\\r")
      .replace(/\t/g, "\\t")
  }

  private formatElispArg(value: string | number | boolean | null): string {
    if (typeof value === "string") {
      return `"${this.escapeElispString(value)}"`
    }
    if (typeof value === "number") {
      return value.toString()
    }
    if (typeof value === "boolean") {
      return value ? "t" : "nil"
    }
    if (value === null) {
      return "nil"
    }
    throw new Error("Unsupported elisp argument type")
  }
}
