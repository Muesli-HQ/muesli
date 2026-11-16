# Publish muesli as a skills-only plugin

muesli is local-first. This package contains a skill and official branding, with no hosted service or MCP server. Check the existing listing for current skills-only submission eligibility. The skill can analyze a muesli transcript supplied in chat; on a Mac with local shell access, it can also guide an agent through `muesli-cli`. Its listing states that a cloud ChatGPT conversation cannot directly browse the user's local muesli data.

## Package and listing

- The portable manifest is `plugin.json`; `.codex-plugin/plugin.json` is a compatibility manifest. Keep their identity and listing copy aligned.
- `assets/muesli-icon.png` is the repository's official 1024×1024 app icon, used as the listing logo and composer icon.
- Select the verified **Muesli** business identity in the OpenAI Platform organization. The package's `author.name` and `developerName` both use **Muesli**.
- The public website, help, privacy, and terms pages are `https://muesli.works/`, `https://muesli.works/help`, `https://muesli.works/privacy`, and `https://muesli.works/terms`. Review the policy pages against the final skill behavior before submission.
- The listing describes supplied-transcript analysis and optional local CLI use. Keep this boundary in screenshots, starter prompts, and any marketing copy.
- The package sets `publication.countries` to `[]` for all available countries and includes version-specific release notes. Confirm both values after import.

## Submission steps

1. Build a ZIP containing exactly one `muesli/` directory with the manifests, skill, and icon. Exclude secrets, symlinks, MCP declarations, app bindings, and UI screenshots.
2. In the [OpenAI Plugins dashboard](https://platform.openai.com/plugins), open the existing muesli plugin under its verified publisher and upload the ZIP as a new metadata and skills version.
3. Check the imported listing and skill. Wait for the required skill safety and security scans, resolve any findings, and review the chosen countries and release notes.
4. Have an authorized developer complete the required policy attestations and submit the draft for review.
5. After approval, select **Publish**. Uploading a draft, submitting for review, and publishing are separate actions.

Skills-only submissions do not require an MCP endpoint, domain challenge, reviewer credentials, five positive and three negative MCP cases, or an MCP demo recording. If muesli later decides to offer live remote access, OpenAI's current guidance says an MCP server cannot be added to an existing skills-only listing; plan that as a separate MCP-backed plugin submission.

Directory approval is subject to OpenAI's skill scans, listing review, and any additional eligibility requirements for skills-only plugins.

References: [submission guide](https://developers.openai.com/plugins/deploy/submission), [submission errors](https://developers.openai.com/plugins/deploy/submission-errors), and [plugin guidelines](https://developers.openai.com/plugins/plugin-guidelines).
