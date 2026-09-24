# Observable GitHub MCP Server on Kubernetes

A production-shaped deployment of an MCP (Model Context Protocol) server —
infrastructure as code, packaged with Helm, observable end-to-end.

## The problem

Most public MCP server examples stop at "it runs locally over stdio."
Once an MCP server needs to serve real traffic, teams have almost no
visibility into tool call latency, failure rates, or how the server
behaves under load — most AI tooling today is observability-blind by
default. This project is a small, honest attempt to close that gap.

## Architecture

```
                 ┌─────────────────────────────┐
                 │   GitHub Actions CI/CD       │
                 │   build → push → helm deploy │
                 └───────────────┬─────────────┘
                                 │
                 ┌───────────────▼─────────────┐
                 │   AWS EKS (Terraform)        │
                 │  ┌─────────────────────────┐ │
                 │  │  Helm-deployed pods      │ │
                 │  │  github-mcp-server       │ │
                 │  │  (HPA: 1-5 replicas)     │ │
                 │  └──────────┬──────────────┘ │
                 └─────────────┼────────────────┘
                                │
              ┌─────────────────┼─────────────────┐
              ▼                                     ▼
     ┌─────────────────┐                 ┌─────────────────────┐
     │ Datadog          │                 │ Langfuse             │
     │ infra layer:      │                 │ AI layer:            │
     │ pod health,       │                 │ tool call traces,    │
     │ resource usage,   │                 │ latency, success/    │
     │ scaling events    │                 │ failure per tool     │
     └─────────────────┘                 └─────────────────────┘
```

## What's here

| Layer | Tool | What it proves |
|---|---|---|
| MCP server | Python (`fastmcp`), streamable HTTP transport | Not a stdio toy — deployable as a real service |
| Containerisation | Docker (non-root, health-checked, multi-stage `uv` build) | Production container hygiene |
| Infra provisioning | Terraform (EKS + VPC via community modules) | Infra as code, not manual clicking |
| App deployment | Helm | Reusable, versioned releases — not raw `kubectl apply` |
| Scaling | Kubernetes HPA | Handles bursty traffic without manual intervention |
| Secrets management | AWS Secrets Manager + External Secrets Operator, IRSA-authenticated | No static AWS credentials in-cluster, no plaintext secrets applied by hand, least-privilege IAM scoped to one secret ARN |
| CI/CD | GitHub Actions | Terraform plan (on PR, posted as a review comment) → apply (on merge) → build → push → Helm deploy → smoke test, each gated behind a manual approval environment |
| Infra observability | Datadog | Pod health, resource usage, scaling events |
| AI-layer observability | Langfuse | Per-tool-call tracing via FastMCP middleware: latency, success/failure, inputs/outputs — applied once, covers every tool automatically |

## Tools exposed

- `get_repo_info(owner, repo)` — repo metadata (stars, open issues, description)
- `list_issues(owner, repo, state, limit)` — list issues for a repo
- `create_issue_comment(owner, repo, issue_number, body)` — post a comment (requires a token with write access)

## Real numbers

*(filled in after load testing — Day 10 of the build)*

- Baseline latency (p50 / p95): TBD
- Behaviour under burst load (HPA scale-out time): TBD
- Theoretical always-on vs autoscaled cost comparison: TBD

## What I'd add for a real production deployment

- KEDA-based autoscaling on request queue depth instead of plain CPU —
  more accurate for bursty, I/O-bound MCP workloads
- OAuth-based auth on the MCP server itself (the July 2026 MCP spec
  moves toward OAuth 2.1/OIDC-aligned authorization)
- Multi-tenant rate limiting per client
- Terraform remote state (S3 + DynamoDB lock) instead of local state
- Log shipping to Datadog (not just infra metrics) — omitted here to
  stay within Datadog's free tier during development

## Setting up Langfuse

