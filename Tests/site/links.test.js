// 사이트 HTML의 내부 링크·이미지가 실제 파일을 가리키는지, 두 언어 페이지가 짝을 이루는지 확인한다.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const site = path.join(__dirname, "../../site");
const pages = fs.readdirSync(site).filter((f) => f.endsWith(".html"));

function internalRefs(html) {
  return [...html.matchAll(/(?:href|src)="([^"]+)"/g)]
    .map((m) => m[1])
    .filter((u) => !/^(https?:|mailto:|#|data:)/.test(u))
    .map((u) => u.split("#")[0])
    .filter(Boolean);
}

test("every page exists in English and Korean", () => {
  assert.deepEqual(pages.sort(), ["index.html", "ko.html", "manual-ko.html", "manual.html"]);
});

for (const page of pages) {
  test(`${page}: internal links and images exist`, () => {
    const html = fs.readFileSync(path.join(site, page), "utf8");
    for (const ref of internalRefs(html)) {
      const target = path.join(site, ref === "./" ? "index.html" : ref);
      assert.ok(fs.existsSync(target), `${page} → ${ref}`);
    }
  });

  test(`${page}: in-page anchors exist`, () => {
    const html = fs.readFileSync(path.join(site, page), "utf8");
    const ids = new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
    for (const m of html.matchAll(/href="#([^"]+)"/g)) {
      assert.ok(ids.has(m[1]), `${page} → #${m[1]}`);
    }
  });
}

test("manuals in both languages have the same sections", () => {
  const ids = (f) => [...fs.readFileSync(path.join(site, f), "utf8").matchAll(/<h2 id="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(ids("manual-ko.html"), ids("manual.html"));
});

test("CSS mask image exists", () => {
  const css = fs.readFileSync(path.join(site, "assets/style.css"), "utf8");
  for (const m of css.matchAll(/url\("([^"]+)"\)/g)) {
    assert.ok(fs.existsSync(path.join(site, "assets", m[1])), m[1]);
  }
});

test("every page loads the same Google Analytics tag first in <head>", () => {
  for (const page of pages) {
    const html = fs.readFileSync(path.join(site, page), "utf8");
    const head = html.slice(html.indexOf("<head>"), html.indexOf("</head>"));
    assert.match(head, /googletagmanager\.com\/gtag\/js\?id=G-FN8RPB2HYW/, page);
    assert.match(head, /gtag\('config', 'G-FN8RPB2HYW'\)/, page);
    assert.ok(head.indexOf("gtag/js") < head.indexOf("<title>"), `${page}: 태그는 <head> 맨 앞`);
    assert.match(html, /Google Analytics/, `${page}: 푸터 안내`);
  }
});
