# PTC-JSON Test Report

**Generated:** 2025-12-11 14:10:18 UTC
**Model:** openrouter:deepseek/deepseek-v3.2
**Data Mode:** schema

## Summary

| Metric | Value |
|--------|-------|
| Passed | 11/14 |
| Failed | 3 |
| Total Attempts | 29 |
| Avg Attempts/Test | 2.07 |
| Duration | 3.8m |
| Total Tokens | 7720 |
| Cost | $0.00 |

## Results

| # | Query | Status | Attempts | Program |
|---|-------|--------|----------|---------|
| 1 | How many products are there? | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 2 | How many orders have status 'delivered'? | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 3 | What is the total revenue from all order... | PASS | 1 | `{"program": {"op": "pipe", "steps": [{"o...` |
| 4 | What is the average product rating? | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 5 | How many employees work remotely? | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 6 | How many products cost more than $500? | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 7 | How many orders over $1000 were paid by ... | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 8 | What is the name of the cheapest product... | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 9 | Get the names of the 3 most expensive pr... | FAIL | 5 | `-` |
| 10 | How many orders are either cancelled or ... | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 11 | What is the average salary of senior-lev... | PASS | 1 | `{ "program": { "op": "pipe", "steps": [ ...` |
| 12 | How many unique products have been order... | FAIL | 5 | `-` |
| 13 | Count delivered orders and store the res... | FAIL | 5 | `-` |
| 14 | Store the list of employees in the engin... | PASS | 4 | `{ "program": { "op": "pipe", "steps": [ ...` |

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
    - Result: "\"Product 114\""
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
        "op": "let",
        "in": {
          "op": "pipe",
          "steps": [
            {
              "op": "var",
              "name": "sorted_products"
            },
            {
              "op": "map",
              "expr": {
                "op": "get",
                "field": "name"
              }
            }
          ]
        },
        "name": "sorted_products"
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
        "name": "products"
      },
      {
        "op": "sort_by",
        "field": "price",
        "desc": true
      },
      {
        "op": "let",
        "value": {
          "op": "pipe",
          "steps": [
            {
              "op": "var",
              "name": "sorted_products"
            },
            {
              "op": "map",
              "expr": {
                "op": "get",
                "field": "name"
              }
            }
          ]
        },
        "in": {
          "op": "var",
          "name": "sorted_products"
        },
        "name": "sorted_products"
      }
    ]
  }
}`
    - Result: ERROR: ExecutionError: map requires a list, got nil

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
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "select",
        "fields": ["product_id"]
      },
      {
        "op": "map",
        "expr": {
          "op": "get",
          "field": "product_id"
        }
      },
      {
        "op": "var",
        "name": "all_product_ids"
      },
      {
        "op": "pipe",
        "steps": [
          {
            "op": "var",
            "name": "all_product_ids"
          },
          {
            "op": "map",
            "expr": {
              "op": "literal",
              "value": null
            }
          },
          {
            "op": "keys"
          },
          {
            "op": "count"
          }
        ]
      }
    ]
  }
}`
    - Result: ERROR: ExecutionError: map requires a list, got nil
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "select",
        "fields": ["product_id"]
      },
      {
        "op": "var",
        "name": "product_ids"
      },
      {
        "op": "pipe",
        "steps": [
          {
            "op": "var",
            "name": "product_ids"
          },
          {
            "op": "map",
            "expr": {
              "op": "get",
              "field": "product_id"
            }
          },
          {
            "op": "var",
            "name": "id_list"
          },
          {
            "op": "pipe",
            "steps": [
              {
                "op": "var",
                "name": "id_list"
              },
              {
                "op": "map",
                "expr": {
                  "op": "literal",
                  "value": null
                }
              },
              {
                "op": "keys"
              },
              {
                "op": "count"
              }
            ]
          }
        ]
      }
    ]
  }
}`
    - Result: ERROR: ExecutionError: map requires a list, got nil
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "select",
        "fields": ["product_id"]
      },
      {
        "op": "var",
        "name": "product_records"
      },
      {
        "op": "pipe",
        "steps": [
          {
            "op": "var",
            "name": "product_records"
          },
          {
            "op": "map",
            "expr": {
              "op": "get",
              "field": "product_id"
            }
          },
          {
            "op": "var",
            "name": "id_list"
          },
          {
            "op": "pipe",
            "steps": [
              {
                "op": "var",
                "name": "id_list"
              },
              {
                "op": "sort_by",
                "field": null
              },
              {
                "op": "var",
                "name": "sorted_ids"
              },
              {
                "op": "pipe",
                "steps": [
                  {
                    "op": "var",
                    "name": "sorted_ids"
                  },
                  {
                    "op": "filter",
                    "where": {
                      "op": "neq",
                      "field": null,
                      "value": {
                        "op": "pipe",
                        "steps": [
                          {
                            "op": "var",
                            "name": "sorted_ids"
                          },
                          {
                            "op": "nth",
                            "index": {
                              "op": "pipe",
                              "steps": [
                                {
                                  "op": "var",
                                  "name": "sorted_ids"
                                },
                                {
                                  "op": "index_of",
                                  "value": {
                                    "op": "get",
                                    "field": null
                                  }
                                }
                              ]
                            }
                          }
                        ]
                      }
                    }
                  },
                  {
                    "op": "count"
                  }
                ]
              }
            ]
          }
        ]
      }
    ]
  }
}`
    - Result: ERROR: ValidationError: Operation 'sort_by' requires fiel...
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "select",
        "fields": ["product_id"]
      },
      {
        "op": "var",
        "name": "product_records"
      },
      {
        "op": "pipe",
        "steps": [
          {
            "op": "var",
            "name": "product_records"
          },
          {
            "op": "map",
            "expr": {
              "op": "get",
              "field": "product_id"
            }
          },
          {
            "op": "var",
            "name": "id_list"
          },
          {
            "op": "pipe",
            "steps": [
              {
                "op": "var",
                "name": "id_list"
              },
              {
                "op": "count"
              }
            ]
          }
        ]
      }
    ]
  }
}`
    - Result: ERROR: ExecutionError: map requires a list, got nil
  - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "var",
        "name": "all_orders"
      },
      {
        "op": "pipe",
        "steps": [
          {
            "op": "var",
            "name": "all_orders"
          },
          {
            "op": "map",
            "expr": {
              "op": "get",
              "field": "product_id"
            }
          },
          {
            "op": "var",
            "name": "product_ids"
          },
          {
            "op": "pipe",
            "steps": [
              {
                "op": "var",
                "name": "product_ids"
              },
              {
                "op": "count"
              }
            ]
          }
        ]
      }
    ]
  }
}`
    - Result: ERROR: ExecutionError: map requires a list, got nil

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
        "in": "delivered-count",
        "value": {
          "op": "var",
          "name": "input"
        }
      }
    ]
  }
}`
    - Result: ERROR: ValidationError: Operation 'let' requires field 'n...
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
        "name": "delivered-count",
        "value": {
          "op": "var",
          "name": "input"
        }
      }
    ]
  }
}`
    - Result: ERROR: ValidationError: Operation 'let' requires field 'i...
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
          "op": "var",
          "name": "input"
        },
        "name": "delivered-count",
        "value": {
          "op": "var",
          "name": "input"
        }
      }
    ]
  }
}`
    - Result: "nil"
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
          "value": "stored"
        },
        "name": "delivered-count",
        "value": {
          "op": "var",
          "name": "input"
        }
      },
      {
        "op": "var",
        "name": "input"
      }
    ]
  }
}`
    - Result: "nil"
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
          "op": "var",
          "name": "input"
        },
        "name": "delivered-count",
        "value": {
          "op": "var",
          "name": "input"
        }
      }
    ]
  }
}`
    - Result: "nil"



## All Programs Generated

### 1. How many products are there? [PASS]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "products"},
      {"op": "count"}
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
}` -> "190"

