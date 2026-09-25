APP := .build/Agentz.app
APPDIR ?= $(HOME)/Applications
PREFIX ?= /usr/local

.PHONY: app debug core run test smoke install uninstall link unlink clean

app: core
	./build-app.sh release

debug: core
	./build-app.sh debug

# The Rust core and its generated Swift side. See build-core.sh.
core:
	./build-core.sh

# Opens the app for this checkout's project.
run: debug
	open -n $(APP) --args --project "$(CURDIR)/.."

test: core
	swift test

# Opens the app with real terminals and checks what it sees. Needs a
# desktop session; the window shows for about half a minute.
smoke: debug
	rm -f .build/smoke.log
	open -n -W --env AGENTZ_SMOKE_LOG="$(CURDIR)/.build/smoke.log" $(APP) --args --project "$(CURDIR)/.."
	cat .build/smoke.log
	grep -qx PASS .build/smoke.log

# Copies the app to ~/Applications.
install: app
	mkdir -p "$(APPDIR)"
	rm -rf "$(APPDIR)/Agentz.app"
	cp -R $(APP) "$(APPDIR)/Agentz.app"

uninstall:
	rm -rf "$(APPDIR)/Agentz.app"

# Links the `agentz` command to the installed app. Set PREFIX to put it
# somewhere else.
link:
	ln -sf "$(APPDIR)/Agentz.app/Contents/MacOS/agentz" $(PREFIX)/bin/agentz

unlink:
	rm -f $(PREFIX)/bin/agentz

clean:
	rm -rf .build Frameworks Sources/AgentzCore/Generated
