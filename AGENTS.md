# Working in this repository

A GKE cluster built with Terraform and deployed to from GitHub Actions, serving
`nginx` and `sky` behind one Gateway. The infrastructure and the delivery live
here. The application is [sky](https://github.com/sindredg/sky), and that
repository has its own guidance.

The README holds the architecture and what has been measured. `plan.md` holds
the phases, `decisions.md` holds why each choice was made. This file holds only
what none of those can tell you.

## Authority

The cluster is real, serves a public domain, and costs about kr462 a week.

Propose, never apply. No `terraform apply`, no `kubectl apply`, no `gcloud`
command that mutates. Write the manifests and the Terraform, open a pull
request, and stop. A human applies and pastes the result back.

Never merge, close, approve, enable auto-merge, or force push a shared branch.
Never weaken branch protection, required checks, or Actions restrictions.

## Changes

Branch names carry a type: `feat/`, `fix/`, `docs/`, `ci/`. Never `claude/`.

The conventional prefix goes in the pull request title, because squash merge
makes it the commit subject. The body says why and what it cost.

Do not stack pull requests. GitHub retargets the child only after the base
merges, and not instantly, so merging both quickly lands the second in a
squash-merged branch where it never reaches `main`.

Confirm CI ran on your head commit, not that the pull request looks green. A
run against an earlier commit displays as three passing checks and has examined
none of your work.

## Evidence

Every claim in the README, `plan.md` and the worklogs has a command and its
output behind it. Do not write one you have not run.

Give the number, not the adjective. Either you measured it or you did not.

A check that passes without examining anything is the worst outcome here,
because it becomes evidence. Two in this repository behave that way.
`scripts/check-docs.sh` reads `git ls-files`, so an unstaged new file is
invisible to it and it reports `ok` having skipped your work entirely.
`kubeconform` runs with `-ignore-missing-schemas`, so every CRD passes
unvalidated, and a misspelled field in a policy applies cleanly and does
nothing.

## The cluster

`terraform plan` must be clean before anything is applied. Check whether an
attribute is `ForceNew` before changing it: `initial_node_count` drifted from
Phase 9 to Phase 11 and would have destroyed both nodes on the next apply.

Both delivery workflows share a concurrency group because two rollouts at once
filled `limits.cpu`. The pipeline Role holds `patch` and not `create`, so a
workload has to exist before the pipeline can update it.

Cost is a constraint, not a footnote. Anything with recurring spend is said out
loud. The load generator and its VPC exist for a session and are deleted after.

## Where writing goes

| File | Holds |
| --- | --- |
| `plan.md` | Phases, their scope, and exit criteria |
| `decisions.md` | Decision, Why, Alternatives, and Cost when there is one |
| `worklog/` | What was run, what came back, and the screenshots |
| `reference/` | How a mechanism works, for a reader who was not there |

A worklog needs screenshots and you cannot take them. Write the prose and leave
the human to capture the images. Never reference an image that is not
committed, and never commit one nothing references: `check-docs.sh` fails both
ways.

## Conventions

Comments are one line or absent. The bar is not "is this true" but "does the
code already say this".

Every agent-authored commit carries `Co-Authored-By: Claude Opus 5
<noreply@anthropic.com>`. Human and Dependabot commits do not.
