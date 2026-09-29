// node --test Tests/site
const test = require("node:test");
const assert = require("node:assert/strict");
const { scriptOf } = require("../../site/assets/input-script.js");

test("detects the script of the last letter", () => {
  assert.equal(scriptOf("hello"), "latin");
  assert.equal(scriptOf("안녕"), "korean");
  assert.equal(scriptOf("こんにちは"), "japanese");
  assert.equal(scriptOf("カタカナ"), "japanese");
  assert.equal(scriptOf("中文"), "chinese");
  assert.equal(scriptOf("Привет"), "cyrillic");
  assert.equal(scriptOf("Größe"), "latin");
});

test("uses the last letter when languages are mixed", () => {
  assert.equal(scriptOf("hello 안녕"), "korean");
  assert.equal(scriptOf("안녕 hello"), "latin");
});

test("ignores digits, spaces and punctuation", () => {
  assert.equal(scriptOf("안녕 123 !?"), "korean");
  assert.equal(scriptOf("   "), null);
  assert.equal(scriptOf("123"), null);
  assert.equal(scriptOf(""), null);
});

test("unknown letters fall back to latin", () => {
  assert.equal(scriptOf("שלום"), "latin"); // 히브리 문자: 데모에는 별도 색이 없다
});
