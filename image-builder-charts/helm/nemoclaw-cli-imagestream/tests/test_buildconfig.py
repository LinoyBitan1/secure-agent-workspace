from pathlib import Path


BUILD_CONFIG = Path(__file__).parents[1] / "templates" / "buildconfig.yaml"


def test_cli_image_patches_gateway_binding_before_preflight():
    template = BUILD_CONFIG.read_text()

    assert 'const a="let GATEWAY_PORT = DEFAULT_GATEWAY_PORT;"' in template
    assert 'envInt(' in template
    assert 'NEMOCLAW_GATEWAY_PORT' in template
