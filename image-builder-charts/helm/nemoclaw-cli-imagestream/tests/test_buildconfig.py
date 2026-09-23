from pathlib import Path


BUILD_CONFIG = Path(__file__).parents[1] / "templates" / "buildconfig.yaml"


def test_cli_image_patches_gateway_binding_before_preflight():
    template = BUILD_CONFIG.read_text()

    assert 'const a="let GATEWAY_PORT = DEFAULT_GATEWAY_PORT;"' in template
    assert 'envInt(' in template
    assert 'NEMOCLAW_GATEWAY_PORT' in template
    assert 'dist/lib/onboard.js' in template
    assert 'compiled NemoClaw bundle does not honor' in template
    assert 'NEMOCLAW_PRESERVE_GATEWAY_REGISTRATION' in template
    assert 'dist/lib/onboard/gateway-host-runtime.js' in template
    assert 'compiled NemoClaw bundle does not preserve external gateway registration' in template
    assert 'NEMOCLAW_BUILD_CREDENTIAL_ENV' in template
    assert 'dist/lib/onboard/providers.js' in template
    assert 'compiled NemoClaw bundle does not honor NEMOCLAW_BUILD_CREDENTIAL_ENV' in template


def test_cli_image_keeps_podman_stock_onboarding_managed_only():
    template = BUILD_CONFIG.read_text()

    assert 'input.stockManagedRuntime && input.computePlan.driverName === \\"podman\\"' in template
    assert 'compiled NemoClaw bundle does not keep Podman stock onboarding managed-only' in template
