# PTC-JSON Test Report

**Generated:** 2025-12-11 10:50:21 UTC
**Model:** openrouter:deepseek/deepseek-v3.2
**Data Mode:** schema

## Summary

| Metric | Value |
|--------|-------|
| Passed | 10/14 |
| Failed | 4 |
| Total Attempts | 30 |
| Avg Attempts/Test | 2.14 |
| Duration | 3.6m |
| Total Tokens | 6180 |
| Cost | $0.00 |

## Results

| # | Query | Status | Attempts | Program |
|---|-------|--------|----------|---------|
| 1 | How many products are there? | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 2 | How many orders have status 'delivered'? | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 3 | What is the total revenue from all order... | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 4 | What is the average product rating? | PASS | 1 | `{"program": {"op": "pipe", "steps": [{"o...` |
| 5 | How many employees work remotely? | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 6 | How many products cost more than $500? | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 7 | How many orders over $1000 were paid by ... | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 8 | What is the name of the cheapest product... | PASS | 1 | `{"program": {"op": "pipe", "steps": [ {"...` |
| 9 | Get the names of the 3 most expensive pr... | FAIL | 5 | `-` |
| 10 | How many orders are either cancelled or ... | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 11 | What is the average salary of senior-lev... | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 12 | How many unique products have been order... | FAIL | 5 | `-` |
| 13 | Count delivered orders and store the res... | FAIL | 5 | `-` |
| 14 | Store the list of employees in the engin... | FAIL | 5 | `-` |

## Failed Tests

### 9. Get the names of the 3 most expensive products

- **Error:** Query failed: "Max iterations reached"
- **Expected:** Sort descending + take N + extract field
- **Constraint:** `{:length, 3}`
- **Attempts:** 5

