package main

import (
	"context"
	"fmt"
	"os"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/bedrock"
	"github.com/anthropics/anthropic-sdk-go/option"

	"amazon_bedrock_integration/observability"
)

func main() {
	ctx := context.Background()

	client := anthropic.NewClient(
		bedrock.WithLoadDefaultConfig(ctx),
		option.WithMiddleware(observability.NewMiddleware(observability.Config{
			APIKey:      os.Getenv("THREE_API_KEY"),
			UseCaseSlug: "my-use-case",
		})),
	)

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
