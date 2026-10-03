#include "FlashTestsBootstrap.h"

// SwiftPM test bundles have no principal class, so nothing in Swift runs
// before the first test. This image constructor runs when XCTest loads the
// bundle and hands control to `flash_tests_bootstrap`, which registers the
// suite-wide observers (see TestWindowHygiene.swift) for every run, filtered
// or not.
__attribute__((constructor)) static void flash_tests_bootstrap_on_load(void) {
  flash_tests_bootstrap();
}