**Programs tried:**
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "sort_by",
        "field": "price",
        "desc": true
      },
      {
        "op": "take",
        "n": 3
      },
      {
        "op": "map",
        "expr": {
          "op": "get",
          "field": "name"
        }
      }
    ]
  }
}`
    - Result: ERROR: ValidationError: Unknown operation 'take'
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "sort_by",
        "field": "price",
        "desc": true
      },
      {
        "op": "first",
        "n": 3
      },
      {
        "op": "map",
        "expr": {
          "op": "get",
          "field": "name"
        }
      }
    ]
  }
}`
    - Result: ERROR: ExecutionError: map requires a list, got %{"catego...
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "sort_by",
        "field": "price",
        "desc": true
      },
      {
        "op": "nth",
        "index": 0
      },
      {
        "op": "get",
        "field": "name"
      }
    ]
  }
}`
    - Result: "\"Product 466\""
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "sort_by",
        "field": "price",
        "desc": true
      },
      {
        "op": "filter",
        "where": {
          "op": "or",
          "conditions": [
            {
              "op": "eq",
              "field": "id",
              "value": 466
            },
            {
              "op": "eq",
              "field": "id",
              "value": 123
            },
            {
              "op": "eq",
              "field": "id",
              "value": 456
            }
          ]
        }
      },
      {
        "op": "map",
        "expr": {
          "op": "get",
          "field": "name"
        }
      }
    ]
  }
}`
    - Result: "[\"Product 466\", \"Product 123\", \"Product 456\...
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "sort_by",
        "field": "price",
        "desc": true
      },
      {
        "op": "filter",
        "where": {
          "op": "lt",
          "field": "id",
          "value": 4
        }
      },
      {
        "op": "map",
        "expr": {
          "op": "get",
          "field": "name"
        }
      }
    ]
  }
}`
    - Result: "[\"Product 2\", \"Product 1\", \"Product 3\"]"

---
### 12. How many unique products have been ordered? (count distinct product_id values in orders)

- **Error:** Query failed: "Max iterations reached"
- **Expected:** Distinct + count (cross-dataset reasoning)
- **Constraint:** `{:between, 1, 500}`
- **Attempts:** 5

**Programs tried:**
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "map", "expr": {"op": "get", "field": "product_id"}},
      {"op": "var", "name": "product_ids"},
      {"op": "literal", "value": []},
      {
        "op": "let",
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "load", "name": "product_ids"},
            {
              "op": "filter",
              "where": {
                "op": "not",
                "condition": {
                  "op": "contains",
                  "field": {"op": "var", "name": "unique_ids"},
                  "value": {"op": "get"}
                }
              }
            },
            {"op": "map", "expr": {"op": "get"}},
            {
              "op": "let",
              "in": {
                "op": "pipe",
                "steps": [
                  {"op": "var", "name": "unique_ids"},
                  {"op": "concat", "lists": [{"op": "var", "name": "new_ids"}]},
                  {"op": "var", "name": "updated_unique_ids"}
                ]
              },
              "name": "new_ids"
            },
            {"op": "count"}
          ]
        },
        "name": "unique_ids"
      }
    ]
  }
}`
    - Result: ERROR: ValidationError: Operation 'let' requires field 'v...
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "map", "expr": {"op": "get", "field": "product_id"}},
      {"op": "var", "name": "all_product_ids"},
      {
        "op": "let",
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "load", "name": "all_product_ids"},
            {"op": "sort_by", "field": {"op": "get"}},
            {
              "op": "filter",
              "where": {
                "op": "or",
                "conditions": [
                  {
                    "op": "eq",
                    "field": {"op": "nth", "index": 0},
                    "value": {"op": "get"}
                  },
                  {
                    "op": "neq",
                    "field": {"op": "get"},
                    "value": {"op": "nth", "index": -1}
                  }
                ]
              }
            },
            {"op": "count"}
          ]
        },
        "name": "sorted_ids",
        "value": {"op": "literal", "value": []}
      }
    ]
  }
}`
    - Result: ERROR: ValidationError: Field 'field' must be a string
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "map", "expr": {"op": "get", "field": "product_id"}},
      {"op": "var", "name": "all_ids"},
      {
        "op": "let",
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "load", "name": "all_ids"},
            {"op": "sort_by", "field": "value"},
            {
              "op": "filter",
              "where": {
                "op": "or",
                "conditions": [
                  {
                    "op": "eq",
                    "field": "index",
                    "value": 0
                  },
                  {
                    "op": "neq",
                    "field": "value",
                    "value": {"op": "nth", "index": -1}
                  }
                ]
              }
            },
            {"op": "count"}
          ]
        },
        "name": "sorted_ids",
        "value": {"op": "literal", "value": []}
      }
    ]
  }
}`
    - Result: ERROR: ExecutionError: sort_by requires a list, got nil
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "select", "fields": ["product_id"]},
      {"op": "var", "name": "product_ids"},
      {
        "op": "let",
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "load", "name": "product_ids"},
            {"op": "sort_by", "field": "product_id"},
            {
              "op": "filter",
              "where": {
                "op": "or",
                "conditions": [
                  {
                    "op": "eq",
                    "field": "index",
                    "value": 0
                  },
                  {
                    "op": "neq",
                    "field": "product_id",
                    "value": {"op": "nth", "index": -1, "field": "product_id"}
                  }
                ]
              }
            },
            {"op": "count"}
          ]
        },
        "name": "sorted",
        "value": {"op": "literal", "value": []}
      }
    ]
  }
}`
    - Result: ERROR: ExecutionError: sort_by requires a list, got nil
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "map", "expr": {"op": "get", "field": "product_id"}},
      {"op": "var", "name": "ordered_product_ids"},
      {"op": "load", "name": "products"},
      {
        "op": "filter",
        "where": {
          "op": "contains",
          "field": {"op": "var", "name": "ordered_product_ids"},
          "value": {"op": "get", "field": "id"}
        }
      },
      {"op": "count"}
    ]
  }
}`
    - Result: ERROR: ValidationError: Field 'field' must be a string

---
### 13. Count delivered orders and store the result in memory as delivered-count → What percentage of all orders are delivered? Use memory/delivered-count and total order count.

- **Error:** Query failed: "Max iterations reached"
- **Expected:** Multi-turn: percentage calculation using stored count
- **Constraint:** `{:between, 1, 99}`
- **Attempts:** 5

