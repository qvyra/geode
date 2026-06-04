import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
	{ ignores: ["node_modules/", ".cache/", "Packages/", "DevPackages/"] },
	js.configs.recommended,
	{
		files: ["types/**/*.ts"],
		extends: [...tseslint.configs.strictTypeChecked, ...tseslint.configs.stylisticTypeChecked],
		languageOptions: {
			parserOptions: {
				projectService: true,
				tsconfigRootDir: import.meta.dirname,
			},
		},
		rules: {
			"@typescript-eslint/naming-convention": [
				"error",
				{ selector: "typeLike", format: ["PascalCase"] },
				{
					selector: "variable",
					modifiers: ["const"],
					format: ["camelCase", "UPPER_CASE", "PascalCase"],
				},
				{ selector: "function", format: ["camelCase"] },
				{ selector: "property", format: ["camelCase", "UPPER_CASE"] },
			],
		},
	},
);
