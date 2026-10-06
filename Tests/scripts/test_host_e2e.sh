# Host runner preflight tests use fake commands; no GUI or input source is changed.
make_host_preflight() {
    mkdir -p bin app/Contents/MacOS
    cat > app/Contents/MacOS/KeyHue <<'TOOL'
#!/usr/bin/env bash
echo worker-ran >> "$TEST_TMP/actions"
exit 65
TOOL
    cat > bin/cmp <<'TOOL'
#!/usr/bin/env bash
echo compare >> "$TEST_TMP/actions"
exit "${TEST_CMP_STATUS:-1}"
TOOL
    chmod +x bin/cmp app/Contents/MacOS/KeyHue
    export PATH="$PWD/bin:$PATH" KEYHUE_TEST_APP_PATH="$PWD/app"
    unset KEYHUE_TEST_CORRECTION_PROBE KEYHUE_TEST_UPDATE_SERVICE
}

test_host_e2e_requires_explicit_opt_in_before_running_commands() {
    make_host_preflight
    KEYHUE_TEST_HOST_E2E=0 expect_failure bash "$REPO_ROOT/Tests/host/input-method-e2e.sh"
    assert_contains "$OUT" 'KEYHUE_TEST_HOST_E2E=1'
    [[ ! -e actions ]] || fail 'runner executed a command without opt-in'
}

test_basic_host_e2e_rejects_stale_service_before_running_worker() {
    make_host_preflight
    TEST_CMP_STATUS=1 KEYHUE_TEST_HOST_E2E=1 expect_failure bash "$REPO_ROOT/Tests/host/input-method-e2e.sh"
    assert_contains "$OUT" 'Update the installed service'
    assert_eq "$(cat actions)" compare
}

test_host_e2e_checks_the_service_even_for_correction_probe() {
    make_host_preflight
    KEYHUE_TEST_CORRECTION_PROBE=1 TEST_CMP_STATUS=1 KEYHUE_TEST_HOST_E2E=1 expect_failure bash "$REPO_ROOT/Tests/host/input-method-e2e.sh"
    assert_contains "$OUT" 'Update the installed service'
    assert_eq "$(cat actions)" compare
}

test_textedit_fixture_automation_compiles() {
    expect_success osacompile -o "$TEST_TMP/TextEditInputMethod.scpt" "$REPO_ROOT/Tests/host/TextEditInputMethod.applescript"
    [[ -s "$TEST_TMP/TextEditInputMethod.scpt" ]] || fail 'TextEdit fixture did not compile'
}
