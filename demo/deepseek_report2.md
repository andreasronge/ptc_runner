# PTC-Lisp Test Report

**Generated:** 2025-12-11 14:04:20 UTC
**Model:** openrouter:deepseek/deepseek-v3.2
**Data Mode:** schema

## Summary

| Metric | Value |
|--------|-------|
| Passed | 13/14 |
| Failed | 1 |
| Total Attempts | 18 |
| Avg Attempts/Test | 1.29 |
| Duration | 1.7m |
| Total Tokens | 19180 |
| Cost | $0.00 |

## Results

| # | Query | Status | Attempts | Program |
|---|-------|--------|----------|---------|
| 1 | How many products are there? | PASS | 1 | `(count ctx/products)` |
| 2 | How many orders have status 'delivered'? | PASS | 1 | `(->> ctx/orders (filter (where :status =...` |
| 3 | What is the total revenue from all order... | PASS | 1 | `(->> ctx/orders (sum-by :total))` |
| 4 | What is the average product rating? | PASS | 1 | `(avg-by :rating ctx/products)` |
| 5 | How many employees work remotely? | PASS | 1 | `(count (filter (where :remote) ctx/emplo...` |
| 6 | How many products cost more than $500? | PASS | 1 | `(->> ctx/products (filter (where :price ...` |
| 7 | How many orders over $1000 were paid by ... | PASS | 1 | `(->> ctx/orders (filter (all-of (where :...` |
| 8 | What is the name of the cheapest product... | PASS | 1 | `(->> ctx/products (filter (where :status...` |
| 9 | Get the names of the 3 most expensive pr... | PASS | 1 | `(->> ctx/products (sort-by :price >) (ta...` |
| 10 | How many orders are either cancelled or ... | PASS | 1 | `(->> ctx/orders (filter (any-of (where :...` |
| 11 | What is the average salary of senior-lev... | PASS | 1 | `(->> ctx/employees (filter (where :level...` |
| 12 | How many unique products have been order... | PASS | 1 | `(->> ctx/orders (pluck :product_id) (dis...` |
| 13 | Count delivered orders and store the res... | PASS | 2 | `(let [delivered-count memory/delivered-c...` |
| 14 | Store the list of employees in the engin... | FAIL | 4 | `-` |

## Failed Tests

### 14. Store the list of employees in the engineering department in memory as engineering-employees → What is the average salary of the engineering employees stored in memory?

- **Error:** No result returned after multi-turn
- **Expected:** Multi-turn: average salary using stored employee list
- **Constraint:** `{:between, 50000, 200000}`
- **Attempts:** 4

