WIPPY ?= wippy

.PHONY: check lint
lint:
	"$(WIPPY)" lint

check: lint
	WIPPY="$(WIPPY)" GOWORK=off go test ./tests/client_test.go -count=1 -v
