#!/usr/bin/env bash
# Simple test script for MCP server
echo "Testing MCP server..."

# Test 1: Initialize
echo "Test 1: Initialize request"
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' | bin/mcp-emacs-elisp
echo ""

# Test 2: Tools list
echo "Test 2: Tools list request"
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | bin/mcp-emacs-elisp
echo ""

echo "Tests completed"
