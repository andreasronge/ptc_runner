# Batched decision refund triage

Run six refund questions from frozen decision answers, with the threshold visible in the workflow.

```console
ptc init decision-refund-triage --example decision-refund-triage
ptc run decision-refund-triage/ptc-project.json
```

No API key is needed. `ptc-host.json` installs a decision replay with the same per-call reservations as a live installation. The workflow selects tickets from measured backends at probability 0.5 or above, and from discrete backends when their answer is true. Run `ptc docs host-installation` for live alpha OpenRouter Decisions configuration.
