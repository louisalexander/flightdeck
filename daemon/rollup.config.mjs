import typescript from "@rollup/plugin-typescript";

const OUT = "dist";

function bundle(name) {
  return {
    input: `src/${name}.ts`,
    output: { file: `${OUT}/${name}.js`, format: "es", sourcemap: true },
    plugins: [typescript()],
    external: (id) => {
      return [
        "node:fs", "node:path", "node:os", "node:child_process", "node:events",
        "@elgato-stream-deck/node", "sharp"
      ].includes(id);
    }
  };
}

export default [
  "row-math", "render-to-image", "fleet-state", "interpreter", "dispatch",
  "keymap", "slot-handler", "boot-handler", "command-handler", "verdict-handler", "index"
].map(bundle);
