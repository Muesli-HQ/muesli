# History skills

Type `/` in Chat, then click a skill or use the arrow keys and Return to insert its tag. The composer shows the skill name in bold with an underline. For example, select **Possible follow-ups**, type “What did I promise yesterday?” after the **Follow-ups** label, and send. Copying the full tag preserves its portable `$follow-ups` form. An explicit tag selects the skill to load. In an untagged chat, the model can choose a relevant skill from the catalog through `read_skill`. Loading instructions grants no additional data access. The model requests a day of history or the most recent meetings, then can inspect excerpts and cite them. The dedicated daily recap uses the date shown on its page. Project brief needs a topic. The answer is a normal saved Chat turn. A follow-up can rewrite that answer in the same conversation, including after reopening it from Recent chats. Generate a saved daily recap from Time Turner → Recap.

Ask “Which meetings did I have last week?” directly in a new chat, or choose **Find meetings** to look up a title. “Last week” means the previous calendar week in your local time zone. An explicitly chosen meeting or folder still limits results.

For meeting-only follow-ups, type **Follow-ups** “for my last 3 meetings.” The skill selects the latest saved meetings across days (up to ten), within any chosen folder, meetings, or date range. An otherwise unscoped new draft uses that request to select recent meetings for this run only. Recap source preferences apply to the Recap page. Chat uses the scope of the conversation.

The shared built-ins are Daily recap, Resume my work, Project brief, Possible
follow-ups and Find meetings. They use sampled evidence and describe possible actions without
executing them. Source changes/deletions invalidate generated results. Hosted
models receive selected text, not screenshots; local models follow the configured
local provider.

Meeting summary templates also appear in Chat’s slash picker. Search by name, press Return to insert the skill, then send your prompt. **New skill…** opens the shared template editor. Saving inserts the new skill into your draft and makes it available for future meeting summaries. Right-click a skill to duplicate it or edit a personal one. **Import…** previews a Markdown file for editing before saving its instructions. Imported scripts, tools and supporting files are unavailable. Personal skills use the existing custom template configuration in the selected app lane. Meetings keep the template snapshot used to generate their notes.

## External agents

Discover tasks and read the common skill:

```sh
muesli-cli skills list
muesli-cli skills get resume-work
muesli-cli skills get muesli-history --markdown
```

To install for an external agent, save the last command's Markdown output as
`SKILL.md` inside that agent's supported skill directory. The CLI does not edit
agent configuration or install anything automatically. It must be available on
that agent's PATH; `muesli-cli spec` provides all usage and examples.

Retrieve the same bounded evidence used by app tasks:

```sh
muesli-cli history sample \
  --from 2026-11-04T00:00:00+05:30 \
  --until 2026-11-05T00:00:00+05:30 \
  --sources meetings,dictations --query Orion
muesli-cli history read dictations 42
```

Omit `--sources` for screen history alone. Sources accept `meetings`, `dictations`,
`commands`, `quill`, `cotypist`, `chat`. CUA supplies command input only; Cotypist
supplies accepted text only. Chats are dated by conversation update time, not
individual message time. An external agent must re-read source IDs and compare
revisions before making claims from a prior sample. Missing or changed evidence
must not be replaced with stale text.

For full screen-history paging and exact screenshot inspection, use
`time-turner history`, `time-turner search` and `time-turner get`. Full meeting
content is available with `meetings get`. The sample is deliberately partial;
it cannot establish that nothing else happened that day. Optional history reads
return at most 16 KB and explicitly flag truncation.

Use `--support-dir` on history commands to select a dev app's data directory.
CLI requests run retrieval only; the external agent uses its own model to execute
the task instructions. They do not run the app's configured hosted model, launch
the app, change capture settings, or execute suggested follow-ups.
