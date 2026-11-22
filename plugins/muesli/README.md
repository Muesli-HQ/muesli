# muesli plugin source

This skills-only package adapts the repository's `muesli-agent` skill for ChatGPT and Codex. It includes the official app icon from `assets/muesli_app_icon.png`, a portable Agent Plugins manifest, and a Codex compatibility manifest.

In ChatGPT, provide a muesli transcript in the conversation and the skill helps summarize it, extract decisions and action items, or draft notes for muesli. On a Mac with shell-capable Codex, it can also use the installed muesli CLI to inspect Vidshot frames and narration, search Time Turner, and retrieve meetings, dictations, or bounded activity history. `muesli-cli spec` is the runtime command reference.

The package contains no MCP server, remote endpoint, or muesli data sync. ChatGPT cannot directly read a user's local muesli database through this package.

See `PUBLISHING.md` for the release instructions.
