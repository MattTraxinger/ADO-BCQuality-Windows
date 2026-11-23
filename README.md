# BCQuality for Azure DevOps (Windows agents)

Scripts and pipeline pieces that review pull requests in Azure Repos with [BCQuality](https://github.com/microsoft/BCQuality), made to run on **Windows agents**. It mirrors the division of labor in AL-Go for GitHub's Copilot code review ([microsoft/AL-Go#2402](https://github.com/microsoft/AL-Go/pull/2402)): BCQuality owns the AL expertise, this repo owns execution, permissions and publishing. It is a worked example, not part of BCQuality.

A Linux-agent version is at [ADO-BCQuality-Linux](https://github.com/MattTraxinger/ADO-BCQuality-Linux). What differs here:

- The agent CLIs are installed into a private folder and started directly from their installed entry point, never through `cmd.exe` or a global npm shim (`scripts/Install-AgentCli.ps1`, `scripts/Providers/AgentLaunch.ps1`).
- Nothing in the pipeline pieces needs `bash`.
- It can run as steps inside an existing PR validation job, with the calling pipeline writing the settings instead of the PR's target branch (`scripts/Prepare-PrReview.ps1`, `Get-PrContext.ps1 -SettingsFile`). **To wire it into a pipeline, start with [docs/add-to-existing-pipeline.md](docs/add-to-existing-pipeline.md).**
- The in-job flow needs `scripts`, `schemas` and `package.json` available on the agent, by checkout, release download or your own package.
- The standalone `extends` template takes a `pool` parameter (default `windows-latest`) instead of `vmImage`.

## How it works

| Stage | Job | Rights | Does |
| --- | --- | --- | --- |
| Review | Context | `System.AccessToken` (read PR), no Copilot token | Reads PR metadata; reads settings from the **target branch**; decides skip |
| Review | Generate | The chosen provider's secret (variable group), no `System.AccessToken` | Pins BCQuality and the agent CLI, builds the knowledge index, diffs, reviews, runs the acceptance gate, builds `publish-plan.json` |
| Publish | Post | `System.AccessToken`, no Copilot token | Checks the PR head is unchanged, posts threads and a summary, sets status |

Findings cross from Review to Publish only as the `bcquality-review` pipeline artifact. Nothing from the PR is executed.

## Prerequisites

| You need | Notes |
| --- | --- |
| A variable group with the secret for your provider | `copilot`: secret `COPILOT_GITHUB_TOKEN`, a fine-grained GitHub token with the **Copilot Requests** permission, from an account with a Copilot license. `claude-code`: secret `ANTHROPIC_API_KEY`, an Anthropic API key. Only the chosen provider's secret is mapped into the review step. Protect the group with a **Required template** check. Authorize the pipeline to use it. |
| **Contribute to pull requests** for the build identity on the reviewed repo | Project settings, Repositories, Security. The identity is `<Project> Build Service (<Org>)`; if posting fails with TF401027, the error names the identity actually used. |
| Read access to the template repo | If the template repo is in another project, cross-project access may need enabling. |
| A Windows agent with PowerShell 7.5+, git, Node and npm | The scripts require PowerShell 7.5 (`#requires`). The agent installs the pinned CLI with npm into a private folder, so no admin rights or global npm changes are needed. |
| Outbound access from the agent | To the npm registry (the CLI install), github.com (the BCQuality clone, no credentials sent) and the model service (`api.anthropic.com` for `claude-code`, GitHub's Copilot service for `copilot`). |
| `.bcquality/settings.json` on the **target branch** | A PR cannot change its own review settings. If the file is missing or `enabled` is false, the run reports `skipped: review-disabled`. |
| Client agreement allowing code to go to the model host | Your host and model decide where code is processed; BCQuality does not. |

`package.json` must pin `@github/copilot` and `@anthropic-ai/claude-code` to exact versions (the install step refuses anything else).

## Use it

In the client repo, `azure-pipelines/bcquality.yml` (also in `examples/`):

GitHub:
```yaml
resources:
  repositories:
    - repository: bcquality-ado
      type: github
      name: <owner>/<this-repo>
      ref: refs/tags/<template-version>
      endpoint: <github-service-connection>

trigger: none

extends:
  template: templates/bcquality-pr-review.yml@bcquality-ado
  parameters:
    variableGroup: bcquality-secrets   # contains COPILOT_GITHUB_TOKEN
```

Azure DevOps:
```yaml
resources:
  repositories:
    - repository: bcquality-ado
      type: git
      name: <Project>/<Repo>
      ref: refs/tags/<template-version>

trigger: none

extends:
  template: templates/bcquality-pr-review.yml@bcquality-ado
  parameters:
    variableGroup: bcquality-secrets   # contains COPILOT_GITHUB_TOKEN
```

Then add **Build validation** on `main` with this pipeline, policy requirement **Optional**. Commit `.bcquality/settings.json` to the target branch (example: `examples/settings.json`; schema: `schemas/bcquality-ado.settings.schema.json`). Pin the template by tag: after changing the template, publish a new tag and update `ref:`.

**The repository alias must be `bcquality-ado`.** The template checks out its own scripts from that alias, so the scripts that receive the API key always come from the same repository and tag as the template you `extends`. Do not rename it or add a second repository resource for the scripts.

**Restrict the pool.** The `pool` parameter is set by the calling pipeline file, which a pull request can edit, and the Generate job holds the API key. Limit the pipeline's **Agent pool permissions** (Project settings > Agent pools) to the pools you intend, so a PR cannot send the job to another self-hosted pool.



The standalone template reads these from `.bcquality/settings.json` on the target branch. The in-job flow (`examples/pr-validation/`) reads them from a file the pipeline writes itself, never from the repository or the pull request; there, everything beyond the basic step parameters goes in the `extraSettings` parameter (see [docs/add-to-existing-pipeline.md](docs/add-to-existing-pipeline.md)). The keys and rules are the same in both.

| Key | Default | Meaning |
| --- | --- | --- |
| `BCQuality.version` | template's `defaultBCQualityVersion` | Release to clone, `major.minor` (tag `v<version>`); `major.minor.patch` for a release of your own fork |
| `BCQuality.repo` | `https://github.com/microsoft/BCQuality` | Upstream or a fork with a Custom layer. A repository in this Azure DevOps organization is cloned with the build identity; any other host gets no credentials. See [Using a fork of BCQuality](#using-a-fork-of-bcquality) |
| `BCQuality.enabledLayers` | all | `microsoft`, `community`, `custom` |
| `BCQuality.disabledSkills` | none | Repo-relative skill paths |
| `BCQuality.knowledge.allow` | none (keep all) | Globs on clone-relative article paths, for example `microsoft/knowledge/security/**`. When set, only matching articles are kept |
| `BCQuality.knowledge.deny` | none | Globs for articles to remove. Deny wins over allow. See [Knowledge filtering](#knowledge-filtering) |
| `CodeReviewAgent.enabled` | `false` | Opt-in per repo |
| `CodeReviewAgent.branches` | `["main"]` | Target branches that get reviews, as an ordered list of branch patterns with `!` exclusions. A plain name still matches exactly. See [Branch patterns](#branch-patterns) |
| `CodeReviewAgent.excludedAuthors` | none | PR author unique names to skip |
| `CodeReviewAgent.suggestions` | `apply` | `apply` posts a finding's `suggested-code` as a one-click suggestion when it passes the span check; `manual` always posts it as a labelled snippet; `off` leaves it out. See [Suggested changes](#suggested-changes) |
| `CodeReviewAgent.nearDuplicateLines` | `2` | A new finding for the same rule in the same file within this many lines of one of our earlier threads is not posted again. `0` turns it off. See [Repeated findings](#repeated-findings) |
| `CodeReviewAgent.regional.layouts` | none (off) | Path templates for regional copies of a file, each with one `{region}` and one `{path}`, for example `src/Apps/{region}/{path}`. Identical findings across copies become one thread |
| `CodeReviewAgent.regional.primary` | `W1` | The copy that carries the merged thread; otherwise the first region alphabetically |
| `CodeReviewAgent.provider` | `copilot` | `copilot` or `claude-code`. Read from the target branch, so a PR cannot switch it. Unknown values are rejected, never guessed |
| `CodeReviewAgent.model`, `leafModel` | Copilot CLI default | Consolidation and leaf models; never guessed |
| `CodeReviewAgent.consolidation` | `host` | Who merges the review-area reports (tier 2): `host` does it in code, `agent` has the model do it; see [Consolidation](#consolidation) |
| `appFolders` | auto-detect `app.json` | Apps to review |
| `bcVersion` | none | Target BC major, omitted rather than guessed |
| `maxChangedFiles` | 60 | Skip above this many AL/`app.json` files |
| `mode` | `advisory` | `advisory` or `status` (tier 2 only) |
| `tier` | `2` | `2` full runner (use this). `1` quick start: one agent call, and in testing the agent did not compose a valid super-skill report, so it is not recommended. It has no retry and no fallback to tier 2, which a tier 1 review would need before it could be relied on |

## Branch patterns

`CodeReviewAgent.branches` is an ordered list of patterns in the syntax GitHub Actions uses for `branches:` filters (the same one AL-Go uses), matched against the pull request's **target** branch by its short name (`release/2.0`, not `refs/heads/release/2.0`).

```json
{ "CodeReviewAgent": { "branches": ["main", "release/**", "!release/legacy/**"] } }
```

| Pattern | Matches |
| --- | --- |
| `main` | exactly `main` (case-sensitive) |
| `release/*` | `release/2.0`, not `release/2.0/hotfix` (`*` never crosses `/`) |
| `release/**` | both of those (`**` crosses `/`); `feature/**/x` also matches `feature/x` |
| `v[0-9]+` | `v1`, `v123` (a class holds letters, digits and `-`) |
| `v1?` | `v` and `v1`. **`?` and `+` repeat the previous character; they are not wildcards** |
| `a\+b` | a literal `+` (`\` makes the next character literal) |
| `!release/legacy/**` | a leading `!` excludes |

- **The last matching pattern decides**, so order matters: `["release/**", "!release/legacy/**"]` reviews `release/2.0` but not `release/legacy/1.0`; reversed, it reviews both.
- **Mistakes are errors, not silence.** An invalid pattern (a bad `[...]`, a `?` or `+` with nothing before it, a trailing `\`, an empty `!`, whitespace at either end) and a list with **only** exclusions (which could never match) make the run report `settings-invalid: ...` with the reason, instead of quietly reviewing nothing. A repo with the review disabled is skipped as `review-disabled` before the patterns are looked at.
- **Existing configurations keep working.** Plain names such as `main` or `release/2.0` match exactly as before. The one exception is a branch name that contains `+` (Git allows it): write it `\+`. `?`, `*`, `[` and `\` cannot appear in a Git branch name.
- Matching uses .NET's non-backtracking regex engine, so its time is linear in the branch name however many `*` a pattern has.
- Like every other setting, the patterns are read from the target branch, so a pull request cannot widen its own reach.
- A skipped run says why: `branch-not-enabled: <target>`.

## Knowledge filtering

`BCQuality.knowledge.allow` and `deny` limit which knowledge articles a review can use, for example to leave out a domain your team has decided not to follow. BCQuality's own tools do not enforce these rules (the index builder only records them, and `enabled-layers` only narrows discovery), so setup deletes the unwanted articles, and their `<slug>.good.al` / `<slug>.bad.al` samples, from the temporary clone before it builds `knowledge-index.json`. The agent cannot read what is not there.

```json
{ "BCQuality": { "knowledge": { "deny": ["**/performance/**", "community/knowledge/agents/**"] } } }
```

- Patterns match the clone-relative path with forward slashes, such as `microsoft/knowledge/security/some-article.md`. `*` and `?` stay inside one path segment, `**/` matches any depth (including none), and matching is case-sensitive.
- Patterns are read from the target branch, so a PR cannot widen its own knowledge. Empty patterns, absolute paths and `..` are rejected.
- A pattern that matches nothing is not an error, so a typo removes nothing. Check `knowledge-filter-report.json` in the `bcquality-review` artifact (and `knowledgeFilter` in `diagnostics.json`): it lists every removed file with the reason (`deny-list-hit`, `allow-list-miss` or `layer-disabled`), the number of articles indexed, and a SHA-256 of the retained content.
- If the rules remove every article the setup step warns, and reviews report that no knowledge applies.
- Allow/deny rules apply to the enabled layers. A layer left out of `BCQuality.enabledLayers` is deleted from the clone too (its knowledge, code samples and skills), because BCQuality's `enabled-layers` only narrows discovery and the agent can read anything on disk. `microsoft` must stay enabled: the review's super-skill lives in that layer, and setup fails early with a clear message if it is not.

## Using a fork of BCQuality

A company's own rules go in a fork of [BCQuality](https://github.com/microsoft/BCQuality), in its `custom/` layer (`custom/knowledge/<domain>/` and `custom/skills/`). Custom wins over Community and Microsoft where they contradict; otherwise the layers add up. Upstream does not take custom rules, and BCQuality's [Customizing BCQuality](https://github.com/microsoft/BCQuality/blob/main/docs/customizing-bcquality.md) describes how to write them.

The full setup is in [docs/bcquality-fork.md](docs/bcquality-fork.md). In short:

1. Create an empty repository in your Azure DevOps organization and seed it with `pwsh scripts/New-BCQualityFork.ps1 -TargetUrl https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/BCQualityFork -Version 1.9`. That clones it, adds Microsoft's repository as `upstream`, and pushes `main` at the upstream release plus a `v1.9` tag.
2. Add the rules on a branch, merge it, and tag a release of your own: `v<upstream release>.<n>`, for example `v1.9.1`. The pipeline clones that tag. To take a newer upstream release, merge it into the fork (do not overwrite the fork with a download). `examples/bcquality-fork/sync-upstream.yml` does that on a schedule in the fork: when Microsoft publishes a release it merges it into a branch and opens a pull request (tags only, never upstream's `main`).
3. Point the review at the fork and turn the custom layer on:

   - standalone template: `.bcquality/settings.json` on the target branch;
   - in-job flow: the `extraSettings` step parameter, and `enabledLayers: 'microsoft,community,custom'` (that parameter defaults to `microsoft,community`).

   ```json
   { "BCQuality": { "repo": "https://dev.azure.com/ORG/PROJECT/_git/BCQuality", "version": "1.9.1", "enabledLayers": ["microsoft", "community", "custom"] } }
   ```

4. Let the build identity read the fork. In the same project this is usually already true; for a fork in another project give the project's build service identity Read access to the repository.

**Credentials.** When `BCQuality.repo` is on the same Azure DevOps organization as the build (same host, and under the organization's path on `dev.azure.com`), the clone sends the build's `System.AccessToken`. It goes in through the environment of that one `git clone` process, so it is not on the command line and not stored in the clone. Any other host, including GitHub, gets no credentials and must be publicly readable. The setup step reads the token from its `SYSTEM_ACCESSTOKEN` variable (the in-job flow's Prepare step already has it; the standalone template maps it into the setup step only). The settings file is read from the target branch, so a pull request cannot send the token somewhere else.

**Links.** Comments link each cited article at the exact commit that was reviewed: GitHub style (`/blob/<commit>/<path>`) for a GitHub repository, and `?path=/<path>&version=GC<commit>` for an Azure DevOps one.

The review summary names the BCQuality version and commit that were used, and the run diagnostics record the repository. Layers are not an access boundary: a layer you disable is deleted from the clone, but a custom rule is visible to everyone who can read the fork.

## Run metrics

Every agent call is logged with the usage its CLI reported, and the run ends with a totals line plus two artifact files in `bcquality-review`: `run-metrics.json` (totals and one record per call: app, role, skill, attempt, requested and observed model, seconds, usage, error) and a `metrics` summary in `diagnostics.json`. The step log prints a `usage:` line after each call and `Usage: N agent call(s) ...` at the end.

- **Source.** Usage comes from the CLI's own output, never from the model: Claude Code's final `result` event (tokens, API-equivalent cost, and the models it actually used), and Copilot CLI's `session.usage_record` events in the session `events.jsonl` that retrieval evidence already reads (tokens, premium requests, AI credits). No telemetry setup is needed. The Copilot shape was checked against real sessions from CLI 1.0.105; the Claude shape against a real 2.1.187 capture.
- **One token convention.** `inputTokens` is fresh (uncached) input only; cache reads and cache writes are separate fields, so the three add up to the prompt size. Copilot reports the whole prompt in one number, so its cache parts are subtracted. A field a provider does not report is `null`, not 0.
- **Cost differs by provider.** `costUsd` (Claude) is the API-equivalent price, not necessarily what you are billed. Copilot reports `aiCredits` and `premiumRequests` instead.
- **Totals are a lower bound when a call fails.** A call that times out or errors returns no usage. `callsWithoutUsage` counts them and the run warns; `usage.complete` is false.
- **Model check.** Each call's requested model is compared with the model the CLI reported. `verified` means the requested model, or a `-YYYYMMDD` snapshot of its name, is among the models reported. Claude Code also reports a small helper model (Haiku) for its own side tasks on most calls; that is listed as information (`otherModels` in `run-metrics.json`), not a warning. `mismatch` means the requested model was not reported (for example `sonnet` resolving to `claude-sonnet-4-6`) and raises a pipeline warning; `unverifiable` means the CLI reported no model; `not-requested` means no model was set, so the CLI default ran. A mismatch is reported, not failed: findings are still validated by the acceptance gate. Use full model names in `CodeReviewAgent.model` and `leafModel`.
- Not measured: calls that fail report no tokens, so their cost is not in the totals, and nothing here converts Copilot credits to money.

### Consolidation

A tier 2 review ends by rolling the area reports up into one report. By default (`CodeReviewAgent.consolidation: "host"`) the pipeline does that in code (`scripts/HostConsolidation.ps1`) instead of asking the model:

- **What it does.** The area reports go into `sub-results` unchanged and in worklist order. Every finding of a non-failed area becomes a top-level finding with `from-sub-skill` set. A finding with no citation (an agent finding) keeps its text and gets the id prefix `<area>:`. Findings that overlap and prescribe the same correction are merged (highest severity and confidence, references added), because BCQuality's validator requires that. Outcome, counts and coverage are derived from the area reports.
- **Same gate.** The result goes through the same acceptance gate as before (`Validate-FindingsReport.ps1 -SkillKind super` with the host-owned composition). If the gate rejects it, the agent does the roll-up instead (with its one retry), and the rejected host report is kept as `raw/consolidation-host.json` with the gate text beside it. Both rejected still fails the review closed.
- **Why.** The model merge cost about $0.5 per review in output tokens and it could drop or rewrite a finding. In one measured run, the model merge did exactly that: it folded an agent finding into a cited one, which the validator does not accept. Done in code, every finding is kept and the merge is the same every time.
- **What is lost.** The super-skill's own cross-cutting self-review pass (agent findings attributed to `agent`, `domain: "Agent"`) is not performed, because it needs a model. A review that produced none of those loses nothing. To keep that pass, set `CodeReviewAgent.consolidation` to `"agent"`.
- **Where it shows.** `result.json` records `consolidation` (`host` or `agent`) per app, and the step log says which one ran.

### Prompt-cache sharing (Claude Code, tier 2)

A tier 2 review makes one call per review area plus one for the final merge, and each call is a separate Claude Code process. Cache writes were the largest part of the bill (about three quarters of it in a measured day), so the calls are arranged to share a cached prefix:

- **Shared system-prompt text.** BCQuality's `skills/entry.md` and `skills/do.md` (about 16k tokens) are the same for every call. They are written once per run to `shared-context.md` in the `bcquality-review` artifact and appended to the system prompt (`--append-system-prompt-file`), so the first call writes them to the cache and the others read them from it, instead of every call reading them with the Read tool and writing them to the cache again. The prompts tell the agent not to read the two files again, and to read them from disk if that section is missing.
- **A stable front.** Every call runs in the same empty working directory (`bcq-claude-cwd` in the temp folder) and passes `--exclude-dynamic-system-prompt-sections`, which moves the working directory, environment and `--add-dir` list out of the system prompt into the first user message. Before, a random folder name per call changed the system prompt each time.
- **Tier 1 and Copilot are unchanged.** Tier 1 is one call, so nothing is shared. Copilot has no equivalent option and still reads the two files.
- **Check the effect.** Compare `usage:` lines before and after: the first call should still write the prefix, later calls should show it as cache read, and cache write per call should fall by roughly the size of the prefix. Two live runs of the Linux version have been compared by their logged cost: one measured run at $2.00 before this change and the host roll-up, and one at $1.41 after both. Most of the drop came from no longer asking the agent to do the roll-up; the effect of the shared prefix alone has not been measured, and nothing has been measured on Windows agents. Two runs are a small sample, and the logged cost is an API-equivalent figure that runs above the published rates.

## What a comment looks like

Each finding is one thread on the changed line. The first line is a severity marker, the severity and the confidence; then the message, an optional suggestion (see below), and a link to every knowledge article the finding cites:

````
🟠 **MAJOR** · confidence: high

Count() > 0 materializes a count the caller does not need; use IsEmpty() for an existence check.

Knowledge:
- [microsoft/knowledge/performance/use-isempty-for-existence-check.md](https://github.com/microsoft/BCQuality/blob/<commit>/microsoft/knowledge/performance/use-isempty-for-existence-check.md)
````

- **Markers.** 🔴 blocker, 🟠 major, 🟡 minor, 🔵 info, and a neutral ⚪ for anything else. The same marker prefixes findings listed in the summary because they could not be anchored to a changed line.
- **Knowledge links.** One article is shown on a single `Knowledge:` line; several become a list, in the order the finding cites them, each once. Links are pinned to the BCQuality commit that was reviewed against, not to a moving tag. Characters that would end a link early (`[`, `]`, `(`, `)`, spaces) in a path are escaped. If no base URL is known the paths are shown as plain code.
- **Agent findings.** A finding with no knowledge reference has no `Knowledge:` line and is labelled `_Advisory: agent finding without a BCQuality knowledge reference._`
- **Not included.** No iteration counter (each reviewed head gets its own summary thread rather than one edited in place) and no version or label markers inside the comment text: the data the review needs later is kept in invisible thread properties (`BCQuality.Fingerprint`, `Kind`, `Rule`).

## Suggested changes

BCQuality findings can carry `suggested-code`: a literal replacement for the lines in `location.line` (or `location.range`). Azure Repos can show such a comment as a suggestion that the PR author applies and commits from the PR page (it replaces the lines the comment thread is anchored to). The publish plan turns each `suggested-code` into one of three things:

- **One-click suggestion** (`apply`). The thread is anchored over exactly the lines being replaced and the comment carries a fenced `suggestion` block.
- **Manual snippet.** A labelled `al` block that says why it is not one-click (for example "it would replace lines this pull request did not change"). The advice is never dropped.
- **Nothing.** No suggestion, `suggestions: off`, or the suggestion is identical to the source.

**The span check.** A suggestion is only offered as one-click when every line it would replace is a line this PR **added or changed** (a `+` line in the diff), the span lies inside the file, is at most 25 lines, and `location.range`, if present, contains `location.line`. Context lines are never replaced, so applying a suggestion cannot touch code the PR did not change. The check uses the reviewed head and the diff, both fixed in the Review stage.

- **No re-anchoring.** AL-Go also tries to move a suggestion whose anchor looks wrong by matching it against the file. This does not: a span that fails a check falls back to a manual snippet instead of being moved.
- **Reruns.** Fingerprints do not depend on the suggestion, so changing the setting or a suggestion does not post duplicate threads.
- **Checked on a live PR.** A comment posted with the `suggestion` fence (the tag is set once in `scripts/SuggestionPlacement.ps1`) shows as a suggestion in Azure Repos and **Apply changes** works, with the thread anchored by the start/end offsets this code sends. Microsoft documents the feature but not the tag, so if a future Azure DevOps change breaks it, the symptom is a plain code block instead of an **Apply changes** button: change the tag there, or set `suggestions` to `manual`. Multi-line spans (`location.range`) were not separately recorded.
- Findings that cannot be anchored to a changed line go in the summary comment without their suggestion.
- `publish-plan.json` records `suggestions` (setting, counts of one-click, manual and none, and the reasons), and the Review step logs one line with the same numbers.

## Repeated findings

Two mechanisms keep the same issue from being posted more than once.

**Regional grouping.** Some repositories keep the same code in several regional copies (a W1 base plus country layers). When a change touches several copies, the identical finding lands on each one. With `CodeReviewAgent.regional.layouts` set, identical findings across copies become **one** thread on the primary copy (W1 if present, otherwise the first region alphabetically), and that thread ends with a list of the other copies:

```json
{ "CodeReviewAgent": { "regional": { "layouts": ["src/Apps/{region}/{path}", "src/Layers/{region}/{path}"], "primary": "W1" } } }
```

- Which paths are copies is a repository convention, so it is configured and **off by default**. AL-Go hard-codes Microsoft's own BCApps layout (the example above); this does not assume any layout.
- Only genuinely identical findings merge: the same layout, relative path and line, and the same rule, severity, message, confidence, domain and suggested code. A cluster merges only when it has at least two members, all in different regions. Anything else is left as separate threads.
- The merged thread keeps the primary copy's fingerprint, so a rerun matches it. Findings are still all counted in the summary; `publish-plan.json` records `regional` (layouts, primary, groups, merged copies), and the Review step logs one line.
- A finding that is not anchored to a changed line goes to the summary and is never merged.

**Near-duplicate suppression.** The fingerprint of a finding includes the text around it, so editing the flagged line or its neighbours changes the fingerprint and would post the same issue again. The Publish step therefore also skips a new finding when one of our own earlier threads for the **same rule** is anchored in the **same file** within `nearDuplicateLines` lines (default 2).

- It compares against earlier threads only, so findings posted in the same run never suppress each other.
- It needs the thread to record its rule (`BCQuality.Rule`, written from now on). Threads posted before this change, and threads by anyone else, are never used to suppress anything.
- The trade-off: a genuinely new violation of the same rule within two lines of an old thread (for example the next field, also missing a tooltip) is not posted. Set `nearDuplicateLines` to `0` to turn it off.
- It compares against the line a thread was posted on, so it is meant to catch edits close to the finding. When lines are inserted above it, the fingerprint is what recognizes the thread. (Whether Azure DevOps reports a moved thread at its new line was not checked.)

## What the review does

Tier 2 resolves BCQuality's review areas with `Resolve-SkillWorklist.ps1`, runs each as a separate agent call (Copilot or Claude Code, see [Providers](#providers)), and validates each report with `Validate-FindingsReport.ps1`. The area reports are then merged into one report by the pipeline in code, and the result goes through the same acceptance gate against a host-owned composition artifact; the agent only does that merge if the gate rejects the host's version (see [Consolidation](#consolidation)). That is up to 20 sequential agent calls per app folder (the last one only when the agent does the merge), so expect tens of minutes on a small PR (see `diagnostics.json` for real timings). The step log shows a header with what is being reviewed, a `>>`/`<<` line per step with `step N/M`, a progress bar, and a rough time estimate; agent activity is in collapsed groups.

- **Retrieval evidence.** BCQuality only accepts a finding whose cited article the host recorded as read in full. The host record comes from the agent CLI's own output, never from the model: Copilot's session `events.jsonl` (`scripts/Providers/Copilot/Evidence.ps1`; if exactly one new session cannot be identified, no reads are recorded) or Claude Code's `stream-json` stream (`scripts/Providers/Claude/Evidence.ps1`; a read counts only if it had no range argument and the result reports every line returned). When evidence is missing, findings citing knowledge are rejected.
- **Retry.** A rejected leaf report is retried once with the validator's error. Timeouts and Copilot errors are not retried. Raw returns and full gate messages are kept in the artifact (`raw/`).
- **Normalization.** DO's bounded optional-range repair is allowed; each removed range is recorded in `diagnostics.json`.
- **Never clean by default.** A leaf that still fails is a host-made failed report, the run is `partial`, and the PR summary names the areas not reviewed.
- **Knowledge index.** The agent has no shell, so setup builds `knowledge-index.json` in the pinned clone.
- **Dedup.** Findings are fingerprinted from knowledge ID, file and normalized code context, stored in thread properties, and only read back from threads written by the build identity.

## Providers

| Provider | Secret | Isolation |
| --- | --- | --- |
| `copilot` | `COPILOT_GITHUB_TOKEN` | `--deny-tool shell`, `--deny-tool write`; unattended mode denies anything not pre-approved |
| `claude-code` | `ANTHROPIC_API_KEY`. A local run can use the developer's Claude Code login instead (`BCQ_CLAUDE_AUTH=subscription`, see [Running the review locally](#running-the-review-locally)) | `--tools Read,Glob,Grep` (no shell, write or web), `--permission-mode dontAsk`, reads allowed only inside path-scoped `Read(...)` rules for the directories the review passes, `--safe-mode` (no CLAUDE.md, hooks, skills, plugins or MCP; `--bare` was rejected because it also removes Glob and Grep), and a clean empty working directory so nothing in the PR can configure the CLI |

Claude Code's per-call token counts and cost are captured in the adapter's result (cost is API-equivalent). Not yet shown in the log or `diagnostics.json`.

Verified locally with Claude Code 2.1.187 (the pinned version): scoped reads succeed inside the allowed directory and are denied outside it for Read, Glob and Grep, and the event stream carries the line counts the evidence check uses. While a call runs, the log shows a live line per tool call and a 30-second heartbeat (tool calls so far, thinking tokens, last tool), plus any API retry or rate-limit event. The first line of each call reports the model the CLI actually resolved (the `sonnet` alias resolved to `claude-sonnet-4-6` on CLI 2.1.187; use a full model name if you need a specific model).

Verified on the hosted Ubuntu agent: the `//`-prefixed read rules work (reads inside the scope succeed); that run used `--bare`, which has since been replaced by `--safe-mode`. Claude's Read tool cannot open the 260 KB `knowledge-index.json` (limit 256 KB / 25,000 tokens), and BCQuality's own retrieval helpers need a shell the agent never has, so the adapter writes per-domain slices (`knowledge-index-slices/<domain>.json`, rows copied unchanged, largest about 49 KB) and tells the agent to read those instead. Not yet verified: that the slices let a full review run complete on the hosted agent, whether a symlink committed in a PR can lead a read outside the allowed directories, and the quality and retry rate of leaf reports on a Claude model.

## Running inside an existing PR validation job

Besides the standalone template, the same scripts can run as plain steps inside a job that already checks out the PR. The calling pipeline owns the gating, the secrets and the settings:

| Step | Script | Environment it gets |
| --- | --- | --- |
| Write settings | inline in the pipeline | none. The pipeline writes the settings JSON outside the PR tree; nothing is read from the PR |
| Install agent CLI | `Install-AgentCli.ps1` | none. Installs the pinned CLI into a private folder (no global npm changes) and publishes `BCQ_AGENT_PATH` |
| Prepare | `Prepare-PrReview.ps1` | the build identity's token only. Reads the PR, checks the PR head out into its own worktree, decides eligibility, clones the pinned BCQuality |
| Review | `Run-Generate.ps1` | the provider's secret only |
| Publish | `Publish-PrReview.ps1` | the build identity's token only |

The scripts package must unpack to `<root>\scripts`, `<root>\schemas` and `<root>\package.json`. Prepare sets `BCQ_CONTEXT`, `BCQ_SKIP`, `BCQ_READY`, `BCQ_REPO_DIR`, `BCQ_ROOT` and `BCQ_COMMIT` for later step conditions. `Get-PrContext.ps1 -SettingsFile` takes the pipeline-written file; a missing file is reported as `settings-invalid`, never as defaults.

On Windows, `Providers/AgentLaunch.ps1` starts the CLI directly from its installed entry point (Claude Code's native `claude.exe`, or `node` plus Copilot's script) and never through `cmd.exe`, so prompt text is never parsed by a shell.

## Running the review locally

`scripts/Invoke-LocalReview.ps1` runs the same review on a developer's machine before the push, so most findings can be fixed before the PR exists. It reviews the committed HEAD against the merge base with `origin/<Target>` (the diff a PR into that branch gets) with the PR Validation settings (BCQuality 1.9, `microsoft,community` layers, `claude-sonnet-5-5`, tier 2, advisory), and writes the threads `Publish-PrReview.ps1` would post to `bcquality.md` instead of posting them. It needs no PR and no Azure DevOps token.

```powershell
pwsh -NoProfile -File scripts/Invoke-LocalReview.ps1 -RepoDir C:\src\client-repo -Target main
```

| Parameter | Default | Notes |
| --- | --- | --- |
| `-RepoDir` | current folder | The client repo, on the branch to review. Uncommitted tracked changes stop the run (`-AllowDirty` reviews HEAD anyway, without them) |
| `-Target` | `main` | The branch the PR will target |
| `-OutDir` | `<temp>\bcquality-local\<repo>-<stamp>` | Holds `bcquality.md`, the review artifacts (`review\`) and the work folder |
| `-ListOnly` | | Prints the AL and `app.json` files that would be reviewed and stops |
| `-UseApiKey` | | Authenticates with `ANTHROPIC_API_KEY` instead of the Claude Code login |
| `-BCQualityVersion`, `-EnabledLayers`, `-Model`, `-ExtraSettingsJson` | `1.9`, `microsoft,community`, `claude-sonnet-5-5`, none | Same meaning as the in-job settings step |

**Authentication.** By default the run sets `BCQ_CLAUDE_AUTH=subscription`. The Claude adapter then skips the API key check and removes `ANTHROPIC_API_KEY` from the CLI's environment, so the CLI uses the developer's own Claude Code login (`claude` signed in once interactively). Usage counts against the developer's plan limits. The adapter refuses subscription mode when `TF_BUILD` is set, and `Invoke-LocalReview.ps1` refuses to run in a pipeline at all, so pipelines keep using the API key. Without the variable nothing changes.

**Cost and time.** Measured on an 11-file AL change: 38 agent calls, 10 to 13 minutes, about USD 14 API-equivalent. Run it once per branch before the PR, not on every commit. The reviewer is not deterministic, so a local run catches most findings, not all of them.

**Prerequisites.** PowerShell 7.5+, git, Node and npm (the pinned CLI is installed once per version into the cache folder), Claude Code signed in, and network access to npm, github.com and `api.anthropic.com`.

## Layout

| Path | Purpose |
| --- | --- |
| `templates/bcquality-pr-review.yml` | Template clients `extends` |
| `templates/steps/` | Pinned BCQuality (and knowledge index) and Copilot CLI setup |
| `scripts/Common.ps1` | Settings loading, outcome ranking, optional-property helper |
| `scripts/Get-PrContext.ps1` | Eligibility, target-branch settings, head SHA, merge base |
| `scripts/New-BCQualityFork.ps1`, `docs/bcquality-fork.md` | Seeds your organization's copy of BCQuality, and the guide to running it |
| `scripts/Sync-BCQualityFork.ps1`, `ForkSync.ps1`, `examples/bcquality-fork/` | Brings a new upstream release into the copy as a pull request; the scheduled pipeline that runs it |
| `scripts/BCQualityRepo.ps1` | Cloning BCQuality (with the build identity for a fork in this organization) and linking to its articles |
| `scripts/Get-PrDiff.ps1` | Per-file diffs with literal pathspecs, grouped by app folder |
| `scripts/Invoke-BCQualityReview.ps1` | Tier 1 / Tier 2 review, acceptance gate, SARIF |
| `scripts/AgentProvider.ps1` | The one seam to the agent (`Invoke-AgentCall`). A new provider is a new folder under `scripts/Providers/` plus one row here |
| `scripts/Providers/Copilot/` | `Adapter.ps1` (runs the CLI) and `Evidence.ps1` (reads Copilot's session events) |
| `scripts/Providers/Claude/` | `Adapter.ps1`, `Evidence.ps1` (reads the stream-json output) and `IndexSlices.ps1` (per-domain index slices for Claude's Read limit) |
| `scripts/Run-Generate.ps1` | The Generate job's review step (diff, review, plan), shared by every provider |
| `scripts/Invoke-LocalReview.ps1` | Local run on a developer's machine: no PR, no token, report to `bcquality.md` (see [Running the review locally](#running-the-review-locally)) |
| `scripts/New-ReviewSettings.ps1`, `Prepare-PrReview.ps1`, `Install-AgentCli.ps1`, `Initialize-BCQuality.ps1` | The in-job flow: write the settings, prepare, install the CLI, clone BCQuality (the standalone template shares `Initialize-BCQuality.ps1`) |
| `scripts/Providers/AgentLaunch.ps1` | How each CLI is started on Windows and Linux |
| `scripts/New-PublishPlan.ps1`, `PublishPlan.ps1` | Placement, fingerprints, summary, status |
| `scripts/FindingPlacement.ps1`, `FindingDeduplication.ps1` | Diff-line placement and fingerprints |
| `scripts/AzureDevOps.ps1`, `Publish-PrReview.ps1` | PR threads, statuses, head check |
| `examples/` | Client pipeline and settings to copy; `examples/pr-validation/bcquality-review-steps.yml` is the step template for the in-job flow |
| `docs/` | `add-to-existing-pipeline.md`: wiring the in-job steps into an existing PR validation pipeline, and `bcquality-fork.md`: keeping a private BCQuality fork |
| `tests/` | Pester tests by area (`Settings`, `Publishing`, `AgentProvider`, `Providers/Copilot`, `Providers/Claude`). `tests/fixtures/` holds real Claude Code streams, trimmed and stripped of local paths |

## Decisions the design left open

- **Status rule.** In `status` mode a `completed` run posts `succeeded`, or `failed` if any blocker finding exists. `partial` and `failed` always post `failed`. Skipped and not-applicable runs post `notApplicable`.
- **Summary thread status.** Finding threads are posted active. The summary thread is posted closed when it asks nothing of the author: a `completed` run with no findings (info included), or a run that did not apply (skipped, not-applicable, no-knowledge). An active thread holds a "Comment requirements" branch policy, so a clean summary would otherwise block completion until someone resolves it. `partial` and `failed` summaries stay active.
- **Context job.** The design had one Review stage; PR metadata (draft, author) needs a token, and the Copilot job must not hold one, so Context is its own job in that stage.
- **Agent isolation.** The agent runs with shell and write tools denied so PR content cannot reach the Copilot token in the environment. The unattended CLI also denies anything not pre-approved, which is why reads outside the repo need `--add-dir`.
- **Plugin install.** The agent is pointed at the pinned clone and `skills/al-code-review/SKILL.md` directly instead of `copilot plugin install`.
- **Not implemented.** Parallel leaves (serial in v1), removing obsolete threads, authenticated access to a private BCQuality fork.

## Confirmed

On Linux, in the Linux version's test runs (a full Claude Code Tier 2 review on `ubuntu-latest`, 19 leaves plus consolidation in about 6 minutes on `claude-sonnet-5-5`):

- Copilot CLI runs non-interactively with `-p`, `--add-dir` and `--deny-tool`; the CLI is installed from the pinned npm package.
- Checkout `path:` values (`$(Pipeline.Workspace)/client` and `/tools`) work with `checkout: self` plus a template repo.
- `System.PullRequest.SourceCommitId` matches the PR head the head check compares against; PR `isDraft` and `lastMergeSourceCommit` are read as expected.
- `connectionData` requires `api-version=7.1-preview`; the other calls use `7.1`.
- The validator accepts repo-relative `-SourcePaths`.
- Findings and a summary thread are posted to the PR once the build identity has Contribute to pull requests.

Locally on Windows 11 with PowerShell 7.6 (the Pester suite, 63 tests, passes):

- The Claude adapter runs a real call, with a backslash BCQuality root and forward slashes mixed into the prompt path. The read is allowed and recorded as evidence.
- `Get-PrContext.ps1 -SettingsFile` against a real temporary git repo; `Get-PrDiff.ps1` with an app folder that has a space in its name.
- BCQuality's own `Resolve-SkillWorklist.ps1` (19 leaves) and `Validate-FindingsReport.ps1` accept Windows source paths.

## Still to verify on a hosted Windows agent

- **A full run on the real agent.** Nothing here has run in a pipeline on Windows yet: the npm install of the CLI (the native `claude.exe` is placed by the package's postinstall), outbound access to npm, github.com and the model service, and PowerShell 7.5 on the agent.
- The YAML pieces are unvalidated until Azure DevOps parses them.
- Copilot on Windows (started as `node npm-loader.js`) has not been run; Claude Code is the tested provider.

## Not yet verified

- **Required-template check.** It blocks every bypass: a PR that edits the pipeline file to skip the template must not be able to read the token. Highest priority.
- A PR that edits `.bcquality/settings.json` does not change that run's settings (the code reads the target branch; the live test is not done).
- Rerunning on an unchanged PR creates no new threads (fingerprints in thread properties); a push during a run makes Publish post nothing.
- Findings are anchored to the correct right-side line (`threadContext` fields).
- A forced `partial` is shown as `partial` in the summary and the status; `status` mode and the PR status context.
- Host consolidation: how often the acceptance gate rejects the host's merged report (the agent then does the roll-up). That fallback has been tested only with unit tests, not on a live run.
- Whether the one retry is enough: how often areas still fail validation (for example JSON escaping of AL quotes), and run duration against the 60-minute job limit on larger PRs.
- Whether AL-Go's `Git.ps1`, `FindingPlacement.ps1` and `FindingDeduplication.ps1` can replace the clean-room versions here; if any code is ported, keep AL-Go's copyright notice (see `NOTICE`).

## Tests

Pester 5 or later:

```powershell
Invoke-Pester ./tests -Output Detailed
```
