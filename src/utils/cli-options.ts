export interface CliOptions {
  emacsclientExecutable?: string
}

export function parseCliOptions(args: string[]): CliOptions {
  const options: CliOptions = {}

  for (let i = 0; i < args.length; i++) {
    const arg = args[i]
    if (arg === "--emacsclient-executable") {
      const value = args[i + 1]
      if (!value || value.startsWith("--")) {
        throw new Error("--emacsclient-executable requires a value")
      }
      options.emacsclientExecutable = value
      i += 1
      continue
    }

    if (arg.startsWith("--emacsclient-executable=")) {
      const value = arg.split("=", 2)[1]
      if (!value) {
        throw new Error("--emacsclient-executable requires a value")
      }
      options.emacsclientExecutable = value
      continue
    }
  }

  return options
}
