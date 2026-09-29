// 입력한 글자로 "어떤 입력 소스일지" 짐작한다(데모 전용). 브라우저는 macOS 입력 소스를 읽을 수 없다.
// 브라우저에서는 window.KeyHueInput, Node 테스트(Tests/site)에서는 module.exports로 쓴다.
(function (root) {
  const scripts = [
    ["korean", /\p{Script=Hangul}/u],
    ["japanese", /[\p{Script=Hiragana}\p{Script=Katakana}]/u],
    ["chinese", /\p{Script=Han}/u],
    ["cyrillic", /\p{Script=Cyrillic}/u],
    ["latin", /\p{Script=Latin}/u],
  ];

  /** 마지막으로 입력한 "문자"(공백·숫자·기호 제외)의 문자 체계. 문자가 없으면 null. */
  function scriptOf(text) {
    const letters = [...text].filter((c) => /\p{L}/u.test(c));
    const last = letters[letters.length - 1];
    if (!last) return null;
    const match = scripts.find(([, re]) => re.test(last));
    return match ? match[0] : "latin";
  }

  const api = { scriptOf };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.KeyHueInput = api;
})(typeof window !== "undefined" ? window : globalThis);
