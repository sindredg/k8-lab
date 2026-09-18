# Worklog: Phase 14 Close the Baseline

Date: 2026-09-17
Status: Complete. Six slices measured, two findings raised.

## Goal

Close the findings [Phase 13](phase-13-security-baseline.md) measured, in the order the [threat model](../reference/threat-model.md) ranked them. See [Phase 14](../plan.md#phase-14-close-the-baseline).

Every slice below has commands and output behind it. Four were measured when this worklog first landed, and the two that were not were written here as headings with the gap named rather than left out, because a phase that reports only its finished slices reads as complete. Both were closed on 2026-09-18, the load test among them, and it is the phase's own exit criterion.

Where a claim is still unmeasured it is marked in the slice that makes it. Three remain: the causal half of the rate limit claim, whether the availability alert fired, and the overlap between Security Command Center and the static analysers, which cannot be read until its first scan finishes.

## Slice 1: Federation scoped to refs/heads/main

Status: Complete. Both directions measured, and finding 2 is closed.

[#102](https://github.com/sindredg/k8-lab/pull/102) narrowed the provider's `attribute_condition` from the repository to the repository and the ref, closing finding 2 on [boundary 4](../reference/threat-model.md#boundary-4-github-actions-to-google-cloud). The reasoning is in [decisions.md](../decisions.md#federation-trust-boundary).

The plan touched one resource, in place, and replaced nothing:

```bash
terraform -chdir=terraform plan
```

```text
  # module.delivery.google_iam_workload_identity_pool_provider.github will be updated in-place
  ~ resource "google_iam_workload_identity_pool_provider" "github" {
      ~ attribute_condition                = "assertion.repository == 'sindredg/k8-lab'" -> "assertion.repository == 'sindredg/k8-lab' && assertion.ref == 'refs/heads/main'"
        id                                 = "projects/project-69726555-c4de-48de-a69/locations/global/workloadIdentityPools/github/providers/github-oidc"
        name                               = "projects/421458901689/locations/global/workloadIdentityPools/github/providers/github-oidc"
        # (9 unchanged attributes hidden)

        # (1 unchanged block hidden)
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

**The apply's own completion line was not captured and is not reproduced here.** The session ran `apply` against the saved plan and read only the output block that follows it; a second invocation returned `Error: Saved plan is stale`, which is the expected result of a plan already consumed. Convergence is therefore evidenced by the two checks below rather than by an `Apply complete!` line.

The condition that actually landed on the provider:

```bash
gcloud iam workload-identity-pools providers describe github-oidc \
  --location=global --workload-identity-pool=github --format=json
```

```text
{
  "attributeCondition": "assertion.repository == 'sindredg/k8-lab' && assertion.ref == 'refs/heads/main'",
  "attributeMapping": {
    "attribute.ref": "assertion.ref",
    "attribute.repository": "assertion.repository",
    "google.subject": "assertion.sub"
  },
  "displayName": "GitHub OIDC",
  "name": "projects/421458901689/locations/global/workloadIdentityPools/github/providers/github-oidc",
  "oidc": {
    "issuerUri": "https://token.actions.githubusercontent.com"
  },
  "state": "ACTIVE"
}
```

![The condition on the provider, in gcloud's default output](../images/federation-condition.png)

State matches configuration afterwards:

```bash
terraform -chdir=terraform plan -detailed-exitcode
```

```text
No changes. Your infrastructure matches the configuration.

Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.
EXIT=0
```

### Delivery still works

Run [35277444850](https://github.com/sindredg/k8-lab/actions/runs/35277444850), `workflow_dispatch` from `main` with `build_only=true`, conclusion `success`:

```text
1   Set up job                              completed  success
2   Check out this repository               completed  success
3   Read the pinned commit                  completed  success
4   Fetch the application source at the pinned commit  completed  success
5   Authenticate to Google Cloud            completed  success
6   Set up gcloud                           completed  success
7   Authenticate Docker against Artifact Registry      completed  success
8   Set up Buildx                           completed  success
9   Build and push                          completed  success
10  Report the digest                       completed  success
11  Get cluster credentials                 completed  skipped
12  Check the workload exists               completed  skipped
13  Apply the Deployment with the new digest            completed  skipped
14  Wait for the rollout                    completed  skipped
15  Smoke test from inside the cluster      completed  skipped
```

The auth step, which is the one the condition governs:

```text
2026-09-17T21:34:46.9615645Z   workload_identity_provider: projects/421458901689/locations/global/workloadIdentityPools/github/providers/github-oidc
2026-09-17T21:34:46.9616322Z   service_account: k8-lab-deploy@project-69726555-c4de-48de-a69.iam.gserviceaccount.com
2026-09-17T21:34:47.2527109Z Created credentials file at "/home/runner/work/k8-lab/k8-lab/gha-creds-6c6b25e2896b562c.json"
```

Steps 11 to 15 skipped, which is what `build_only` is for.

### The deny direction, settled 2026-09-18

The run above proves a token from `refs/heads/main` is still accepted. It does not prove a token from any other ref is rejected, and that is the direction the finding was about. A provider whose condition silently failed to narrow would produce exactly the output above.

Dispatched from `bump-sky`, a branch that is not `main`:

```bash
gh workflow run "Deploy sky" --ref bump-sky -f build_only=true
gh run view 35357804630 --log-failed
```

```text
2026-09-18T14:41:42.7087254Z Created credentials file at "/home/runner/work/k8-lab/k8-lab/gha-creds-db0aeb9eba445067.json"
2026-09-18T14:41:42.7974694Z ##[error]google-github-actions/auth failed with: failed to generate Google
Cloud federated token for //iam.googleapis.com/projects/421458901689/locations/global/
workloadIdentityPools/github/providers/github-oidc: {"error":"unauthorized_client",
"error_description":"The given credential is rejected by the attribute condition."}
```

Failed at step 5, before the build. Google names the attribute condition as the reason, so the rejection is the control rather than a coincidence. Both directions are now measured and finding 2 is closed.

### The evidence the allow run does not carry

`Created credentials file at ...` appears in **both** runs. It is printed 89 milliseconds before the federated token exchange fails, because it records the action writing a file, not Google accepting anything.

The first version of this slice quoted that line as the auth step working. It does not prove that. What proves it in the allow run is what follows: `Build and push` succeeded, which cannot happen without a token. A line that appears identically on success and on rejection is not evidence, and it took the deny run to notice.

## Slice 2: Branch protection

Status: Complete. Both repositories are protected, and the misread starting state is a finding.

### What was already there

Both repositories answered the classic protection endpoint identically:

```bash
gh api repos/sindredg/k8-lab/branches/main/protection
gh api repos/sindredg/sky/branches/main/protection
```

```text
{"message":"Branch not protected","documentation_url":"https://docs.github.com/rest/branches/branch-protection#get-branch-protection","status":"404"}
gh: Branch not protected (HTTP 404)
```

That 404 was read as "nothing is there, in either repository". **For `k8-lab` that reading is wrong**, and [Phase 13](phase-13-security-baseline.md) had already documented why: the repository is governed by a Ruleset, a separate mechanism the classic endpoint does not see. The trap was recorded in this repository's own worklog and walked into anyway.

The ruleset, read this session:

```bash
gh api repos/sindredg/k8-lab/rulesets
```

```text
21742516 Protect main active 2026-08-28T17:16:30.952+02:00 2026-09-17T20:28:40.082+02:00
```

```bash
gh api repos/sindredg/k8-lab/rulesets/21742516
```

```text
{"conditions":{"ref_name":{"exclude":[],"include":["~DEFAULT_BRANCH"]}},"current_user_can_bypass":"never","rules":[{"parameters":null,"type":"deletion"},{"parameters":null,"type":"non_fast_forward"},{"parameters":{"do_not_enforce_on_create":false,"required_status_checks":[{"context":"Terraform","integration_id":15368},{"context":"Kubernetes","integration_id":15368},{"context":"Docs and scripts","integration_id":15368}],"strict_required_status_checks_policy":true},"type":"required_status_checks"},{"parameters":{"allowed_merge_methods":["merge","squash","rebase"],"dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,"require_extra_approval_for_unattributed_changes":true,"require_last_push_approval":false,"required_approving_review_count":0,"required_review_thread_resolution":false,"required_reviewers":[]},"type":"pull_request"}],"updated_at":"2026-09-17T20:28:40.082+02:00"}
```

So `k8-lab` already required `Terraform`, `Kubernetes` and `Docs and scripts`, with `strict_required_status_checks_policy: true` and `current_user_can_bypass: "never"`. `Static analysis` was the one missing check, which is what this slice was asked to add.

`sky` has no ruleset, so for `sky` the 404 was the whole truth:

```bash
gh api repos/sindredg/sky/rulesets
```

```text
[]
```

### What was set

Classic branch protection, on both:

```bash
gh api -X PUT repos/sindredg/k8-lab/branches/main/protection --input k8lab-prot.json
```

```text
{"url":"https://api.github.com/repos/sindredg/k8-lab/branches/main/protection","required_status_checks":{"url":"https://api.github.com/repos/sindredg/k8-lab/branches/main/protection/required_status_checks","strict":false,"contexts":["Static analysis"],"contexts_url":"https://api.github.com/repos/sindredg/k8-lab/branches/main/protection/required_status_checks/contexts","checks":[{"context":"Static analysis","app_id":15368}]},"required_signatures":{"url":"https://api.github.com/repos/sindredg/k8-lab/branches/main/protection/required_signatures","enabled":false},"enforce_admins":{"url":"https://api.github.com/repos/sindredg/k8-lab/branches/main/protection/enforce_admins","enabled":false},"required_linear_history":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false},"block_creations":{"enabled":false},"required_conversation_resolution":{"enabled":false},"lock_branch":{"enabled":false},"allow_fork_syncing":{"enabled":false}}
```

```bash
gh api -X PUT repos/sindredg/sky/branches/main/protection --input sky-prot.json
```

```text
{"url":"https://api.github.com/repos/sindredg/sky/branches/main/protection","required_status_checks":{"url":"https://api.github.com/repos/sindredg/sky/branches/main/protection/required_status_checks","strict":false,"contexts":["Lint and test","Frontend tests"],"contexts_url":"https://api.github.com/repos/sindredg/sky/branches/main/protection/required_status_checks/contexts","checks":[{"context":"Lint and test","app_id":15368},{"context":"Frontend tests","app_id":15368}]},"required_signatures":{"url":"https://api.github.com/repos/sindredg/sky/branches/main/protection/required_signatures","enabled":false},"enforce_admins":{"url":"https://api.github.com/repos/sindredg/sky/branches/main/protection/enforce_admins","enabled":false},"required_linear_history":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false},"block_creations":{"enabled":false},"required_conversation_resolution":{"enabled":false},"lock_branch":{"enabled":false},"allow_fork_syncing":{"enabled":false}}
```

Effective state, read back this session:

| Repo | Mechanism | Required contexts | Strict |
| --- | --- | --- | --- |
| k8-lab | Ruleset 21742516 | `Terraform`, `Kubernetes`, `Docs and scripts` | true |
| k8-lab | Classic protection | `Static analysis` | false |
| sky | Classic protection | `Lint and test`, `Frontend tests` | false |

### Why "Public surface" was left out

`security-scan.yml` triggers on `pull_request` only for two paths:

```yaml
  pull_request:
    branches: [main]
    paths:
      - 'scripts/check-public-surface.sh'
      - '.github/workflows/security-scan.yml'
```

A required context that never reports leaves a pull request pending forever. Any pull request touching neither path would never produce `Public surface`, so requiring it would block every other change in the repository. Left out deliberately, not overlooked.

### Choices, not defaults

- `strict: false` on both classic rules. Chosen, not inherited. The brief was to require a check, not to change merge mechanics. It does **not** weaken anything: `k8-lab`'s ruleset already sets `strict_required_status_checks_policy: true`, and GitHub evaluates rulesets and classic protection together, taking the more restrictive. The up-to-date requirement Phase 13's open question asked about is already enforced on `k8-lab` by the ruleset.
- `enforce_admins: false` on both. Chosen. The sole collaborator is the only identity that can apply infrastructure and merge. With `required_approving_review_count: 0` and no second reviewer, `true` would leave nobody able to merge. The ruleset's `current_user_can_bypass: "never"` is the stronger control on `k8-lab` and is untouched.

### Finding: two mechanisms now govern one branch

`k8-lab`'s `main` is protected by a ruleset **and** by classic protection, with a disjoint set of required checks and disagreeing `strict` settings. Nothing is weaker for it, but the required-check list for the branch is now spread across two API surfaces, and a future reader of either one sees an incomplete answer. This is the same class of problem Phase 13 found, where an active-looking ruleset matched no branch for three weeks.

The cleaner shape is one mechanism: add `Static analysis` to ruleset 21742516's `required_status_checks` and delete the classic rule on `k8-lab`. That was done on 2026-09-18 and is recorded in [the open table](#what-this-phase-leaves-open) and in [decisions.md](../decisions.md#merge-protection). **No command output for it was captured in this worklog**, so it is the one closure in this phase evidenced by a note rather than by a run. `sky` has no ruleset, so classic protection is the whole answer there and needs no consolidation.

## Slice 3: Content Security Policy on the project page

Status: Complete. Both paths serve a policy, and finding 6 is closed.

[#100](https://github.com/sindredg/k8-lab/pull/100) added the policy. Merging triggered `deploy.yml`. The header as served:

```bash
curl -sS -o /dev/null -D - https://sindrg.com/
```

```text
HTTP/2 200 
server: nginx/1.30.4
date: Thu, 17 Sep 2026 21:35:02 GMT
content-type: text/html
cache-control: no-store
content-security-policy: default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'
via: 1.1 google
referrer-policy: strict-origin-when-cross-origin
strict-transport-security: max-age=86400
x-content-type-options: nosniff
alt-svc: h3=":443"; ma=2592000,h3-29=":443"; ma=2592000
```

That closes the `csp` and `frame-ancestors` findings on the nginx root, and confirms the Phase 13 header set is still present alongside it.

### The page still renders under it

`default-src 'none'` blocks every resource class not named explicitly, so the policy is only safe if the page loads nothing it does not allow. It loads nothing at all:

```bash
grep -c "<script" page.html   # 0
grep -c "<img" page.html      # 0
grep -c "<style" page.html    # 1
curl -sS https://sindrg.com/ | wc -c
```

```text
0
0
1
17149
```

The document is complete, closing tags present:

```text
        </nav>
      </footer>
    </div>
  </body>
</html>
```

Every external reference in the page is an anchor `href`, which no directive in this policy restricts:

```bash
grep -oE '<script[^>]*>|<img[^>]*>|<link[^>]*>|url\([^)]*\)|https?://[^"'"'"' )]*' page.html | sort -u
```

```text
https://github.com/sindredg/k8-lab
https://github.com/sindredg/k8-lab/blob/main/decisions.md
https://github.com/sindredg/k8-lab/tree/main/worklog
```

The single `<style>` block is covered by `style-src 'unsafe-inline'`. `img-src 'self'` is declared and currently unused by any element; it still governs the browser's implicit `/favicon.ico` request, which is same-origin.

### The other path, closed 2026-09-18

`/sky/` served no policy when this was written. [sky#59](https://github.com/sindredg/sky/pull/59) had merged upstream, but the pin still named the commit before it, so the cluster kept building a `sky` without one. [#106](https://github.com/sindredg/k8-lab/pull/106) moved the pin and `deploy-sky.yml` rolled that commit out.

```bash
curl -sS -o /dev/null -D - https://sindrg.com/sky/
```

![The application's own policy, served alongside the Phase 13 header set](../images/csp-sky-headers.png)

The policy is the application's rather than the platform's: `default-src 'self'` with Google Fonts named explicitly, where the project page serves `default-src 'none'`. Each is correct for what it serves, and both are declared by the workload rather than by the Gateway, for the reason [Phase 13](phase-13-security-baseline.md#what-the-run-settles) gives.

With both paths covered, the surface check reported the closure instead of a pass:

![The gate reporting two findings resolved, and naming the lines to delete](../images/surface-resolved.png)

That is the `RESOLVED` direction firing on a real change rather than on a copy of the script, and exiting `1` as [the deliberate test](phase-13-security-baseline.md#the-gate-tested-deliberately) forced it to. Deleting both lines from `KNOWN_OPEN` leaves the surface at:

![Eleven checks passing, with CAA and DNSSEC the only findings open](../images/surface-clean.png)

`caa` and `dnssec` are what remain, and both belong to Slice 4. `caa` closed later in this phase; `dnssec` is the one the surface still carries.

## Slice 4: CAA

Status: Complete. The pair is live and verified, finding 3 is closed, and a new finding was raised on the way.

### What the domain publishes now

Both records were created by hand in Cloudflare with flags `0`, as `DNS only`:

![The two CAA records in the Cloudflare dashboard, and the only two it shows](../images/caa-cloudflare-dashboard.png)

Read back from two public resolvers. The zone's own nameservers do not answer this query form, so they are not the check:

```bash
dig +short CAA sindrg.com @1.1.1.1
dig +short CAA sindrg.com @8.8.8.8
```

```text
0 issue "pki.goog"
0 issuewild ";"
0 issue "pki.goog"
0 issuewild ";"
```

![The derived pair, and nothing else, from a public resolver](../images/caa-verified.png)

Each resolver returns the derived pair and nothing else. No `letsencrypt.org`, `ssl.com`, `comodoca.com` or `digicert.com`, which is the result that decides whether the control is in force rather than partly in force. Google Trust Services is the only CA authorised to issue for `sindrg.com`, no CA may issue a wildcard, and finding 3 is closed.

That is the second reading. The first one looked different.

### Finding: Universal SSL makes the authorised issuer set Cloudflare's to change

Cloudflare adds CAA records for its own partner CAs whenever Universal SSL is on and any CAA record exists in the zone. Adding the pair above turned that on. Queried before Universal SSL was disabled, the same resolver returned this:

```bash
dig +short CAA sindrg.com @1.1.1.1
```

```text
0 issue "comodoca.com"
0 issue "digicert.com; cansignhttpexchanges=yes"
0 issue "letsencrypt.org"
0 issue "pki.goog; cansignhttpexchanges=yes"
0 issue "ssl.com"
0 issuewild ";"
0 issuewild "comodoca.com"
0 issuewild "digicert.com; cansignhttpexchanges=yes"
0 issuewild "letsencrypt.org"
0 issuewild "pki.goog; cansignhttpexchanges=yes"
0 issuewild "ssl.com"
```

![Eleven records returned where the zone holds two, with four partner CAs added](../images/caa-universal-ssl-injected.png)

Eleven records where the zone holds two. Four CAs the platform never authorised, on both tags.

The dashboard screenshot above was taken while this was live. It shows two rows. **The injected records do not appear in the interface that is supposed to display the zone**, so the gap is invisible from the place an operator would look, and is visible only from a resolver. Cloudflare's documentation states the list "is not exhaustive, and other CAs might be added or removed for operational reasons".

Source: <https://developers.cloudflare.com/ssl/edge-certificates/caa-records/>

So while Universal SSL is on, the set of CAs authorised for this domain is Cloudflare's to change rather than the platform's, by a documented process with no announced membership and no representation in the zone's own control panel. A CAA record a third party may extend at its own discretion is not the control [boundary 6](../reference/threat-model.md#boundary-6-dns-and-certificate-issuance) asked for, so Universal SSL was turned off rather than worked around.

### Why the injection was a weakening and not a duplication

RFC 8659 takes the union of the records at a name. It does not resolve them against each other, and there is no precedence between a broad record and a narrow one.

So `issuewild ";"`, the empty issuer set, is inert beside a named `issuewild` record rather than overriding it. The output above proves the point rather than predicting it: `0 issuewild ";"` sits in the same answer as five named `issuewild` records, and a CA reading that set finds itself authorised. Wildcard issuance the derived pair was written to forbid was authorised for four CAs, and the `issue` set was widened the same way.

Both halves of the pair were undone. That is the difference between a cosmetic addition and a real weakening, and it is why the check is what a resolver returns rather than what the dashboard shows.

### How the pair was derived

The rest of this slice is how those two records were arrived at. It is kept in full because the reasoning is reusable for any domain on this platform, and because one step of it is corroborated rather than quoted.

The starting point was an empty answer. No CAA record existed, which is the finding the threat model recorded on boundary 6:

```bash
dig +short CAA sindrg.com @1.1.1.1
dig +noall +answer CAA sindrg.com @8.8.8.8
dig +noall +answer CAA www.sindrg.com @8.8.8.8
```

```text
```

All three returned nothing, so every CA that would issue for this domain was permitted to.

### The issuer, read off the live certificate

Not taken from configuration or from memory:

```bash
echo | openssl s_client -connect sindrg.com:443 -servername sindrg.com 2>/dev/null |
  openssl x509 -noout -issuer -subject -dates -ext subjectAltName -ext authorityInfoAccess
```

```text
issuer=C = US, O = Google Trust Services, CN = WR3
subject=CN = sindrg.com
notBefore=Sep  4 12:17:24 2026 GMT
notAfter=Dec  3 13:13:19 2026 GMT
X509v3 Subject Alternative Name: 
    DNS:sindrg.com
Authority Information Access: 
    CA Issuers - URI:http://i.pki.goog/wr3.crt
```

The chain as served:

```bash
echo | openssl s_client -connect sindrg.com:443 -servername sindrg.com -showcerts 2>/dev/null |
  grep -E "^ *[0-9]+ s:|^ *i:"
```

```text
 0 s:CN = sindrg.com
   i:C = US, O = Google Trust Services, CN = WR3
 1 s:C = US, O = Google Trust Services, CN = WR3
   i:C = US, O = Google Trust Services LLC, CN = GTS Root R1
 2 s:C = US, O = Google Trust Services LLC, CN = GTS Root R1
   i:C = BE, O = GlobalSign nv-sa, OU = Root CA, CN = GlobalSign Root CA
```

One SAN, no wildcard. Issued by GTS WR3 under GTS Root R1, cross-signed by GlobalSign Root CA.

### The CA identifier

A CAA record names an Issuer Domain Name, which is whatever string the CA declares it honours, not the issuer CN read above. For Google Trust Services that string is **`pki.goog`**, per section 4.2.4 of its Certification Practice Statement v5.22, which states `pki.goog` is the only Issuer Domain Name it recognises in `issue`, `issuewild` or `issuemail` records.

Source: <https://pki.goog/repo/cps/5.22/GTS-CPS.html>

**This one item is not pasted verbatim.** The CPS was read through a page fetch that returned a summary of section 4.2.4 rather than its text, so the sentence above is a paraphrase of that summary and not a quotation. The identifier is corroborated independently by the certificate's own AIA URI, `http://i.pki.goog/wr3.crt`, and the record it produced resolves correctly, so it is right in practice. The CPS wording should still be read directly before anyone changes CA or edits the record.

### Why both records, and why flags 0

| Name | Flags | Tag | Value |
| --- | --- | --- | --- |
| `sindrg.com` | 0 | `issue` | `pki.goog` |
| `sindrg.com` | 0 | `issuewild` | `;` |

The second row of that pair is **required, not optional**. RFC 8659 resolves a wildcard request against `issuewild` when one is present, and falls back to `issue` when none is. With `issue "pki.goog"` alone, a wildcard certificate for `*.sindrg.com` from GTS would still be authorised. The served certificate has a single SAN and the platform issues no wildcard, so `issuewild ";"` — the empty issuer set, meaning no CA may issue a wildcard — costs nothing and is what makes the pair mean "this issuer and nothing else".

Flags `0` rather than `128`: the critical flag changes how a CA must treat a property tag it does not understand, and adds nothing for `issue` and `issuewild`, which every compliant CA understands.

### The proxy question, answered before the records were added

DNS is not this repository's to change, and one question decided whether the pair was correct or an outage:

**Is `sindrg.com` proxied through Cloudflare, or is Cloudflare only hosting the zone?** If the zone is DNS-only, the platform's gateway terminates TLS and GTS is the only issuer, so a `pki.goog`-only CAA is right. If the record is proxied, Cloudflare's edge terminates TLS and issues its own certificate through its own CAs, and a `pki.goog`-only CAA would forbid the renewal of the certificate actually facing visitors.

Resolved 2026-09-18:

```bash
dig +short A sindrg.com
dig +short NS sindrg.com
```

```text
8.232.183.150
kareem.ns.cloudflare.com.
eva.ns.cloudflare.com.
```

The A record is the gateway's own address, not a Cloudflare anycast address. Cloudflare hosts the zone and does not proxy this record, so the Gateway terminates TLS and GTS is the only issuer. That cleared the way to add the pair.

### What would break if the pair were wrong

CAA is evaluated by the CA at issuance, not at request time, and the platform renews through Certificate Manager's ACME DNS-01 authorisation. So a wrong record changes nothing visible: the current certificate keeps serving until **2026-12-03**, and the failure appears as an expired certificate on a site that was working the previous day. The failure mode is silent and delayed, which is the same shape as the Cloudflare-versus-Google collision this project already hit at `_acme-challenge`.

### The local resolver reported the opposite for half an hour

`scripts/check-public-surface.sh` queries the system resolver, which on this workstation is a WSL2 stub at `10.255.255.254`. With the records live and correct, it still reported them missing:

```bash
dig +short CAA sindrg.com
dig CAA sindrg.com | sed -n '/AUTHORITY SECTION/,/^$/p'
```

```text
sindrg.com.		1608	IN	SOA	eva.ns.cloudflare.com. dns.cloudflare.com. 2415229573 10000 2400 604800 1800
```

Empty, with the SOA in the authority section. That is a cached negative answer rather than a resolver that cannot answer the query form, and the difference decides what to do about it: the same resolver returns `0 issue "pki.goog"` for `google.com` and a DS record for `cloudflare.com`. The zone's SOA minimum is `1800`, so a NODATA answer cached before the records existed is served for up to 30 minutes after they exist.

The gate was re-run once that TTL expired rather than modified. The stale answer belongs to this workstation, CI resolves through its own runner, and a check changed to work around one machine's cache would have been the wrong fix.

Re-run once the TTL expired, the gate reported the closure and refused to pass on it:

```bash
./scripts/check-public-surface.sh
```

```text
ok        cert-expiry      75 days remaining
RESOLVED  caa              certificate issuance is restricted
          remove caa from KNOWN_OPEN in check-public-surface.sh
known     dnssec           no DS record

11 ok, 1 known open, 0 regressed, 1 resolved, 0 inconclusive
EXIT=1
```

That is the `RESOLVED` direction firing on a finding this phase actually closed. Deleting the `caa` line from `KNOWN_OPEN` leaves `dnssec` as the only entry:

```text
ok        cert-expiry      75 days remaining
ok        caa              certificate issuance is restricted
known     dnssec           no DS record

12 ok, 1 known open, 0 regressed, 0 resolved, 0 inconclusive
EXIT=0
```

Twelve checks passing, and finding 9 is the one the surface still carries.
## Slice 5: The rate limit under flood

Status: Complete. The throttle engaged where the policy says it should, and finding 1 is closed. One claim in it is not isolated.

This is Phase 14's exit criterion and the threat model's outstanding claim on [boundary 1](../reference/threat-model.md#boundary-1-internet-to-gateway).

### The policy under test

From `terraform/modules/gateway/main.tf`:

```terraform
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"

      rate_limit_threshold {
        count        = 300
        interval_sec = 60
      }
    }
```

300 requests per 60 seconds per address is an effective ceiling of 5 rps from one source.

### The resting state

Read before the run:

```bash
kubectl get resourcequota -n demo -o wide
kubectl get hpa -n demo
```

```text
NAME          REQUEST                                                        LIMIT                                            AGE
demo-budget   pods: 4/16, requests.cpu: 800m/5, requests.memory: 384Mi/2Gi   limits.cpu: 2500m/13, limits.memory: 768Mi/4Gi   20d

NAME   REFERENCE        TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
sky    Deployment/sky   cpu: 1%/70%   2         8         2          2d23h
```

### The flood

1200 requests, ten concurrent, one source address, against `https://sindrg.com/`:

```bash
seq 1200 | xargs -P 10 -I{} sh -c 'printf "%s %s\n" "$(date +%s.%N)" "$(curl -s -o /dev/null -w "%{http_code}" https://sindrg.com/)"' > ~/rl.txt
sort -n ~/rl.txt > ~/rl-sorted.txt
awk 'NR==1{s=$1} END{printf "%d requests in %.1fs, %.1f rps\n", NR, $1-s, NR/($1-s)}' ~/rl-sorted.txt
awk '{print $2}' ~/rl.txt | sort | uniq -c
grep -n ' 429' ~/rl-sorted.txt | head -1
```

```text
1200 requests in 79.8s, 15.0 rps
    607 200
    593 429
293:1789744339.285246716 429
```

15 rps offered against a 5 rps ceiling, and 593 of 1200 requests refused with `429`. The throttle is enforcing on live traffic, which is the claim the threat model had marked unproven.

### Where the refusals begin

```bash
awk 'NR==1{s=$1} $2==429 && !seen {printf "first 429 at t+%.1fs, request %d of the run\n", $1-s, NR; seen=1}' ~/rl-sorted.txt
head -292 ~/rl-sorted.txt | awk '{print $2}' | sort | uniq -c
awk 'NR==1{s=$1} {w=int(($1-s)/60); if($2==200) a[w]++; t[w]++} END{for(i=0;i<=1;i++) printf "window %d (t+%ds to t+%ds): %d allowed, %d offered\n", i, i*60, i*60+60, a[i], t[i]}' ~/rl-sorted.txt
```

```text
first 429 at t+18.0s, request 293 of the run
    292 200
window 0 (t+0s to t+60s): 319 allowed, 910 offered
window 1 (t+60s to t+120s): 288 allowed, 290 offered
```

The first 292 requests all returned `200` and the 293rd was the first `429`. That is the shape a spent budget produces rather than a fixed-interval throttle: the window's 300 requests are consumed at whatever rate they arrive, and refusals start when they are gone. At 15 rps a 300-request budget lasts 20 seconds, and the first refusal came at 18.0 seconds.

Two numbers qualify that. Window 0 allowed **319** against a documented 300, so enforcement is approximate at the margin, about 6% over, which is what counting across distributed load balancer instances rather than one counter produces. Window 1 is partial: the run ended at 79.8s, so it spans 19.8 seconds, in which a refilled budget passed 288 of 290.

### The second-order claim: the quota never moved

The claim to test is that the throttle keeps the HPA from scaling, so `demo-budget` stays at its resting pods 4/16 and requests.cpu 800m/5. Sampled every 5 seconds for the duration of the run:

```bash
while kill -0 "$FLOOD" 2>/dev/null; do
  date -u +'--- %H:%M:%SZ'
  kubectl get resourcequota -n demo -o wide --no-headers
  kubectl get hpa -n demo --no-headers
  sleep 5
done
```

Thirteen samples, `15:12:01Z` through `15:13:21Z`. Every one reads identically. The first and the last:

```text
--- 15:12:01Z
demo-budget   pods: 4/16, requests.cpu: 800m/5, requests.memory: 384Mi/2Gi   limits.cpu: 2500m/13, limits.memory: 768Mi/4Gi   20d
sky   Deployment/sky   cpu: 1%/70%   2     8     2     2d23h
--- 15:13:21Z
demo-budget   pods: 4/16, requests.cpu: 800m/5, requests.memory: 384Mi/2Gi   limits.cpu: 2500m/13, limits.memory: 768Mi/4Gi   20d
sky   Deployment/sky   cpu: 1%/70%   2     8     2     2d23h
```

`pods: 4/16` and `requests.cpu: 800m/5` throughout, the HPA held at 2 replicas, and CPU stayed at 1% against a 70% target. The Pods are the same four the run started with:

```bash
kubectl get pods -n demo --no-headers | awk '{print $1, $3, $5}'
```

```text
nginx-845dd5f676-gg6pc Running 17h
nginx-845dd5f676-lgqlc Running 17h
sky-7c57fd7d9b-f6whh Running 78m
sky-7c57fd7d9b-jjwz6 Running 77m
```

No Pod was created during the run. The HPA did not scale and the quota was never approached.

### What this run does not prove

The offered rate was 15 rps because that is what ten concurrent curls from one host over TLS produce. Three times the ceiling is enough to make the throttle engage and enough to measure where it engages. It is **not** enough to reproduce the conditions Phase 12 used to drive this namespace to its quota.

So the quota holding flat is consistent with the claim that the rate limit keeps the HPA from scaling, but it does not isolate the rate limit as the cause. At 1% CPU the HPA would not have scaled at this offered rate without a rate limit either. Settling the causal claim needs the offered rate Phase 12 used, from `loadtest/loadgen.sh`, which is the repo owner's to run and was out of scope for this session.

What this run does settle is the control: a single address held above 300 requests a minute is refused, the refusals begin when the budget is spent, and the excess never reaches a backend. That is the exit criterion, and it is the claim the threat model carried as open.

### The availability alert

The policy is enabled:

```bash
gcloud alpha monitoring policies list --format='value(displayName,enabled)'
```

```text
sindrg.com is not serving	True
```

**Whether it opened an incident during the run was not captured, and that is a gap in this slice.** `gcloud alpha monitoring time-series` does not exist in this SDK, so the probe results across the window were never read. The prediction is that it did not fire: `enforce_on_key = "IP"` gives each of Google's prober addresses its own 300-a-minute budget, and a probe sends a few requests a minute. The site answered from this host as soon as the flood stopped:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://sindrg.com/
```

```text
200
```

That is consistent with the prediction. It is not a measurement of it.

## Slice 6: Security Command Center

Status: Complete as a first look. The tier is read and the count is one. The first Security Health Analytics scan has not finished, so nothing here is a clean bill of health.

### The tier, and the two facts no API holds

Security Command Center **Premium** was activated at the organization level on 2026-09-18: `sindre-demetrio-org`, id `550178366891`. Project `421458901689` sits under it and inherits the activation. Phase 13's open question was what the free tier covers; that question is now moot for the length of the trial and returns when it expires.

| Fact | Value | Source |
| --- | --- | --- |
| Trial ends | 2026-10-18 | The console page, confirmed by the owner |
| Tier at expiry | Standard | The console page, confirmed by the owner |

Neither is readable from any API, which is why both are attributed rather than pasted. Standard keeps Security Health Analytics' basic detectors and drops the Premium-only ones, so the detector set below is the trial's rather than the steady state, and this slice should be re-read on 2026-10-18.

### The count is one

Read at project scope and through the V2 API, for the three reasons in [the last section](#the-corrections-it-took-to-read-any-of-this):

```bash
gcloud scc findings list projects/421458901689 --location=global \
  --format='value(finding.findingClass,finding.severity,finding.category,finding.createTime)' > ~/scc-all.txt
wc -l < ~/scc-all.txt
awk -F'\t' '{print $1, $2}' ~/scc-all.txt | sort | uniq -c
awk -F'\t' '{print $3}' ~/scc-all.txt | sort | uniq -c
```

```text
1
      1 THREAT LOW
      1 Persistence: Service Account Created in sensitive namespace
```

That one finding in full:

```bash
gcloud scc findings list projects/421458901689 --location=global \
  --format='yaml(finding.category,finding.findingClass,finding.severity,finding.state,finding.createTime,finding.parentDisplayName,finding.resourceName,finding.access.principalEmail,finding.access.methodName)'
```

```text
finding:
  access:
    methodName: io.k8s.core.v1.serviceaccounts.create
    principalEmail: service-project-421458901689@gcp-sa-ktd-hpsa.iam.gserviceaccount.com
  category: 'Persistence: Service Account Created in sensitive namespace'
  createTime: '2026-09-18T15:01:06.363Z'
  findingClass: THREAT
  parentDisplayName: Event Threat Detection
  resourceName: //container.googleapis.com/projects/project-69726555-c4de-48de-a69/locations/europe-north1-a/clusters/k8-lab
  severity: LOW
  state: ACTIVE
```

Worth reading before acting on. The principal is `gcp-sa-ktd-hpsa`, which is Container Threat Detection's own agent service account, and the timestamp is minutes after activation. Event Threat Detection flagged Container Threat Detection installing itself. The platform's only Security Command Center finding is Security Command Center's own onboarding, and a reader who counted it as a platform finding would be counting the tool.

**The organization-wide count is not read directly**, because the account cannot list findings at that scope. It is covered rather than guessed, because the organization holds one project:

```bash
gcloud projects list --format='value(projectId,projectNumber)'
```

```text
project-69726555-c4de-48de-a69	421458901689
```

A project-scoped count over the only project is the organization's count. What the project scope would miss is a finding attached to the organization or to a folder rather than to a resource inside the project, and that class is not enumerated here.

### Phase 13 assumed a backlog, and there is none

[Phase 13](phase-13-security-baseline.md) treated Security Command Center as holding findings waiting to be read. It does not. Findings are generated from activation forward, so the count starts at zero and the single entry above was created after activation rather than before it.

That has a consequence beyond the correction: today's count says nothing about this project's posture over the twenty days it has been running. There is no history to inherit, and a low count on the day of activation is a statement about the clock, not about the platform.

### The scan that would overlap has not run

```bash
gcloud scc manage services list --project=421458901689 \
  --format='value(name.basename(),effectiveEnablementState)'
```

```text
VM_THREAT_DETECTION	DISABLED
WEB_SECURITY_SCANNER	ENABLED
SECURITY_HEALTH_ANALYTICS	ENABLED
AGENT_ENGINE_THREAT_DETECTION	ENABLED
EC2_VULNERABILITY_ASSESSMENT	DISABLED
AGENT_ENGINE_VULN_ASSESSMENT	ENABLED
CLOUD_RUN_THREAT_DETECTION	DISABLED
ARTIFACT_GUARD	DISABLED
EVENT_THREAT_DETECTION	ENABLED
NOTEBOOK_SECURITY_SCANNER	DISABLED
VM_MANAGER	DISABLED
GCE_VULNERABILITY_ASSESSMENT	ENABLED
AZURE_VULNERABILITY_ASSESSMENT	DISABLED
CONTAINER_THREAT_DETECTION	ENABLED
ARTIFACT_ANALYSIS	ENABLED
EXTERNAL_EXPOSURE	ENABLED
VM_THREAT_DETECTION_AWS	DISABLED
```

`SECURITY_HEALTH_ANALYTICS` is `ENABLED` and has produced zero findings. That is **first scan not yet complete**, and it is the only honest reading of a zero an hour after activation. Security Health Analytics is the configuration scanner and the one detector here whose output overlaps what this repository already runs.

### What Security Command Center adds beyond checkov and kubescape

The useful question, and the count above cannot answer it yet.

| Tool | Reads | Sees | Overlaps |
| --- | --- | --- | --- |
| checkov | The Terraform and the manifests in git | Configuration before it applies | Security Health Analytics, once it scans |
| kubescape | The live cluster through a kubeconfig | Cluster and workload posture against MITRE and NSA | Security Health Analytics' GKE detectors |
| Security Health Analytics | The project's resources through asset inventory | Google Cloud configuration as applied | Both of the above |
| Event and Container Threat Detection | Audit logs and container runtime | Behaviour rather than configuration | **Neither** |

The overlap that can be measured is the third row against the first two, and it cannot be measured today because the third row has returned nothing. Naming an overlap figure now would be naming zero and calling it agreement.

What the detector list already settles is the part that does not overlap. checkov reads files and kubescape reads cluster state, and both are point-in-time reads of configuration. Event Threat Detection and Container Threat Detection read audit logs and container runtime behaviour continuously, which neither of the other two does at all. This project's single finding is the demonstration: no static analyser reports a service account created in a sensitive namespace, because that is an event and not a configuration.

The traffic runs the other way too. checkov gates a pull request before an apply; Security Command Center reads resources that already exist, so it cannot refuse a change, only report one. Neither replaces the other, and the threat model's continuous-verification argument covers both.

The comparison worth making once the first scan lands is narrow: how many Security Health Analytics findings name something `.checkov.baseline` already records as a priced, accepted decision. High overlap there means Security Command Center is re-reporting risks this project has already reasoned about, and its value is the remainder plus the threat detection that nothing else here provides. That comparison is not made in this phase, because there is nothing yet to compare.

### The corrections it took to read any of this

Three of them, kept because each is a trap the next reader hits in the same order.

The API was not enabled on the project:

```bash
gcloud scc findings list 550178366891 --limit 20
```

```text
ERROR: (gcloud.scc.findings.list) PERMISSION_DENIED: Security Command Center API has not been
used in project project-69726555-c4de-48de-a69 before or it is disabled.
```

Enabling a service is the owner's decision against live billing, not this session's, so the owner enabled `securitycenter.googleapis.com`. `securitycentermanagement.googleapis.com` came with it:

```bash
gcloud services list --enabled | grep -i securitycenter
```

```text
securitycenter.googleapis.com            Security Command Center API
securitycentermanagement.googleapis.com  Security Center Management API
```

The organization-scoped query is still refused, for a different reason:

```bash
gcloud scc findings list 550178366891 --limit 20
```

```text
ERROR: (gcloud.scc.findings.list) PERMISSION_DENIED: Permission 'securitycenter.findings.list'
denied on resource '//securitycenter.googleapis.com/organizations/550178366891/sources/-'
(or it may not exist).
```

The account holds `resourcemanager.organizationAdmin` and no Security Command Center role. Administering the organization does not include reading its findings:

```bash
gcloud organizations get-iam-policy 550178366891 \
  --flatten='bindings[].members' \
  --filter='bindings.members:sindre.demetrio@gmail.com' \
  --format='value(bindings.role)'
```

```text
roles/billing.admin
roles/billing.creator
roles/iam.workforcePoolAdmin
roles/resourcemanager.organizationAdmin
roles/resourcemanager.projectCreator
roles/resourcemanager.projectMover
roles/serviceusage.serviceUsageAdmin
```

Granting a role is an infrastructure change and was out of scope, so what follows is read at project scope. That needs the V2 API: V1 is retired for project parents, and `gcloud` routes to V1 unless `--location` is given.

```bash
gcloud scc findings list projects/421458901689 --limit 20
```

```text
ERROR: (gcloud.scc.findings.list) INVALID_ARGUMENT: This API is no longer available. Please use
API V2 as an alternative.
```
## What this phase leaves open

| # | Item | State |
| --- | --- | --- |
| 1 | Federation deny direction | Closed 2026-09-18. A dispatch from `bump-sky` was rejected by the attribute condition |
| 2 | Rate limit under flood | Closed 2026-09-18. 593 of 1200 requests from one address refused, quota flat throughout. The causal claim about the HPA is not isolated, and the alert state was not captured |
| 3 | Security Command Center tier | Read 2026-09-18. Premium trial to 2026-10-18, then Standard. One finding, which is its own onboarding. The first Security Health Analytics scan has not completed, so the overlap question is open |
| 4 | CAA record | Closed 2026-09-18. Both records live and verified on two public resolvers, after Universal SSL was disabled to stop Cloudflare widening the set |
| 5 | Two protection mechanisms on `k8-lab` main | Closed 2026-09-18. `Static analysis` added to ruleset 21742516, classic protection deleted |
| 6 | DNSSEC, threat model finding 9 | Open, measured. The zone is unsigned and no decision has been taken |
| 7 | Provenance, SBOM, signing, admission, threat model finding 10 | Open. A Phase 14 bullet, not started |
| 8 | Universal SSL can be switched back on | Open. It is console state, and the surface check reads CAA for presence rather than contents, so it would not report the set widening again |

Items 1 through 5 are closed or read. Items 6 and 7 are the two Phase 14 bullets this phase did not reach, and both stay in the threat model's findings table rather than being carried silently. Item 8 is new, and it is a consequence of closing item 4 rather than a leftover.

## Where this is recorded elsewhere

The threat model's findings table, `decisions.md` on branch protection and on
certificate issuance, and Phase 14 in `plan.md` were reconciled against this
worklog after it landed.
