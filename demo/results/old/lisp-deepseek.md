# PTC-Lisp Test Report

**Generated:** 2025-12-11 10:52:05 UTC
**Model:** openrouter:deepseek/deepseek-v3.2
**Data Mode:** schema

## Summary

| Metric | Value |
|--------|-------|
| Passed | 12/14 |
| Failed | 2 |
| Total Attempts | 23 |
| Avg Attempts/Test | 1.64 |
| Duration | 1.4m |
| Total Tokens | 17947 |
| Cost | $0.00 |

## Results

| # | Query | Status | Attempts | Program |
|---|-------|--------|----------|---------|
| 1 | How many products are there? | PASS | 1 | `(count ctx/products)` |
| 2 | How many orders have status 'delivered'? | PASS | 1 | `(->> ctx/orders (filter (where :status =...` |
| 3 | What is the total revenue from all order... | PASS | 1 | `(sum-by :total ctx/orders)` |
| 4 | What is the average product rating? | PASS | 1 | `(avg-by :rating ctx/products)` |
| 5 | How many employees work remotely? | PASS | 1 | `(->> ctx/employees (filter (where :remot...` |
| 6 | How many products cost more than $500? | PASS | 1 | `(->> ctx/products (filter (where :price ...` |
| 7 | How many orders over $1000 were paid by ... | PASS | 1 | `(->> ctx/orders (filter (all-of (where :...` |
| 8 | What is the name of the cheapest product... | PASS | 1 | `(->> ctx/products (filter (where :status...` |
| 9 | Get the names of the 3 most expensive pr... | PASS | 1 | `(->> ctx/products (sort-by :price >) (ta...` |
| 10 | How many orders are either cancelled or ... | PASS | 1 | `(->> ctx/orders (filter (any-of (where :...` |
| 11 | What is the average salary of senior-lev... | FAIL | 3 | `-` |
| 12 | How many unique products have been order... | PASS | 1 | `(->> ctx/orders (pluck :product_id) (dis...` |
| 13 | Count delivered orders and store the res... | PASS | 2 | `(let [total-count (count ctx/orders) del...` |
| 14 | Store the list of employees in the engin... | FAIL | 7 | `{:engineering-employees (->> ctx/employe...` |

## Failed Tests

### 11. What is the average salary of senior-level employees?

- **Error:** No result returned
- **Expected:** Filter then aggregate
- **Constraint:** `{:between, 50000, 200000}`
- **Attempts:** 3

**Programs tried:**
  - `(->> ctx/employees
     (filter (where :level = :senior))
     (avg-by :salary))`
    - Result: "nil"
  - `(->> ctx/employees
     (filter (where :level = :senior))
     (avg-by :salary))`
    - Result: "nil"
  - `(keys ctx)`
    - Result: ERROR: Error: {:unbound_var, :ctx}

---
### 14. Store the list of employees in the engineering department in memory as engineering-employees → What is the average salary of the engineering employees stored in memory?

- **Error:** Query failed: "Max iterations reached"
- **Expected:** Multi-turn: average salary using stored employee list
- **Constraint:** `{:between, 50000, 200000}`
- **Attempts:** 7

