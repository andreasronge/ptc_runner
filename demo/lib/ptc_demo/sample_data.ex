defmodule PtcDemo.SampleData do
  @moduledoc """
  Sample data generator for demonstrating PtcRunner's context efficiency.

  Generates realistic datasets that would be expensive to pass through
  LLM context in traditional function calling, but are efficiently
  processed by PtcRunner in BEAM memory.
  """

  @doc """
  Generates a list of products (500 items).
  In traditional function calling, this would consume ~50KB of context.
  """
  def products do
    categories = ["electronics", "clothing", "food", "books", "sports", "home", "toys"]
    statuses = ["active", "discontinued", "out_of_stock"]

    for i <- 1..500 do
      %{
        "id" => i,
        "name" => "Product #{i}",
        "category" => Enum.random(categories),
        "price" => :rand.uniform(1000) + :rand.uniform(100) / 100,
        "stock" => :rand.uniform(500),
        "rating" => Float.round(:rand.uniform() * 4 + 1, 1),
        "status" => Enum.random(statuses),
        "created_at" => random_date(2023, 2024)
      }
    end
  end

  @doc """
  Generates a list of orders (1000 items).
  In traditional function calling, this would consume ~100KB of context.
  """
  def orders do
    statuses = ["pending", "shipped", "delivered", "cancelled", "refunded"]
    payment_methods = ["credit_card", "paypal", "bank_transfer", "crypto"]

    for i <- 1..1000 do
      %{
        "id" => i,
        "customer_id" => :rand.uniform(200),
        "product_id" => :rand.uniform(500),
        "quantity" => :rand.uniform(10),
        "total" => :rand.uniform(5000) + :rand.uniform(100) / 100,
        "status" => Enum.random(statuses),
        "payment_method" => Enum.random(payment_methods),
        "created_at" => random_date(2024, 2024)
      }
    end
  end

  @doc """
  Generates a list of employees (200 items).
  """
  def employees do
    departments = ["engineering", "sales", "marketing", "support", "hr", "finance"]
    levels = ["junior", "mid", "senior", "lead", "manager", "director"]

    for i <- 1..200 do
      base_salary = 50_000 + :rand.uniform(150_000)

      %{
        "id" => i,
        "name" => "Employee #{i}",
        "department" => Enum.random(departments),
        "level" => Enum.random(levels),
        "salary" => base_salary,
        "bonus" => Float.round(base_salary * :rand.uniform() * 0.2, 2),
        "years_employed" => :rand.uniform(15),
        "remote" => :rand.uniform(2) == 1
      }
    end
  end

  @doc """
  Generates expense records (800 items).
  """
  def expenses do
    categories = ["travel", "equipment", "software", "meals", "office", "training"]
    statuses = ["pending", "approved", "rejected", "reimbursed"]

    for i <- 1..800 do
      %{
        "id" => i,
        "employee_id" => :rand.uniform(200),
        "category" => Enum.random(categories),
        "amount" => :rand.uniform(2000) + :rand.uniform(100) / 100,
        "description" => "Expense #{i} description",
        "status" => Enum.random(statuses),
        "date" => random_date(2024, 2024)
      }
    end
  end

  @doc """
  Generates policy documents for knowledge base search (40 items).

  Documents are designed to enable multi-turn search scenarios where
  the LLM must refine queries to find specific documents.
  """
  def documents do
    # Define document templates with topics for realistic search scenarios
    document_templates() |> Enum.with_index(1) |> Enum.map(&build_document/1)
  end

  defp build_document({template, index}) do
    id = String.pad_leading(Integer.to_string(index), 3, "0")

    %{
      "id" => "DOC-#{id}",
      "title" => template.title,
      "topics" => template.topics,
      "department" => template.department,
      "content" => template.content,
      "updated_at" => random_date(2024, 2024)
    }
  end

  defp document_templates do
    [
      # Remote work policies (several docs)
      %{
        title: "Remote Work Guidelines",
        topics: ["remote work", "home office", "flexibility", "work from home"],
        department: "HR",
        content:
          "Guidelines for employees working remotely including equipment setup and communication expectations."
      },
      %{
        title: "Home Office Setup Requirements",
        topics: ["remote work", "equipment", "home office", "ergonomics"],
        department: "HR",
        content:
          "Requirements for home office setup including desk, chair, and monitor specifications."
      },
      %{
        title: "Remote Work Security Protocol",
        topics: ["remote work", "security", "vpn", "data protection"],
        department: "IT",
        content:
          "Security requirements for remote workers including VPN usage and device encryption."
      },
      # Expense policies (several docs)
      %{
        title: "Travel Expense Policy",
        topics: ["expense reimbursement", "travel", "per diem", "receipts"],
        department: "Finance",
        content:
          "Policy for travel expense reimbursement including per diem rates and receipt requirements."
      },
      %{
        title: "Equipment Purchase Reimbursement",
        topics: ["expense reimbursement", "equipment", "purchase", "approval"],
        department: "Finance",
        content: "Process for getting reimbursed for approved equipment purchases."
      },
      %{
        title: "Meal and Entertainment Expenses",
        topics: ["expense reimbursement", "meals", "entertainment", "client"],
        department: "Finance",
        content:
          "Guidelines for meal and entertainment expense claims including limits and documentation."
      },
      # THE KEY DOCUMENT: covers BOTH remote work AND expense reimbursement
      %{
        title: "Policy WFH-2024-REIMB",
        topics: ["remote work", "expense reimbursement", "home office", "internet", "utilities"],
        department: "HR",
        content:
          "Comprehensive guide for remote workers on expense reimbursement for home office costs including internet and utilities allowance."
      },
      # Security policies
      %{
        title: "Data Classification Policy",
        topics: ["security", "data handling", "classification", "confidential"],
        department: "IT",
        content: "How to classify and handle data based on sensitivity levels."
      },
      %{
        title: "Password and Authentication Standards",
        topics: ["security", "passwords", "authentication", "mfa"],
        department: "IT",
        content: "Requirements for password complexity and multi-factor authentication."
      },
      %{
        title: "Incident Response Procedure",
        topics: ["security", "incident", "breach", "reporting"],
        department: "IT",
        content: "Steps to follow when a security incident is detected."
      },
      # Performance and HR
      %{
        title: "Performance Review Process",
        topics: ["performance", "review", "evaluation", "goals"],
        department: "HR",
        content: "Annual performance review process and timeline."
      },
      %{
        title: "Promotion Criteria and Process",
        topics: ["promotion", "career", "advancement", "criteria"],
        department: "HR",
        content: "Criteria for promotion consideration and the approval process."
      },
      %{
        title: "Employee Benefits Overview",
        topics: ["benefits", "health", "insurance", "retirement"],
        department: "HR",
        content: "Overview of employee benefits including health insurance and retirement plans."
      },
      %{
        title: "Paid Time Off Policy",
        topics: ["pto", "vacation", "sick leave", "time off"],
        department: "HR",
        content: "Policy for requesting and using paid time off."
      },
      # Equipment and software
      %{
        title: "Software Request Process",
        topics: ["software", "request", "approval", "license"],
        department: "IT",
        content: "How to request new software and the approval workflow."
      },
      %{
        title: "Hardware Refresh Policy",
        topics: ["equipment", "hardware", "laptop", "refresh"],
        department: "IT",
        content: "Schedule and process for hardware refresh cycles."
      },
      %{
        title: "Bring Your Own Device Policy",
        topics: ["byod", "personal device", "mobile", "security"],
        department: "IT",
        content: "Policy for using personal devices for work purposes."
      },
      # Training and development
      %{
        title: "Training Budget Allocation",
        topics: ["training", "budget", "professional development", "courses"],
        department: "HR",
        content: "Annual training budget and how to request funding for courses."
      },
      %{
        title: "Conference Attendance Policy",
        topics: ["conference", "travel", "professional development", "approval"],
        department: "HR",
        content: "Process for requesting approval to attend conferences."
      },
      %{
        title: "Certification Reimbursement",
        topics: ["certification", "expense reimbursement", "professional", "training"],
        department: "HR",
        content: "Reimbursement policy for professional certifications."
      },
      # Compliance
      %{
        title: "Code of Conduct",
        topics: ["conduct", "ethics", "behavior", "compliance"],
        department: "Legal",
        content: "Expected standards of conduct for all employees."
      },
      %{
        title: "Anti-Harassment Policy",
        topics: ["harassment", "discrimination", "reporting", "compliance"],
        department: "Legal",
        content: "Policy against harassment and discrimination with reporting procedures."
      },
      %{
        title: "Conflict of Interest Disclosure",
        topics: ["conflict", "disclosure", "ethics", "compliance"],
        department: "Legal",
        content: "Requirements for disclosing potential conflicts of interest."
      },
      # Communication
      %{
        title: "Internal Communication Guidelines",
        topics: ["communication", "email", "slack", "meetings"],
        department: "HR",
        content: "Best practices for internal communication channels."
      },
      %{
        title: "External Communication Policy",
        topics: ["communication", "media", "social media", "public"],
        department: "Legal",
        content: "Guidelines for external communications and media interactions."
      },
      # Onboarding
      %{
        title: "New Hire Onboarding Checklist",
        topics: ["onboarding", "new hire", "orientation", "setup"],
        department: "HR",
        content: "Checklist for new employee onboarding process."
      },
      %{
        title: "IT Setup for New Employees",
        topics: ["onboarding", "it setup", "accounts", "equipment"],
        department: "IT",
        content: "IT account creation and equipment provisioning for new hires."
      },
      # Office policies
      %{
        title: "Office Access and Hours",
        topics: ["office", "access", "hours", "badge"],
        department: "Facilities",
        content: "Office access hours and badge requirements."
      },
      %{
        title: "Meeting Room Booking",
        topics: ["meeting", "booking", "conference room", "calendar"],
        department: "Facilities",
        content: "How to book meeting rooms and usage guidelines."
      },
      %{
        title: "Visitor Policy",
        topics: ["visitor", "guest", "access", "escort"],
        department: "Facilities",
        content: "Policy for hosting visitors in the office."
      },
      # More expense-related for search variety
      %{
        title: "Corporate Card Usage Policy",
        topics: ["corporate card", "expense", "payment", "limits"],
        department: "Finance",
        content: "Guidelines for using corporate credit cards."
      },
      %{
        title: "Expense Report Submission Deadlines",
        topics: ["expense reimbursement", "deadline", "submission", "monthly"],
        department: "Finance",
        content: "Monthly deadlines for expense report submissions."
      },
      # More remote work for search variety
      %{
        title: "Hybrid Work Schedule",
        topics: ["remote work", "hybrid", "schedule", "office days"],
        department: "HR",
        content: "Policy for hybrid work arrangements and required office days."
      },
      %{
        title: "Remote Work Eligibility",
        topics: ["remote work", "eligibility", "approval", "manager"],
        department: "HR",
        content: "Criteria for remote work eligibility and approval process."
      },
      # Additional variety
      %{
        title: "Intellectual Property Policy",
        topics: ["ip", "intellectual property", "patents", "inventions"],
        department: "Legal",
        content: "Policy regarding intellectual property and inventions."
      },
      %{
        title: "Data Retention Policy",
        topics: ["data", "retention", "deletion", "compliance"],
        department: "Legal",
        content: "Requirements for data retention and deletion schedules."
      },
      %{
        title: "Emergency Procedures",
        topics: ["emergency", "evacuation", "safety", "procedures"],
        department: "Facilities",
        content: "Emergency evacuation procedures and safety protocols."
      },
      %{
        title: "Sustainability Initiatives",
        topics: ["sustainability", "environment", "green", "recycling"],
        department: "Facilities",
        content: "Company sustainability initiatives and employee participation."
      },
      %{
        title: "Parental Leave Policy",
        topics: ["parental leave", "maternity", "paternity", "family"],
        department: "HR",
        content: "Parental leave entitlements and application process."
      },
      %{
        title: "Sabbatical Leave Program",
        topics: ["sabbatical", "leave", "extended", "eligibility"],
        department: "HR",
        content: "Sabbatical leave program details and eligibility criteria."
      }
    ]
  end

  @doc """
  Returns available datasets and their sizes.
  """
  def available_datasets do
    %{
      "products" => "500 product records (~50KB)",
      "orders" => "1000 order records (~100KB)",
      "employees" => "200 employee records (~20KB)",
      "expenses" => "800 expense records (~80KB)",
      "documents" => "40 policy documents (~15KB)"
    }
  end

  @doc """
  Returns context descriptions for SubAgent's Data Inventory.

  These descriptions are shown alongside each ctx/ variable in the prompt.
  """
  def context_descriptions do
    %{
      "products" =>
        "Product catalog [{id, name, category, price, stock, rating, status, created_at}]",
      "orders" =>
        "Orders [{id, customer_id, product_id, quantity, total, status, payment_method, created_at}]",
      "employees" =>
        "Employees [{id, name, department: engineering|sales|marketing|support|hr|finance, level: junior|mid|senior|lead|manager|director, salary, bonus, years_employed, remote: bool}]",
      "expenses" => "Expenses [{id, employee_id, category, amount, description, status, date}]"
    }
  end

  @doc """
  Loads a dataset by name.
  """
  def load(name) do
    case name do
      "products" -> {:ok, products()}
      "orders" -> {:ok, orders()}
      "employees" -> {:ok, employees()}
      "expenses" -> {:ok, expenses()}
      "documents" -> {:ok, documents()}
      _ -> {:error, "Unknown dataset: #{name}"}
    end
  end

  defp random_date(start_year, end_year) do
    year = Enum.random(start_year..end_year)
    month = :rand.uniform(12)
    day = :rand.uniform(28)
    "#{year}-#{String.pad_leading("#{month}", 2, "0")}-#{String.pad_leading("#{day}", 2, "0")}"
  end
end
