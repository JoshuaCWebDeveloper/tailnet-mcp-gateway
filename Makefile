.PHONY: build clean test

build:
	go build -o mcp-terminal-server ./terminal_mcp

clean:
	rm -f mcp-terminal-server

test:
	go test ./terminal_mcp/...