**Programs tried:**
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "status",
          "value": "delivered"
        }
      },
      {
        "op": "count"
      },
      {
        "op": "let",
        "in": {
          "op": "literal",
          "value": "delivered-count"
        },
        "name": "result"
      }
    ]
  }
}`
    - Result: ERROR: ValidationError: Operation 'let' requires field 'v...
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "status",
          "value": "delivered"
        }
      },
      {
        "op": "count"
      },
      {
        "op": "let",
        "in": {
          "op": "literal",
          "value": "delivered-count"
        },
        "name": "result",
        "value": {
          "op": "get"
        }
      }
    ]
  }
}`
    - Result: ERROR: ValidationError: Operation 'get' requires either '...
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "status",
          "value": "delivered"
        }
      },
      {
        "op": "count"
      },
      {
        "op": "let",
        "in": {
          "op": "literal",
          "value": "delivered-count"
        },
        "name": "result",
        "value": {
          "op": "get",
          "field": "value"
        }
      }
    ]
  }
}`
    - Result: "\"delivered-count\""
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "status",
          "value": "delivered"
        }
      },
      {
        "op": "avg",
        "field": "total"
      },
      {
        "op": "let",
        "in": {
          "op": "literal",
          "value": "delivered-avg"
        },
        "name": "result",
        "value": {
          "op": "get",
          "field": "value"
        }
      }
    ]
  }
}`
    - Result: "\"delivered-avg\""
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "status",
          "value": "delivered"
        }
      },
      {
        "op": "max",
        "field": "total"
      },
      {
        "op": "let",
        "in": {
          "op": "literal",
          "value": "delivered-max"
        },
        "name": "result",
        "value": {
          "op": "get",
          "field": "value"
        }
      }
    ]
  }
}`
    - Result: "\"delivered-max\""

---
### 14. Store the list of employees in the engineering department in memory as engineering-employees → What is the average salary of the engineering employees stored in memory?

- **Error:** Query failed: "Max iterations reached"
- **Expected:** Multi-turn: average salary using stored employee list
- **Constraint:** `{:between, 50000, 200000}`
- **Attempts:** 5

**Programs tried:**
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "employees"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "department",
          "value": "engineering"
        }
      },
      {
        "op": "store as",
        "name": "engineering-employees"
      }
    ]
  }
}`
    - Result: ERROR: ValidationError: Unknown operation 'store as'
  - `{
  "program": {
    "op": "let",
    "in": {
      "op": "pipe",
      "steps": [
        {
          "op": "load",
          "name": "employees"
        },
        {
          "op": "filter",
          "where": {
            "op": "eq",
            "field": "department",
            "value": "engineering"
          }
        }
      ]
    },
    "name": "engineering-employees"
  }
}`
    - Result: ERROR: ValidationError: Operation 'let' requires field 'v...
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "employees"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "department",
          "value": "engineering"
        }
      },
      {
        "op": "let",
        "name": "engineering-employees",
        "value": {
          "op": "get"
        }
      }
    ]
  }
}`
    - Result: ERROR: ValidationError: Operation 'let' requires field 'i...
  - `{
  "program": {
    "op": "let",
    "name": "engineering-employees",
    "value": {
      "op": "pipe",
      "steps": [
        {
          "op": "load",
          "name": "employees"
        },
        {
          "op": "filter",
          "where": {
            "op": "eq",
            "field": "department",
            "value": "engineering"
          }
        }
      ]
    },
    "in": {
      "op": "get"
    }
  }
}`
    - Result: ERROR: ValidationError: Operation 'get' requires either '...
  - `{
  "program": {
    "op": "let",
    "name": "engineering-employees",
    "value": {
      "op": "pipe",
      "steps": [
        {
          "op": "load",
          "name": "employees"
        },
        {
          "op": "filter",
          "where": {
            "op": "eq",
            "field": "department",
            "value": "engineering"
          }
        }
      ]
    },
    "in": {
      "op": "literal",
      "value": "Stored engineering employees in memory"
    }
  }
}`
    - Result: "\"Stored engineering employees in memory\""



## All Programs Generated

### 1. How many products are there? [PASS]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "count"
      }
    ]
  }
}` -> "500"

