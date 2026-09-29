// KeyHue site: 최신 릴리즈 정보 + 입력 언어에 따라 색이 바뀌는 데모.
// 브라우저는 macOS 입력 소스를 알 수 없으므로 데모는 "입력된 글자의 문자 체계"로 흉내 낸다.
(() => {
  const REPO = "sejoung/KeyHue";
  const lang = document.documentElement.lang.startsWith("ko") ? "ko" : "en";
  const t = {
    en: {
      version: (v, d) => `Version ${v}, released ${d}. For macOS 13 or later.`,
      none: "No release yet. You can build it from the source code.",
      noneButton: "Build from source",
      states: { latin: "ABC (English)", korean: "Korean", japanese: "Japanese", chinese: "Chinese", cyrillic: "Russian (Cyrillic)", caps: "Caps Lock" },
      detected: (s) => `Input looks like <b>${s}</b>.`,
    },
    ko: {
      version: (v, d) => `버전 ${v}, ${d} 출시. macOS 13 이상.`,
      none: "아직 릴리즈가 없습니다. 소스 코드에서 빌드할 수 있습니다.",
      noneButton: "소스에서 빌드하기",
      states: { latin: "ABC (영문)", korean: "한국어", japanese: "일본어", chinese: "중국어", cyrillic: "러시아어 (키릴)", caps: "Caps Lock" },
      detected: (s) => `지금 입력은 <b>${s}</b>(으)로 보입니다.`,
    },
  }[lang];

  // ── 최신 릴리즈 ───────────────────────────────────────
  const button = document.querySelector("[data-download]");
  const meta = document.querySelector("[data-release]");
  if (button && meta) {
    fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: "application/vnd.github+json" } })
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((release) => {
        const version = release.tag_name.replace(/^v/, "");
        const date = new Date(release.published_at).toLocaleDateString(lang === "ko" ? "ko-KR" : "en-US", { year: "numeric", month: "long", day: "numeric" });
        meta.textContent = t.version(version, date);
        const asset = (release.assets || []).find((a) => a.name === `KeyHue-${version}.zip`) || (release.assets || []).find((a) => a.name === "KeyHue.zip");
        if (asset) button.href = asset.browser_download_url;
      })
      .catch((status) => {
        // 404: 아직 릴리즈 없음. 그 외(네트워크, API 한도)는 고정 링크를 그대로 둔다.
        if (status !== 404) return;
        meta.textContent = t.none;
        button.href = `https://github.com/${REPO}#build-from-source`;
        button.querySelector("strong").textContent = t.noneButton;
      });
  }

  // ── 라이브 데모 ───────────────────────────────────────
  const root = document.documentElement;
  const colors = { latin: "--src-latin", korean: "--src-korean", japanese: "--src-japanese", chinese: "--src-chinese", cyrillic: "--src-cyrillic", caps: "--src-caps" };
  const glyphs = { latin: "a", korean: "가", japanese: "あ", chinese: "中", cyrillic: "Я", caps: "A" };
  const input = document.querySelector("[data-demo-input]");
  const status = document.querySelector("[data-demo-status]");
  const hud = document.querySelector("[data-demo-hud]");
  let source = "latin";
  let caps = false;
  let shown = null;
  let hudTimer;

  function paint() {
    const state = caps ? "caps" : source;
    root.style.setProperty("--edge", `var(${colors[state]})`);
    if (status) status.innerHTML = t.detected(t.states[state]);
    if (hud && shown !== null && shown !== state) {
      hud.textContent = glyphs[state];
      hud.classList.add("show");
      clearTimeout(hudTimer);
      hudTimer = setTimeout(() => hud.classList.remove("show"), 600);
    }
    shown = state;
  }

  if (input) {
    input.addEventListener("input", () => {
      // 마지막으로 입력한 문자의 문자 체계(assets/input-script.js)
      source = window.KeyHueInput.scriptOf(input.value) || source;
      paint();
    });
    const syncCaps = (e) => {
      if (typeof e.getModifierState !== "function") return;
      const on = e.getModifierState("CapsLock");
      if (on !== caps) { caps = on; paint(); }
    };
    input.addEventListener("keydown", syncCaps);
    input.addEventListener("keyup", syncCaps);
    paint();
  }
})();
