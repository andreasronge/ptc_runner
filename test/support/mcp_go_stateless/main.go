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
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type cityTimeParams struct {
	City string `json:"city" jsonschema:"City to get time for (nyc, sf, or boston)"`
}

func main() {
	host := flag.String("host", "127.0.0.1", "host to listen on")
	port := flag.Int("port", 8000, "port to listen on")
	addressFile := flag.String("address-file", "", "optional file for the bound HTTP endpoint")
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
	if *addressFile != "" {
		if err := os.WriteFile(*addressFile, []byte(endpoint+"\n"), 0o600); err != nil {
			listener.Close()
			log.Fatalf("write address file: %v", err)
		}
	}
	log.Printf("stateless MCP interoperability server listening on %s", endpoint)
	log.Fatal(http.Serve(listener, handler))
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