### 3. What is the total revenue from all orders? (sum the total field) [PASS]
   - `{"program": {"op": "pipe", "steps": [{"op": "load", "name": "orders"}, {"op": "sum", "field": "total"}]}}` -> "2516593.85"

### 4. What is the average product rating? [PASS]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "products"},
      {"op": "avg", "field": "rating"}
    ]
  }
}` -> "2.99"

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
}` -> "100"

### 6. How many products cost more than $500? [PASS]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "products"},
      {"op": "filter", "where": {"op": "gt", "field": "price", "value": 500}},
      {"op": "count"}
    ]
  }
}` -> "258"

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
}` -> "203"

### 8. What is the name of the cheapest product? [PASS]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "products"
      },
      {
        "op": "min_by",
        "field": "price"
      },
      {
        "op": "get",
        "field": "name"
      }
    ]
  }
}` -> "\"Product 114\""

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
}` -> "\"Product 114\""
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
        "op": "let",
        "in": {
          "op": "pipe",
          "steps": [
            {
              "op": "var",
              "name": "sorted_products"
            },
            {
              "op": "map",
              "expr": {
                "op": "get",
                "field": "name"
              }
            }
          ]
        },
        "name": "sorted_products"
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
        "name": "products"
      },
      {
        "op": "sort_by",
        "field": "price",
        "desc": true
      },
      {
        "op": "let",
        "value": {
          "op": "pipe",
          "steps": [
            {
              "op": "var",
              "name": "sorted_products"
            },
            {
              "op": "map",
              "expr": {
                "op": "get",
                "field": "name"
              }
            }
          ]
        },
        "in": {
          "op": "var",
          "name": "sorted_products"
        },
        "name": "sorted_products"
      }
    ]
  }
}` -> ERROR: ExecutionError: map requires a list, got nil

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
}` -> "392"

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
}` -> "140420.88"

### 12. How many unique products have been ordered? (count distinct product_id values in orders) [FAIL]
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "select",
        "fields": ["product_id"]
      },
      {
        "op": "map",
        "expr": {
          "op": "get",
          "field": "product_id"
        }
      },
      {
        "op": "var",
        "name": "all_product_ids"
      },
      {
        "op": "pipe",
        "steps": [
          {
            "op": "var",
            "name": "all_product_ids"
          },
          {
            "op": "map",
            "expr": {
              "op": "literal",
              "value": null
            }
          },
          {
            "op": "keys"
          },
          {
            "op": "count"
          }
        ]
      }
    ]
  }
}` -> ERROR: ExecutionError: map requires a list, got nil
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "select",
        "fields": ["product_id"]
      },
      {
        "op": "var",
        "name": "product_ids"
      },
      {
        "op": "pipe",
        "steps": [
          {
            "op": "var",
            "name": "product_ids"
          },
          {
            "op": "map",
            "expr": {
              "op": "get",
              "field": "product_id"
            }
          },
          {
            "op": "var",
            "name": "id_list"
          },
          {
            "op": "pipe",
            "steps": [
              {
                "op": "var",
                "name": "id_list"
              },
              {
                "op": "map",
                "expr": {
                  "op": "literal",
                  "value": null
                }
              },
              {
                "op": "keys"
              },
              {
                "op": "count"
              }
            ]
          }
        ]
      }
    ]
  }
}` -> ERROR: ExecutionError: map requires a list, got nil
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "select",
        "fields": ["product_id"]
      },
      {
        "op": "var",
        "name": "product_records"
      },
      {
        "op": "pipe",
        "steps": [
          {
            "op": "var",
            "name": "product_records"
          },
          {
            "op": "map",
            "expr": {
              "op": "get",
              "field": "product_id"
            }
          },
          {
            "op": "var",
            "name": "id_list"
          },
          {
            "op": "pipe",
            "steps": [
              {
                "op": "var",
                "name": "id_list"
              },
              {
                "op": "sort_by",
                "field": null
              },
              {
                "op": "var",
                "name": "sorted_ids"
              },
              {
                "op": "pipe",
                "steps": [
                  {
                    "op": "var",
                    "name": "sorted_ids"
                  },
                  {
                    "op": "filter",
                    "where": {
                      "op": "neq",
                      "field": null,
                      "value": {
                        "op": "pipe",
                        "steps": [
                          {
                            "op": "var",
                            "name": "sorted_ids"
                          },
                          {
                            "op": "nth",
                            "index": {
                              "op": "pipe",
                              "steps": [
                                {
                                  "op": "var",
                                  "name": "sorted_ids"
                                },
                                {
                                  "op": "index_of",
                                  "value": {
                                    "op": "get",
                                    "field": null
                                  }
                                }
                              ]
                            }
                          }
                        ]
                      }
                    }
                  },
                  {
                    "op": "count"
                  }
                ]
              }
            ]
          }
        ]
      }
    ]
  }
}` -> ERROR: ValidationError: Operation 'sort_by' requires fiel...
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "select",
        "fields": ["product_id"]
      },
      {
        "op": "var",
        "name": "product_records"
      },
      {
        "op": "pipe",
        "steps": [
          {
            "op": "var",
            "name": "product_records"
          },
          {
            "op": "map",
            "expr": {
              "op": "get",
              "field": "product_id"
            }
          },
          {
            "op": "var",
            "name": "id_list"
          },
          {
            "op": "pipe",
            "steps": [
              {
                "op": "var",
                "name": "id_list"
              },
              {
                "op": "count"
              }
            ]
          }
        ]
      }
    ]
  }
}` -> ERROR: ExecutionError: map requires a list, got nil
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "load",
        "name": "orders"
      },
      {
        "op": "var",
        "name": "all_orders"
      },
      {
        "op": "pipe",
        "steps": [
          {
            "op": "var",
            "name": "all_orders"
          },
          {
            "op": "map",
            "expr": {
              "op": "get",
              "field": "product_id"
            }
          },
          {
            "op": "var",
            "name": "product_ids"
          },
          {
            "op": "pipe",
            "steps": [
              {
                "op": "var",
                "name": "product_ids"
              },
              {
                "op": "count"
              }
            ]
          }
        ]
      }
    ]
  }
}` -> ERROR: ExecutionError: map requires a list, got nil

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
        "in": "delivered-count",
        "value": {
          "op": "var",
          "name": "input"
        }
      }
    ]
  }
}` -> ERROR: ValidationError: Operation 'let' requires field 'n...
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
        "name": "delivered-count",
        "value": {
          "op": "var",
          "name": "input"
        }
      }
    ]
  }
}` -> ERROR: ValidationError: Operation 'let' requires field 'i...
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
          "op": "var",
          "name": "input"
        },
        "name": "delivered-count",
        "value": {
          "op": "var",
          "name": "input"
        }
      }
    ]
  }
}` -> "nil"
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
          "value": "stored"
        },
        "name": "delivered-count",
        "value": {
          "op": "var",
          "name": "input"
        }
      },
      {
        "op": "var",
        "name": "input"
      }
    ]
  }
}` -> "nil"
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
          "op": "var",
          "name": "input"
        },
        "name": "delivered-count",
        "value": {
          "op": "var",
          "name": "input"
        }
      }
    ]
  }
}` -> "nil"

### 14. Store the list of employees in the engineering department in memory as engineering-employees → What is the average salary of the engineering employees stored in memory? [PASS]
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
        "in": {
          "op": "literal",
          "value": "engineering-employees"
        },
        "name": "engineering-employees"
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
        "in": {
          "op": "literal",
          "value": "engineering-employees"
        },
        "name": "engineering-employees",
        "value": {
          "op": "var",
          "name": "input"
        }
      }
    ]
  }
}` -> "\"engineering-employees\""
   - `{
  "program": {
    "op": "pipe",
    "steps": [
      {
        "op": "var",
        "name": "engineering-employees"
      },
      {
        "op": "avg",
        "field": "salary"
      }
    ]
  }
}` -> ERROR: ExecutionError: avg requires a list, got nil
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
        "op": "avg",
        "field": "salary"
      }
    ]
  }
}` -> "131423.91"