**Programs tried:**
  - `{:engineering-employees (filter (where :department = :engineering) ctx/employees)}`
    - Result: "%{\"engineering-employees\": [%{\"bonus\" => 2086...
  - `(let [eng-employees memory/engineering-employees]
  {:eng-count (count eng-employees)
   :eng-salary-avg (avg-by :salary eng-employees)
   :eng-salary-max (max-by :salary eng-employees)
   :eng-salary-min (min-by :salary eng-employees)
   :eng-bonus-total (sum-by :bonus eng-employees)
   :eng-levels (->> eng-employees
                    (group-by :level)
                    (update-vals count))
   :eng-remote-count (count (filter (where :remote) eng-employees))
   :eng-experience-avg (avg-by :years_employed eng-employees)})`
    - Result: ERROR: Error: {:type_error, "update-vals expects (map, fu...
  - `(let [eng-employees memory/engineering-employees]
  {:eng-count (count eng-employees)
   :eng-salary-avg (avg-by :salary eng-employees)
   :eng-salary-max (max-by :salary eng-employees)
   :eng-salary-min (min-by :salary eng-employees)
   :eng-bonus-total (sum-by :bonus eng-employees)
   :eng-levels (-> (group-by :level eng-employees)
                   (update-vals count))
   :eng-remote-count (count (filter (where :remote) eng-employees))
   :eng-experience-avg (avg-by :years_employed eng-employees)})`
    - Result: "%{\"eng-count\": 32, \"eng-salary-avg\": 117777.5...
  - `(let [eng-employees memory/engineering-employees]
  {:eng-count (count eng-employees)
   :eng-salary-avg (avg-by :salary eng-employees)
   :eng-salary-max (:salary (max-by :salary eng-employees))
   :eng-salary-min (:salary (min-by :salary eng-employees))
   :eng-bonus-total (sum-by :bonus eng-employees)
   :eng-levels (-> (group-by :level eng-employees)
                   (update-vals count))
   :eng-remote-count (count (filter (where :remote) eng-employees))
   :eng-experience-avg (avg-by :years_employed eng-employees)})`
    - Result: "%{\"eng-count\": 32, \"eng-salary-avg\": 117777.5...



## All Programs Generated

### 1. How many products are there? [PASS]
   - `(count ctx/products)` -> "500"

### 2. How many orders have status 'delivered'? [PASS]
   - `(->> ctx/orders
     (filter (where :status = "delivered"))
     (count))` -> "209"

### 3. What is the total revenue from all orders? (sum the total field) [PASS]
   - `(->> ctx/orders
     (sum-by :total))` -> "2533294.73"

### 4. What is the average product rating? [PASS]
   - `(avg-by :rating ctx/products)` -> "3.02"

### 5. How many employees work remotely? [PASS]
   - `(count (filter (where :remote) ctx/employees))` -> "110"

### 6. How many products cost more than $500? [PASS]
   - `(->> ctx/products
     (filter (where :price > 500))
     (count))` -> "257"

### 7. How many orders over $1000 were paid by credit card? [PASS]
   - `(->> ctx/orders
     (filter (all-of
               (where :total > 1000)
               (where :payment_method = "credit_card")))
     (count))` -> "177"

### 8. What is the name of the cheapest product? [PASS]
   - `(->> ctx/products
     (filter (where :status = "active"))
     (min-by :price)
     (:name))` -> "\"Product 128\""

### 9. Get the names of the 3 most expensive products [PASS]
   - `(->> ctx/products
     (sort-by :price >)
     (take 3)
     (pluck :name))` -> "[\"Product 459\", \"Product 403\", \"Product 247\...

### 10. How many orders are either cancelled or refunded? [PASS]
   - `(->> ctx/orders
     (filter (any-of (where :status = "cancelled")
                     (where :status = "refunded")))
     (count))` -> "402"

### 11. What is the average salary of senior-level employees? [PASS]
   - `(->> ctx/employees
     (filter (where :level = :senior))
     (avg-by :salary))` -> "135866.13"

### 12. How many unique products have been ordered? (count distinct product_id values in orders) [PASS]
   - `(->> ctx/orders
     (pluck :product_id)
     (distinct)
     (count))` -> "435"

### 13. Count delivered orders and store the result in memory as delivered-count → What percentage of all orders are delivered? Use memory/delivered-count and total order count. [PASS]
   - `{:delivered-count (->> ctx/orders (filter (where :status = "delivered")) (count))}` -> "%{\"delivered-count\": 209}"
   - `(let [delivered-count memory/delivered-count
      total-count (count ctx/orders)]
  {:percentage (if (> total-count 0)
                 (* 100 (/ delivered-count total-count))
                 0)
   :result (if (> total-count 0)
             (* 100 (/ delivered-count total-count))
             0)})` -> "20.90"

### 14. Store the list of employees in the engineering department in memory as engineering-employees → What is the average salary of the engineering employees stored in memory? [FAIL]
   - `{:engineering-employees (filter (where :department = :engineering) ctx/employees)}` -> "%{\"engineering-employees\": [%{\"bonus\" => 2086...
   - `(let [eng-employees memory/engineering-employees]
  {:eng-count (count eng-employees)
   :eng-salary-avg (avg-by :salary eng-employees)
   :eng-salary-max (max-by :salary eng-employees)
   :eng-salary-min (min-by :salary eng-employees)
   :eng-bonus-total (sum-by :bonus eng-employees)
   :eng-levels (->> eng-employees
                    (group-by :level)
                    (update-vals count))
   :eng-remote-count (count (filter (where :remote) eng-employees))
   :eng-experience-avg (avg-by :years_employed eng-employees)})` -> ERROR: Error: {:type_error, "update-vals expects (map, fu...
   - `(let [eng-employees memory/engineering-employees]
  {:eng-count (count eng-employees)
   :eng-salary-avg (avg-by :salary eng-employees)
   :eng-salary-max (max-by :salary eng-employees)
   :eng-salary-min (min-by :salary eng-employees)
   :eng-bonus-total (sum-by :bonus eng-employees)
   :eng-levels (-> (group-by :level eng-employees)
                   (update-vals count))
   :eng-remote-count (count (filter (where :remote) eng-employees))
   :eng-experience-avg (avg-by :years_employed eng-employees)})` -> "%{\"eng-count\": 32, \"eng-salary-avg\": 117777.5...
   - `(let [eng-employees memory/engineering-employees]
  {:eng-count (count eng-employees)
   :eng-salary-avg (avg-by :salary eng-employees)
   :eng-salary-max (:salary (max-by :salary eng-employees))
   :eng-salary-min (:salary (min-by :salary eng-employees))
   :eng-bonus-total (sum-by :bonus eng-employees)
   :eng-levels (-> (group-by :level eng-employees)
                   (update-vals count))
   :eng-remote-count (count (filter (where :remote) eng-employees))
   :eng-experience-avg (avg-by :years_employed eng-employees)})` -> "%{\"eng-count\": 32, \"eng-salary-avg\": 117777.5...


