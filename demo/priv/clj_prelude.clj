;; PTC-Lisp Clojure REPL Prelude
;; Loads tool stubs and data bindings so LLM-generated code can execute in a real clj REPL.

;; --- Tool namespace ---
(ns tool)

(def ^:private documents
  [{:id "DOC-001" :title "Remote Work Guidelines"
    :topics ["remote work" "home office" "flexibility" "work from home"]
    :department "HR"
    :content "Guidelines for employees working remotely including equipment setup and communication expectations."}
   {:id "DOC-002" :title "Home Office Setup Requirements"
    :topics ["remote work" "equipment" "home office" "ergonomics"]
    :department "HR"
    :content "Requirements for home office setup including desk, chair, and monitor specifications."}
   {:id "DOC-003" :title "Remote Work Security Protocol"
    :topics ["remote work" "security" "vpn" "data protection"]
    :department "IT"
    :content "Security requirements for remote workers including VPN usage and device encryption."}
   {:id "DOC-004" :title "Travel Expense Policy"
    :topics ["expense reimbursement" "travel" "per diem" "receipts"]
    :department "Finance"
    :content "Policy for travel expense reimbursement including per diem rates and receipt requirements."}
   {:id "DOC-005" :title "Equipment Purchase Reimbursement"
    :topics ["expense reimbursement" "equipment" "purchase" "approval"]
    :department "Finance"
    :content "Process for getting reimbursed for approved equipment purchases."}
   {:id "DOC-006" :title "Meal and Entertainment Expenses"
    :topics ["expense reimbursement" "meals" "entertainment" "client"]
    :department "Finance"
    :content "Guidelines for meal and entertainment expense claims including limits and documentation."}
   {:id "DOC-007" :title "Policy WFH-2024-REIMB"
    :topics ["remote work" "expense reimbursement" "home office" "internet" "utilities"]
    :department "HR"
    :content "Comprehensive guide for remote workers on expense reimbursement for home office costs including internet and utilities allowance."}
   {:id "DOC-008" :title "Data Classification Policy"
    :topics ["security" "data handling" "classification" "confidential"]
    :department "IT"
    :content "How to classify and handle data based on sensitivity levels."}
   {:id "DOC-009" :title "Password and Authentication Standards"
    :topics ["security" "passwords" "authentication" "mfa"]
    :department "IT"
    :content "Requirements for password complexity and multi-factor authentication."}
   {:id "DOC-010" :title "Incident Response Procedure"
    :topics ["security" "incident" "breach" "reporting"]
    :department "IT"
    :content "Steps to follow when a security incident is detected."}
   {:id "DOC-011" :title "Performance Review Process"
    :topics ["performance" "review" "evaluation" "goals"]
    :department "HR"
    :content "Annual performance review process and timeline."}
   {:id "DOC-012" :title "Promotion Criteria and Process"
    :topics ["promotion" "career" "advancement" "criteria"]
    :department "HR"
    :content "Criteria for promotion consideration and the approval process."}
   {:id "DOC-013" :title "Employee Benefits Overview"
    :topics ["benefits" "health" "insurance" "retirement"]
    :department "HR"
    :content "Overview of employee benefits including health insurance and retirement plans."}
   {:id "DOC-014" :title "Paid Time Off Policy"
    :topics ["pto" "vacation" "sick leave" "time off"]
    :department "HR"
    :content "Policy for requesting and using paid time off."}
   {:id "DOC-015" :title "Software Request Process"
    :topics ["software" "request" "approval" "license"]
    :department "IT"
    :content "How to request new software and the approval workflow."}
   {:id "DOC-016" :title "Hardware Refresh Policy"
    :topics ["equipment" "hardware" "laptop" "refresh"]
    :department "IT"
    :content "Schedule and process for hardware refresh cycles."}
   {:id "DOC-017" :title "Bring Your Own Device Policy"
    :topics ["byod" "personal device" "mobile" "security"]
    :department "IT"
    :content "Policy for using personal devices for work purposes."}
   {:id "DOC-018" :title "Training and Certification Budget"
    :topics ["training" "certification" "reimbursement" "professional development" "courses"]
    :department "HR"
    :content "Annual training budget allocation and course funding. Covers tuition reimbursement for degree programs and training courses only. For professional certification exam fees, see the dedicated certification policy."}
   {:id "DOC-019" :title "Parking Policy"
    :topics ["parking" "office" "commute" "allocation"]
    :department "Facilities"
    :content "Parking spot allocation and rules for office locations."}
   {:id "DOC-020" :title "Training Budget Allocation"
    :topics ["training" "budget" "professional development" "courses"]
    :department "HR"
    :content "Annual training budget and how to request funding for courses."}
   {:id "DOC-021" :title "Certification Reimbursement"
    :topics ["certification" "expense reimbursement" "professional" "training"]
    :department "HR"
    :content "Reimbursement policy for professional certification exam fees. Employees are eligible for full reimbursement of certification fees upon passing. Submit receipts within 30 days of the exam date."}
   {:id "DOC-022" :title "Code of Conduct"
    :topics ["conduct" "ethics" "behavior" "compliance"]
    :department "Legal"
    :content "Expected standards of conduct for all employees."}
   {:id "DOC-023" :title "Anti-Harassment Policy"
    :topics ["harassment" "discrimination" "reporting" "compliance"]
    :department "Legal"
    :content "Policy against harassment and discrimination with reporting procedures."}
   {:id "DOC-024" :title "Conflict of Interest Disclosure"
    :topics ["conflict" "disclosure" "ethics" "compliance"]
    :department "Legal"
    :content "Requirements for disclosing potential conflicts of interest."}
   {:id "DOC-025" :title "Internal Communication Guidelines"
    :topics ["communication" "email" "slack" "meetings"]
    :department "HR"
    :content "Best practices for internal communication channels."}
   {:id "DOC-026" :title "External Communication Policy"
    :topics ["communication" "media" "social media" "public"]
    :department "Legal"
    :content "Guidelines for external communications and media interactions."}
   {:id "DOC-027" :title "New Hire Onboarding Checklist"
    :topics ["onboarding" "new hire" "orientation" "setup"]
    :department "HR"
    :content "Checklist for new employee onboarding process."}
   {:id "DOC-028" :title "IT Setup for New Employees"
    :topics ["onboarding" "it setup" "accounts" "equipment"]
    :department "IT"
    :content "IT account creation and equipment provisioning for new hires."}
   {:id "DOC-029" :title "Office Access and Hours"
    :topics ["office" "access" "hours" "badge"]
    :department "Facilities"
    :content "Office access hours and badge requirements."}
   {:id "DOC-030" :title "Meeting Room Booking"
    :topics ["meeting" "booking" "conference room" "calendar"]
    :department "Facilities"
    :content "How to book meeting rooms and usage guidelines."}
   {:id "DOC-031" :title "Visitor Policy"
    :topics ["visitor" "guest" "access" "escort"]
    :department "Facilities"
    :content "Policy for hosting visitors in the office."}
   {:id "DOC-032" :title "Corporate Card Usage Policy"
    :topics ["corporate card" "expense" "payment" "limits"]
    :department "Finance"
    :content "Guidelines for using corporate credit cards."}
   {:id "DOC-033" :title "Expense Report Submission Deadlines"
    :topics ["expense reimbursement" "deadline" "submission" "monthly"]
    :department "Finance"
    :content "Monthly deadlines for expense report submissions."}
   {:id "DOC-034" :title "Hybrid Work Schedule"
    :topics ["remote work" "hybrid" "schedule" "office days"]
    :department "HR"
    :content "Policy for hybrid work arrangements and required office days."}
   {:id "DOC-035" :title "Remote Work Eligibility"
    :topics ["remote work" "eligibility" "approval" "manager"]
    :department "HR"
    :content "Criteria for remote work eligibility and approval process."}
   {:id "DOC-036" :title "Intellectual Property Policy"
    :topics ["ip" "intellectual property" "patents" "inventions"]
    :department "Legal"
    :content "Policy regarding intellectual property and inventions."}
   {:id "DOC-037" :title "Data Retention Policy"
    :topics ["data" "retention" "deletion" "compliance"]
    :department "Legal"
    :content "Requirements for data retention and deletion schedules."}
   {:id "DOC-038" :title "Emergency Procedures"
    :topics ["emergency" "evacuation" "safety" "procedures"]
    :department "Facilities"
    :content "Emergency evacuation procedures and safety protocols."}
   {:id "DOC-039" :title "Sustainability Initiatives"
    :topics ["sustainability" "environment" "green" "recycling"]
    :department "Facilities"
    :content "Company sustainability initiatives and employee participation."}
   {:id "DOC-040" :title "Parental Leave Policy"
    :topics ["parental leave" "maternity" "paternity" "family"]
    :department "HR"
    :content "Parental leave entitlements and application process."}
   {:id "DOC-041" :title "Sabbatical Leave Program"
    :topics ["sabbatical" "leave" "extended" "eligibility"]
    :department "HR"
    :content "Sabbatical leave program details and eligibility criteria."}
   {:id "DOC-042" :title "Security Compliance Audit Process"
    :topics ["security" "compliance" "audit" "controls"]
    :department "IT"
    :content "Annual security compliance audit process covering SOC2 controls and remediation tracking."}])

