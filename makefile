SHELL := /bin/bash
MAKEFLAGS += --warn-undefined-variables
 
SCRIPT := $(PWD)/setup_quartz_cloudflare.sh
SITE_DIR := $(HOME)/de1-website/de1-quartz-site
 
.PHONY: help site/setup site/update site/clean site/check
 
help:
	@echo "Usage: make <target>"
	@echo "Targets:"
	@echo "  site/setup  - First-time bootstrap (chmod + run setup script)."
	@echo "  site/update - Rebuild and deploy using the setup script."
	@echo "  site/check  - Run local lint checks (black + bash -n)."
	@echo "  site/clean  - Remove the generated Quartz site directory."
 
site/setup:
	@echo "[site/setup] Bootstrapping Quartz site"
	@chmod +x "$(SCRIPT)"
	@"$(SCRIPT)"
 
site/update:
	@if [ ! -d "$(SITE_DIR)" ]; then \
		echo "Quartz site not initialised in $(SITE_DIR). Run 'make site/setup' first."; \
		exit 1; \
	fi
	@echo "[site/update] Rebuilding and deploying Quartz site"
	@"$(SCRIPT)"
 
site/check:
	@echo "[site/check] Running local lint checks"
	@python3 -m pip install --user --upgrade black >/dev/null
	@if compgen -G "DE1/**/*.py" >/dev/null; then \
		python3 -m black --check DE1; \
	else \
		echo "No Python files under DE1/, skipping black."; \
	fi
	@bash -n "$(SCRIPT)"
 
site/clean:
	@echo "[site/clean] Removing $(SITE_DIR)"
	@rm -rf "$(SITE_DIR)"