1. **Create a free account** at [cloud.langfuse.com](https://cloud.langfuse.com) (generous free tier — plenty for a solo project) — or self-host via their Docker Compose setup if you'd rather not send traces to their cloud.
2. **Create a project**, then go to Settings → API Keys and generate a public/secret key pair.
3. **Set the environment variables** the server reads (see `mcp_server.py` / `langfuse_middleware.py`):
   ```bash
   export LANGFUSE_PUBLIC_KEY=pk-lf-...
   export LANGFUSE_SECRET_KEY=sk-lf-...
   export LANGFUSE_HOST=https://cloud.langfuse.com   # or your self-hosted URL
   ```
4. **Run the server** — every tool call now shows up in the Langfuse dashboard as a trace, with:
   - Tool name and full input arguments
   - Output (truncated to 2000 chars to keep traces lightweight)
   - Latency in milliseconds
   - Success/error status, with the exact exception message on failure
5. **In Kubernetes**, these same three env vars are injected from the `github-mcp-secrets` Secret — populated automatically by External Secrets Operator from AWS Secrets Manager (see "Secrets" section below) rather than applied by hand — nothing to change in code between local and cluster runs.
6. **If the env vars aren't set**, the server still boots and works normally — Langfuse tracing just no-ops, and you fall back to the structured JSON logs (`kubectl logs`) for the same event data. This was deliberate: a missing observability dependency should never take down the actual service.

**Why middleware instead of decorating each tool:** FastMCP's middleware pipeline (`mcp.add_middleware(...)`) hooks into `on_call_tool` once and wraps every tool automatically — add a fourth or fifth tool later and it's traced for free, no extra decorator needed. This is a small design choice, but it's the kind of detail worth mentioning in a client pitch: it shows the tracing was built to scale with the server, not bolted on tool-by-tool.

## Secrets: pushed to AWS Secrets Manager, pulled automatically by External Secrets Operator

No static AWS credentials live in the cluster, and no plaintext secret
ever gets `kubectl apply`'d by hand:

```
   push-secrets.sh              ESO (IRSA-authenticated,
        │                       scoped to ONE secret ARN)
        ▼                              │
  AWS Secrets Manager  ─────refresh────►  ExternalSecret CR
  (empty until you                        │
   push real values)                      ▼
                                   github-mcp-secrets
                                   (real K8s Secret)
                                          │
                                          ▼
                                 mcp-server pod env vars
```

1. **`terraform apply`** creates the (empty) Secrets Manager secret, an
   IAM role scoped to read *only that one secret ARN* (least privilege —
   not blanket Secrets Manager access), and installs External Secrets
   Operator via Helm, bound to that role via IRSA.
2. **Push real values in:**
   ```bash
   cd terraform
   ./push-secrets.sh $(terraform output -raw secret_arn)
   ```
3. **`helm upgrade --install`** deploys a `SecretStore` + `ExternalSecret`
   alongside the app (see `helm/mcp-server/templates/`). ESO syncs
   Secrets Manager into a real `github-mcp-secrets` K8s Secret on a
   5-minute refresh interval by default.
4. **Rotate a key later?** Just re-run `push-secrets.sh` — ESO picks up
   the change within its refresh interval and updates the K8s Secret
   automatically. No redeploy, no pod restart, no `kubectl apply`.

Check sync status any time:
```bash
kubectl get externalsecret github-mcp-secrets -o wide
```

## Running it locally

Dependencies are managed with [`uv`](https://docs.astral.sh/uv/) — fast,
and the committed `uv.lock` means everyone (and CI) installs the exact
same resolved versions, not just "whatever pip picks today."

```bash
cd server
uv sync                              # creates .venv, installs from uv.lock
export GITHUB_TOKEN=ghp_your_token   # optional, needed for write ops
uv run python3 mcp_server.py
# server listens on :8000, MCP endpoint at /mcp, health check at /healthz
```

## Deploying

**One-time setup** — Terraform's remote state needs an S3 bucket + DynamoDB
lock table to exist *before* `terraform init` can use them as a backend
(Terraform can't create the backend it's about to store its state in):

```bash
cd terraform
./bootstrap-backend.sh my-tf-state-bucket my-tf-lock-table eu-west-2
cp backend.hcl.example backend.hcl   # fill in the names from the step above
```

**Provision infra:**

```bash
terraform init -backend-config=backend.hcl
terraform plan    # review before applying — same habit the CI pipeline enforces on PRs
terraform apply
```

**Point kubectl at the new cluster** (Terraform prints this command in its output):

```bash
aws eks update-kubeconfig --region eu-west-2 --name mcp-observability-demo-cluster
```

**Push real secret values into Secrets Manager** (the secret itself was created empty by Terraform — see "Secrets" section above for why):

```bash
./push-secrets.sh $(terraform output -raw secret_arn)
```

**Deploy the app** (this also installs the `SecretStore`/`ExternalSecret` that pull the values above into the pod):

```bash
helm upgrade --install github-mcp-server ./helm/mcp-server
```

**In CI**, this same flow runs automatically: a PR touching `terraform/`
gets a `terraform plan` posted as a PR comment for review; merging to
`main` runs `terraform apply`, then builds and pushes the image, then
deploys via Helm — in that order, so the app never tries to deploy onto
infra that doesn't exist yet. Set these once as repo variables/secrets:
`vars.TF_STATE_BUCKET`, `vars.TF_LOCK_TABLE`, `secrets.AWS_DEPLOY_ROLE_ARN`.

---

Built as a side project alongside my day job in platform engineering —
progress log on [LinkedIn](#).
