CHECKS := DriverChecks EngineChecks SystemChecks AgentsChecks AudioChecks UIChecks

.PHONY: build app run run-sim install checks clean

build:
	swift build

## Bundle build/Lidlight.app (ad-hoc signed)
app:
	./scripts/build-app.sh release

## Build and open the app (drives the real logo)
run: app
	open build/Lidlight.app

## Run unbundled with the simulated driver (no hardware writes)
run-sim:
	swift run LidlightApp --simulate

## Copy the app to ~/Applications
install: app
	rm -rf ~/Applications/Lidlight.app
	mkdir -p ~/Applications
	cp -R build/Lidlight.app ~/Applications/

## Run every module's checks
checks:
	@for t in $(CHECKS); do swift run $$t || exit 1; done

clean:
	rm -rf .build .build-* build
