export function createFakeServer() {
  const tools = new Map()
  return {
    registerTool(name, _metadata, handler) {
      tools.set(name, handler)
    },
    callTool(name, args) {
      if (!tools.has(name)) {
        throw new Error(`Tool ${name} is not registered`)
      }
      return tools.get(name)(args, undefined, undefined)
    }
  }
}

export function createStubEmacs(responses = {}) {
  const calls = []
  return {
    calls,
    callElispFunction(name, args = []) {
      calls.push({ name, args })
      const response = responses[name]
      if (response === undefined) throw new Error(`No stubbed response for ${name}`)
      if (typeof response === "function") return response(args)
      return response
    },
    parseElispString(str) {
      if (str.startsWith('"') && str.endsWith('"')) return str.slice(1, -1)
      return str
    }
  }
}
