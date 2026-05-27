package main

import (
	"context"
	"fmt"
	"os"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/bedrock"
	"github.com/anthropics/anthropic-sdk-go/option"
	"github.com/google/uuid"

	"amazon_bedrock_integration/observability"
)

func main() {
	ctx := context.Background()

	apiKey      := os.Getenv("THREE_API_KEY")
	useCaseSlug := os.Getenv("USE_CASE_SLUG")
	endpoint    := os.Getenv("THREE_ENDPOINT")

	// Flush ensures all in-flight reports reach Three.dev before main() exits.
	// In a long-running HTTP server, call observability.Flush() in your graceful
	// shutdown handler instead (after the server stops accepting new requests).
	defer observability.Flush()

	client := anthropic.NewClient(
		bedrock.WithLoadDefaultConfig(ctx),
		// Must be registered last — the SDK builds the middleware chain in reverse,
		// so last = innermost. This ensures the middleware sees the Bedrock-transformed
		// request (/model/{model}/invoke) rather than the Anthropic API path (/v1/messages).
		option.WithMiddleware(observability.NewMiddleware(observability.Config{
			APIKey:      apiKey,
			UseCaseSlug: useCaseSlug,
			Endpoint:    endpoint,
		})),
	)

	// WithSessionID groups all calls that belong to the same conversation.
	// Generate it once per session and reuse across turns.
	ctx = observability.WithSessionID(ctx, uuid.New().String())

	message, err := client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:     "global.anthropic.claude-sonnet-4-6",
		MaxTokens: 1024,
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock("Say hello.")),
		},
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	for _, block := range message.Content {
		if block.Type == "text" {
			fmt.Println(block.Text)
		}
	}
}
