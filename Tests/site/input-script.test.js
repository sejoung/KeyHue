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

test("Korean jamo and halfwidth katakana count as their scripts", () => {
  assert.equal(scriptOf("ㅋㅋㅋ"), "korean"); // 호환 자모
  assert.equal(scriptOf("ㅎㄷㄷ"), "korean");
  assert.equal(scriptOf("ｶﾀｶﾅ"), "japanese"); // 반각 가타카나
});

test("decomposed accents, fullwidth and astral letters keep their script", () => {
  assert.equal(scriptOf("Café"), "latin"); // e + 결합 악센트(NFD)
  assert.equal(scriptOf("ＡＢＣ"), "latin"); // 전각 라틴
  assert.equal(scriptOf("\u{20000}"), "chinese"); // 확장 B 한자(서로게이트 쌍)
});

test("trailing emoji and symbols do not change the detected script", () => {
  assert.equal(scriptOf("안녕 😀"), "korean");
  assert.equal(scriptOf("hello 👍🏽 → ✓"), "latin");
  assert.equal(scriptOf("😀"), null);
});

test("other scripts such as Greek fall back to latin", () => {
  assert.equal(scriptOf("αβγ"), "latin");
});

test("장음 부호(ー)로 끝나는 일본어는 일본어다", () => {
  // ー(U+30FC)·ｰ(U+FF70)는 Script=Common이고 Script_Extensions가 히라가나·가타카나다.
  assert.equal(scriptOf("コーヒー"), "japanese");
  assert.equal(scriptOf("ｺｰﾋｰ"), "japanese");
  assert.equal(scriptOf("すごーい"), "japanese");
  assert.equal(scriptOf("ー"), "japanese");
  assert.equal(scriptOf("coffee コーヒー"), "japanese");
  assert.equal(scriptOf("コーヒー coffee"), "latin");
});

test("어느 문자에도 속하지 않는 글자는 지금처럼 latin이다", () => {
  assert.equal(scriptOf("ª"), "latin"); // Script=Latin
  assert.equal(scriptOf("ʰ"), "latin");
});
