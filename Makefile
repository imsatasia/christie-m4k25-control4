.PHONY: help image test live-test build clean

IMAGE := christie-lua
HOST  ?= 192.0.2.50

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

image: ## Build the throwaway Lua 5.1 test image
	docker build -t $(IMAGE) .

test: image ## Run the offline test suite (no hardware needed)
	docker run --rm -v "$(PWD)":/d -w /d $(IMAGE) lua5.1 tests/test_driver.lua

live-test: image ## Run the driver against a real projector, read-only (default HOST=192.0.2.50)
	docker run --rm --network host -v "$(PWD)":/d -w /d $(IMAGE) lua5.1 tests/live_test.lua $(HOST)

build: ## Validate and package driver.xml + driver.lua into christie_m4k25.c4z
	./build.sh

clean: ## Remove the built .c4z
	rm -f christie_m4k25.c4z
