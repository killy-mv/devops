# CI/CD

A tiny bakery web app with a **GitHub Actions** pipeline. Every push tests the app, and if the tests pass, builds a Docker image and publishes it to GitHub's container registry. Broken code never ships.

## What is CI/CD?

A robot that runs the same steps on **every push**, so nobody has to remember to.

| Part   | Stands for                                   | Question it answers     | In this demo                          |
|--------|----------------------------------------------|-------------------------|---------------------------------------|
| **CI** | Continuous Integration                       | *Is the code OK?*       | Run the tests on every push and PR    |
| **CD** | Continuous Delivery / Continuous Deployment  | *Ship it*               | Build the image, push it to `ghcr.io` |

- **Continuous Delivery**: every passing change is *ready* to deploy; a human presses the button.
- **Continuous Deployment**: every passing change goes live automatically.

This demo stops at publishing the image (delivery). In a real job, a server or Kubernetes would then pull that image.

## The pipeline

```
git push (touches CI-CD/)
   │
   ▼
┌── job: test (CI) ──────────┐  pass   ┌── job: build-and-push (CD) ──────────┐
│ checkout code              │ ──────► │ log in to ghcr.io                    │
│ install Node.js 22         │         │ build Docker image                   │
│ npm test                   │         │ push :latest and :sha-<commit>       │
└────────────────────────────┘         └──────────────────────────────────────┘
        │ fail                              (skipped on pull requests)
        ▼
   ❌ stop, nothing ships
```

| Event                         | `test` | `build-and-push` |
|-------------------------------|--------|------------------|
| Push to `main` touching `CI-CD/` | ✅ runs | ✅ runs if tests pass |
| Pull request touching `CI-CD/`   | ✅ runs | ⏭️ skipped        |
| Push that doesn't touch `CI-CD/` | ⏭️ pipeline doesn't start at all | |
| *Run workflow* button (Actions tab) | ✅ runs | ✅ runs if tests pass |

## What's in the demo

```
.github/workflows/ci-cd.yml   # the pipeline (GitHub only reads workflows from the repo root)
CI-CD/demo/
├── app.js                    # web server: bakery page on /, JSON on /health
├── app.test.js               # tests (Node's built-in test runner, no dependencies)
├── package.json              # `npm test`, `npm start`
├── Dockerfile                # packages the app; receives the commit ID as GIT_SHA
└── .dockerignore
```

## Try it locally first

Requirements: Node.js 22+ (Docker optional).

```bash
cd CI-CD/demo
npm test                      # what CI will run
npm start                     # http://localhost:3000
curl localhost:3000/health    # {"status":"ok","version":"dev"}
```

Running the tests yourself before pushing is good practice. CI is the safety net, not the first check.

## Walkthrough

### Step 1: First run ✅

Commit and push the demo (the workflow file and `CI-CD/`):

```bash
git add .github/workflows/ci-cd.yml CI-CD/
git commit -m "ci-cd demo"
git push
```

On GitHub, open your repo's **Actions** tab. Then:

- Click the running **CI-CD demo** workflow and watch `test`, then `build-and-push`.
- Click a job to see every step's log, the same output you'd see in a terminal.
- When it's green, the run's **Summary** lists the published image tags.
- The image appears under your GitHub profile's **Packages** tab, named `bakery`.

### Step 2: Run the image the pipeline built 🐳

```bash
docker run --rm -p 3000:3000 ghcr.io/killy-mv/bakery:latest
curl localhost:3000
# <h1>Sweet Bakery</h1> ... Version: a1b2c3d   ← the commit that built it
```

If the pull is denied, the package is private (the default). Either make it public under *Package settings → Change visibility*, or log in first: create a token with `read:packages` at *GitHub → Settings → Developer settings → Personal access tokens*, then run `docker login ghcr.io -u killy-mv`.

You didn't build this image. The pipeline did, from the exact code in git. Anyone on the team gets the identical image.

### Step 3: A normal change ships automatically 🚀

The bakery changes its hours. In `app.js`:

