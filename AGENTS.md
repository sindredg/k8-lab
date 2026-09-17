# Working in this repository

A GKE cluster built with Terraform and deployed from GitHub Actions. The
application it serves is [sky](https://github.com/sindredg/sky), which has its
own guidance. The README holds the architecture, `plan.md` the phases,
`decisions.md` the reasoning. This file holds what none of them can.

## Authority

The cluster is real, public, and costs money. Propose, never apply: no
`terraform apply`, no `kubectl apply`, no mutating `gcloud`. Open a pull request
and stop. A human applies it and returns the result.

A plan that replaces infrastructure is a finding, not a formality. Say so.

Never merge, approve, force push a shared branch, or weaken a check.

## A green check is not evidence

Confirm what a check examined, not that it passed. `check-docs.sh` reads
`git ls-files`, so it skips a file you have not staged. `kubeconform` runs with
`-ignore-missing-schemas`, so every CRD passes unvalidated and a misspelled
policy field applies cleanly and does nothing. CI has reported three passing
checks against a commit two behind the branch head.

The same standard governs what you write. Every claim in the README, `plan.md`
and the worklogs has a command and its output behind it. Give the number, not
the adjective.

## Changes

Branch names and commit subjects both take a Conventional Commits type. The
name describes the change, not its author.

Squash merge rewrites SHAs, so a branch built on another must be rebased once
its base lands, and never merged while its base is anything but `main`.

## Where writing goes

`plan.md` is what will happen, `decisions.md` is why, `worklog/` is what
happened, `reference/` is how something works.

A worklog needs screenshots you cannot take. Write the prose and leave the
capture.

## Conventions

Comments are one line or absent. The bar is not "is this true" but "does the
code already say this".

Every agent-authored commit carries `Co-Authored-By: Claude Opus 5
<noreply@anthropic.com>`. Human and Dependabot commits do not.
