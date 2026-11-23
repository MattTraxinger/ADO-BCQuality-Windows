# Setting up your own copy of BCQuality

Your organization's own review rules go in the **Custom layer** of BCQuality. Upstream (`microsoft/BCQuality`) does not accept custom rules, so they live in a copy you control, in your Azure DevOps organization. This page sets that copy up, keeps it current, and points the review at it.

Replace `YOUR_ORG` and `YOUR_PROJECT` below with your Azure DevOps organization and project. The examples name the repository `BCQualityFork`; any name works.

## What you end up with

- A repository `https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/BCQualityFork` whose `main` is a Microsoft BCQuality release plus your rules under `custom/`.
- Microsoft's repository as the `upstream` remote in your clone, for taking newer releases.
- Release tags in your repository. The review clones one tag, `v<BCQuality.version>`, so a review is repeatable.

## 1. Create an empty repository

In Azure DevOps: **Repos > Files > New repository**, name `BCQualityFork`, and **untick "Add a README"**. The repository has to be empty. From a terminal, with the Azure DevOps extension of the Azure CLI:

```bash
az repos create --name BCQualityFork --project "YOUR_PROJECT" --organization https://dev.azure.com/YOUR_ORG
```

## 2. Seed it with a BCQuality release

Pick the Microsoft release to start from (the tags are listed at https://github.com/microsoft/BCQuality/tags; use the one your reviews pin today in `BCQuality.version`, for example `1.9`). From a checkout of this repository:

```bash
pwsh scripts/New-BCQualityFork.ps1 -TargetUrl https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/BCQualityFork -Version 1.9
```

The script uses your own Git credentials and stops before changing anything if the target has any content, if the target is Microsoft's repository, if the release does not exist, or if its working folder (`-WorkDir`, a temp folder by default) is not empty. It never forces a push. It does these steps, which you can also run by hand:

```bash
git clone https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/BCQualityFork
cd BCQualityFork
git remote add upstream https://github.com/microsoft/BCQuality.git
git fetch --no-tags upstream refs/tags/v1.9:refs/tags/upstream/v1.9
git checkout -B main refs/tags/upstream/v1.9
git tag v1.9
git push origin main refs/tags/v1.9
```

`main` now holds exactly the upstream release, and `v1.9` marks it. Upstream's own tag is kept only in your clone, as `upstream/v1.9`, so it cannot be confused with a release of yours. Check that `git remote get-url origin` is your repository, not `microsoft/BCQuality`, before you add anything.

## 3. Add your rules

Work on a branch and merge it with a pull request, like any other repository. A rule is a knowledge article in the Custom layer, in the same format as the Microsoft ones:

```
custom/knowledge/<domain>/<rule-name>.md        # for example custom/knowledge/style/
custom/skills/                                    # your own review skills, if you need them
```

Custom articles win over Community and Microsoft ones where they contradict each other, and add to them otherwise. BCQuality's guide to the format and a worked example is [Customizing BCQuality](https://github.com/microsoft/BCQuality/blob/main/docs/customizing-bcquality.md). A rule in a domain that no review area covers is never read: a new knowledge domain also needs a skill that discovers it. Keep company content out of any pull request you send to Microsoft.

## 4. Release it

The review runs a tagged release, so a change is not in use until it is tagged. Tag the merge commit:

```bash
git checkout main && git pull
git tag v1.9.1
git push origin refs/tags/v1.9.1
```

Name your releases `v<upstream release>.<n>`: `v1.9` is the untouched upstream release, `v1.9.1` is that release with your first set of rules, `v1.9.2` the next. Never move or delete a tag a pipeline uses; make a new one. In Azure DevOps you can limit who may create and delete tags under **Project settings > Repositories > BCQualityFork > Security**.

## 5. Point the review at your copy

Set the repository and the release, and turn the Custom layer on:

```json
{
  "BCQuality": {
    "repo": "https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/BCQualityFork",
    "version": "1.9.1",
    "enabledLayers": ["microsoft", "community", "custom"]
  }
}
```

- **Standalone template:** put this in `.bcquality/settings.json` on the target branch.
- **In-job flow:** pass the `BCQuality` object in the `extraSettings` step parameter, and `enabledLayers: 'microsoft,community,custom'` (that parameter defaults to `microsoft,community`).

Give the build identity **Read** access to the repository: **Project settings > Repositories > BCQualityFork > Security**, user `YOUR_PROJECT Build Service (YOUR_ORG)`. Inside one organization this is all the clone needs: the review clones with the build's own token, and never sends it to another host. (A fork on any other host has to be publicly readable.) Use URL-encoded project names (`My%20Project`) or plain ones; both work.

To check it worked, open a review's log: the setup step prints `Cloned ... with the build identity`, `BCQuality v1.9.1 at <commit>`, and the number of indexed articles (more than upstream's if you added rules). Review comments link the cited article at that commit, in your repository.

