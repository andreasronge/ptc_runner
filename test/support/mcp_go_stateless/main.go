// Adapted from the Go MCP SDK HTTP example.
// SPDX-FileCopyrightText: 2025 The Go MCP SDK Authors
// SPDX-FileCopyrightText: 2025 Andreas Ronge
// SPDX-License-Identifier: MIT
//
// Command mcp_go_stateless is the independent MCP HTTP interoperability
// target for PtcRunner. Protocol behavior comes from the pinned official Go
// SDK; this program only configures its HTTP transport as stateless and
// installs one deterministic-shape tool.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type cityTimeParams struct {
	City string `json:"city" jsonschema:"City to get time for (nyc, sf, or boston)"`
}

type oauthHarness struct {
	mu            sync.Mutex
	endpoint      string
	issuer        string
	codes         map[string]string
	accessToken   string
	refreshToken  string
	authorization int
	codeExchange  int
	refresh       int
	mcpCalls      int
	challenges    int
	directed      int
	fallback      int
}

func main() {
	host := flag.String("host", "127.0.0.1", "host to listen on")
	port := flag.Int("port", 8000, "port to listen on")
	addressFile := flag.String("address-file", "", "optional file for the bound HTTP endpoint")
	bearerToken := flag.String("bearer-token", "", "optional bearer token required for every MCP request")
	oauth := flag.Bool("oauth", false, "serve the deterministic local OAuth interoperability harness")
	flag.Parse()

	server := mcp.NewServer(
		&mcp.Implementation{Name: "ptc-runner-interop", Version: "1"},
		nil,
	)
	mcp.AddTool(
		server,
		&mcp.Tool{
			Name:        "cityTime",
			Description: "Get the current time in NYC, San Francisco, or Boston",
		},
		cityTime,
	)

	handler := mcp.NewStreamableHTTPHandler(
		func(*http.Request) *mcp.Server { return server },
		&mcp.StreamableHTTPOptions{Stateless: true},
	)
	address := net.JoinHostPort(*host, strconv.Itoa(*port))
	listener, err := net.Listen("tcp", address)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	endpoint := "http://" + listener.Addr().String()

	var httpHandler http.Handler
	if *oauth {
		harness := &oauthHarness{
			endpoint: endpoint,
			issuer:   endpoint + "/oauth",
			codes:    make(map[string]string),
		}
		mux := http.NewServeMux()
		mux.HandleFunc("/.well-known/oauth-protected-resource", harness.protectedResourceMetadata)
		mux.HandleFunc("/.well-known/oauth-authorization-server/oauth", harness.authorizationServerMetadata)
		mux.HandleFunc("/oauth/authorize", harness.authorize)
		mux.HandleFunc("/oauth/token", harness.token)
		mux.HandleFunc("/oauth/stats", harness.stats)
		mux.Handle("/", harness.protect(handler))
		httpHandler = mux
	} else if *bearerToken != "" {
		httpHandler = http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
			if request.Header.Get("Authorization") != "Bearer "+*bearerToken {
				response.Header().Set("WWW-Authenticate", `Bearer error="invalid_token"`)
				http.Error(response, "unauthorized", http.StatusUnauthorized)
				return
			}
			handler.ServeHTTP(response, request)
		})
	} else {
		httpHandler = handler
	}
	if *addressFile != "" {
		if err := os.WriteFile(*addressFile, []byte(endpoint+"\n"), 0o600); err != nil {
			listener.Close()
			log.Fatalf("write address file: %v", err)
		}
	}
	log.Printf("stateless MCP interoperability server listening on %s", endpoint)
	log.Fatal(http.Serve(listener, httpHandler))
}

func (h *oauthHarness) protectedResourceMetadata(response http.ResponseWriter, _ *http.Request) {
	writeJSON(response, map[string]any{
		"resource":              h.endpoint,
		"authorization_servers": []string{h.issuer},
		"scopes_supported":      []string{"read", "offline_access"},
	})
}

func (h *oauthHarness) authorizationServerMetadata(response http.ResponseWriter, _ *http.Request) {
	writeJSON(response, map[string]any{
		"issuer":                                         h.issuer,
		"authorization_endpoint":                         h.issuer + "/authorize",
		"token_endpoint":                                 h.issuer + "/token",
		"response_types_supported":                       []string{"code"},
		"grant_types_supported":                          []string{"authorization_code", "refresh_token"},
		"response_modes_supported":                       []string{"query"},
		"code_challenge_methods_supported":               []string{"S256"},
		"token_endpoint_auth_methods_supported":          []string{"none"},
		"authorization_response_iss_parameter_supported": true,
		"scopes_supported":                               []string{"read", "offline_access"},
	})
}

func (h *oauthHarness) authorize(response http.ResponseWriter, request *http.Request) {
	query := request.URL.Query()
	redirectURI, err := url.Parse(query.Get("redirect_uri"))
	if err != nil ||
		query.Get("response_type") != "code" ||
		query.Get("client_id") != "ptc-oauth-e2e" ||
		query.Get("resource") != h.endpoint ||
		query.Get("code_challenge_method") != "S256" ||
		query.Get("code_challenge") == "" ||
		query.Get("state") == "" ||
		redirectURI.Scheme != "http" ||
		redirectURI.Hostname() != "127.0.0.1" ||
		redirectURI.Path != "/callback" {
		http.Error(response, "invalid authorization request", http.StatusBadRequest)
		return
	}

	const code = "e2e-code"
	h.mu.Lock()
	h.codes[code] = query.Get("code_challenge")
	h.authorization++
	h.mu.Unlock()

	callback := *redirectURI
	parameters := callback.Query()
	parameters.Set("code", code)
	parameters.Set("state", query.Get("state"))
	parameters.Set("iss", h.issuer)
	callback.RawQuery = parameters.Encode()
	response.Header().Set("Location", callback.String())
	response.WriteHeader(http.StatusFound)
}

