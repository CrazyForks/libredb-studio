# First-Run Admin Setup

## Status

Backlog / RFC — **not scheduled**. This is a significant architectural change that
needs deeper discussion before it can be planned or built. No decision has been
made yet; this document exists to capture the idea, its ripple effects, and the
open questions so we can revisit it thoughtfully.

**Discussion:** [First-run admin setup: should the local admin become data instead of an env
var?](https://github.com/orgs/libredb/discussions/254) — deliberately a discussion and not an
issue: there is no bug to fix and no scoped feature yet, only a decision to reach. An issue comes
after the decision. This file stays the canonical text of the proposal (it is versioned alongside
the code paths it references); the thread is where the open questions get argued.

### Partly overtaken since it was written (2026-07-01)

The first motivation below — a newcomer hitting a "login unavailable" wall — no longer holds. The
zero-config first run ([#109](https://github.com/libredb/libredb-studio/issues/109), shipped in
[#122](https://github.com/libredb/libredb-studio/pull/122), `src/lib/auth-bootstrap.ts`) now
generates the admin password on first boot and prints it once, so an operator who runs
`docker run` or `npx @libredb/studio` without reading anything gets a working login.

What survives is the *conceptual* argument — "the admin is a user you create" versus "the admin is
an environment variable compared in plaintext" — plus the security upside of hashing stored
credentials. Both are worth deciding on their own merits; neither is urgent.

## Overview

Many self-hosted open-source tools (Grafana, GitLab, Gitea, Portainer, n8n)
present a one-time "setup" or "register" screen on first launch: if no
administrator account exists yet, the app asks the operator to create one
interactively instead of requiring credentials to be supplied up front.

This document explores adding the same flow to LibreDB Studio's **local**
authentication provider: when the app boots and no admin is configured, show a
first-run setup screen that creates the admin account.

## Motivation

- **Friendlier onboarding.** The current local provider requires the operator to
  set `ADMIN_PASSWORD` (and optionally `USER_PASSWORD`) as environment variables
  before the first login works. A newcomer running `docker run ...` without
  reading the docs hits a "login unavailable" wall. An interactive setup screen is
  a more welcoming first experience. **(Superseded — the zero-config first run now
  generates and prints the credentials; see Status.)**
- **A cleaner conceptual model.** "The admin is a user you create" is arguably
  simpler to reason about than "the admin is an environment variable compared in
  plaintext."
- **Alignment with peer tools.** It is the expected behaviour for self-hosted
  software in 2026.

### Relationship to recent work

PR #106 (`fix/optional-user-account`) already moved the local-provider credential
logic into its own module, `src/lib/local-auth.ts` (`AuthUser`, `AuthConfigError`,
`getAuthUsers`), made the user account optional, and turned a missing
`ADMIN_PASSWORD` into a clear, actionable login-screen error. That module is the
natural home for a future `UserStore`, so this feature builds on that seam rather
than fighting it. The env-based path is **not wasted work** — see "Scope Options"
below.

## The Core Architectural Shift

The feature looks like "a register screen," but underneath it is a shift in where
identity lives:

**config-as-env  ->  users-as-data**

Today an admin is defined by an environment variable and verified by a plaintext
comparison (`u.password === password`). A register flow means the admin becomes
**persisted data** the operator creates at runtime. That single change pulls in
several requirements that do not exist today:

1. **A persistent, server-side user store.** Registered credentials must be
   verified by the server on every login, so they must live server-side and
   survive restarts.
2. **Password hashing.** Storing an operator-chosen password requires a proper
   one-way hash (bcrypt / argon2 / scrypt). This is a net security improvement
   over the current plaintext env comparison, but it is a new dependency and a
   new surface to get right.
3. **A notion of "an admin exists."** Today there is no such state — admin-ness is
   implied by an env var. The setup flow needs a reliable, race-free way to answer
   "has the first admin been created yet?"

## Impact on Existing Modes

This is the part that needs the most care. LibreDB Studio runs in several very
different contexts, and a naive first-run screen would break some of them.

### Local auth, standalone (Docker / bare Next.js)

The target scenario. A setup screen fits here — but only if a persistent server
store is available (see "Storage & Persistence").

### OIDC (`NEXT_PUBLIC_AUTH_PROVIDER=oidc`)

**Cleanly exempt.** In OIDC mode there is no local admin at all — users are
authenticated by the external identity provider (Keycloak, Auth0, Okta, ...) and
admin-vs-user is derived from `OIDC_ROLE_CLAIM`. A first-run register screen makes
no sense here and must be **skipped entirely** when the provider is `oidc`. Low
risk: gate the whole feature behind `provider === "local"`.

### npm package embedded in libredb-platform

**The highest-risk interaction.** libredb-platform consumes `@libredb/studio` as
a package and owns its own multi-tenant users / roles / RBAC. If studio were to
show its own setup or login screen inside platform, it would collide with the
host's auth. Studio must have an **explicit signal** that "authentication is
managed by the host" and, in that mode, disable its own login *and* setup flows.

Relying on implicit routing (assuming platform simply never hits studio's
`/login`) is too fragile for an auth feature. Today `src/instrumentation.ts`
already documents that its boot hook does not run in embedded mode, but there is
no first-class "managed auth" capability flag. Introducing one is likely a
prerequisite for this feature.

### Declarative / automated deployments (Kubernetes, GitOps, CI)

Automated deployments generally do **not** want an interactive click-through.
They want the admin provisioned declaratively from config so a pod can come up
unattended and identically across replicas. This is exactly what the current
env-based path provides, and it is why removing it would be a regression for
these users.

## Scope Options (undecided)

The single most important open decision is how the interactive setup relates to
the existing env-based admin. Three options, no choice locked in:

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **A. Coexist** (leaning toward) | `ADMIN_PASSWORD` set -> use it (declarative path). Not set + persistent store available -> show setup screen. | Non-breaking; serves both automated and interactive deployments; matches Grafana / GitLab prior art. | Two auth code paths to maintain for a while. |
| **B. Replace** | Remove `ADMIN_PASSWORD`; admin is always created via setup. | Single, clean path; strongest conceptual model. | Breaking change for every existing deployment; hostile to unattended/GitOps provisioning. |
| **C. Opt-in feature flag** | Env path stays the default; setup screen only enabled by an explicit flag (e.g. `ENABLE_SETUP_WIZARD=true`). | Most conservative; lets the new path be tested in isolation. | Two paths coexist indefinitely; extra config knob. |

Prior art strongly favours coexistence: Grafana supports `GF_SECURITY_ADMIN_PASSWORD`
*or* a default admin with a forced password change; GitLab supports
`GITLAB_ROOT_PASSWORD` *or* setting the root password on first visit.

## Storage & Persistence

- **`STORAGE_PROVIDER=local` (the current default) cannot back this feature.** It
  is browser `localStorage`, which is client-side and per-browser — it cannot hold
  a server-verified credential. So the setup flow requires a server-side store
  (`sqlite` or `postgres`), or a dedicated auth store separate from
  `STORAGE_PROVIDER`.
- **Multi-node / HA.** A SQLite file is single-node; horizontally scaled
  deployments (K8s replicas) would each get their own admin state. Shared admin
  state across replicas implies `postgres` (or another shared backend).
- **Open question:** should the admin/user store reuse `STORAGE_PROVIDER`, or be
  its own concern? Auth arguably deserves stronger guarantees than general app
  storage.

## Security Considerations

- **First-run race.** The classic first-run-setup vulnerability: in the window
  between deployment and the first registration, anyone who reaches the URL can
  claim the admin account. Mitigations to evaluate:
  - a setup token printed to the server logs (Jenkins `initialAdminPassword`
    style) that must be entered to complete setup;
  - binding setup to a bootstrap value supplied via env;
  - a clearly-communicated "first request wins" with prominent warnings.
- **Password hashing.** Introduce bcrypt/argon2 for stored passwords. Decide
  whether the env-based path (if kept) also moves to hashing or stays a plaintext
  comparison of an operator-controlled secret.
- **Transport.** Setup submits a chosen password; deployments must be behind TLS.
  Consider warning when served over plain HTTP on a non-loopback host.
- **Lockout / recovery.** If the only admin's credentials are lost, there must be
  a documented recovery path (e.g. an env override that re-enables bootstrap).

## Open Questions

1. Coexist, replace, or feature-flag (Scope Options A/B/C)?
2. Where do registered users live — reuse `STORAGE_PROVIDER`, or a dedicated auth
   store? What is the behaviour when only `local` storage is configured?
3. How does studio reliably know it is embedded in platform (explicit "managed
   auth" capability flag)? Is that flag a prerequisite deliverable?
4. How is the first-run race mitigated — setup token, env bootstrap, or explicit
   accepted risk?
5. Does the optional lower-privilege "user" account also become creatable via the
   UI, or does it stay env-only / admin-managed?
6. What is the admin-recovery / password-reset story once credentials are data?
7. Migration: how does an existing env-based deployment transition (or not) to the
   new model without a surprise breaking change?

## Non-Goals (for now)

- Full user management (inviting multiple users, per-user roles beyond
  admin/user, teams). This RFC is scoped to bootstrapping the *first admin*.
- Replacing or changing the OIDC provider flow.
- Any change to how libredb-platform manages its own users.

## Prior Art

- **Grafana** — env admin password or default admin with forced change on first
  login.
- **GitLab** — `GITLAB_ROOT_PASSWORD` env or set-root-password-on-first-visit.
- **Portainer** — create the admin account on first launch; times out for
  security if left unconfigured.
- **Gitea / n8n / Jellyfin** — interactive first-run setup wizards.

## Related

- PR #106 — optional user account + clear missing-`ADMIN_PASSWORD` error.
- `src/lib/local-auth.ts` — local provider credential logic (future `UserStore` home).
- `src/lib/oidc.ts` — OIDC provider (the exempt path).
- `src/proxy.ts` — RBAC enforcement (admin vs user).
- `docs/STORAGE.md` — storage providers (`local` / `sqlite` / `postgres`).
- `docs/OIDC.md` — OIDC configuration and role mapping.
- `.claude/rules/platform-integration.md` — embedded-in-platform constraints.