## 6. Take newer Microsoft releases

Microsoft publishes a release as a `v<major>.<minor>` tag. Your copy takes **releases only**, never upstream's `main` branch, which holds unfinished work between releases. A release is merged into your `main` by pull request; your copy is never replaced with a download.

### Automatically (recommended)

`examples/bcquality-fork/sync-upstream.yml` is a pipeline for your fork. Every Monday (and whenever you run it by hand) it checks Microsoft's tags and, if the newest release is not in your `main` yet, merges it into a new branch `sync-upstream-v1.10`, pushes the branch and opens a pull request into `main`. It never changes `main` itself. Set it up once:

1. Copy the file into your fork as `.azureDevOps/sync-upstream.yml` (a normal pull request), replace `YOUR_PROJECT` with the project that holds this tools repository, and create a pipeline from it: **Pipelines > New pipeline > Azure Repos Git > your fork > Existing Azure Pipelines YAML file**.
2. Give the build identity (`YOUR_PROJECT Build Service (YOUR_ORG)`) these permissions on the fork under **Project settings > Repositories > BCQualityFork > Security**: **Contribute**, **Create branch** and **Contribute to pull requests**. It uses the pipeline's own token; there is no stored secret. Also allow the pipeline to read the tools repository.
3. Protect `main` with a branch policy that requires a pull request, so nothing, including this pipeline, changes it directly.
4. Run it once by hand to check. With nothing new it says `Up to date`. Turn on email notifications for failed runs of this pipeline (**Pipelines > the pipeline > ... > Manage notifications**), because a conflict is reported as a failed run.

What a run does:

- **Nothing newer upstream:** it ends successfully (`Up to date`). If a branch for that release is already waiting, it says `Already proposed` and leaves it. Delete the branch to have it proposed again.
- **A clean merge:** it opens the pull request. Look at what changed under `microsoft/` and `community/`, run a review on a sample pull request if your rules rely on upstream articles, and complete it.
- **A conflict:** it pushes nothing and fails, naming the files that conflict. Merge by hand as below.
- **Several releases missed:** it proposes the newest one; it contains the others.

After you complete the pull request, tag the result with your own release and raise `BCQuality.version`:

```bash
git checkout main && git pull
git tag v1.10.1
git push origin refs/tags/v1.10.1
```

The tag is left to you on purpose: it is the moment you confirm your rules still work on the new release. To go back, set `BCQuality.version` to the previous tag.

### By hand

The same steps in your clone (needed for a conflict):

```bash
git fetch --no-tags upstream refs/tags/v1.10:refs/tags/upstream/v1.10
git checkout main && git pull
git checkout -b sync-upstream-v1.10
git merge refs/tags/upstream/v1.10
```

Fix any conflicts (they are in files you changed, usually under `custom/`), run a review on a sample pull request, push the branch, merge it by pull request, then tag the result as above. `scripts/Sync-BCQualityFork.ps1 -RepoDir .` does the whole thing in a clone, including pushing the branch, if you would rather not type it.

## Things to know

- **Custom rules are visible to everyone who can read the repository**, and the Custom layer is not an access boundary. Do not put secrets or customer data in it.
- **Rules are instructions to the model.** Review pull requests to the fork like code.
- **A rule that does nothing:** check its `domain` matches a review area that runs, and that `custom` is in `enabledLayers`. BCQuality's report lists an overridden Microsoft or Community article under `suppressed`.
