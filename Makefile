# ---------------------------------------
# Author: David Marsh <rdmarsh@gmail.com>
# ---------------------------------------
#
# This Makefile is used to generate files for elm
#   for usage: make help
#   more info: make about
#
# elm Extract LogicMonitor
# Copyright (C) 2021 David Marsh rdmarsh@gmail.com
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

name := elm
prog := $(name).py

CURL := curl
JQ := jq
AWK := awk
JINJA := jinja2

swagger_url := https://www.logicmonitor.com/swagger-ui-master/dist/swagger.json

bakdir := ../$(name)_back
cmddir := _commands
defdir := _definitions
tmpdir := _templates

CMDSOURCES := $(wildcard $(defdir)/[A-Z]*.json)
CMDTARGETS := $(patsubst $(defdir)/%.json,$(cmddir)/%.py,$(CMDSOURCES))

########################################
###
### TARGETS
###
########################################

.PHONY: all
all: init commands ## Build everything

# ---------------------------------------
#  check needed progs
# ---------------------------------------

.PHONY: req PYTHON-exists CURL-exists JQ-exists AWK-exists JINJA-exists
req: PYTHON-exists CURL-exists JQ-exists AWK-exists JINJA-exists ## Perform requirement check
PYTHON-exists: ; @which python3 > /dev/null
CURL-exists: ; @which $(CURL) > /dev/null
JQ-exists: ; @which $(JQ) > /dev/null
AWK-exists: ; @which $(AWK) > /dev/null
JINJA-exists: ; @which $(JINJA) > /dev/null

# ---------------------------------------
#  init, not called by default
# ---------------------------------------

.PHONY: req init
init: $(bakdir) $(cmddir) $(defdir) $(tmpdir) $(defdir)/commands.json ## Initialise dirs, get swagger file, create definition files

$(bakdir) $(cmddir) $(defdir) $(tmpdir):
	mkdir -p $@

$(defdir)/swagger.json:
	$(CURL) $(swagger_url) $(OUTPUT_OPTION)

#cant split this long line
#high level magic https://stackoverflow.com/questions/56167046/jq-split-a-huge-json-of-array-and-save-into-file-named-with-a-value
$(defdir)/commands.json: $(defdir)/swagger.json
	$(JQ) '{ "commands": [ .paths | to_entries[] | .key as $$path | .value | to_entries[] | select(.key == "get") | .value.operationId |= gsub("^(get|collect)";"") | { command:.value.operationId, path:$$path, summary:.value.summary, tag:.value.tags[0], options:.value.parameters } ]}' $< > $@
	$(JQ) -c '.commands[] | (.command | if type == "number" then . else tostring | gsub("[^A-Za-z0-9-_]";"+") end), .' $@ | $(AWK) 'function fn(s) { sub(/^\"/,"",s); sub(/\"$$/,"",s); return "$(defdir)/" s ".json"; } NR%2{f=fn($$0); next} {print > f; close(f);} '
	$(MAKE)

# ---------------------------------------
#  python commands
# ---------------------------------------

.PHONY: commands
commands: engine.py $(prog)

$(prog): $(tmpdir)/$(prog).j2 $(defdir)/commands.json $(CMDTARGETS)
	$(JINJA) $(tmpdir)/$(prog).j2 $(defdir)/commands.json  $(OUTPUT_OPTION)
	chmod 755 $@

engine.py: $(tmpdir)/engine.py.j2 $(defdir)/commands.json
	$(JINJA) $^ $(OUTPUT_OPTION)

$(cmddir)/%.py: $(tmpdir)/command.py.j2 $(defdir)/%.json
	$(JINJA) $^ $(OUTPUT_OPTION)

# ---------------------------------------
#  tests
# ---------------------------------------

.PHONY: tests
tests: ## run tests
	@echo test $(prog) ; ./$(prog) >/dev/null
	@echo test $(prog) --help ; ./$(prog) --help >/dev/null
	@echo test $(prog) --version ; ./$(prog) --version >/dev/null

.PHONY: fail
fail: ## a failing test
	@echo test false ; false >/dev/null

# ---------------------------------------
#  cleanup
# ---------------------------------------

back: nomac ## TAR and backup (eg ../name_backup/name.YYYY-MM-DD.tar.gz)
	tar -cvf $(bakdir)/$(name).$(shell date +%Y-%m-%d).tar.gz .

.PHONY: clean
clean: nomac ## Remove generated files
	$(RM) -r __pycache__
	$(RM) -r $(cmddir) $(defdir)
	$(RM) $(CMDTARGETS)
	$(RM) $(prog)
	$(RM) engine.py

.PHONY: nomac
nomac:
	$(RM) .DS_Store

# ---------------------------------------
#  about help
# ---------------------------------------

.PHONY: about
about: ## About this Makefile
	@echo
	@echo 'This Makefile is used to generate files for elm'
	@echo
	@echo 'Run "make help" to for how to run'
	@echo
	@echo 'See https://github.com/rdmarsh/elm'
	@echo

.PHONY: copying
copying: ## Copyright notice
	@echo
	@echo 'Copyright (C) 2021 David Marsh'
	@echo 'rdmarsh@gmail.com'
	@echo
	@echo 'This program is free software: you can redistribute it and/or modify'
	@echo 'it under the terms of the GNU General Public License as published by'
	@echo 'the Free Software Foundation, either version 3 of the License, or'
	@echo '(at your option) any later version.'
	@echo
	@echo 'This program comes with ABSOLUTELY NO WARRANTY.'
	@echo 'This is free software, and you are welcome to redistribute it'
	@echo 'under certain conditions. View the file "LICENSE" for details.'
	@echo

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make [flags] [option]\n"} /^[$$()% \.0-9a-zA-Z_-]+:.*?##/ { printf "  \033[36mmake %-12s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
	@echo
	@echo 'Useful make flags:'
	@echo '  make -n  dry run'
	@echo '  make -j  run simultaneous jobs'
	@echo '  make -B  force make target'
	@echo
