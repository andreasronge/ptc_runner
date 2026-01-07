(def employee-spending (group-by :employee_id ctx/expenses))

(def employee-total-amount
  (map
    (fn [[id expenses]]
      [id (sum-by :amount expenses)])
    employee-spending))

(def employee-average-amount
  (map
    (fn [[id expenses]]
      [id (avg-by :amount expenses)])
    employee-spending))

(def employee-distinct-categories
  (map
    (fn [[id expenses]]
      [id (count (distinct (pluck :category expenses)))])
    employee-spending))

(def employee-rejection-rate
  (map
    (fn [[id expenses]]
      (let [total-expenses (count expenses)
            rejected-expenses (count (filter (where :status = "rejected") expenses))]
        [id (if (> total-expenses 0)
              (/ rejected-expenses total-expenses)
              0)]))
    employee-spending))

(def employee-expense-frequency
  (map
    (fn [[id expenses]]
      (let [dates (sort (pluck :date expenses))
            first-date (first dates)
            last-date (last dates)
            num-expenses (count expenses)]
        [id (if (and first-date last-date (> num-expenses 1))
              (let [first-millis (.getTime (java.util.Date. (first dates)))
                    last-millis (.getTime (java.util.Date. (last dates)))
                    date-diff-days (quot (- last-millis first-millis) (* 1000 60 60 24))]
                (if (> date-diff-days 0)
                  (/ num-expenses (double date-diff-days))
                  num-expenses))
              0)]))
    employee-spending))

(def suspicious-scores
  (into {}
    (for [[employee-id total-amount] employee-total-amount]
      (let [avg-amount (second (first (filter #(= employee-id (first %)) employee-average-amount)))
            distinct-categories (second (first (filter #(= employee-id (first %)) employee-distinct-categories)))
            rejection-rate (second (first (filter #(= employee-id (first %)) employee-rejection-rate)))
            expense-frequency (second (first (filter #(= employee-id (first %)) employee-expense-frequency)))]
        [employee-id (+
                       (* total-amount 0.00001) ; High total spending (scaled down for balance)
                       (* avg-amount 0.0001)   ; High average spending (scaled down for balance)
                       (* distinct-categories 10.0) ; Many distinct categories
                       (* rejection-rate 50.0) ; High rejection rate
                       (* expense-frequency 200.0))] ; High expense frequency
        ))))

(def most-suspicious-employee
  (first (apply max-key second suspicious-scores)))

; (return most-suspicious-employee)