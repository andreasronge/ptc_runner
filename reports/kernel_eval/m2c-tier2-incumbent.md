# PTC Kernel Eval

suite: tier2
mode: live
variant: incumbent
requested_model: deepseek
resolved_model: openrouter:deepseek/deepseek-v4-flash
provider: openrouter
llm_source: registry
provenance_eligible: true
evidence_eligible: true
preregistered_config: true
commit: d94728134834993d1941e8686034bc72a688aba7
dataset_seed: 17
dataset_hash: 503d8233cce08aa825a00e14d49c6e13d2a9db931fa219a8cc3500866e8a0953
case_definition_hash: 4b448ecc370db8260cc8b4537bd7ed61ae9c8c0c0bbec80203d754d362df4431
aborted: false
abort_reason: none
runs: 1
pass_rate: 4/5 (80.0%)

| run | case | status | expected result | actual result | actions | evals | expected turns | actual turns | dropped | unexpected | write errors | failure | failure hash |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 1 | products_count | pass | {"constraint":{"value":500,"kind":"eq"},"expect":"integer"} | {"type":"integer","value":500} | 1 | 1 | 1 | 1 | 0 | 0 | 0 |  |  |
| 1 | delivered_orders | pass | {"constraint":{"value":200,"kind":"eq"},"expect":"integer"} | {"type":"integer","value":200} | 1 | 1 | 1 | 1 | 0 | 0 | 0 |  |  |
| 1 | total_revenue | pass | {"constraint":{"max":515675.01,"min":515674.99,"kind":"between"},"expect":"number"} | {"type":"float","value":515675.0} | 3 | 3 | 3 | 3 | 0 | 0 | 0 |  |  |
| 1 | remote_employees | pass | {"constraint":{"value":67,"kind":"eq"},"expect":"integer"} | {"type":"integer","value":67} | 2 | 2 | 2 | 2 | 0 | 0 | 0 |  |  |
| 1 | engineering_expenses | fail | {"constraint":{"max":24280.889999999992,"min":24280.869999999995,"kind":"between"},"expect":"number"} | {"type":"float","value":24280.88} | 4 | 4 | 4 | 4 | 0 | 0 | 0 | required_persisted_value_not_defined |  |