### 2. How many orders have status 'delivered'? [PASS]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "filter", "where": {"op": "eq", "field": "status", "value": "delivered"}},
      {"op": "count"}
    ]
  }
}` -> "212"

### 3. What is the total revenue from all orders? (sum the total field) [PASS]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "sum", "field": "total"}
    ]
  }
}` -> "2463054.67"

### 4. What is the average product rating? [PASS]
   - `{"program": {"op": "pipe", "steps": [{"op": "load", "name": "products"}, {"op": "avg", "field": "rating"}]}}` -> "3.04"

### 5. How many employees work remotely? [PASS]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "employees"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "remote",
          "value": true
        }
      },
      {
        "op": "count"
      }
    ]
  }
}` -> "101"

### 6. How many products cost more than $500? [PASS]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "filter",
        "where": {
          "op": "gt",
          "field": "price",
          "value": 500
        }
      },
      {
        "op": "count"
      }
    ]
  }
}` -> "246"

### 7. How many orders over $1000 were paid by credit card? [PASS]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "filter",
        "where": {
          "op": "and",
          "conditions": [
            {
              "op": "gt",
              "field": "total",
              "value": 1000
            },
            {
              "op": "eq",
              "field": "payment_method",
              "value": "credit_card"
            }
          ]
        }
      },
      {
        "op": "count"
      }
    ]
  }
}` -> "232"

### 8. What is the name of the cheapest product? [PASS]
   - `{"program": {"op": "pipe", "steps": [
    {"op": "load", "name": "products"},
    {"op": "sort_by", "field": "price"},
    {"op": "first"},
    {"op": "get", "field": "name"}
]}}` -> "\"Product 466\""

### 9. Get the names of the 3 most expensive products [FAIL]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "sort_by",
        "field": "price",
        "desc": true
      },
      {
        "op": "take",
        "n": 3
      },
      {
        "op": "map",
        "expr": {
          "op": "get",
          "field": "name"
        }
      }
    ]
  }
}` -> ERROR: ValidationError: Unknown operation 'take'
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "sort_by",
        "field": "price",
        "desc": true
      },
      {
        "op": "first",
        "n": 3
      },
      {
        "op": "map",
        "expr": {
          "op": "get",
          "field": "name"
        }
      }
    ]
  }
}` -> ERROR: ExecutionError: map requires a list, got %{"catego...
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "sort_by",
        "field": "price",
        "desc": true
      },
      {
        "op": "nth",
        "index": 0
      },
      {
        "op": "get",
        "field": "name"
      }
    ]
  }
}` -> "\"Product 466\""
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "sort_by",
        "field": "price",
        "desc": true
      },
      {
        "op": "filter",
        "where": {
          "op": "or",
          "conditions": [
            {
              "op": "eq",
              "field": "id",
              "value": 466
            },
            {
              "op": "eq",
              "field": "id",
              "value": 123
            },
            {
              "op": "eq",
              "field": "id",
              "value": 456
            }
          ]
        }
      },
      {
        "op": "map",
        "expr": {
          "op": "get",
          "field": "name"
        }
      }
    ]
  }
}` -> "[\"Product 466\", \"Product 123\", \"Product 456\...
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "sort_by",
        "field": "price",
        "desc": true
      },
      {
        "op": "filter",
        "where": {
          "op": "lt",
          "field": "id",
          "value": 4
        }
      },
      {
        "op": "map",
        "expr": {
          "op": "get",
          "field": "name"
        }
      }
    ]
  }
}` -> "[\"Product 2\", \"Product 1\", \"Product 3\"]"

### 10. How many orders are either cancelled or refunded? [PASS]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "filter",
        "where": {
          "op": "or",
          "conditions": [
            {
              "op": "eq",
              "field": "status",
              "value": "cancelled"
            },
            {
              "op": "eq",
              "field": "status",
              "value": "refunded"
            }
          ]
        }
      },
      {
        "op": "count"
      }
    ]
  }
}` -> "412"

### 11. What is the average salary of senior-level employees? [PASS]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "employees"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "level",
          "value": "senior"
        }
      },
      {
        "op": "avg",
        "field": "salary"
      }
    ]
  }
}` -> "123257.89"

