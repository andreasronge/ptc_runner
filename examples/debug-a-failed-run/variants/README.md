# Alternative failure shapes

The example's main story seeds one defect: a helper follows a relationship it
cannot follow. These trees give the same debugger and repair agent two other
shapes to meet, so a passing run is not evidence about one bug only.

| Tree | Failure shape |
| --- | --- |
| `target-ambiguous/` | Two components both ignore the subtotal, so the evidence cannot single one out and an abstention is a correct answer. |
| `target-workflow-control/` | A fulfillment workflow passes the order id where the reservation id belongs, so the defect is in the workflow that wires two evaluations together rather than in either component it calls. |

`target-workflow-control` doubles as the second capture the main story checks
the repaired helper against: a helper that only works on the pricing capture
is not a repaired helper.

Both applications fail on purpose, so the first command below exits 5 and
leaves the capture the second one reads:

```console
ptc run debug-a-failed-run/variants/target-ambiguous.ptc-project.json
ptc run debug-a-failed-run/repair-agent-ambiguous.ptc-project.json --env-file .env
```

The repair entry points stay in the parent directory because a PTC project
document cannot name a path above itself, and both reuse `repair-agent/ptc.json`
from there. Everything they read — the host document and the captured
application — lives here. `mix help ptc.repair` runs their validation suites
from a checkout.
