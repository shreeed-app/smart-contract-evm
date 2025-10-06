import { FlatCompat } from "@eslint/eslintrc";
import importPlugin from "eslint-plugin-import";
import jsdoc from "eslint-plugin-jsdoc";
import jsxA11y from "eslint-plugin-jsx-a11y";
import noRel from "eslint-plugin-no-relative-import-paths";
import noSecrets from "eslint-plugin-no-secrets";
import promise from "eslint-plugin-promise";
import security from "eslint-plugin-security";
import simpleImportSort from "eslint-plugin-simple-import-sort";
import { dirname } from "path";
import { fileURLToPath } from "url";

/** @type {string} */
const __filename = fileURLToPath(import.meta.url);
/** @type {string} */
const __dirname = dirname(__filename);

/** @type {import("@eslint/eslintrc").FlatCompat} */
const compat = new FlatCompat({
  baseDirectory: __dirname,
});

/** @type {import("eslint").Linter.Config[]} */
const eslintConfig = [
  ...compat.extends("plugin:prettier/recommended"),
  {
    ignores: ["node_modules", "artifacts", "cache"],
  },
  {
    files: ["**/*.js", "**/*.ts"],
    parser: "@babel/eslint-parser",
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
    },
    plugins: {
      import: importPlugin,
      jsdoc: jsdoc,
      "jsx-a11y": jsxA11y,
      "no-secrets": noSecrets,
      promise: promise,
      security: security,
      "simple-import-sort": simpleImportSort,
      "no-relative-import-paths": noRel,
    },
    rules: {
      "security/detect-object-injection": "warn",
      "promise/always-return": "warn",
      "promise/no-return-wrap": "error",
      "promise/param-names": "error",
      "promise/catch-or-return": "warn",
      "import/no-unresolved": "error",
      "import/order": [
        "warn",
        {
          groups: [
            "builtin",
            "external",
            "internal",
            "parent",
            "sibling",
            "index",
          ],
          "newlines-between": "always",
        },
      ],
      "no-restricted-syntax": [
        "error",
        {
          selector: "ImportDeclaration[source.value=/\\\\/]",
          message: "Use forward slashes (/) in imports, not backslashes (\\).",
        },
      ],
      "no-secrets/no-secrets": "warn",
      "jsx-a11y/alt-text": "warn",
      "jsx-a11y/anchor-is-valid": "warn",
      "jsx-a11y/aria-role": "warn",
      "jsdoc/require-description-complete-sentence": "warn",
      "max-len": [
        "warn",
        {
          code: 79,
          comments: 79,
          ignoreUrls: true,
          ignoreStrings: true,
          ignoreTemplateLiterals: true,
        },
      ],
      "capitalized-comments": [
        "warn",
        "always",
        {
          ignorePattern: "eslint",
          ignoreInlineComments: true,
          ignoreConsecutiveComments: true,
        },
      ],
    },
  },
];

export default eslintConfig;