**Programs tried:**
  - `{:engineering-employees (->> ctx/employees (filter (where :department = :engineering)))}`
    - Result: "%{\"engineering-employees\": []}"
  - `{:engineering-employees (->> ctx/employees (filter (where :department = :engineering)))}`
    - Result: "%{\"engineering-employees\": []}"
  - `(avg-by :salary memory/engineering-employees)`
    - Result: "nil"
  - `{:engineering-employees-count (count memory/engineering-employees)
 :engineering-employees-sample (first memory/engineering-employees)}`
    - Result: "%{\"engineering-employees-count\": 0, \"engineeri...
  - `(let [engineering-employees (->> ctx/employees (filter (where :department = :engineering)))]
  {:engineering-count (count engineering-employees)
   :engineering-avg-salary (avg-by :salary engineering-employees)})`
    - Result: "%{\"engineering-count\": 0, \"engineering-avg-sal...
  - `(->> ctx/employees (pluck :department) (distinct) (sort))`
    - Result: "[\"engineering\", \"finance\", \"hr\", \"marketin...
  - `(->> ctx/employees 
     (group-by :department)
     (update-vals count))`
    - Result: ERROR: Error: {:type_error, "invalid argument types: func...



## All Programs Generated

### 1. How many products are there? [PASS]
   - `(count ctx/products)` -> "500"

### 2. How many orders have status 'delivered'? [PASS]
   - `(->> ctx/orders
     (filter (where :status = "delivered"))
     (count))` -> "214"

### 3. What is the total revenue from all orders? (sum the total field) [PASS]
   - `(sum-by :total ctx/orders)` -> "2464681.83"

### 4. What is the average product rating? [PASS]
   - `(avg-by :rating ctx/products)` -> "3.01"

### 5. How many employees work remotely? [PASS]
   - `(->> ctx/employees
     (filter (where :remote))
     (count))` -> "93"

### 6. How many products cost more than $500? [PASS]
   - `(->> ctx/products
     (filter (where :price > 500))
     (count))` -> "250"

### 7. How many orders over $1000 were paid by credit card? [PASS]
   - `(->> ctx/orders
     (filter (all-of (where :total > 1000)
                     (where :payment_method = :credit_card)))
     (count))` -> "0"

### 8. What is the name of the cheapest product? [PASS]
   - `(->> ctx/products
     (filter (where :status = "active"))
     (min-by :price)
     (:name))` -> "\"Product 73\""

### 9. Get the names of the 3 most expensive products [PASS]
   - `(->> ctx/products
     (sort-by :price >)
     (take 3)
     (pluck :name))` -> "[\"Product 225\", \"Product 222\", \"Product 386\...

### 10. How many orders are either cancelled or refunded? [PASS]
   - `(->> ctx/orders
     (filter (any-of (where :status = "cancelled")
                     (where :status = "refunded")))
     (count))` -> "381"

### 11. What is the average salary of senior-level employees? [FAIL]
   - `(->> ctx/employees
     (filter (where :level = :senior))
     (avg-by :salary))` -> "nil"
   - `(->> ctx/employees
     (filter (where :level = :senior))
     (avg-by :salary))` -> "nil"
   - `(keys ctx)` -> ERROR: Error: {:unbound_var, :ctx}

### 12. How many unique products have been ordered? (count distinct product_id values in orders) [PASS]
   - `(->> ctx/orders
     (pluck :product_id)
     (distinct)
     (count))` -> "424"

### 13. Count delivered orders and store the result in memory as delivered-count → What percentage of all orders are delivered? Use memory/delivered-count and total order count. [PASS]
   - `{:delivered-count (->> ctx/orders (filter (where :status = "delivered")) (count))}` -> "%{\"delivered-count\": 214}"
   - `(let [total-count (count ctx/orders)
      delivered-count memory/delivered-count
      percentage (* 100.0 (/ delivered-count total-count))]
  {:result percentage})` -> "21.40"

### 14. Store the list of employees in the engineering department in memory as engineering-employees → What is the average salary of the engineering employees stored in memory? [FAIL]
   - `{:engineering-employees (->> ctx/employees (filter (where :department = :engineering)))}` -> "%{\"engineering-employees\": []}"
   - `{:engineering-employees (->> ctx/employees (filter (where :department = :engineering)))}` -> "%{\"engineering-employees\": []}"
   - `(avg-by :salary memory/engineering-employees)` -> "nil"
   - `{:engineering-employees-count (count memory/engineering-employees)
 :engineering-employees-sample (first memory/engineering-employees)}` -> "%{\"engineering-employees-count\": 0, \"engineeri...
   - `(let [engineering-employees (->> ctx/employees (filter (where :department = :engineering)))]
  {:engineering-count (count engineering-employees)
   :engineering-avg-salary (avg-by :salary engineering-employees)})` -> "%{\"engineering-count\": 0, \"engineering-avg-sal...
   - `(->> ctx/employees (pluck :department) (distinct) (sort))` -> "[\"engineering\", \"finance\", \"hr\", \"marketin...
   - `(->> ctx/employees 
     (group-by :department)
     (update-vals count))` -> ERROR: Error: {:type_error, "invalid argument types: func...


