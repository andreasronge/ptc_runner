# Alternative failure shapes

The example's main story seeds one defect: a helper follows a relationship it
cannot follow. These trees give the same debugger and repair agent two other
shapes to meet, so a passing run is not evidence about one bug only.

| Tree | Failure shape |
| --- | --- |
| `target-ambiguous/` | Two components could explain the result, so a correct answer may be an abstention. |
| `target-workflow-control/` | A fulfillment workflow routes to the wrong branch; the defect is in control flow, not arithmetic. |

`target-workflow-control` doubles as the second capture the main story checks
the repaired helper against: a helper that only works on the pricing capture
is not a repaired helper.

Run one directly:

```console
ptc run debug-a-failed-run/variants/target-ambiguous.ptc-project.json
ptc run debug-a-failed-run/repair-agent-ambiguous.ptc-project.json --env-file .env
```

The repair entry points stay in the parent directory because a PTC project
document cannot name a path above itself, and both reuse `repair-agent/ptc.json`
from there. Everything they read — the host document and the captured
application — lives here. `mix help ptc.repair` runs their validation suites
from a checkout.