### 12. How many unique products have been ordered? (count distinct product_id values in orders) [FAIL]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "map", "expr": {"op": "get", "field": "product_id"}},
      {"op": "var", "name": "product_ids"},
      {"op": "literal", "value": []},
      {
        "op": "let",
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "load", "name": "product_ids"},
            {
              "op": "filter",
              "where": {
                "op": "not",
                "condition": {
                  "op": "contains",
                  "field": {"op": "var", "name": "unique_ids"},
                  "value": {"op": "get"}
                }
              }
            },
            {"op": "map", "expr": {"op": "get"}},
            {
              "op": "let",
              "in": {
                "op": "pipe",
                "steps": [
                  {"op": "var", "name": "unique_ids"},
                  {"op": "concat", "lists": [{"op": "var", "name": "new_ids"}]},
                  {"op": "var", "name": "updated_unique_ids"}
                ]
              },
              "name": "new_ids"
            },
            {"op": "count"}
          ]
        },
        "name": "unique_ids"
      }
    ]
  }
}` -> ERROR: ValidationError: Operation 'let' requires field 'v...
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "map", "expr": {"op": "get", "field": "product_id"}},
      {"op": "var", "name": "all_product_ids"},
      {
        "op": "let",
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "load", "name": "all_product_ids"},
            {"op": "sort_by", "field": {"op": "get"}},
            {
              "op": "filter",
              "where": {
                "op": "or",
                "conditions": [
                  {
                    "op": "eq",
                    "field": {"op": "nth", "index": 0},
                    "value": {"op": "get"}
                  },
                  {
                    "op": "neq",
                    "field": {"op": "get"},
                    "value": {"op": "nth", "index": -1}
                  }
                ]
              }
            },
            {"op": "count"}
          ]
        },
        "name": "sorted_ids",
        "value": {"op": "literal", "value": []}
      }
    ]
  }
}` -> ERROR: ValidationError: Field 'field' must be a string
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "map", "expr": {"op": "get", "field": "product_id"}},
      {"op": "var", "name": "all_ids"},
      {
        "op": "let",
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "load", "name": "all_ids"},
            {"op": "sort_by", "field": "value"},
            {
              "op": "filter",
              "where": {
                "op": "or",
                "conditions": [
                  {
                    "op": "eq",
                    "field": "index",
                    "value": 0
                  },
                  {
                    "op": "neq",
                    "field": "value",
                    "value": {"op": "nth", "index": -1}
                  }
                ]
              }
            },
            {"op": "count"}
          ]
        },
        "name": "sorted_ids",
        "value": {"op": "literal", "value": []}
      }
    ]
  }
}` -> ERROR: ExecutionError: sort_by requires a list, got nil
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "select", "fields": ["product_id"]},
      {"op": "var", "name": "product_ids"},
      {
        "op": "let",
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "load", "name": "product_ids"},
            {"op": "sort_by", "field": "product_id"},
            {
              "op": "filter",
              "where": {
                "op": "or",
                "conditions": [
                  {
                    "op": "eq",
                    "field": "index",
                    "value": 0
                  },
                  {
                    "op": "neq",
                    "field": "product_id",
                    "value": {"op": "nth", "index": -1, "field": "product_id"}
                  }
                ]
              }
            },
            {"op": "count"}
          ]
        },
        "name": "sorted",
        "value": {"op": "literal", "value": []}
      }
    ]
  }
}` -> ERROR: ExecutionError: sort_by requires a list, got nil
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "map", "expr": {"op": "get", "field": "product_id"}},
      {"op": "var", "name": "ordered_product_ids"},
      {"op": "load", "name": "products"},
      {
        "op": "filter",
        "where": {
          "op": "contains",
          "field": {"op": "var", "name": "ordered_product_ids"},
          "value": {"op": "get", "field": "id"}
        }
      },
      {"op": "count"}
    ]
  }
}` -> ERROR: ValidationError: Field 'field' must be a string

### 13. Count delivered orders and store the result in memory as delivered-count → What percentage of all orders are delivered? Use memory/delivered-count and total order count. [FAIL]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "status",
          "value": "delivered"
        }
      },
      {
        "op": "count"
      },
      {
        "op": "let",
        "in": {
          "op": "literal",
          "value": "delivered-count"
        },
        "name": "result"
      }
    ]
  }
}` -> ERROR: ValidationError: Operation 'let' requires field 'v...
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "status",
          "value": "delivered"
        }
      },
      {
        "op": "count"
      },
      {
        "op": "let",
        "in": {
          "op": "literal",
          "value": "delivered-count"
        },
        "name": "result",
        "value": {
          "op": "get"
        }
      }
    ]
  }
}` -> ERROR: ValidationError: Operation 'get' requires either '...
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "status",
          "value": "delivered"
        }
      },
      {
        "op": "count"
      },
      {
        "op": "let",
        "in": {
          "op": "literal",
          "value": "delivered-count"
        },
        "name": "result",
        "value": {
          "op": "get",
          "field": "value"
        }
      }
    ]
  }
}` -> "\"delivered-count\""
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "status",
          "value": "delivered"
        }
      },
      {
        "op": "avg",
        "field": "total"
      },
      {
        "op": "let",
        "in": {
          "op": "literal",
          "value": "delivered-avg"
        },
        "name": "result",
        "value": {
          "op": "get",
          "field": "value"
        }
      }
    ]
  }
}` -> "\"delivered-avg\""
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "status",
          "value": "delivered"
        }
      },
      {
        "op": "max",
        "field": "total"
      },
      {
        "op": "let",
        "in": {
          "op": "literal",
          "value": "delivered-max"
        },
        "name": "result",
        "value": {
          "op": "get",
          "field": "value"
        }
      }
    ]
  }
}` -> "\"delivered-max\""

