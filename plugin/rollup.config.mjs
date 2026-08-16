import typescript from "@rollup/plugin-typescript";
import nodeResolve from "@rollup/plugin-node-resolve";
import commonjs from "@rollup/plugin-commonjs";

const OUT = "com.louisalexander.flightdeck.sdPlugin/bin";

export default [
  {
    input: "src/plugin.ts",
    output: { file: `${OUT}/plugin.js`, format: "es", sourcemap: true },
    plugins: [typescript(), nodeResolve({ browser: false }), commonjs()],
    external: ["node:fs", "node:path", "node:os", "node:child_process"]
  },
  {
    input: "src/render.ts",
    output: { file: `${OUT}/render.js`, format: "es" },
    plugins: [typescript()]
  },
  {
    input: "src/splash.ts",
    output: { file: `${OUT}/splash.js`, format: "es" },
    plugins: [typescript()]
  },
  {
    input: "src/command.ts",
    output: { file: `${OUT}/command.js`, format: "es" },
    plugins: [typescript()]
  },
  {
    input: "src/verdict.ts",
    output: { file: `${OUT}/verdict.js`, format: "es" },
    plugins: [typescript()]
  }
];
