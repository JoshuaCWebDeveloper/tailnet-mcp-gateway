.PHONY: build clean deps test

build: deps
	go build -o mcp-terminal-server

deps:
	go mod tidy

clean:
	rm -f mcp-terminal-server

test: deps
	go test ./...