### 14. Store the list of employees in the engineering department in memory as engineering-employees → What is the average salary of the engineering employees stored in memory? [FAIL]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "employees"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "department",
          "value": "engineering"
        }
      },
      {
        "op": "store as",
        "name": "engineering-employees"
      }
    ]
  }
}` -> ERROR: ValidationError: Unknown operation 'store as'
   - `{
  "program": {
    "op": "let",
    "in": {
      "op": "pipe",
      "steps": [
        {
          "op": "load",
          "name": "employees"
        },
        {
          "op": "filter",
          "where": {
            "op": "eq",
            "field": "department",
            "value": "engineering"
          }
        }
      ]
    },
    "name": "engineering-employees"
  }
}` -> ERROR: ValidationError: Operation 'let' requires field 'v...
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "employees"
      },
      {
        "op": "filter",
        "where": {
          "op": "eq",
          "field": "department",
          "value": "engineering"
        }
      },
      {
        "op": "let",
        "name": "engineering-employees",
        "value": {
          "op": "get"
        }
      }
    ]
  }
}` -> ERROR: ValidationError: Operation 'let' requires field 'i...
   - `{
  "program": {
    "op": "let",
    "name": "engineering-employees",
    "value": {
      "op": "pipe",
      "steps": [
        {
          "op": "load",
          "name": "employees"
        },
        {
          "op": "filter",
          "where": {
            "op": "eq",
            "field": "department",
            "value": "engineering"
          }
        }
      ]
    },
    "in": {
      "op": "get"
    }
  }
}` -> ERROR: ValidationError: Operation 'get' requires either '...
   - `{
  "program": {
    "op": "let",
    "name": "engineering-employees",
    "value": {
      "op": "pipe",
      "steps": [
        {
          "op": "load",
          "name": "employees"
        },
        {
          "op": "filter",
          "where": {
            "op": "eq",
            "field": "department",
            "value": "engineering"
          }
        }
      ]
    },
    "in": {
      "op": "literal",
      "value": "Stored engineering employees in memory"
    }
  }
}` -> "\"Stored engineering employees in memory\""