(defn- matches-query? [doc query]
  (let [terms (clojure.string/split (clojure.string/lower-case query) #"\s+")
        searchable (clojure.string/lower-case
                     (str (:title doc) " "
                          (clojure.string/join " " (:topics doc)) " "
                          (:content doc) " "
                          (:department doc)))]
    (every? #(clojure.string/includes? searchable %) terms)))

(defn search [{:keys [query limit cursor] :or {limit 10 cursor nil}}]
  (let [offset (if cursor (parse-long cursor) 0)
        matching (filter #(matches-query? % query) documents)
        total (count matching)
        page (->> matching (drop offset) (take limit))
        has-more (< (+ offset (count page)) total)
        next-cursor (when has-more (str (+ offset limit)))]
    {:results (mapv #(select-keys % [:id :title :topics :department]) page)
     :cursor next-cursor
     :has_more has-more
     :total total}))

(defn fetch [{:keys [id]}]
  (first (filter #(= (:id %) id) documents)))

;; --- Data namespace ---
(ns data)

(def question
  "Find the policy document about reimbursement for professional certifications. Search for relevant documents, then fetch the content of candidates to find the one specifically about certification reimbursement (not training budget). Return the document ID.")

;; --- Back to user namespace with return/fail primitives ---
(ns user (:require [tool] [data]))

(defn return
  "Signal task completion with a result value. Prints tagged EDN for the host to parse."
  [value]
  (println (str "::RETURN:: " (pr-str value)))
  value)

(defn fail
  "Signal task failure with a reason. Prints tagged EDN for the host to parse."
  [reason]
  (println (str "::FAIL:: " (pr-str reason)))
  reason)

(def ^:dynamic __prev-vars {})

(def __builtin-vars #{'return 'fail '__preview-vars '__builtin-vars '__prev-vars '__truncate})

(defn __truncate [s max-len]
  (if (> (count s) max-len)
    (str (subs s 0 max-len) " ...")
    s))

(defn __preview-vars
  "Print previews of user-defined vars that changed since last call."
  []
  (let [current-vars (into {} (for [[sym v] (ns-publics 'user)
                                     :when (not (__builtin-vars sym))]
                                 [sym @v]))
        prev __prev-vars
        changed (into {} (filter (fn [[k v]] (not= v (get prev k))) current-vars))]
    (when (seq changed)
      (println (str ";; "
                    (clojure.string/join ", "
                      (map (fn [[sym val]]
                             (str sym " = " (__truncate (pr-str val) 120)))
                           (sort-by first changed))))))
    (alter-var-root #'__prev-vars (constantly current-vars))
    nil))

(println ";;; Prelude loaded. Available: tool/search, tool/fetch, data/question, return, fail")
