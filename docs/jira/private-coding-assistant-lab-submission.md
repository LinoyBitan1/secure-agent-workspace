# Red Hat One Lab Submission: Private AI Coding Assistant

## Title

"Private AI Coding Assistant: a hands-on Red Hat OpenShift quickstart for air-gapped AI-assisted development"

---

## Session outline (120 min)

1. **The problem, shown first (10 min)** — Facilitators open with a developer already coding in Dev Spaces with AI assistance running. Frame two live objections: a security lead asking "where does our code go?" and an engineering director asking "why are we paying per-seat for a tool we don't control?"

2. **Where this fits (5 min)** — Position this quickstart as another entry point into the maintained Red Hat OpenShift AI quickstart catalog.

3. **Guided build (55 min)** — Attendees log into their own pre-provisioned Dev Spaces workspace (OpenCode IDE pre-wired with AI assistance) and use AI-assisted coding hands-on — completions, chat, inline edits — against a Qwen 3.6 model served on-cluster via vLLM. (Facilitators pre-provision the cluster, RHCL AI Gateway, model serving, and per-developer API keys before the session — attendees only need a laptop and network access.)

4. **Prove it (30 min)** — Three checks, mapped to the dual hook: (a) confirm no traffic leaves the cluster to any public model API — addresses the security objection; (b) check the RHCL AI Gateway's per-developer usage and audit trail via Langfuse — addresses the cost/visibility objection; (c) swap the served open-source model without touching IDE config — addresses vendor lock-in.

5. **Pitch practice (15 min)** — Paired exercise: each attendee picks the stakeholder that matches their own accounts (security lead or cost-conscious engineering director) and delivers a talk track to a partner playing that skeptic.

6. **Wrap-up & catalog map (5 min)** — Where to find the rest of the catalog and how it stays current.

## Outcomes

1. Provision and use a per-developer AI-assisted IDE (OpenShift Dev Spaces with OpenCode) backed by on-cluster inference via vLLM, from workspace login to a live coding session.
2. Confirm that developer code and AI requests never leave the OpenShift network boundary.
3. Read a per-developer usage and audit trail from the RHCL AI Gateway and Langfuse, and swap the underlying open-source model without reconfiguring the IDE.
4. Deliver a confident talk track that answers either a data-security objection or a cost/vendor-lock-in objection, matched to the SA's own account.
5. Locate the right quickstart for other AI conversations from the maintained catalog.
