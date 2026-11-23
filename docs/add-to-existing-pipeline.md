# Adding BCQuality to an existing PR validation pipeline

This repo changes nothing in your pipeline. You copy one step template into it, make this repo's scripts available on the agent, and decide what gates the review.

## How it fits

`examples/pr-validation/bcquality-review-steps.yml` is a set of five steps for a job that already checks out the pull request. Each step also requires the `condition` parameter (default `'true'`), so your pipeline decides when a review runs, for example from a variable or a config value.

| Step | Runs | Gets |
| --- | --- | --- |
| Write settings | `New-ReviewSettings.ps1` | nothing. It writes the review settings JSON from the step's parameters plus the optional `extraSettings`; nothing is read from the PR |
| Install agent CLI | `Install-AgentCli.ps1` | nothing. Installs the pinned CLI into a private folder |
| Prepare | `Prepare-PrReview.ps1` | `System.AccessToken` only. Checks the PR head out into its own worktree, decides eligibility, clones the pinned BCQuality |
| Review | `Run-Generate.ps1` | the provider's secret only |
| Publish | `Publish-PrReview.ps1` | `System.AccessToken` only |

Every step is `continueOnError`, so a BCQuality problem never fails PR validation. If something breaks after the PR was read, Publish still posts a FAILED summary, so silence is never mistaken for a clean review.

## One-time setup

1. **Scripts on the agent.** The steps need this repository's `scripts\`, `schemas\` and `package.json` under the `scriptsRoot` parameter (default `$(Agent.TempDirectory)\bcquality-scripts`). Get them there by a checkout of this repo, a release download, or a package you publish yourself. Keep the folder outside the PR's working tree: the Review step holds an API key.
2. **Secret.** Expose the provider's secret to the job as a pipeline variable, for example from a variable group or a Key Vault task. By default the template reads `ANTHROPIC_API_KEY` (provider `claude-code`) or `COPILOT_GITHUB_TOKEN` (provider `copilot`); use the `anthropicKeyVariable` and `copilotTokenVariable` parameters if yours are named differently. Put a spend limit on the key.
3. **Gate.** Decide when the review runs and pass it as `condition`.

## Edit your pipeline

1. Copy `examples/pr-validation/bcquality-review-steps.yml` into your pipeline templates.
2. Include it in the job that validates pull requests, after the PR is checked out (with `fetchDepth: 0`):

   ```yaml
   - template: bcquality-review-steps.yml
     parameters:
       scriptsRoot: '$(Agent.TempDirectory)\bcquality-scripts'
       condition: eq(variables['RunBCQuality'], 'true')
   ```

Defaults in the step template: provider `claude-code`, models `claude-sonnet-5-5`, BCQuality `1.9`, layers `microsoft,community`. Override them with `parameters:` on the `template:` line. Use full model names: an alias such as `sonnet` can resolve to an older model.

`condition` is inserted into each step's `condition:` at compile time, so it must be a valid pipeline condition expression such as `eq(variables['RunBCQuality'], 'true')`. Try it on a test pipeline first.

## Turning on the newer features

Everything below is off or at its default unless you set it, and none of it needs a YAML change beyond the `extraSettings` parameter. In this flow the settings come **only from the pipeline**, never from the repository or the pull request, so `extraSettings` is the one place to set them:

```yaml
    - template: bcquality-review-steps.yml
      parameters:
        extraSettings: '{"BCQuality":{"disabledSkills":["microsoft/skills/review/al-finance-review.md"]},"CodeReviewAgent":{"suggestions":"manual"}}'
```

It is a JSON object merged over the basic settings: objects merge key by key, arrays and values replace. The result is checked against the settings schema before anything is written, so a typo fails the *Write settings* step with the schema's message instead of showing up later as a skipped review.

