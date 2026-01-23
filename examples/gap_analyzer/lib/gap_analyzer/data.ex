defmodule GapAnalyzer.Data do
  @moduledoc """
  Simulates large documents stored as searchable chunks.

  In a real system, this would be a vector database or search index.
  Here we simulate it with in-memory maps, showing the pattern of
  search (returns summaries) vs retrieve (returns full text).
  """

  @doc "Regulation sections - simulating a large regulatory document"
  def regulation_sections do
    %{
      "REQ-1.1" => %{
        id: "REQ-1.1",
        title: "Encryption at Rest",
        section: "Data Encryption",
        keywords: ["encryption", "aes", "data at rest", "pii", "storage"],
        summary: "Requires AES-256 encryption for all PII stored in databases and file systems.",
        full_text: """
        All personally identifiable information (PII) must be encrypted at rest
        using AES-256 or equivalent encryption standard approved by NIST.

        This requirement applies to:
        - Database fields containing PII
        - File system storage of documents with PII
        - Backup media and archives
        - Cloud storage buckets

        Encryption keys must be managed according to REQ-1.3.
        """
      },
      "REQ-1.2" => %{
        id: "REQ-1.2",
        title: "Encryption in Transit",
        section: "Data Encryption",
        keywords: ["encryption", "tls", "https", "transit", "network"],
        summary: "Mandates TLS 1.2+ for all data transmitted over networks.",
        full_text: """
        All data transmitted over networks must use TLS 1.2 or higher.

        This applies to:
        - External API communications
        - Internal service-to-service calls
        - Database connections
        - File transfers

        Certificate management must follow industry best practices.
        Self-signed certificates are not permitted in production.
        """
      },
      "REQ-1.3" => %{
        id: "REQ-1.3",
        title: "Key Management",
        section: "Data Encryption",
        keywords: ["encryption", "keys", "rotation", "hsm", "kms"],
        summary: "Requires annual key rotation and secure key storage separate from data.",
        full_text: """
        Encryption keys must be rotated at least annually and stored
        separately from encrypted data.

        Requirements:
        - Keys must be stored in a Hardware Security Module (HSM) or
          approved Key Management Service (KMS)
        - Key rotation must occur at least every 12 months
        - Emergency key rotation procedures must be documented
        - Key access must be logged and auditable
        - Separation of duties for key management operations
        """
      },
      "REQ-2.1" => %{
        id: "REQ-2.1",
        title: "Multi-Factor Authentication",
        section: "Access Control",
        keywords: ["mfa", "authentication", "2fa", "login", "access"],
        summary: "Requires MFA for all system access, especially privileged accounts.",
        full_text: """
        All system access must require multi-factor authentication (MFA).

        MFA must combine at least two of:
        - Something you know (password)
        - Something you have (token, phone)
        - Something you are (biometric)

        Privileged accounts (admin, root) must use hardware tokens.
        SMS-based MFA is acceptable only for non-privileged accounts.
        """
      },
      "REQ-2.2" => %{
        id: "REQ-2.2",
        title: "Role-Based Access Control",
        section: "Access Control",
        keywords: ["rbac", "authorization", "roles", "permissions", "least privilege"],
        summary: "Mandates RBAC with least privilege principle for sensitive data access.",
        full_text: """
        Access to sensitive data must follow the principle of least privilege
        with role-based access control (RBAC).

        Requirements:
        - Roles must be defined based on job functions
        - Users receive minimum permissions needed for their role
        - Access reviews must occur quarterly
        - Privileged access requires additional approval
        - Role changes must be logged
        """
      },
      "REQ-2.3" => %{
        id: "REQ-2.3",
        title: "Session Management",
        section: "Access Control",
        keywords: ["session", "timeout", "idle", "logout", "inactivity"],
        summary: "Requires 30-minute session timeout for inactive users.",
        full_text: """
        User sessions must timeout after 30 minutes of inactivity.

        Additional requirements:
        - Sessions must be invalidated on logout
        - Concurrent session limits may be enforced
        - Session tokens must be securely generated
        - Re-authentication required for sensitive operations
        """
      },
      "REQ-3.1" => %{
        id: "REQ-3.1",
        title: "Access Logging",
        section: "Audit and Monitoring",
        keywords: ["logging", "audit", "access", "trail", "monitoring"],
        summary: "Requires logging of all sensitive data access with user ID and timestamp.",
        full_text: """
        All access to sensitive data must be logged with:
        - Timestamp (UTC)
        - User ID
        - Action performed (read, write, delete)
        - Resource accessed
        - Source IP address
        - Success/failure status

        Logs must be tamper-evident and stored securely.
        """
      },
      "REQ-3.2" => %{
        id: "REQ-3.2",
        title: "Log Retention",
        section: "Audit and Monitoring",
        keywords: ["retention", "logs", "storage", "archive", "compliance"],
        summary: "Mandates minimum 90-day retention for audit logs.",
        full_text: """
        Audit logs must be retained for a minimum of 90 days in
        immediately accessible storage.

        Additional requirements:
        - Logs older than 90 days may be archived
        - Archived logs must be retrievable within 48 hours
        - Total retention period must meet regulatory requirements
        - Log deletion must be authorized and logged
        """
      },
      "REQ-3.3" => %{
        id: "REQ-3.3",
        title: "Anomaly Detection",
        section: "Audit and Monitoring",
        keywords: ["anomaly", "detection", "monitoring", "alerts", "siem"],
        summary: "Requires automated monitoring for unusual access patterns.",
        full_text: """
        Systems must implement automated monitoring for unusual access patterns.

        Detection must cover:
        - Access outside normal hours
        - Access from unusual locations
        - Bulk data downloads
        - Failed authentication attempts
        - Privilege escalation attempts

        Alerts must be generated and reviewed within 24 hours.
        """
      },
      "REQ-4.1" => %{
        id: "REQ-4.1",
        title: "Data Classification",
        section: "Data Handling",
        keywords: ["classification", "labels", "sensitivity", "categories"],
        summary: "Requires classification of all data by sensitivity level.",
        full_text: """
        All data must be classified according to sensitivity levels:
        - Public: No restrictions
        - Internal: Company employees only
        - Confidential: Need-to-know basis
        - Restricted: Highest sensitivity, special handling

        Classification must be applied at data creation and reviewed periodically.
        """
      },
      "REQ-4.2" => %{
        id: "REQ-4.2",
        title: "Data Retention Limits",
        section: "Data Handling",
        keywords: ["retention", "deletion", "purpose", "gdpr", "privacy"],
        summary: "Personal data must not be retained longer than necessary.",
        full_text: """
        Personal data must not be retained longer than necessary
        for the stated purpose.

        Requirements:
        - Define retention periods for each data category
        - Implement automated deletion where possible
        - Document justification for retention periods
        - Regular reviews of retained data
        - Honor data subject deletion requests
        """
      },
      "REQ-4.3" => %{
        id: "REQ-4.3",
        title: "Secure Data Disposal",
        section: "Data Handling",
        keywords: ["disposal", "deletion", "destruction", "sanitization", "wipe"],
        summary: "Data must be securely deleted using approved sanitization methods.",
        full_text: """
        When data is no longer needed, it must be securely deleted
        using approved methods.

        Requirements:
        - Digital media: Cryptographic erasure or DOD 5220.22-M
        - Physical media: Degaussing or physical destruction
        - Cloud storage: Verify provider deletion procedures
        - Disposal must be logged and certified
        - Third-party disposal requires chain of custody
        """
      }
    }
  end

  @doc "Policy sections - simulating a company policy document"
  def policy_sections do
    %{
      "POL-2.1" => %{
        id: "POL-2.1",
        title: "Encryption Standards",
        section: "Data Protection",
        keywords: ["encryption", "aes", "tls", "https", "data"],
        summary: "Company uses AES-256 for data at rest and TLS 1.2+ for data in transit.",
        full_text: """
        All customer data stored in our databases is encrypted using AES-256
        encryption. Database backups are also encrypted before being transferred
        to offsite storage.

        For data in transit, we require HTTPS (TLS 1.2+) for all external
        communications. Internal service-to-service communication within our
        private network may use unencrypted channels for performance reasons.

        Note: Key management procedures are handled by the infrastructure team
        but are not formally documented in this policy.
        """
      },
      "POL-2.2" => %{
        id: "POL-2.2",
        title: "Access Controls",
        section: "Data Protection",
        keywords: ["access", "authentication", "rbac", "roles", "credentials"],
        summary: "Employees authenticate with corporate credentials; RBAC is implemented.",
        full_text: """
        Employees must authenticate using their corporate credentials.
        Administrative access to production systems requires approval from
        the security team.

        We implement role-based access control where employees are granted
        access based on their job function. Access reviews are conducted
        quarterly by department managers.

        Note: Multi-factor authentication is available but not currently
        mandatory for all users.
        """
      },
      "POL-3.1" => %{
        id: "POL-3.1",
        title: "Audit Trails",
        section: "Logging and Monitoring",
        keywords: ["logging", "audit", "queries", "database", "monitoring"],
        summary: "Production database queries are logged with timestamps.",
        full_text: """
        All production database queries are logged. Logs include the
        timestamp and the query executed. Logs are stored in our
        centralized logging system.

        Application-level access logging is implemented for critical
        operations but does not currently capture all data access events.

        Note: User ID is captured for authenticated sessions but may be
        missing for some system-level operations.
        """
      },
      "POL-3.2" => %{
        id: "POL-3.2",
        title: "Log Management",
        section: "Logging and Monitoring",
        keywords: ["retention", "logs", "storage", "archive"],
        summary: "Logs retained 60 days in hot storage, 6 months archived.",
        full_text: """
        Audit logs are retained for 60 days in hot storage and archived
        for an additional 6 months in cold storage.

        Log access is restricted to the security and operations teams.
        Log deletion requires approval from the security manager.

        Note: Some application logs may have shorter retention periods
        due to storage constraints.
        """
      },
      "POL-4" => %{
        id: "POL-4",
        title: "Incident Response",
        section: "Security Operations",
        keywords: ["incident", "response", "security", "breach", "reporting"],
        summary: "Security incidents must be reported within 24 hours.",
        full_text: """
        Security incidents must be reported to the security team within
        24 hours of discovery. The security team will assess the severity
        and coordinate response efforts.

        Critical incidents are escalated to executive leadership.
        Post-incident reviews are conducted for significant events.
        """
      },
      "POL-5" => %{
        id: "POL-5",
        title: "Employee Responsibilities",
        section: "General",
        keywords: ["training", "awareness", "employees", "responsibilities"],
        summary: "Annual security training required for all employees.",
        full_text: """
        All employees must complete annual security awareness training.
        Employees must report suspected security incidents immediately.

        Contractors and third parties with system access must also
        complete security training before being granted access.
        """
      }
    }
  end

  @doc "Search regulations by keyword"
  def search_regulations(query) do
    query_lower = String.downcase(query)

    regulation_sections()
    |> Enum.filter(fn {_id, section} ->
      Enum.any?(section.keywords, &String.contains?(&1, query_lower)) or
        String.contains?(String.downcase(section.title), query_lower) or
        String.contains?(String.downcase(section.summary), query_lower)
    end)
    |> Enum.map(fn {_id, section} ->
      %{
        id: section.id,
        title: section.title,
        section: section.section,
        summary: section.summary
      }
    end)
  end

  @doc "Search policy by keyword"
  def search_policy(query) do
    query_lower = String.downcase(query)

    policy_sections()
    |> Enum.filter(fn {_id, section} ->
      Enum.any?(section.keywords, &String.contains?(&1, query_lower)) or
        String.contains?(String.downcase(section.title), query_lower) or
        String.contains?(String.downcase(section.summary), query_lower)
    end)
    |> Enum.map(fn {_id, section} ->
      %{
        id: section.id,
        title: section.title,
        section: section.section,
        summary: section.summary
      }
    end)
  end

  @doc "Get full text of a regulation section"
  def get_regulation(id) do
    case Map.get(regulation_sections(), id) do
      nil -> {:error, "Regulation #{id} not found"}
      section -> {:ok, section}
    end
  end

  @doc "Get full text of a policy section"
  def get_policy(id) do
    case Map.get(policy_sections(), id) do
      nil -> {:error, "Policy #{id} not found"}
      section -> {:ok, section}
    end
  end
end
