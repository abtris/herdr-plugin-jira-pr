# herdr-plugin-jira-pr

A [Herdr](https://herdr.dev) plugin that shows the Jira issue behind the current
branch's pull request, so you can see whether an agent carried the ticket you
assigned it into the PR it opened.

The line appears under the agent in the Agents sidebar:

```
● claude · working
  #45 KR-1234 Fix the retry loop · In Review
  krypton-kag · shell
```

When the branch says one ticket and the PR says another — the usual way a PR
ends up linked to the wrong issue — you get this instead:

```
● claude · working
  ⚠ #45 KR-1234 (branch) ≠ KR-1240 (PR)
  krypton-kag · shell
```

The other warning is a ticket that never left the branch name, `⚠ #55 KR-1234 not
in PR title`. That is the assignment going missing: you hand an agent a ticket by
branching from it, and the PR is where the ticket has to reappear.

Remaining states: `⚠ #48 KR-9999 not in Jira` when the key is a typo, and
`#45 KR-1234 · jira?` when Jira could not be reached. A PR with no ticket
anywhere shows `#47` on its own — chore work, triage, and repos that do not use
Jira are all normal, and nagging about them trains you to ignore the line. With
no PR for the branch at all, the line disappears.

## How it decides

The branch name carries the assignment, the PR title is where it has to end up.
That mirrors a common convention — branch `$USER/KR-XXXXX-name`, PR title
`type(scope): KR-XXXXX description` — so candidate keys are read from the branch
name, then the PR title, then the PR body, and each is looked up in Jira until one
exists.

Two filters keep noise out of the sidebar. Keys must carry one of the project
prefixes in `JIRA_PROJECTS` (`KR,KRI` by default), so a branch called
`fix/retry-2` never looks like a ticket, and neither does a testbed named
`kr-dev-44`. And a key in the PR body counts only inside a Jira link or behind a
linking word such as `fixes` or `resolves` — bodies mention tickets in passing far
too often for a bare key to mean "this is the issue".

Both warnings need a real issue to fire. The mismatch needs the branch and the PR
each naming a *different* issue that exists in Jira; the missing-from-title
warning needs the branch's ticket to exist. Silence on one side is normal.

## The popup

Herdr's own right-click menus are not extensible by plugins, so the menu hangs off
a key instead. Bind one to the `menu` pane entrypoint and it opens a modal popup
over the current pane:

```
  Jira PR — lprskavec/KR-1234-retry

   ▸ p  #45 KR-1234 Fix the retry loop · In Review
     j  KR-1234 in Jira
     a  assign a ticket…
     c  clear assigned KR-1234
     r  refresh now

  ↑↓ move · enter select · esc close
```

Move with the arrow keys and hit enter, or press the letter shown against a row.
Escape closes the menu, and also backs out of the ticket prompt.

`p` opens the pull request in a browser, `j` opens the issue, `r` re-resolves
immediately instead of waiting for the cache to expire. `a` prompts for a key and
pins it to this repo and branch, which is how you attach a ticket to work whose
branch name does not carry one. A pinned ticket outranks the branch, is checked
against Jira before it is accepted, and inherits the same expectation: it has to
appear in the PR title. With no PR yet, a pinned ticket still shows, so you can see
what an agent is supposed to be working on before it opens anything.

Assigning, clearing, and refreshing leave the menu open on the updated state;
only the two browser actions close it.

```toml
[[keys.command]]
key = "cmd+j"
type = "shell"
command = "herdr plugin pane open --plugin abtris.jira-pr --entrypoint menu"
```

**Pick a key Herdr does not already use.** A custom binding that collides with a
built-in is silently disabled — no error, the key simply keeps doing its old job.
In the `prefix+` namespace that rules out most letters: `prefix+o` is
`open_notification_target` and `prefix+j` is `focus_pane_down`, so both look
tempting and neither works. Run `herdr --default-config` and grep for `prefix+`
before choosing.

A direct `cmd+` chord sidesteps that namespace entirely, since Herdr binds no
`cmd+` keys by default. It does require your terminal to forward the chord rather
than consume it — on Ghostty, check that nothing in its own config binds
`super+<key>`.

## Reading the ticket back

The resolved key is reported as a second token, `$jira_key`, alongside the display
line. Nothing renders it unless you add it to a sidebar row, but any agent in the
pane can read its own assigned ticket and use it when it names a branch or writes
a PR title:

```bash
herdr pane get "$HERDR_PANE_ID" | jq -r '.result.tokens.jira_key // empty'
```

`bash bin/jira-pr ticket` prints the same value for scripts, exiting non-zero when
there is no ticket. Only a key Jira confirms is published, so a typo in a branch
name never reaches an agent this way.

## Requirements

`git`, `gh` (authenticated), `jq`, `curl`, and Herdr 0.8.0 or newer.

## Install

```bash
herdr plugin install abtris/herdr-plugin-jira-pr
```

Put your Jira token in the plugin's config dir:

```bash
cp config.env.example "$(herdr plugin config-dir abtris.jira-pr)/config.env"
$EDITOR "$(herdr plugin config-dir abtris.jira-pr)/config.env"
```

The instance URL defaults to the `server:` value from
[jira-cli](https://github.com/ankitpokhrel/jira-cli)'s config when you have one,
so often the token is the only thing you need to set. Check the setup with:

```bash
herdr plugin action invoke abtris.jira-pr.doctor
```

Then add the `$jira` token to a sidebar row in `~/.config/herdr/config.toml`:

```toml
[ui.sidebar.agents]
rows = [
  ["state_icon", "agent", "state_text"],
  ["$jira"],
  ["workspace", "tab"],
]
```

Then bind the popup as shown above. Refreshing on demand lives in the popup under
`r`, so one binding covers everything; `abtris.jira-pr.refresh-forced` is still
available as a `plugin_action` binding if you would rather have a dedicated key.

Reload with `herdr server reload-config`.

## Refresh behavior

The plugin has no timer of its own. It refreshes on `pane.focused`,
`pane.agent_detected`, and `pane.agent_status_changed` — that last one means an
agent going idle after a push re-checks the PR on its own. A per repo and branch
cache holds each result for `CACHE_TTL` seconds (300 by default), so the frequent
events are cheap; only the first one after the cache expires calls out to GitHub
and Jira. The reported value carries a 15-minute TTL, so a stale line expires
instead of lying to you.

## Spaces instead of Agents

To hang the line off the workspace rather than the agent pane, change
`report-metadata` in `bin/jira-pr` from `pane` to `workspace` (passing
`$HERDR_WORKSPACE_ID`), and use `[ui.sidebar.spaces]` rows.

## Tests

```bash
bash tests/run.sh
```

`herdr`, `gh`, and `curl` are stubbed, so the suite touches neither the network
nor a running Herdr server.

## License

MIT