| Feature | Default | `extraSettings` |
| --- | --- | --- |
| Knowledge filtering | off | `{"BCQuality":{"knowledge":{"deny":["**/performance/**"]}}}`. A layer left out of `enabledLayers` is deleted from the clone too, and `microsoft` must stay enabled |
| Skip review areas (faster, cheaper) | all areas run | `{"BCQuality":{"disabledSkills":["microsoft/skills/review/al-finance-review.md"]}}` |
| Suggested changes | `apply` (one-click when the span passes the check) | `{"CodeReviewAgent":{"suggestions":"manual"}}` or `"off"` |
| Near-duplicate suppression | 2 lines | `{"CodeReviewAgent":{"nearDuplicateLines":0}}` turns it off |
| Regional grouping | off | `{"CodeReviewAgent":{"regional":{"layouts":["src/Apps/{region}/{path}"],"primary":"W1"}}}` |
| Branch patterns | not used here | `branches` is always `**`; your `condition` decides whether a review runs. Patterns apply when settings are read from the target branch (the standalone template) |
| Run metrics, severity markers, links to every article | always on | nothing to set |

The README describes each feature, its rules and its limits.

## Check the agent first

On the agent that runs the job (or any machine like it), these should all succeed:

```powershell
pwsh --version          # 7.5 or later
git --version
node --version
npm ping                # reaches the npm registry
git ls-remote https://github.com/microsoft/BCQuality refs/tags/v1.9
Test-NetConnection api.anthropic.com -Port 443
```

## Test it safely

Try it on one test repository before rolling it out:

1. Put your pipeline edits on a branch and point a test pipeline at it.
2. Make `condition` true for that pipeline only.
3. Open a PR with a small AL change and a normal target branch.

In the step log you should see: the settings JSON, `Claude Code 2.1.x installed; the CLI reports...`, `BCQuality v1.9 at <commit>; reviewing ...`, then per review area `>> [app 1/1 | step N/20] ...` with live tool lines, and finally `Published N new thread(s); summary thread=closed.` (or `active`, or `summary already posted` on a rerun). The review outputs land in `$(Build.ArtifactStagingDirectory)\bcquality-review`; publish that folder as a pipeline artifact if you want to keep it.

To turn it off, make `condition` false.

## If something goes wrong

| What you see | Likely cause |
| --- | --- |
| Write settings step: `The extra settings are not valid JSON` | `extraSettings` is not a JSON object; check quotes and commas |
| Write settings step: `Settings do not satisfy the schema` | A key or value in `extraSettings` is not in the settings schema (`schemas\bcquality-ado.settings.schema.json`); the message names it |
| Install step: `npm install ... failed` | The agent cannot reach the npm registry |
| Install step: `claude.exe is missing after install` | npm ran with install scripts disabled, so the package's postinstall did not place the native binary |
| Prepare step: `Could not clone BCQuality` | The agent cannot reach github.com |
| Prepare step: `No merge base` or `Could not check out PR head` | The checkout is shallow; the job needs `fetchDepth: 0` |
| `BCQuality review skipped: no-al-changes` | The PR has no `.al` or `app.json` changes; normal, and nothing is posted |
| Publish: TF401027 | The build identity needs **Contribute to pull requests** on the repo |
| A script says it requires PowerShell 7.5 | The agent's pwsh is older; the scripts need 7.5 or later |
| Review step runs very long | Check the model name; a heavier default model is much slower. Use `claude-sonnet-5-5` |
| Review summary says PARTIAL | Some review areas failed validation; the summary names them |

## Things to know

- **Keep the scripts out of the PR's working tree.** The Review step holds an API key, so it should run scripts the PR cannot change. That is why `scriptsRoot` defaults to the agent's temp directory.
- **Pin what you download.** If you fetch the scripts from a release or a package, use a fixed version rather than "latest", so a change to this repo reaches your pipeline only when you choose.
- **Only claude-code is verified.** Copilot is wired the same way (`provider: copilot`) but has not been run on Windows.
- **Advisory only.** Findings are posted as PR threads; the status check is not set in this mode.