```js
const OPENING_HOURS = "Open 7am - 5pm";
```

```bash
npm test && git commit -am "open at 7am" && git push
```

After the pipeline finishes, pull and run again: `docker pull ghcr.io/killy-mv/bakery:latest`, then repeat step 2. The page shows the new hours and the new version.

### Step 4: A broken change is blocked ❌

Introduce a typo in `app.js`:

```js
const BAKERY_NAME = "Sweat Bakery";
```

Push it **without** running the tests (pretend you forgot):

```bash
git commit -am "oops" && git push
```

On the Actions tab:

- `test` is **red**: `page shows the bakery name` failed, and the log shows the expected vs actual text.
- `build-and-push` is **skipped**. `:latest` still points to the last good image, so users never see the typo.
- GitHub emails you about the failed run.

Fix it, push again, and it goes green.

### Step 5: Pull requests: check *before* merging 🔀

```bash
git switch -c new-hours
# edit OPENING_HOURS in app.js
git commit -am "weekend hours" && git push -u origin new-hours
```

Open a pull request on GitHub. The PR page shows the `test` check running, then ✅ or ❌, **before** you merge. `build-and-push` doesn't run for the PR; it runs only after you merge into `main`.

On real teams, branch protection (*Settings → Branches*) can **require** the check to pass before the merge button works.

### Step 6: Roll back to an older version ⏪

Every run pushes two tags: `latest`, and `sha-<short commit>`. Find older tags under *Packages → bakery*, then:

```bash
docker run --rm -p 3000:3000 ghcr.io/killy-mv/bakery:sha-a1b2c3d
```

Because every version is kept and named after its commit, you always know exactly which code is running, and going back is one command.

## Key concepts

| Term            | Meaning                                                   | In the demo                                  |
|-----------------|-----------------------------------------------------------|----------------------------------------------|
| Workflow        | One pipeline file                                         | `.github/workflows/ci-cd.yml`                |
| Trigger (`on:`) | What starts it                                            | push to `main`, pull request, manual button  |
| Job             | A group of steps on one fresh machine                     | `test`, `build-and-push`                     |
| Step            | One command (`run:`) or reusable action (`uses:`)          | `npm test`, `actions/checkout@v4`            |
| Runner          | The machine a job runs on (fresh and empty each time)     | `ubuntu-latest`, provided by GitHub          |
| `needs:`        | Job order / dependency                                    | `build-and-push` needs `test`                |
| Artifact        | The thing the pipeline produces                           | Docker image in `ghcr.io`                    |
| Secret / token  | Credentials the pipeline uses, never written in code      | `secrets.GITHUB_TOKEN`                       |

## Notes and gotchas

### Each job starts on an empty machine

That's why both jobs begin with `actions/checkout`: nothing is carried over between jobs or runs. It's also why CI catches "works on my machine" bugs, because the runner only has what's in git.

### `GITHUB_TOKEN` is created per run

You never paste a password into the workflow. GitHub creates a short-lived token for each run, and `permissions:` limits what it can do (`packages: write` only in the CD job). Your own secrets (API keys, server passwords) go in *Settings → Secrets and variables → Actions* and are used as `${{ secrets.NAME }}`.

### `paths:` filters keep other demos quiet

The workflow only starts when `CI-CD/` or the workflow file itself changes. Edit the firewall demo, and no pipeline runs.

### Image names must be lowercase

`ghcr.io/<owner>/bakery` uses your GitHub username. Registry names must be lowercase. `killy-mv` already is, but a `Killy-MV` account would break the push.

### Cost

Free for public repos. Private repos get free monthly minutes. This pipeline takes about 1 to 2 minutes per run.

## Where this goes next

In a real setup, the CD job would continue after pushing the image. It would:

- SSH into a server and run `docker pull` + restart, or
- run `ansible-playbook` to roll out to many servers (`configuration/`), or
- run `terraform apply` to create or update infrastructure first (`provisioning/`), or
- update a Kubernetes deployment (`kubernetes/`).

The idea stays the same: **every step that used to be manual becomes a step in the pipeline.**