func (h *oauthHarness) token(response http.ResponseWriter, request *http.Request) {
	if err := request.ParseForm(); err != nil {
		writeOAuthError(response, "invalid_request")
		return
	}
	if request.Form.Get("client_id") != "ptc-oauth-e2e" ||
		request.Form.Get("resource") != h.endpoint ||
		request.Form.Get("scope") != "offline_access read" {
		writeOAuthError(response, "invalid_request")
		return
	}

	switch request.Form.Get("grant_type") {
	case "authorization_code":
		h.exchangeCode(response, request.Form)
	case "refresh_token":
		h.exchangeRefresh(response, request.Form)
	default:
		writeOAuthError(response, "unsupported_grant_type")
	}
}

func (h *oauthHarness) exchangeCode(response http.ResponseWriter, form url.Values) {
	code := form.Get("code")
	verifier := form.Get("code_verifier")
	challenge := pkceChallenge(verifier)

	h.mu.Lock()
	defer h.mu.Unlock()
	expected, found := h.codes[code]
	if !found ||
		expected != challenge ||
		form.Get("redirect_uri") == "" ||
		!strings.HasPrefix(form.Get("redirect_uri"), "http://127.0.0.1:") {
		writeOAuthError(response, "invalid_grant")
		return
	}
	delete(h.codes, code)
	h.codeExchange++
	h.accessToken = "oauth-e2e-access-1"
	h.refreshToken = "oauth-e2e-refresh-1"
	writeJSON(response, tokenDocument(h.accessToken, h.refreshToken))
}

func (h *oauthHarness) exchangeRefresh(response http.ResponseWriter, form url.Values) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.refreshToken == "" || form.Get("refresh_token") != h.refreshToken {
		writeOAuthError(response, "invalid_grant")
		return
	}
	h.refresh++
	h.accessToken = "oauth-e2e-access-" + strconv.Itoa(h.refresh+1)
	h.refreshToken = "oauth-e2e-refresh-" + strconv.Itoa(h.refresh+1)
	writeJSON(response, tokenDocument(h.accessToken, h.refreshToken))
}

func (h *oauthHarness) protect(next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		h.mu.Lock()
		expected := h.accessToken
		authorized := expected != "" && request.Header.Get("Authorization") == "Bearer "+expected
		challenge := `Bearer scope="read"`
		if !authorized {
			h.challenges++
			if h.challenges == 1 {
				challenge = fmt.Sprintf(
					`Bearer scope="read", resource_metadata="%s/.well-known/oauth-protected-resource"`,
					h.endpoint,
				)
				h.directed++
			} else {
				h.fallback++
			}
		}
		h.mu.Unlock()
		if !authorized {
			response.Header().Set("WWW-Authenticate", challenge)
			http.Error(response, "unauthorized", http.StatusUnauthorized)
			return
		}
		h.mu.Lock()
		h.mcpCalls++
		h.mu.Unlock()
		next.ServeHTTP(response, request)
	})
}

func (h *oauthHarness) stats(response http.ResponseWriter, _ *http.Request) {
	h.mu.Lock()
	defer h.mu.Unlock()
	writeJSON(response, map[string]int{
		"authorization": h.authorization,
		"code_exchange": h.codeExchange,
		"refresh":       h.refresh,
		"mcp_calls":     h.mcpCalls,
		"directed":      h.directed,
		"fallback":      h.fallback,
	})
}

func tokenDocument(accessToken string, refreshToken string) map[string]any {
	return map[string]any{
		"access_token":  accessToken,
		"refresh_token": refreshToken,
		"token_type":    "Bearer",
		"expires_in":    4,
		"scope":         "offline_access read",
	}
}

func pkceChallenge(verifier string) string {
	digest := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(digest[:])
}

func writeOAuthError(response http.ResponseWriter, errorCode string) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(http.StatusBadRequest)
	if err := json.NewEncoder(response).Encode(map[string]string{"error": errorCode}); err != nil {
		log.Printf("write OAuth error: %v", err)
	}
}

func writeJSON(response http.ResponseWriter, value any) {
	response.Header().Set("Content-Type", "application/json")
	response.Header().Set("Cache-Control", "max-age=120")
	if err := json.NewEncoder(response).Encode(value); err != nil {
		log.Printf("write JSON: %v", err)
	}
}

func cityTime(
	_ context.Context,
	_ *mcp.CallToolRequest,
	params *cityTimeParams,
) (*mcp.CallToolResult, any, error) {
	locations := map[string]string{
		"nyc":    "America/New_York",
		"sf":     "America/Los_Angeles",
		"boston": "America/New_York",
	}
	cityNames := map[string]string{
		"nyc":    "New York City",
		"sf":     "San Francisco",
		"boston": "Boston",
	}

	locationName, ok := locations[params.City]
	if !ok {
		return nil, nil, fmt.Errorf("unknown city: %s", params.City)
	}
	location, err := time.LoadLocation(locationName)
	if err != nil {
		return nil, nil, fmt.Errorf("load location: %w", err)
	}
	text := fmt.Sprintf(
		"The current time in %s is %s",
		cityNames[params.City],
		time.Now().In(location).Format(time.RFC3339),
	)
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: text}},
	}, nil, nil
}
