import js from "@eslint/js"
import tseslint from "typescript-eslint"
import prettier from "eslint-config-prettier"

export default tseslint.config(
  { ignores: ["dist/**", "node_modules/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["src/**/*.ts"],
    rules: {
      // Allow intentionally-unused args prefixed with an underscore.
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
      // Keep public members at the top of classes, private helpers below.
      "@typescript-eslint/member-ordering": [
        "warn",
        { default: ["public-instance-field", "constructor", "public-instance-method", "private-instance-method"] }
      ]
    }
  },
  // Disable stylistic rules that conflict with Prettier; Prettier owns formatting.
  prettier
)
