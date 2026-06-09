import type { Linter } from "eslint";
import tseslint from "typescript-eslint";

const config: Linter.Config[] = [
  {
    ignores: [
      "node_modules/**",
      "artifacts/**",
      "cache/**",
      "coverage/**",
      "types/**",
      "dist/**",
    ],
  },
  {
    files: ["test/**/*.ts", "ignition/**/*.ts", "scripts/**/*.ts", "*.ts"],
    languageOptions: {
      parser: tseslint.parser,
    },
    rules: {
      "max-len": [
        "error",
        {
          code: 9999,
          comments: 79,
          ignoreUrls: true,
        },
      ],
    },
  },
];

export default config;
